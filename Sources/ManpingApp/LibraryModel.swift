import ManpingCore
import Foundation
import SwiftUI

@MainActor final class LibraryModel: ObservableObject {
  enum Mode: Equatable {
    case search(String, LibrarySearchType, LibrarySearchOrder)
    case space(SpaceArchiveQuery)
    case collections(Int64), collection(SpaceCollection, Bool)
    case following(Int64, Int64?), followers(Int64)
  }
  @Published private(set) var entries: [LibraryEntry] = []
  @Published private(set) var relatedUsers: [LibraryUser] = []
  @Published private(set) var collections: [SpaceCollection] = []
  @Published private(set) var overview: SpaceOverview?
  @Published private(set) var profileError: String?
  @Published private(set) var spacePage: SpaceArchivePage?
  @Published private(set) var playAllProgress = false
  @Published private(set) var playAllNotice: String?
  private struct PartialPlayback {
    let videos: [Video]
    let identity: AuthSnapshot
    let context: String
    let revision: UUID
  }
  @Published private var partialPlayback: PartialPlayback?
  var partialVideos: [Video] {
    guard let partialPlayback, partialPlayback.revision == generation,
      partialPlayback.context == playlistKey else { return [] }
    return partialPlayback.videos
  }
  @Published private(set) var users: [LibraryUser] = []
  @Published private(set) var groups: [LibraryGroup] = []
  @Published private(set) var profile: LibraryUser?
  @Published private(set) var isLoading = false
  @Published private(set) var hasMore = false
  @Published private(set) var error: String?
  @Published private(set) var total = 0
  @Published private(set) var selectionID: Int64?
  @Published private(set) var identityVersion = 0
  private let service: BiliService
  private let libraryRPC: LibraryRPCService?
  private let readIdentity: @Sendable () async -> AuthSnapshot
  private var identity: AuthIdentityEvent?
  private var identityTask: Task<Void, Never>?
  private var flight: Task<Void, Never>?
  private var generation = UUID()
  private var mode: Mode?
  private var nextPage = 1
  private var nextCursor: String?
  private var seenCursors = Set<String>()
  private var relatedFlight: Task<Void, Never>?
  private var profileFlight: Task<Void, Never>?
  private var playFlight: Task<Void, Never>?
  private var profileGeneration = UUID()
  private var profileMid: Int64?
  private var fallbackContext: String?
  private var fallbackUntil = Date.distantPast
  private var loadedIdentity: AuthSnapshot?


  convenience init(model: AppModel) {
    let installationID = InstallationIdentity.library
    let rpc: LibraryRPCService?
    if let transport = model.libraryRPCTransport {
      rpc = LibraryRPCService(auth: model.service, transport: transport, installationID: installationID)
    } else { rpc = try? LibraryRPCService(auth: model.service, installationID: installationID) }
    self.init(service: model.service, libraryRPC: rpc)
  }
  /// Injectable dependencies exercise the same paging and playback ownership used by the UI.
  init(service: BiliService, libraryRPC: LibraryRPCService? = nil, observeIdentity: Bool = true,
       readIdentity: (@Sendable () async -> AuthSnapshot)? = nil) {
    self.service = service; self.libraryRPC = libraryRPC
    self.readIdentity = readIdentity ?? { await service.authSnapshot() }
    guard observeIdentity else { return }
    let service = self.service
    identityTask = Task { [weak self] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let previous = self.identity
        self.identity = event
        let changed = previous.map { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision }
          ?? (self.mode != nil)
        if changed {
          var currentMode = self.mode
          if case .following(let mid, _) = currentMode { currentMode = .following(mid, nil) }
          self.profileGeneration = UUID(); self.profileFlight?.cancel(); self.profileFlight = nil
          self.profile = nil; self.overview = nil; self.profileMid = nil
          self.fallbackContext = nil; self.fallbackUntil = .distantPast
          self.clear()
          self.identityVersion += 1
          if let currentMode { await self.load(currentMode) }
        }
      }
    }
  }
  deinit { identityTask?.cancel(); flight?.cancel(); relatedFlight?.cancel(); profileFlight?.cancel(); playFlight?.cancel() }
  func cancel() {
    mode = nil
    generation = UUID(); flight?.cancel(); flight = nil; isLoading = false
    relatedFlight?.cancel(); relatedFlight = nil; relatedUsers = []
    playFlight?.cancel(); playFlight = nil; playAllProgress = false; playAllNotice = nil; partialPlayback = nil
  }
  private func clear() {
    cancel(); entries = []; users = []; groups = []; collections = []; spacePage = nil; nextCursor = nil; seenCursors = []
    selectionID = nil; error = nil; total = 0; nextPage = 1; hasMore = false
  }
  func load(_ mode: Mode) async {
    clear(); self.mode = mode; hasMore = true
    if PerformanceOptions.requested, case .search = mode {
      entries = PerformanceFixtures.videos.map { LibraryEntry.video($0) }
      total = entries.count; hasMore = false; return
    }
    if case .search(let term, .video, _) = mode, !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let revision = generation
      relatedFlight = Task { [weak self] in
        guard let self else { return }
        do {
          let identity = await service.authSnapshot()
          let result = try await service.searchUsers(term: term)
          try await checkIdentity(identity); try check(revision)
          relatedUsers = Array(result.items.prefix(8))
        } catch { if generation == revision { relatedUsers = [] } }
      }
    }
    await loadNext()
  }
  func refresh() async { if let mode { await load(mode) } }
  func loadNext() async {
    guard !isLoading, !playAllProgress, hasMore, let mode else { return }
    let revision = generation; let page = nextPage
    isLoading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let snapshot = await service.authSnapshot()
        let batch: LibraryPage<LibraryEntry>
        switch mode {
        case .search(let term, let type, let order):
          if type == .user {
            let result = try await service.searchUsers(term: term, page: page)
            try await checkIdentity(snapshot); try check(revision); appendUsers(result.items)
            batch = LibraryPage(items: [], hasMore: result.hasMore && !result.items.isEmpty, total: result.total)
          } else { batch = try await service.librarySearch(term, type: type, order: order, page: page) }
        case .space(var query):
          query.cursor = nextCursor
          if nextCursor == nil, fallbackContext == query.contextKey, Date() < fallbackUntil { query.provider = .appCursor }
          let result = try await archivePage(query)
          try await checkIdentity(snapshot); try check(revision)
          if result.restarted { entries = []; seenCursors = [] }
          if let cursor = result.nextCursor, !seenCursors.insert(cursor).inserted {
            throw BiliError.invalidResponse("Space cursor cycle")
          }
          if result.provider == .appCursor {
            var base = query; base.provider = nil
            fallbackContext = base.contextKey; fallbackUntil = Date().addingTimeInterval(120)
          }
          spacePage = result; nextCursor = result.nextCursor
          batch = LibraryPage(items: result.videos, hasMore: result.nextCursor != nil, total: result.total)
        case .collections(let mid):
          let result = try await service.spaceCollections(mid: mid, page: page)
          try await checkIdentity(snapshot); try check(revision)
          var seen = Set(collections.map(\.id)); collections += result.items.filter { seen.insert($0.id).inserted }
          batch = LibraryPage(items: [], hasMore: result.hasMore && !result.items.isEmpty, total: result.total)
        case .collection(let collection, let descending):
          batch = try await service.spaceCollectionContents(collection, descending: descending, page: page)
        case .following(let mid, let groupID):
          let snapshot = await service.authSnapshot()
          guard snapshot.token?.mid == mid else {
            throw BiliError.dependency("关注分组仅支持当前登录账号，请登录该账号后查看。")
          }
          if page == 1 {
            let fetched = try await service.libraryFollowGroups()
            try await checkIdentity(snapshot); try check(revision); groups = fetched
            selectionID = groupID.flatMap { selected in fetched.contains { $0.id == selected } ? selected : nil } ?? fetched.first?.id
          }
          guard let selectionID else {
            batch = LibraryPage(items: [], hasMore: false); break
          }
          let result = try await service.libraryFollowing(group: selectionID, page: page)
          try await checkIdentity(snapshot); try check(revision); appendUsers(result.items)
          batch = LibraryPage(items: [], hasMore: result.hasMore && !result.items.isEmpty, total: result.total)
        case .followers(let mid):
          let result = try await service.libraryFollowers(mid: mid, page: page)
          try await checkIdentity(snapshot); try check(revision); appendUsers(result.items)
          batch = LibraryPage(items: [], hasMore: result.hasMore && !result.items.isEmpty, total: result.total)
        }
        try await checkIdentity(snapshot); try check(revision); loadedIdentity = snapshot
        var known = Set(entries.map(\.id))
        entries += batch.items.filter { known.insert($0.id).inserted }
        total = batch.total; hasMore = batch.hasMore; nextPage += 1
      } catch is CancellationError {
      } catch {
        guard generation == revision else { return }
        switch error {
        case AuthFailure.needsLogin, BiliRPCError.needsLogin:
          self.error = "请先登录账号，再查看此页面。"
        default: self.error = error.localizedDescription
        }
      }
      guard generation == revision else { return }
      isLoading = false; flight = nil
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func retryFullSpace() async {
    fallbackContext = nil; fallbackUntil = .distantPast
    if case .space(var query) = mode { query.provider = nil; query.cursor = nil; await load(.space(query)) }
  }
  func loadSpaceProfile(mid: Int64, force: Bool = false) async {
    guard force || profileMid != mid || profile == nil || overview == nil else { return }
    profileFlight?.cancel(); profileGeneration = UUID(); let revision = profileGeneration
    if profileMid != mid { profile = nil; overview = nil }
    profileMid = mid; profileError = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let identity = await service.authSnapshot()
        let user = try await service.libraryProfile(mid: mid)
        try await checkIdentity(identity); try Task.checkCancellation()
        guard profileGeneration == revision else { return }
        profile = user
        let fetched = try await service.spaceOverview(mid: mid)
        try await checkIdentity(identity); try Task.checkCancellation()
        guard profileGeneration == revision else { return }
        overview = fetched
      } catch is CancellationError {} catch {
        if profileGeneration == revision { profileError = error.localizedDescription }
      }
    }
    profileFlight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func stopSpaceProfile() { profileGeneration = UUID(); profileFlight?.cancel(); profileFlight = nil }
  private func checkIdentity(_ expected: AuthSnapshot) async throws {
    let current = await readIdentity()
    guard current.epoch == expected.epoch, current.identityRevision == expected.identityRevision else { throw CancellationError() }
  }
  private func archivePage(_ query: SpaceArchiveQuery) async throws -> SpaceArchivePage {
    let rpc = libraryRPC
    return try await service.spaceArchives(query: query) { mid, keyword, page in
      guard let rpc else { throw BiliError.dependency("无法初始化投稿搜索服务") }
      return try await rpc.userVideos(mid: mid, keyword: keyword, page: page)
    }
  }
  func playAll(_ play: @escaping @MainActor (PlaylistHandoff) async -> Void) {
    guard !isLoading, !playAllProgress, playFlight == nil, let mode, let identity = loadedIdentity else { return }
    let revision = generation
    let service = service, rpc = libraryRPC, provider = spacePage?.provider
    playAllProgress = true; playAllNotice = nil; partialPlayback = nil
    playFlight = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await CursorPlaylistCollector.collect { cursor in
          let current = await service.authSnapshot()
          guard current.epoch == identity.epoch, current.identityRevision == identity.identityRevision else { throw CancellationError() }
          switch mode {
          case .space(var query):
            query.cursor = cursor; query.provider = cursor == nil ? provider : nil
            let page = try await service.spaceArchives(query: query) { mid, keyword, page in
              guard let rpc else { throw BiliError.dependency("无法初始化投稿搜索服务") }
              return try await rpc.userVideos(mid: mid, keyword: keyword, page: page)
            }
            try await self.acceptCollectedProvider(page, query: query, revision: revision, identity: identity)
            return CursorPlaylistPage(page: LibraryPage(items: page.videos, hasMore: page.nextCursor != nil, total: page.total), nextCursor: page.nextCursor, restarted: page.restarted)
          case .collection(let collection, let descending):
            let number = Int(cursor ?? "1") ?? 1
            let page = try await service.spaceCollectionContents(collection, descending: descending, page: number)
            return CursorPlaylistPage(page: page, nextCursor: page.hasMore ? String(number + 1) : nil)
          default: throw CancellationError()
          }
        }
        try await checkIdentity(identity); try check(revision)
        if result.complete, !result.videos.isEmpty {
          await play(handoff(result.videos, identity: identity, revision: revision, context: playlistKey, notice: result.notice))
        } else {
          let shown = entries.compactMap { entry -> Video? in
            if case .video(let video) = entry.destination { return video }; return nil
          }
          partialPlayback = PartialPlayback(
            videos: Array((shown.count > result.videos.count ? shown : result.videos).prefix(PlaylistCollector.defaultLimit)),
            identity: identity, context: playlistKey, revision: revision)
          playAllNotice = result.notice ?? "这个列表里没有可以播放的视频。"
        }
      } catch is CancellationError {} catch {
        let message = error.localizedDescription
        do { try await checkIdentity(identity); try check(revision) }
        catch {
          if generation == revision { playAllProgress = false; playFlight = nil }
          return
        }
        playAllNotice = message
      }
      if generation == revision { playAllProgress = false; playFlight = nil }
    }
  }
  private func acceptCollectedProvider(_ page: SpaceArchivePage, query: SpaceArchiveQuery,
    revision: UUID, identity: AuthSnapshot) async throws {
    try await checkIdentity(identity); try check(revision)
    guard page.provider != spacePage?.provider else { return }
    // A collection can hit risk control on a later page too. Reflect its actual source
    // on the page before a queue from that source can be handed to playback.
    entries = page.videos; spacePage = page; nextCursor = page.nextCursor
    seenCursors = Set(page.nextCursor.map { [$0] } ?? [])
    total = page.total; hasMore = page.nextCursor != nil
    if page.provider == .appCursor {
      var base = query; base.cursor = nil; base.provider = nil
      fallbackContext = base.contextKey; fallbackUntil = Date().addingTimeInterval(120)
    }
  }
  func playLoaded(_ play: @escaping @MainActor (PlaylistHandoff) async -> Void) {
    guard !isLoading, !playAllProgress, playFlight == nil,
      let partial = partialPlayback, !partial.videos.isEmpty,
      partial.revision == generation, partial.context == playlistKey else { return }
    let notice = playAllNotice
    playAllProgress = true
    playFlight = Task { [weak self] in
      guard let self else { return }
      do {
        try await checkIdentity(partial.identity); try check(partial.revision)
        guard playlistKey == partial.context else { throw CancellationError() }
        await play(handoff(partial.videos, identity: partial.identity, revision: partial.revision,
          context: partial.context, notice: notice))
      } catch is CancellationError {} catch {
        if generation == partial.revision { playAllNotice = error.localizedDescription }
      }
      if generation == partial.revision { playAllProgress = false; playFlight = nil }
    }
  }
  #if DEBUG
  var playbackTaskForChecks: Task<Void, Never>? { playFlight }
  #endif
  private var playlistKey: String { String(describing: mode) + ":" + (spacePage?.provider.rawValue ?? "") }
  private func handoff(_ videos: [Video], identity: AuthSnapshot, revision: UUID, context: String, notice: String?) -> PlaylistHandoff {
    PlaylistHandoff(videos: videos, identity: identity, notice: notice) { [weak self] in
      self?.generation == revision && self?.playlistKey == context
    }
  }
  private func check(_ revision: UUID) throws {
    try Task.checkCancellation()
    guard generation == revision else { throw CancellationError() }
  }
  private func appendUsers(_ incoming: [LibraryUser]) {
    var known = Set(users.map(\.id)); users += incoming.filter { known.insert($0.id).inserted }
  }
}
