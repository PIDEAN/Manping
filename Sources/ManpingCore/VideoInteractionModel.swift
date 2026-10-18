import Combine
import Foundation

/// One video and one account boundary own every state load, folder selection, and mutation.
@MainActor public final class VideoInteractionModel: ObservableObject {
  public typealias StateLoader = @Sendable (Int64, AuthSnapshot) async throws -> VideoOperationState
  @Published public private(set) var liked: Bool?
  @Published public private(set) var following: Bool?
  @Published public private(set) var favorited: Bool?
  @Published public private(set) var busy = false
  @Published public private(set) var stateLoading = false
  @Published public private(set) var stateError: String?
  @Published public private(set) var folders: [FavoriteFolder] = []
  @Published public var selectedFolderIDs: Set<Int64> = []
  @Published public var message: String?
  @Published public private(set) var identityGeneration = 0

  private let service: BiliService
  private let stateLoader: StateLoader
  private var source: VideoOperationStateSource?
  private var activeAid: Int64?
  private var generation = 0
  private var identity: AuthIdentityEvent?
  private var stateIdentity: AuthSnapshot?
  private var folderIdentity: AuthSnapshot?
  private var stateTask: Task<Void, Never>?
  private var stateRequest = UUID()
  private var operationTask: Task<Bool, Never>?
  private var identityTask: Task<Void, Never>?

  public init(service: BiliService, stateLoader: StateLoader? = nil) {
    self.service = service
    if let stateLoader { self.stateLoader = stateLoader }
    else {
      let source = VideoOperationStateSource(auth: service)
      self.source = source
      self.stateLoader = { aid, snapshot in try await source.load(aid: aid, expectedIdentity: snapshot) }
    }
    identityTask = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let previous = self.identity
        self.identity = event
        if let previous, previous.epoch != event.epoch || previous.identityRevision != event.identityRevision {
          self.identityGeneration &+= 1
          self.invalidate()
          self.refreshState()
        } else if previous == nil, let loaded = self.stateIdentity,
          loaded.epoch != event.epoch || loaded.identityRevision != event.identityRevision {
          self.identityGeneration &+= 1
          self.invalidate()
          self.refreshState()
        }
      }
    }
  }
  deinit { identityTask?.cancel(); stateTask?.cancel(); operationTask?.cancel() }

  public func reset(aid: Int64?) {
    guard activeAid != aid else { return }
    invalidate()
    activeAid = aid
    refreshState()
  }
  private func invalidate() {
    generation &+= 1
    stateRequest = UUID()
    stateTask?.cancel(); stateTask = nil
    operationTask?.cancel(); operationTask = nil
    liked = nil; following = nil; favorited = nil
    stateIdentity = nil; folderIdentity = nil
    folders = []; selectedFolderIDs = []
    busy = false; stateLoading = false; stateError = nil; message = nil
  }
  public func shutdown() {
    invalidate()
    activeAid = nil
    identityTask?.cancel(); identityTask = nil
    if let source { Task { await source.shutdown() } }
  }

  public func refreshState() { startStateLoad(preservingKnownState: false) }

  private func startStateLoad(preservingKnownState: Bool) {
    guard let aid = activeAid, aid > 0, !busy else { return }
    stateTask?.cancel()
    let request = generation
    let revision = UUID()
    stateRequest = revision
    stateLoading = true; stateError = nil
    let service = self.service
    let loader = stateLoader
    stateTask = Task { [weak self] in
      do {
        let initial = await service.authSnapshot()
        let snapshot = try await service.authorizeAppInteraction(expectedIdentity: initial)
        let state = try await loader(aid, snapshot)
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard let self, self.accepts(request, aid: aid), self.stateRequest == revision,
          Self.sameIdentity(snapshot, current) else { return }
        self.stateIdentity = snapshot
        if preservingKnownState {
          self.liked = self.liked ?? state.liked
          self.following = self.following ?? state.following
          self.favorited = self.favorited ?? state.favorited
        } else {
          self.liked = state.liked; self.following = state.following; self.favorited = state.favorited
        }
        self.stateLoading = false; self.stateTask = nil
      } catch {
        guard let self, self.accepts(request, aid: aid), self.stateRequest == revision else { return }
        self.stateLoading = false; self.stateTask = nil
        if !(error is CancellationError) {
          self.stateError = error.localizedDescription
        }
      }
    }
  }

  public func like(aid: Int64, requiresLogin: @escaping () -> Void = {}) async {
    guard let liked else { refreshState(); return }
    let target = !liked
    _ = await perform(aid: aid, requiresLogin: requiresLogin) { [service] snapshot in
      try await service.setVideoLiked(aid: aid, liked: target, expectedIdentity: snapshot)
    } success: { self.liked = target }
  }
  public func follow(mid: Int64, aid: Int64, requiresLogin: @escaping () -> Void = {}) async {
    guard mid > 0, let following else { refreshState(); return }
    let target = !following
    _ = await perform(aid: aid, requiresLogin: requiresLogin) { [service] snapshot in
      try await service.setFollowing(mid: mid, following: target, expectedIdentity: snapshot)
    } success: { self.following = target }
  }
  public func coin(aid: Int64, count: Int, alsoLike: Bool, requiresLogin: @escaping () -> Void = {}) async {
    guard (1...2).contains(count) else { return }
    _ = await perform(aid: aid, requiresLogin: requiresLogin) { [service] snapshot in
      try await service.coinVideo(aid: aid, count: count, alsoLike: alsoLike, expectedIdentity: snapshot)
    } success: {
      if alsoLike { self.liked = true }
      self.message = "已投 \(count) 枚硬币"
    }
  }
  public func triple(aid: Int64, requiresLogin: @escaping () -> Void = {}) async {
    _ = await perform(aid: aid, requiresLogin: requiresLogin) { [service] snapshot in
      try await service.tripleVideo(aid: aid, expectedIdentity: snapshot)
    } success: {
      self.liked = true; self.favorited = true
      self.message = "已完成点赞、投币和收藏"
    }
  }
  public func loadFolders(aid: Int64, requiresLogin: @escaping () -> Void = {}) async -> Bool {
    var loaded: [FavoriteFolder] = []
    var authorized: AuthSnapshot?
    return await perform(aid: aid, requiresLogin: requiresLogin) { [service] snapshot in
      loaded = try await service.favoriteFolders(aid: aid, expectedIdentity: snapshot)
      authorized = snapshot
    } success: {
      self.folderIdentity = authorized
      self.folders = loaded
      self.selectedFolderIDs = Set(loaded.filter(\.containsVideo).map(\.id))
      self.favorited = !self.selectedFolderIDs.isEmpty
    }
  }
  public func saveFolders(aid: Int64, requiresLogin: @escaping () -> Void = {}) async -> Bool {
    guard let folderIdentity else { return false }
    let original = Set(folders.filter(\.containsVideo).map(\.id))
    let valid = Set(folders.map(\.id))
    let chosen = selectedFolderIDs.intersection(valid)
    let add = Array(chosen.subtracting(original)).sorted()
    let remove = Array(original.subtracting(chosen)).sorted()
    return await perform(aid: aid, expectedIdentity: folderIdentity, requiresLogin: requiresLogin) { [service] snapshot in
      if !add.isEmpty || !remove.isEmpty {
        try await service.updateVideoFavorite(aid: aid, add: add, remove: remove, expectedIdentity: snapshot)
      }
    } success: {
      self.folders = self.folders.map { FavoriteFolder(id: $0.id, title: $0.title, containsVideo: chosen.contains($0.id)) }
      self.selectedFolderIDs = chosen; self.favorited = !chosen.isEmpty
    }
  }

  private func perform(
    aid: Int64, expectedIdentity: AuthSnapshot? = nil, requiresLogin: @escaping () -> Void,
    operation: @escaping @MainActor (AuthSnapshot) async throws -> Void,
    success: @escaping @MainActor () -> Void
  ) async -> Bool {
    guard aid > 0, activeAid == aid, !busy else { return false }
    let request = generation
    let expected = expectedIdentity ?? stateIdentity
    let observed = identity
    busy = true
    stateRequest = UUID()
    stateTask?.cancel(); stateTask = nil; stateLoading = false
    let service = self.service
    let task = Task { @MainActor [weak self] in
      var boundary = expected
      do {
        let initial = await service.authSnapshot()
        if let observed {
          guard observed.epoch == initial.epoch && observed.identityRevision == initial.identityRevision else { throw CancellationError() }
        }
        boundary = expected ?? initial
        let snapshot = try await service.authorizeAppInteraction(expectedIdentity: expected ?? initial)
        boundary = snapshot
        guard let self, self.accepts(request, aid: aid) else { return false }
        try await operation(snapshot)
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard self.accepts(request, aid: aid), Self.sameIdentity(snapshot, current) else { return false }
        success()
        self.busy = false; self.operationTask = nil
        self.completeMissingState(request: request, aid: aid, boundary: snapshot, current: current)
        return true
      } catch {
        let current = await service.authSnapshot()
        guard let self, self.accepts(request, aid: aid) else { return false }
        self.busy = false; self.operationTask = nil
        if !(error is CancellationError) {
          if let auth = error as? AuthFailure, case .needsLogin = auth { requiresLogin() }
          else { self.message = error.localizedDescription }
        }
        self.completeMissingState(request: request, aid: aid, boundary: boundary, current: current)
        return false
      }
    }
    operationTask = task
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func completeMissingState(request: Int, aid: Int64, boundary: AuthSnapshot?, current: AuthSnapshot) {
    guard accepts(request, aid: aid), !busy, !stateLoading,
      liked == nil || following == nil || favorited == nil,
      let boundary, Self.sameIdentity(boundary, current), current.state == .appAuthorized else { return }
    if let identity {
      guard identity.epoch == current.epoch && identity.identityRevision == current.identityRevision else { return }
    }
    startStateLoad(preservingKnownState: true)
  }

  private func accepts(_ request: Int, aid: Int64) -> Bool {
    request == generation && activeAid == aid
  }
  private static func sameIdentity(_ a: AuthSnapshot, _ b: AuthSnapshot) -> Bool {
    a.epoch == b.epoch && a.identityRevision == b.identityRevision
  }
}
