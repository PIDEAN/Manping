import ManpingCore
import Foundation
import SwiftUI

struct M4CommentTarget: Equatable, Sendable {
  let oid: Int64
  let type: Int32
  init?(dynamic: RPCDynamic) {
    guard let oid = Int64(dynamic.commentTargetID), oid > 0,
      [1, 11, 12, 14, 17, 33].contains(dynamic.commentTargetType) else { return nil }
    self.oid = oid; type = dynamic.commentTargetType
  }
  /// A video or a PGC episode's archive: `type` 1 with the aid.
  init?(oid: Int64, type: Int32) {
    guard oid > 0, [1, 11, 12, 14, 17, 33].contains(type) else { return nil }
    self.oid = oid; self.type = type
  }
}

@MainActor final class M4CommentModel: ObservableObject {
  @Published private(set) var target: M4CommentTarget?
  @Published private(set) var comments: [RPCComment] = []
  @Published private(set) var pinned: RPCComment?
  @Published private(set) var sort: RPCCommentSort = .hot
  @Published private(set) var loading = false
  @Published private(set) var isEnd = false
  @Published private(set) var error: String?
  @Published private(set) var thread: RPCComment?
  @Published private(set) var replies: [RPCComment] = []
  @Published private(set) var repliesLoading = false
  @Published private(set) var repliesEnd = false
  @Published private(set) var repliesError: String?
  @Published private(set) var busy = false
  @Published private(set) var mutationError: String?
  @Published private(set) var notice: String?
  @Published private(set) var replyingTo: String?
  @Published var draft = ""
  @Published private(set) var likedOverrides: [Int64: Bool] = [:]
  @Published private(set) var likeCounts: [Int64: Int64] = [:]
  @Published private(set) var canInteract = false
  private let auth: BiliService
  private let rpc: (any BiliRPCService)?
  private var generation = UUID()
  private var pageRevision = UUID()
  private var replyRevision = UUID()
  private var next: Int64 = 0
  private var replyNext: Int64 = 0
  private var targetIdentity: AuthSnapshot?
  private var identities: [Int64: AuthSnapshot] = [:]
  private var composeIdentity: AuthSnapshot?
  private var composeRoot: Int64 = 0
  private var composeParent: Int64 = 0
  private var pageTask: Task<Void, Never>?
  private var replyTask: Task<Void, Never>?
  private var mutation: Task<Void, Never>?
  private var observer: Task<Void, Never>?
  private var identity: AuthIdentityEvent?

  init(model: AppModel) {
    auth = model.service; rpc = try? model.standardRPCService()
    let auth = self.auth
    observer = Task { [weak self] in
      for await event in await auth.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let previous = self.identity; self.identity = event
        let changed = previous.map {
          $0.epoch != event.epoch || $0.identityRevision != event.identityRevision
        } ?? self.targetIdentity.map {
          $0.epoch != event.epoch || $0.identityRevision != event.identityRevision
        } ?? false
        if changed, let target = self.target {
          let sort = self.sort
          await self.select(target, sort: sort)
        }
      }
    }
  }
  deinit { observer?.cancel(); pageTask?.cancel(); replyTask?.cancel(); mutation?.cancel() }
  func cancel() {
    generation = UUID(); pageRevision = UUID(); replyRevision = UUID()
    pageTask?.cancel(); replyTask?.cancel(); mutation?.cancel()
    pageTask = nil; replyTask = nil; mutation = nil
    target = nil; comments = []; pinned = nil; thread = nil; replies = []
    next = 0; replyNext = 0; loading = false; repliesLoading = false; busy = false
    isEnd = false; repliesEnd = false; error = nil; repliesError = nil
    targetIdentity = nil; identities = [:]; likedOverrides = [:]; likeCounts = [:]
    mutationError = nil; notice = nil; canInteract = false; draft = ""; cancelReply()
  }
  func select(_ target: M4CommentTarget, sort: RPCCommentSort = .hot) async {
    cancel(); self.target = target; self.sort = sort
    await loadNext()
  }
  func setSort(_ sort: RPCCommentSort) async {
    guard !busy, self.sort != sort, let target else { return }
    await select(target, sort: sort)
  }
  func refresh() async {
    guard !busy, let target else { return }
    await select(target, sort: sort)
  }
  private func readIdentity() async throws -> AuthSnapshot {
    let initial = await auth.authSnapshot()
    do { return try await auth.authorizeAppInteraction(expectedIdentity: initial) }
    catch AuthFailure.needsLogin { return initial }
  }
  func loadNext() async {
    guard !loading, !isEnd, let target else { return }
    let revision = generation; let request = pageRevision; let cursor = next; let sort = self.sort
    loading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let rpc else { throw BiliError.dependency("无法初始化评论服务") }
        let snapshot = try await readIdentity()
        let page = try await rpc.comments(oid: target.oid, targetType: target.type, sort: sort, next: cursor)
        let current = await auth.authSnapshot()
        try Task.checkCancellation()
        guard generation == revision, pageRevision == request, self.target == target,
          sameIdentity(snapshot, current) else { throw CancellationError() }
        guard page.oid == target.oid, page.targetType == target.type else {
          throw BiliError.invalidResponse("Comment response target mismatch")
        }
        comments = Self.append(comments, page.comments)
        if let pinned = page.pinned { self.pinned = pinned; register(pinned, snapshot: current) }
        for comment in page.comments { register(comment, snapshot: current) }
        targetIdentity = current; canInteract = current.token != nil
        next = page.next; isEnd = page.isEnd || page.next <= cursor
      } catch is CancellationError {
      } catch {
        guard generation == revision, pageRevision == request else { return }
        self.error = error.localizedDescription
      }
      guard generation == revision, pageRevision == request else { return }
      loading = false; pageTask = nil
    }
    pageTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func openThread(_ comment: RPCComment) async {
    guard !busy else { return }
    closeThread(); thread = comment
    bindReply(comment)
    replies = comment.replies.filter { $0.id != comment.id }; repliesEnd = false
    await loadReplies()
  }
  func closeThread() {
    replyRevision = UUID(); replyTask?.cancel(); replyTask = nil
    thread = nil; replies = []; replyNext = 0; repliesEnd = false; repliesLoading = false; repliesError = nil
    cancelReply()
  }
  func loadReplies() async {
    guard !repliesLoading, !repliesEnd, let thread, let target else { return }
    let root = thread.root > 0 ? thread.root : thread.id
    let revision = generation; let request = replyRevision; let cursor = replyNext
    repliesLoading = true; repliesError = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let rpc else { throw BiliError.dependency("无法初始化评论服务") }
        let snapshot = try await readIdentity()
        let page = try await rpc.commentDetails(oid: target.oid, targetType: target.type,
          root: root, sort: .time, next: cursor)
        let current = await auth.authSnapshot()
        try Task.checkCancellation()
        guard generation == revision, replyRevision == request, self.target == target,
          self.thread?.id == thread.id, sameIdentity(snapshot, current) else { throw CancellationError() }
        guard page.oid == target.oid, page.targetType == target.type else {
          throw BiliError.invalidResponse("Reply response target mismatch")
        }
        replies = Self.append(replies, page.comments.filter { $0.id != root })
        for comment in page.comments { register(comment, snapshot: current) }
        if let pinned = page.pinned { register(pinned, snapshot: current) }
        replyNext = page.next; repliesEnd = page.isEnd || page.next <= cursor
      } catch is CancellationError {
      } catch {
        guard generation == revision, replyRevision == request else { return }
        repliesError = error.localizedDescription
      }
      guard generation == revision, replyRevision == request else { return }
      repliesLoading = false; replyTask = nil
    }
    replyTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func reply(to comment: RPCComment) {
    guard !busy else { return }
    bindReply(comment)
  }
  private func bindReply(_ comment: RPCComment) {
    guard let snapshot = identities[comment.id] else { return }
    composeRoot = comment.root > 0 ? comment.root : comment.id
    composeParent = comment.id; composeIdentity = snapshot; replyingTo = comment.author.name
  }
  func cancelReply() {
    composeRoot = 0; composeParent = 0; composeIdentity = nil; replyingTo = nil
    if let thread { bindReply(thread) }
  }
  func isLiked(_ comment: RPCComment) -> Bool { likedOverrides[comment.id] ?? comment.liked }
  func likeCount(_ comment: RPCComment) -> Int64 { likeCounts[comment.id] ?? comment.likes }
  func canLike(_ comment: RPCComment) -> Bool { !busy && identities[comment.id]?.token != nil }
  var canSend: Bool {
    !busy && targetIdentity?.token != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.count <= 1000 && (replyingTo == nil || composeIdentity != nil)
      && (thread == nil || (composeRoot > 0 && composeIdentity != nil))
  }
  func toggleLike(_ comment: RPCComment, requiresLogin: @escaping () -> Void) async {
    guard canLike(comment), let target, let expected = identities[comment.id] else { return }
    let liked = !isLiked(comment)
    await perform(expected: expected, requiresLogin: requiresLogin) { [auth] snapshot in
      try await auth.setCommentLiked(oid: target.oid, targetType: target.type,
        replyID: comment.id, liked: liked, expectedIdentity: snapshot)
    } success: {
      self.likedOverrides[comment.id] = liked
      self.likeCounts[comment.id] = max(0, self.likeCount(comment) + (liked ? 1 : -1))
    }
  }
  func send(requiresLogin: @escaping () -> Void) async {
    guard canSend, let target, let expected = composeIdentity ?? targetIdentity else { return }
    let message = draft; let root = composeRoot; let parent = composeParent
    let revision = generation
    await perform(expected: expected, requiresLogin: requiresLogin) { [auth] snapshot in
      try await auth.sendComment(message: message, oid: target.oid, targetType: target.type,
        root: root, parent: parent, expectedIdentity: snapshot)
    } success: {
      if self.draft == message { self.draft = "" }
      self.cancelReply()
      self.notice = "评论已发送"
    }
    // Refresh only after the guarded mutation reports success, within this caller's cancellation scope.
    guard generation == revision, notice == "评论已发送", self.target == target, !Task.isCancelled else { return }
    if thread != nil {
      replyRevision = UUID(); replyTask?.cancel(); replyTask = nil
      replies = []; replyNext = 0; repliesEnd = false; repliesLoading = false
      await loadReplies()
    } else {
      pageRevision = UUID(); pageTask?.cancel(); pageTask = nil
      comments = []; pinned = nil; next = 0; isEnd = false; loading = false
      await loadNext()
    }
  }
  private func perform(expected: AuthSnapshot, requiresLogin: @escaping () -> Void,
    operation: @escaping @Sendable (AuthSnapshot) async throws -> Void, success: @escaping () -> Void) async {
    guard !busy, target != nil else { return }
    let revision = generation; busy = true; mutationError = nil; notice = nil
    let task = Task { @MainActor [weak self, auth] in
      do {
        let snapshot = try await auth.authorizeAppInteraction(expectedIdentity: expected)
        try Task.checkCancellation()
        guard let self, self.generation == revision, self.sameIdentity(expected, snapshot) else {
          throw CancellationError()
        }
        try await operation(snapshot)
        let current = await auth.authSnapshot()
        try Task.checkCancellation()
        guard self.generation == revision, self.sameIdentity(snapshot, current) else { return }
        success(); self.busy = false; self.mutation = nil
      } catch {
        guard let self, self.generation == revision else { return }
        self.busy = false; self.mutation = nil
        if let value = error as? AuthFailure, case .needsLogin = value { requiresLogin() }
        else if !(error is CancellationError) { self.mutationError = error.localizedDescription }
      }
    }
    mutation = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func register(_ comment: RPCComment, snapshot: AuthSnapshot, depth: Int = 0) {
    guard comment.id > 0, depth <= 8 else { return }
    identities[comment.id] = snapshot
    for child in comment.replies { register(child, snapshot: snapshot, depth: depth + 1) }
  }
  private func sameIdentity(_ a: AuthSnapshot, _ b: AuthSnapshot) -> Bool {
    a.epoch == b.epoch && a.identityRevision == b.identityRevision && a.token?.mid == b.token?.mid
  }
  private static func append(_ existing: [RPCComment], _ incoming: [RPCComment]) -> [RPCComment] {
    var ids = Set(existing.map(\.id))
    return existing + incoming.filter { $0.id > 0 && ids.insert($0.id).inserted }
  }
}
