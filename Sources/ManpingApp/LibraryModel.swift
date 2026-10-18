import ManpingCore
import Foundation
import SwiftUI

@MainActor final class LibraryModel: ObservableObject {
  enum Mode: Equatable {
    case search(String, LibrarySearchType, LibrarySearchOrder)
    case space(Int64, String)
    case following(Int64, Int64?), followers(Int64)
  }
  @Published private(set) var entries: [LibraryEntry] = []
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
  private var identity: AuthIdentityEvent?
  private var identityTask: Task<Void, Never>?
  private var flight: Task<Void, Never>?
  private var generation = UUID()
  private var mode: Mode?
  private var nextPage = 1

  init(model: AppModel) {
    service = model.service
    let installationID = PerformanceEnvironment.defaults.string(forKey: "libraryInstallationID") ?? UUID().uuidString
    PerformanceEnvironment.defaults.set(installationID, forKey: "libraryInstallationID")
    if let transport = model.libraryRPCTransport {
      libraryRPC = LibraryRPCService(auth: model.service, transport: transport, installationID: installationID)
    } else { libraryRPC = try? LibraryRPCService(auth: model.service, installationID: installationID) }
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
          self.clear()
          self.identityVersion += 1
          if let currentMode { await self.load(currentMode) }
        }
      }
    }
  }
  deinit { identityTask?.cancel(); flight?.cancel() }
  func cancel() {
    generation = UUID(); flight?.cancel(); flight = nil; isLoading = false
  }
  private func clear() {
    cancel(); entries = []; users = []; groups = []; profile = nil
    selectionID = nil; error = nil; total = 0; nextPage = 1; hasMore = false
  }
  func load(_ mode: Mode) async {
    clear(); self.mode = mode; hasMore = true
    if PerformanceOptions.requested, case .search = mode {
      entries = PerformanceFixtures.videos.map { LibraryEntry.video($0) }
      total = entries.count; hasMore = false; return
    }
    await loadNext()
  }
  func refresh() async { if let mode { await load(mode) } }
  func loadNext() async {
    guard !isLoading, hasMore, let mode else { return }
    let revision = generation; let page = nextPage
    isLoading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let batch: LibraryPage<LibraryEntry>
        switch mode {
        case .search(let term, let type, let order):
          batch = try await service.librarySearch(term, type: type, order: order, page: page)
        case .space(let mid, let keyword):
          if page == 1 {
            let user = try await service.libraryProfile(mid: mid)
            try check(revision); profile = user
          }
          guard let libraryRPC else { throw BiliError.dependency("无法初始化用户空间服务") }
          batch = try await libraryRPC.userVideos(mid: mid, keyword: keyword, page: page)
        case .following(let mid, let groupID):
          let snapshot = await service.authSnapshot()
          guard snapshot.token?.mid == mid else {
            throw BiliError.dependency("关注分组仅支持当前登录账号，请登录该账号后查看。")
          }
          if page == 1 {
            let fetched = try await service.libraryFollowGroups()
            try check(revision); groups = fetched
            selectionID = groupID.flatMap { selected in fetched.contains { $0.id == selected } ? selected : nil } ?? fetched.first?.id
          }
          guard let selectionID else {
            batch = LibraryPage(items: [], hasMore: false); break
          }
          let result = try await service.libraryFollowing(group: selectionID, page: page)
          try check(revision); appendUsers(result.items)
          batch = LibraryPage(items: [], hasMore: result.hasMore && !result.items.isEmpty, total: result.total)
        case .followers(let mid):
          let result = try await service.libraryFollowers(mid: mid, page: page)
          try check(revision); appendUsers(result.items)
          batch = LibraryPage(items: [], hasMore: result.hasMore && !result.items.isEmpty, total: result.total)
        }
        try check(revision)
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
  private func check(_ revision: UUID) throws {
    try Task.checkCancellation()
    guard generation == revision else { throw CancellationError() }
  }
  private func appendUsers(_ incoming: [LibraryUser]) {
    var known = Set(users.map(\.id)); users += incoming.filter { known.insert($0.id).inserted }
  }
}
