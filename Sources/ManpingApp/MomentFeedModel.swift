import ManpingCore
import Foundation
import SwiftUI

enum MomentFeedSection: String, CaseIterable { case video = "视频", comprehensive = "综合" }

@MainActor final class MomentFeedModel: ObservableObject {
  @Published private(set) var section: MomentFeedSection
  @Published private(set) var selectedUserID: Int64?
  @Published private(set) var items: [RPCDynamic] = []
  @Published private(set) var users: [RPCDynamicProfile] = []
  @Published private(set) var readUsers: Set<Int64> = []
  @Published private(set) var loading = false
  @Published private(set) var hasMore = true
  @Published private(set) var error: String?
  @Published private(set) var mutationError: String?
  @Published private(set) var busy: Set<String> = []
  @Published private(set) var likedOverrides: [String: Bool] = [:]
  @Published private(set) var likeCounts: [String: Int64] = [:]
  @Published private(set) var identityVersion = 0
  private let auth: BiliService
  private let rpc: (any BiliRPCService)?
  private let operations: MomentOperationsService?
  private var offset = ""
  private var baseline = ""
  private var generation = UUID()
  private var stateIdentities: [String: AuthSnapshot] = [:]
  private var flight: Task<Void, Never>?
  private var writes: [String: Task<Void, Never>] = [:]
  private var observer: Task<Void, Never>?
  private var identity: AuthIdentityEvent?
  private var active = false

  init(model: AppModel) {
    auth = model.service; rpc = try? model.standardRPCService()
    section = MomentFeedSection(rawValue: PerformanceEnvironment.defaults.string(forKey: "moment.lastSection") ?? "") ?? .video
    if let transport = model.libraryRPCTransport {
      operations = MomentOperationsService(auth: model.service, transport: transport, installationID: "ui-fixture")
    } else {
      let installationID = InstallationIdentity.rpc
      operations = try? MomentOperationsService(auth: model.service, installationID: installationID)
    }
    let auth = self.auth
    observer = Task { [weak self] in
      for await event in await auth.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let previous = self.identity; self.identity = event
        let changed = previous.map {
          $0.epoch != event.epoch || $0.identityRevision != event.identityRevision
        } ?? self.stateIdentities.values.contains {
          $0.epoch != event.epoch || $0.identityRevision != event.identityRevision
        }
        if changed {
          let wasActive = self.active
          self.reset(clearUsers: true); self.selectedUserID = nil; self.readUsers = []
          self.identityVersion += 1
          if wasActive { self.active = true; await self.loadNext() }
        }
      }
    }
  }
  deinit {
    observer?.cancel(); flight?.cancel()
    for task in writes.values { task.cancel() }
    if let operations { Task { await operations.shutdown() } }
  }
  func cancel() {
    active = false; generation = UUID(); flight?.cancel(); flight = nil; loading = false
    for task in writes.values { task.cancel() }
    writes = [:]; busy = []; stateIdentities = [:]
  }
  private func reset(clearUsers: Bool) {
    cancel(); items = []; offset = ""; baseline = ""; hasMore = true
    error = nil; mutationError = nil; likedOverrides = [:]; likeCounts = [:]
    if clearUsers { users = [] }
  }
  func start(section: MomentFeedSection? = nil) async {
    if let section { self.section = section }
    reset(clearUsers: true); selectedUserID = nil; active = true
    await loadNext()
  }
  func select(section: MomentFeedSection) async {
    guard self.section != section else { return }
    reset(clearUsers: true); self.section = section; selectedUserID = nil; active = true
    PerformanceEnvironment.defaults.set(section.rawValue, forKey: "moment.lastSection")
    await loadNext()
  }
  func selectUser(_ mid: Int64?) async {
    guard section == .comprehensive, selectedUserID != mid,
      mid == nil || users.contains(where: { $0.id == mid }) else { return }
    reset(clearUsers: false); selectedUserID = mid; active = true
    await loadNext()
    if let mid, error == nil { readUsers.insert(mid) }
  }
  func refresh() async {
    let refreshUsers = selectedUserID == nil
    reset(clearUsers: refreshUsers); active = true
    await loadNext()
  }
  func loadNext() async {
    guard active, !loading, hasMore else { return }
    let revision = generation; let offset = self.offset; let baseline = self.baseline
    let section = self.section; let mid = selectedUserID
    loading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let rpc else { throw BiliError.dependency("无法初始化动态服务") }
        let initial = await auth.authSnapshot()
        let snapshot = try await auth.authorizeAppInteraction(expectedIdentity: initial)
        let query: RPCDynamicQuery = mid.map { .userAll(mid: $0, offset: offset) }
          ?? (section == .video ? .video(offset: offset, baseline: baseline) : .all(offset: offset, baseline: baseline))
        let page = try await rpc.dynamics(query)
        let current = await auth.authSnapshot()
        try Task.checkCancellation()
        guard generation == revision, sameIdentity(snapshot, current) else { throw CancellationError() }
        var known = Set(items.map(\.id))
        let incoming = page.items.filter {
          guard !$0.id.isEmpty else { return false }
          if section == .video && mid == nil {
            switch $0.content { case .video, .episode: break; default: return false }
          }
          return known.insert($0.id).inserted
        }
        items += incoming
        for item in incoming { stateIdentities[item.id] = current }
        if mid == nil && offset.isEmpty {
          var userIDs = Set<Int64>()
          users = page.users.filter { $0.id > 0 && userIDs.insert($0.id).inserted }
        }
        self.offset = page.historyOffset; self.baseline = page.updateBaseline
        hasMore = page.hasMore && !page.historyOffset.isEmpty && page.historyOffset != offset
      } catch is CancellationError {
      } catch {
        guard generation == revision else { return }
        self.error = Self.message(error)
      }
      guard generation == revision else { return }
      loading = false; flight = nil
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func isLiked(_ item: RPCDynamic) -> Bool { likedOverrides[item.id] ?? item.liked }
  func likeCount(_ item: RPCDynamic) -> Int64 { likeCounts[item.id] ?? item.likes }
  func canLike(_ item: RPCDynamic) -> Bool {
    (Int64(item.id) ?? 0) > 0 && (item.author?.mid ?? 0) > 0 && operations != nil
      && stateIdentities[item.id]?.token != nil && !busy.contains(item.id)
  }
  func toggleLike(_ item: RPCDynamic, requiresLogin: @escaping () -> Void) async {
    guard canLike(item), let dynamicID = Int64(item.id), let authorID = item.author?.mid,
      let expected = stateIdentities[item.id], let operations else { return }
    let revision = generation; let target = !isLiked(item)
    busy.insert(item.id); mutationError = nil
    let task = Task { @MainActor [weak self, auth] in
      do {
        let snapshot = try await auth.authorizeAppInteraction(expectedIdentity: expected)
        try Task.checkCancellation()
        guard let self, self.generation == revision, self.sameIdentity(expected, snapshot) else {
          throw CancellationError()
        }
        try await operations.setLiked(dynamicID: dynamicID, authorID: authorID,
          liked: target, expectedIdentity: snapshot)
        let current = await auth.authSnapshot()
        try Task.checkCancellation()
        guard self.generation == revision, self.sameIdentity(snapshot, current) else { return }
        self.likedOverrides[item.id] = target
        self.likeCounts[item.id] = max(0, self.likeCount(item) + (target ? 1 : -1))
        self.stateIdentities[item.id] = snapshot
        self.busy.remove(item.id); self.writes[item.id] = nil
      } catch {
        guard let self, self.generation == revision else { return }
        self.busy.remove(item.id); self.writes[item.id] = nil
        if Self.needsLogin(error) { requiresLogin() }
        else if !(error is CancellationError) { self.mutationError = Self.message(error) }
      }
    }
    writes[item.id] = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func sameIdentity(_ a: AuthSnapshot, _ b: AuthSnapshot) -> Bool {
    a.epoch == b.epoch && a.identityRevision == b.identityRevision && a.token?.mid == b.token?.mid
  }
  private static func needsLogin(_ error: Error) -> Bool {
    if let value = error as? AuthFailure, case .needsLogin = value { return true }
    if let value = error as? BiliRPCError, case .needsLogin = value { return true }
    return false
  }
  private static func message(_ error: Error) -> String {
    needsLogin(error) ? "请先登录账号，再查看或操作动态。" : error.localizedDescription
  }
}
