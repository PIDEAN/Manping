import ManpingCore
import Foundation
import SwiftUI

@MainActor final class CollectionActionsModel: ObservableObject {
  enum Page { case favorites, later }
  enum Section: Equatable {
    case folder(Int64), anime, cinema
    var key: String {
      switch self { case .folder(let id): "folder:\(id)"; case .anime: "anime"; case .cinema: "cinema" }
    }
  }
  struct PendingAction {
    fileprivate let entries: [LibraryEntry]
    fileprivate let identity: AuthSnapshot
    fileprivate let section: Section
    fileprivate let status: Int
    fileprivate let folder: LibraryFolder?
    fileprivate let generation: UUID
    let clearsAll: Bool
    let isPGC: Bool
    var count: Int { entries.count }
  }
  @Published private(set) var entries: [LibraryEntry] = []
  @Published private(set) var folders: [LibraryFolder] = []
  @Published private(set) var section: Section = .anime
  @Published private(set) var status = 2
  @Published private(set) var total = 0
  @Published private(set) var hasMore = false
  @Published private(set) var hasMoreFolders = false
  @Published private(set) var isLoading = false
  @Published private(set) var isLoadingFolders = false
  @Published private(set) var isMutating = false
  @Published private(set) var error: String?
  @Published private(set) var actionError: String?
  @Published private(set) var selectedIDs = Set<String>()
  @Published private(set) var isSelecting = false
  @Published private(set) var identityVersion = 0
  @Published private(set) var actionContextGeneration = UUID()
  private(set) var loadedIdentity: AuthSnapshot?
  let page: Page
  private let service: BiliService
  private var identityTask: Task<Void, Never>?
  private var readTask: Task<Void, Never>?
  private var folderTask: Task<Void, Never>?
  private var actionTask: Task<Void, Never>?
  private var generation = UUID()
  private var actionGeneration = UUID()
  private var pendingReadIdentity: AuthSnapshot?
  private var nextPage = 1
  private var nextFolderPage = 2
  private var active = false

  init(model: AppModel, page: Page) {
    service = model.service; self.page = page
    let service = self.service
    identityTask = Task { [weak self] in
      var previous: AuthIdentityEvent?
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let expected = self.pendingReadIdentity ?? self.loadedIdentity
        let observedChange = previous.map { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision } ?? false
        let readMismatch = expected.map { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision } ?? false
        let changed = observedChange || readMismatch
        previous = event
        if changed {
          self.cancel(); self.entries = []; self.folders = []; self.total = 0
          self.loadedIdentity = nil; self.hasMore = false; self.hasMoreFolders = false
          self.section = .anime; self.status = 2; self.error = nil; self.actionError = nil
          self.selectedIDs = []; self.isSelecting = false; self.identityVersion += 1
          if self.active { await self.refresh() }
        }
      }
    }
  }
  deinit { identityTask?.cancel(); readTask?.cancel(); folderTask?.cancel(); actionTask?.cancel() }

  var selectedFolder: LibraryFolder? {
    guard case .folder(let id) = section else { return nil }
    return folders.first { $0.id == id }
  }
  var isPGC: Bool { page == .favorites && selectedFolder == nil }
  var canRemove: Bool {
    if page == .later || isPGC { return true }
    guard let folder = selectedFolder else { return false }
    return !folder.isSeason && folder.group == "我创建的"
  }
  var title: String {
    if page == .later { return "稍后再看" }
    if let folder = selectedFolder { return folder.title }
    return section == .cinema ? "我的追剧" : "我的追番"
  }
  var loadedVideos: [Video] {
    entries.compactMap { if case .video(let video) = $0.destination { video } else { nil } }
  }
  var removableSelected: [LibraryEntry] { entries.filter { selectedIDs.contains($0.id) && removable($0) } }
  func removable(_ entry: LibraryEntry) -> Bool {
    guard canRemove else { return false }
    if isPGC { return seasonID(entry) != nil }
    if case .video(let video) = entry.destination { return (video.aid ?? 0) > 0 }
    return false
  }
  func start() async { active = true; await refresh() }
  func stop() { active = false; cancel() }
  func cancel() {
    actionContextGeneration = UUID()
    generation = UUID(); actionGeneration = UUID()
    readTask?.cancel(); folderTask?.cancel(); actionTask?.cancel()
    readTask = nil; folderTask = nil; actionTask = nil
    pendingReadIdentity = nil
    isLoading = false; isLoadingFolders = false; isMutating = false
    resetPlayAll()
  }

  // MARK: 全部播放

  /// Starts a collected list playing; returns whether it started. It must confirm the
  /// hand-off (`PlaylistHandoff.confirm`) after its last wait and before changing the queue.
  typealias PlayHandler = @MainActor (PlaylistHandoff) async -> Bool
  /// 全部播放 could not read the list to the end (the videos read so far can still be played),
  /// or the list holds nothing playable. Bound to the list and account it was read from. A list
  /// cut short at the limit is said beside the player instead, with the queue it started.
  struct PlayAllNotice {
    let message: String
    let videos: [Video]
    let identity: AuthSnapshot
    let context: PlaylistContext
  }
  /// Videos gathered so far while 全部播放 reads the whole list (and until the list is handed
  /// to playback); nil when it is not reading.
  @Published private(set) var playAllProgress: Int?
  @Published private var playAllNoticeStorage: PlayAllNotice?
  /// The read, or the hand-off of what it (or a failed read) gathered. Owned until playback
  /// started: cancelling it before then (the list, its contents, the account or the page
  /// changed) keeps the list from playing; once playback started it is not undone.
  private var playAllTask: Task<Void, Never>?
  private var playAllGeneration = UUID()

  /// The notice for the list shown now; a notice read from another list or account is never shown.
  var playAllNotice: PlayAllNotice? {
    guard let notice = playAllNoticeStorage, notice.context == currentPlaylistContext else { return nil }
    return notice
  }
  /// The list on screen and the account it was loaded for; nil when nothing is loaded.
  private var currentPlaylistContext: PlaylistContext? {
    guard let loadedIdentity else { return nil }
    return PlaylistContext(list: page == .later ? "later" : section.key, identity: loadedIdentity)
  }

  /// Reads every page of the list shown now (at most `PlaylistCollector.defaultLimit` videos),
  /// independently of what was scrolled, then hands the whole list to `play`. A longer list
  /// plays its first part and the player says so; a failure keeps what was read in a notice,
  /// so the page can offer to play that part instead.
  func playAll(_ play: @escaping PlayHandler) {
    guard active, playAllProgress == nil, !isMutating, !isPGC, selectedFolder?.isSeason != true,
      let identity = loadedIdentity, let context = currentPlaylistContext else { return }
    resetPlayAll()
    let revision = playAllGeneration, section = self.section, folder = selectedFolder
    playAllProgress = 0
    playAllTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var collected: [Video] = []
      do {
        let sourcePage = self.page, service = self.service
        let result = try await CursorPlaylistCollector.collect(progress: { [weak self] count in
          await self?.updatePlayAllProgress(count, revision: revision)
        }) { cursor in
          let number = Int(cursor ?? "1") ?? 1
          let batch: LibraryPage<LibraryEntry>
          if sourcePage == .later {
            batch = try await service.collectionViewLater(page: number, expectedIdentity: identity)
          } else if let folder {
            batch = try await service.collectionContents(folder: folder, page: number, expectedIdentity: identity)
          } else { throw CancellationError() }
          return CursorPlaylistPage(page: batch, nextCursor: batch.hasMore ? String(number + 1) : nil)
        }
        collected = result.videos
        try await checkPlayAll(revision, section: section, identity: identity)
        guard result.complete else { throw BiliError.dependency(result.notice ?? "没能加载完整列表") }
        guard !collected.isEmpty else {
          finishPlayAll(revision)
          playAllNoticeStorage = PlayAllNotice(message: "这个列表里没有可以播放的视频。",
            videos: [], identity: identity, context: context)
          return
        }
        // The task stays the owner while the list is handed over: a cancel before the queue
        // changes still stops it (the hand-off checks this read and list once more right before).
        _ = await play(makeHandoff(collected, identity: identity, context: context,
          revision: revision, notice: result.notice))
        finishPlayAll(revision)
      } catch is CancellationError {
        finishPlayAll(revision)
      } catch {
        // A read for another list or account that failed late is dropped, never kept.
        guard playAllGeneration == revision else { return }
        finishPlayAll(revision)
        guard currentPlaylistContext == context else { return }
        // Whatever is longer: the pages read just now, or the rows already on screen.
        let shown = loadedVideos
        let fallback = collected.count >= shown.count ? collected : shown
        let limit = PlaylistCollector.defaultLimit
        let capped = fallback.count > limit ? "（最多播放前 \(limit) 个）" : ""
        playAllNoticeStorage = PlayAllNotice(message: "没能加载完整列表：\(message(error))\(capped)",
          videos: Array(fallback.prefix(limit)), identity: identity, context: context)
      }
    }
  }
  private func updatePlayAllProgress(_ count: Int, revision: UUID) {
    guard playAllGeneration == revision else { return }
    playAllProgress = count
  }
  /// 播放已加载的 N 个: plays what a failed read gathered, only while the page is shown and
  /// still shows the list (and account) it was read from; otherwise the notice is dropped.
  /// Owned like a read: leaving the list or the page before playback starts cancels it.
  func playLoaded(_ play: @escaping PlayHandler) {
    guard active, playAllProgress == nil, playAllTask == nil, let notice = playAllNotice, !notice.videos.isEmpty else {
      playAllNoticeStorage = nil; return
    }
    resetPlayAll()
    let revision = playAllGeneration
    let handoff = makeHandoff(notice.videos, identity: notice.identity, context: notice.context,
      revision: revision, notice: nil)
    playAllTask = Task { @MainActor [weak self] in
      _ = await play(handoff)
      self?.finishPlayAll(revision)
    }
  }
  func dismissPlayAllNotice() { playAllNoticeStorage = nil }
  /// The hand-off of a list read as `revision` from `context`: still current only while that
  /// read was not replaced or cancelled, the page is shown and it still shows that list.
  private func makeHandoff(_ videos: [Video], identity: AuthSnapshot, context: PlaylistContext,
    revision: UUID, notice: String?) -> PlaylistHandoff {
    PlaylistHandoff(videos: videos, identity: identity, notice: notice) { [weak self] in
      guard let self else { return false }
      return self.active && self.playAllGeneration == revision && self.currentPlaylistContext == context
    }
  }
  /// The read or hand-off `revision` is over; a newer one is left alone.
  private func finishPlayAll(_ revision: UUID) {
    guard playAllGeneration == revision else { return }
    playAllProgress = nil; playAllTask = nil
  }
  /// Stops a running read and forgets its notice: the list, its contents or the account changed.
  private func resetPlayAll() {
    cancelPlayAll(); playAllNoticeStorage = nil
  }
  private func cancelPlayAll() {
    playAllGeneration = UUID(); playAllTask?.cancel(); playAllTask = nil; playAllProgress = nil
  }
  private func checkPlayAll(_ revision: UUID, section: Section, identity: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    guard playAllGeneration == revision, self.section == section, Self.same(current, identity) else { throw CancellationError() }
  }
  func cancelAction() {
    actionContextGeneration = UUID()
    actionGeneration = UUID(); actionTask?.cancel(); actionTask = nil; isMutating = false
  }
  func toggleSelectionMode() {
    guard !isMutating else { return }
    isSelecting.toggle(); if !isSelecting { selectedIDs = [] }
  }
  func toggle(_ entry: LibraryEntry) {
    guard !isMutating, removable(entry) else { return }
    if !selectedIDs.insert(entry.id).inserted { selectedIDs.remove(entry.id) }
  }
  func selectAllLoaded() {
    guard !isMutating else { return }
    let ids = Set(entries.filter(removable).map(\.id))
    selectedIDs = selectedIDs == ids ? [] : ids
  }
  func dismissActionError() { actionError = nil }

  func refresh() async {
    guard !isMutating else { return }
    cancel(); let revision = generation
    isLoading = true; error = nil; actionError = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let expected = await service.authSnapshot()
        pendingReadIdentity = expected
        let authorized = try await service.authorizeAppInteraction(expectedIdentity: expected)
        try await check(revision, identity: authorized)
        if page == .favorites {
          let fetched = try await service.libraryFolders()
          try await check(revision, identity: authorized)
          let sameIdentity = loadedIdentity.map { Self.same($0, authorized) } ?? false
          let restored = sameIdentity ? section : restoredSection(identity: authorized)
          folders = fetched
          hasMoreFolders = fetched.filter { $0.group == "我收藏的" && !$0.isSeason }.count >= 20
          nextFolderPage = 2
          // Restore a collected folder beyond page one within this account only.
          while !valid(restored, folders: folders), hasMoreFolders {
            let batch = try await service.collectionFolders(page: nextFolderPage, expectedIdentity: authorized)
            try await check(revision, identity: authorized)
            var known = Set(folders.map(\.id))
            folders += batch.items.filter { known.insert($0.id).inserted }
            hasMoreFolders = batch.hasMore && !batch.items.isEmpty; nextFolderPage += 1
          }
          section = valid(restored, folders: folders) ? restored : .anime
        }
        loadedIdentity = authorized
        let batch = try await fetch(page: 1)
        try await check(revision, identity: authorized)
        entries = deduplicated(batch.items); total = batch.total
        hasMore = batch.hasMore && !batch.items.isEmpty; nextPage = 2
        loadedIdentity = authorized
        selectedIDs.formIntersection(Set(entries.map(\.id)))
      } catch is CancellationError {
      } catch {
        if generation == revision { self.error = message(error) }
      }
      if generation == revision { isLoading = false; readTask = nil; pendingReadIdentity = nil }
    }
    readTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  func select(_ selected: Section) async {
    guard loadedIdentity != nil, !isMutating, section != selected, valid(selected, folders: folders) else { return }
    section = selected; status = 2
    if let loadedIdentity, let mid = loadedIdentity.token?.mid {
      PerformanceEnvironment.defaults.set(selected.key, forKey: "m3FavoriteSection.\(mid)")
    }
    await reloadEntries()
  }
  func selectStatus(_ value: Int) async {
    guard loadedIdentity != nil, isPGC, !isMutating, (1...3).contains(value), status != value else { return }
    status = value; await reloadEntries()
  }
  private func reloadEntries() async {
    actionContextGeneration = UUID()
    resetPlayAll()
    generation = UUID(); readTask?.cancel(); folderTask?.cancel(); folderTask = nil; isLoadingFolders = false
    pendingReadIdentity = nil
    isLoading = false
    entries = []; selectedIDs = []; isSelecting = false; total = 0; error = nil; actionError = nil
    nextPage = 1; hasMore = true
    await loadNext()
  }
  func loadNext() async {
    guard !isLoading, !isMutating, hasMore, let expected = loadedIdentity else { return }
    let revision = generation; let pageNumber = nextPage
    isLoading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await check(revision, identity: expected)
        let batch = try await fetch(page: pageNumber)
        try await check(revision, identity: expected)
        entries = deduplicated(entries + batch.items); total = batch.total
        hasMore = batch.hasMore && !batch.items.isEmpty; nextPage += 1
      } catch is CancellationError {
      } catch { if generation == revision { self.error = message(error) } }
      if generation == revision { isLoading = false; readTask = nil }
    }
    readTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func loadMoreFolders() async {
    guard !isLoadingFolders, !isMutating, hasMoreFolders, let expected = loadedIdentity else { return }
    let revision = generation; let pageNumber = nextFolderPage
    isLoadingFolders = true
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let batch = try await service.collectionFolders(page: pageNumber, expectedIdentity: expected)
        try await check(revision, identity: expected)
        var known = Set(folders.map(\.id))
        folders += batch.items.filter { known.insert($0.id).inserted }
        hasMoreFolders = batch.hasMore && !batch.items.isEmpty; nextFolderPage += 1
      } catch is CancellationError {
      } catch { if generation == revision { self.error = message(error) } }
      if generation == revision { isLoadingFolders = false; folderTask = nil }
    }
    folderTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  func prepareRemoval(_ requested: [LibraryEntry]) -> PendingAction? {
    guard !isMutating, !isLoading, !isLoadingFolders, let identity = loadedIdentity else { return nil }
    let ids = Set(requested.map(\.id))
    let removing = entries.filter { ids.contains($0.id) && removable($0) }
    guard !removing.isEmpty, removing.count == ids.count else { return nil }
    return PendingAction(entries: removing, identity: identity, section: section, status: status,
      folder: selectedFolder, generation: actionContextGeneration, clearsAll: false, isPGC: isPGC)
  }
  func prepareClearAll() -> PendingAction? {
    guard page == .later, !entries.isEmpty, !isMutating, !isLoading, !isLoadingFolders,
      let identity = loadedIdentity else { return nil }
    return PendingAction(entries: entries, identity: identity, section: section, status: status,
      folder: nil, generation: actionContextGeneration, clearsAll: true, isPGC: false)
  }
  func perform(_ action: PendingAction) async {
    guard !isMutating, !isLoading, !isLoadingFolders, accepts(action) else { return }
    let expected = action.identity
    let removing = action.entries
    let clearAll = action.clearsAll
    let revision = actionGeneration
    isMutating = true; actionError = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await checkAction(revision, action: action)
        _ = try await service.authorizeAppInteraction(expectedIdentity: expected)
        try await checkAction(revision, action: action)
        if clearAll { try await service.clearViewLater(expectedIdentity: expected) }
        else if page == .later {
          try await service.removeViewLater(aids: aids(removing), expectedIdentity: expected)
        } else if case .folder(let folderID) = action.section {
          guard let folder = action.folder, !folder.isSeason, folder.group == "我创建的" else { throw CancellationError() }
          try await service.removeFavoriteVideos(folderID: folderID, aids: aids(removing), expectedIdentity: expected)
        } else {
          for entry in removing {
            try await checkAction(revision, action: action)
            guard let id = seasonID(entry) else { throw BiliError.invalidResponse("Invalid favorite season") }
            try await service.removeFavoritePGC(seasonID: id, expectedIdentity: expected)
          }
        }
        try await checkAction(revision, action: action)
        let removedIDs = Set(removing.map(\.id))
        entries.removeAll { clearAll || removedIDs.contains($0.id) }
        selectedIDs.subtract(removedIDs)
        actionContextGeneration = UUID()
        // The list changed: a running 全部播放 read or its fallback could still hold removed videos.
        resetPlayAll()
        total = clearAll ? 0 : max(0, total - removing.count)
        if clearAll { hasMore = false }
        else {
          // Offset pages shift by the number of deleted rows. Revisit that many
          // pages and deduplicate existing rows rather than skip the boundary.
          let pageSize = page == .later ? 40 : 20
          let shiftedPages = (removing.count + pageSize - 1) / pageSize
          nextPage = max(1, nextPage - shiftedPages)
        }
      } catch is CancellationError {
      } catch { if actionGeneration == revision { actionError = message(error) } }
      if actionGeneration == revision { isMutating = false; actionTask = nil }
    }
    actionTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func fetch(page: Int) async throws -> LibraryPage<LibraryEntry> {
    guard let expected = loadedIdentity else { throw CancellationError() }
    if self.page == .later { return try await service.collectionViewLater(page: page, expectedIdentity: expected) }
    if let folder = selectedFolder { return try await service.collectionContents(folder: folder, page: page, expectedIdentity: expected) }
    return try await service.libraryPGC(cinema: section == .cinema, status: status, page: page)
  }
  private func check(_ revision: UUID, identity: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    guard generation == revision, Self.same(current, identity) else { throw CancellationError() }
    try Task.checkCancellation()
  }
  private func accepts(_ action: PendingAction) -> Bool {
    guard actionContextGeneration == action.generation, section == action.section, status == action.status,
      let loadedIdentity, Self.same(loadedIdentity, action.identity), selectedFolder == action.folder else { return false }
    if action.clearsAll { return page == .later }
    return action.entries.allSatisfy { entries.contains($0) && removable($0) }
  }
  private func checkAction(_ revision: UUID, action: PendingAction) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    guard actionGeneration == revision, accepts(action), Self.same(current, action.identity) else { throw CancellationError() }
    try Task.checkCancellation()
  }
  private static func same(_ a: AuthSnapshot, _ b: AuthSnapshot) -> Bool {
    a.epoch == b.epoch && a.identityRevision == b.identityRevision
  }
  private func deduplicated(_ incoming: [LibraryEntry]) -> [LibraryEntry] {
    var known = Set<String>(); return incoming.filter { known.insert($0.id).inserted }
  }
  private func aids(_ items: [LibraryEntry]) -> [Int64] {
    items.compactMap { if case .video(let video) = $0.destination { video.aid } else { nil } }
  }
  private func seasonID(_ entry: LibraryEntry) -> Int64? {
    guard entry.id.hasPrefix("season"), let id = Int64(entry.id.dropFirst(6)), id > 0 else { return nil }
    return id
  }
  private func valid(_ selection: Section, folders: [LibraryFolder]) -> Bool {
    if case .folder(let id) = selection { return folders.contains { $0.id == id } }
    return true
  }
  private func restoredSection(identity: AuthSnapshot) -> Section {
    guard let mid = identity.token?.mid, let key = PerformanceEnvironment.defaults.string(forKey: "m3FavoriteSection.\(mid)") else { return .anime }
    if key == "cinema" { return .cinema }
    if key == "anime" { return .anime }
    if key.hasPrefix("folder:"), let id = Int64(key.dropFirst(7)), id > 0 { return .folder(id) }
    return .anime
  }
  private func message(_ error: Error) -> String {
    if case AuthFailure.needsLogin = error { return "请先登录账号，再查看此页面。" }
    return error.localizedDescription
  }
}
