import ManpingCore
import Foundation
import SwiftUI

enum MessageMarkReadState: Equatable {
  case idle, running(completed: Int), completed, partialFailure(String)
  var isRunning: Bool { if case .running = self { true } else { false } }
  var needsRetry: Bool { if case .partialFailure = self { true } else { false } }
}

@MainActor final class MessagesModel: ObservableObject {
  @Published private(set) var section: MessageSection = .reply
  @Published private(set) var notifications: [NotifyMessage] = []
  @Published private(set) var sessions: [ChatSession] = []
  @Published private(set) var selected: ChatSession?
  @Published private(set) var messages: [ConversationMessage] = []
  @Published private(set) var loading = false
  @Published private(set) var conversationLoading = false
  @Published private(set) var sending = false
  @Published private(set) var hasMore = true
  @Published private(set) var hasOlder = true
  @Published private(set) var error: String?
  @Published private(set) var conversationError: String?
  @Published private(set) var ownID: Int64?
  @Published var draft = ""
  @Published private(set) var markReadState: MessageMarkReadState = .idle
  private var markReadTask: Task<Void, Never>?
  private var markReadGeneration = UUID()
  private var markReadCompletion: (revision: UUID, finish: @MainActor (MarkAllMessagesReadResult?) -> Void)?
  private let service: BiliService
  private var offsetID: Int64 = 0
  private var offsetTime: Int64 = 0
  private var beforeSequence: Int64?
  private var generation = UUID()
  private var conversationGeneration = UUID()
  private var listTask: Task<Void, Never>?
  private var conversationTask: Task<Void, Never>?
  private var sendTask: Task<Void, Never>?
  private var observer: Task<Void, Never>?
  private var identity: AuthIdentityEvent?
  private var selectionIdentity: AuthSnapshot?
  private var active = false

  init(service: BiliService) {
    self.service = service
    observer = Task { [weak self] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let previous = self.identity
        self.identity = event
        let changed = previous.map { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision }
          ?? self.selectionIdentity.map { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision } ?? false
        if changed {
          let wasActive = self.active
          self.clear(); self.ownID = event.mid
          if wasActive { await self.start(self.section) }
        }
      }
    }
  }
  deinit { observer?.cancel(); listTask?.cancel(); conversationTask?.cancel(); sendTask?.cancel(); markReadTask?.cancel() }
  func cancel() {
    cancelLoading()
    markReadGeneration = UUID(); markReadTask?.cancel(); markReadTask = nil; markReadState = .idle
    let completion = markReadCompletion; markReadCompletion = nil
    completion?.finish(nil)
  }
  private func cancelLoading() {
    active = false; generation = UUID(); conversationGeneration = UUID()
    listTask?.cancel(); conversationTask?.cancel(); sendTask?.cancel()
    listTask = nil; conversationTask = nil; sendTask = nil
    loading = false; conversationLoading = false; sending = false
  }
  private func clear(cancelMarkRead: Bool = true) {
    if cancelMarkRead { cancel() } else { cancelLoading() }
    notifications = []; sessions = []; selected = nil; messages = []; draft = ""
    offsetID = 0; offsetTime = 0; beforeSequence = nil; selectionIdentity = nil
    error = nil; conversationError = nil; hasMore = true; hasOlder = true
  }
  func start(_ section: MessageSection) async {
    clear(cancelMarkRead: false); self.section = section; active = true
    await loadNext()
  }
  func loadNext() async {
    guard active, !loading, hasMore else { return }
    loading = true; error = nil
    let revision = generation, section = section, previousID = offsetID, previousTime = offsetTime
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let snapshot = await service.authSnapshot()
        ownID = snapshot.token?.mid
        if section == .chat {
          let page = try await service.chatSessions(offset: previousTime, expectedIdentity: snapshot)
          try await accept(snapshot, revision: revision)
          var known = Set(sessions.map(\.id))
          sessions += page.sessions.filter { known.insert($0.id).inserted }
          offsetTime = page.offset
          hasMore = page.hasMore && page.offset > 0 && page.offset != previousTime
          if selected == nil, let first = sessions.first { await select(first) }
        } else {
          let page = try await service.notificationMessages(section, offsetID: previousID,
            offsetTime: previousTime, expectedIdentity: snapshot)
          try await accept(snapshot, revision: revision)
          var known = Set(notifications.map(\.id))
          notifications += page.items.filter { known.insert($0.id).inserted }
          offsetID = page.offsetID; offsetTime = page.offsetTime
          hasMore = page.hasMore && (page.offsetID != previousID || page.offsetTime != previousTime)
        }
      } catch is CancellationError {} catch {
        guard generation == revision else { return }
        self.error = Self.message(error)
      }
      guard generation == revision else { return }
      loading = false; listTask = nil
    }
    listTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func select(_ session: ChatSession) async {
    conversationGeneration = UUID(); conversationTask?.cancel(); sendTask?.cancel()
    let revision = conversationGeneration
    selected = session; messages = []; beforeSequence = nil; draft = ""; conversationError = nil
    let snapshot = await service.authSnapshot()
    guard active, conversationGeneration == revision, !Task.isCancelled else { return }
    selectionIdentity = snapshot; ownID = snapshot.token?.mid
    hasOlder = true; conversationLoading = false; sending = false
    await loadOlder()
  }
  func loadOlder() async {
    guard active, !conversationLoading, hasOlder, let selected, let snapshot = selectionIdentity else { return }
    conversationLoading = true; conversationError = nil
    let revision = conversationGeneration, previous = beforeSequence
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let page = try await service.conversationMessages(talkerID: selected.id,
          beforeSequence: previous, expectedIdentity: snapshot)
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard conversationGeneration == revision, sameIdentity(snapshot, current) else { throw CancellationError() }
        var known = Set(messages.map(\.id))
        messages = (page.messages.filter { known.insert($0.id).inserted } + messages)
          .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        beforeSequence = page.minimumSequence
        hasOlder = page.hasMore && page.minimumSequence > 0 && page.minimumSequence != previous
      } catch is CancellationError {} catch {
        guard conversationGeneration == revision else { return }
        conversationError = Self.message(error)
      }
      guard conversationGeneration == revision else { return }
      conversationLoading = false; conversationTask = nil
    }
    conversationTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func send() async {
    guard active, !sending, let selected, let snapshot = selectionIdentity,
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let content = draft, revision = conversationGeneration
    sending = true; conversationError = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let message = try await service.sendConversationMessage(receiverID: selected.id,
          content: content, expectedIdentity: snapshot)
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard conversationGeneration == revision, sameIdentity(snapshot, current) else { throw CancellationError() }
        if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
        if draft == content { draft = "" }
      } catch is CancellationError {} catch {
        guard conversationGeneration == revision else { return }
        conversationError = Self.message(error)
      }
      guard conversationGeneration == revision else { return }
      sending = false; sendTask = nil
    }
    sendTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func markAllRead(onStart: @escaping @MainActor () -> UUID,
    onProgress: @escaping @MainActor (UUID, MessageUnreadCounts) -> Void,
    onFinish: @escaping @MainActor (UUID, MarkAllMessagesReadResult?) -> Void) {
    guard active, !markReadState.isRunning else { return }
    let revision = UUID(); markReadGeneration = revision
    markReadState = .running(completed: 0)
    let token = onStart()
    markReadCompletion = (revision, { onFinish(token, $0) })
    markReadTask = Task { @MainActor [weak self] in
      guard let self else { onFinish(token, nil); return }
      let snapshot = await service.authSnapshot()
      let result = await service.markAllMessagesRead(expectedIdentity: snapshot) { [weak self] _, _, unread in
        await self?.completedMarkCategory(revision, token: token, unread: unread, onProgress: onProgress)
      }
      let current = await service.authSnapshot()
      let valid = !Task.isCancelled && sameIdentity(snapshot, current) && markReadGeneration == revision
      finishMarkRead(revision, result: valid ? result : nil)
      guard valid else { return }
      let failures = MessageSection.allCases.compactMap { section -> String? in
        switch result.outcomes[section] ?? .unknown {
        case .success: return nil
        case .partialFailure(let count):
          return section == .chat ? "有 \(count) 个私信会话没能标为已读" : "\(section.title)仍有 \(count) 条未读"
        case .unknown: return "\(section.title)未能确认清零"
        case .cancelled: return "\(section.title)操作已取消"
        }
      }
      markReadState = failures.isEmpty ? .completed : .partialFailure(failures.joined(separator: "；") + "。可以重试。")
      markReadTask = nil
      if active { await start(section) }
    }
  }
  private func completedMarkCategory(_ revision: UUID, token: UUID, unread: MessageUnreadCounts,
    onProgress: @MainActor (UUID, MessageUnreadCounts) -> Void) {
    // No suspension between accepting this generation and publishing its counts.
    guard !Task.isCancelled, markReadGeneration == revision, markReadCompletion?.revision == revision,
      case .running(let completed) = markReadState else { return }
    markReadState = .running(completed: min(4, completed + 1))
    onProgress(token, unread)
  }
  private func finishMarkRead(_ revision: UUID, result: MarkAllMessagesReadResult?) {
    guard let completion = markReadCompletion, completion.revision == revision else { return }
    markReadCompletion = nil
    completion.finish(result)
  }
  #if DEBUG
  func applyMarkReadFixture(_ state: String) {
    guard ProcessInfo.processInfo.arguments.contains("--ui-fixture") else { return }
    M6MessageFixture.configurePresentation(state)
    switch state {
    case "running": markReadState = .running(completed: 3)
    case "partial": markReadState = .partialFailure("有 2 个私信会话没能标为已读，角标如实保留。可以重试。")
    default: break
    }
  }
  #endif
  private func accept(_ snapshot: AuthSnapshot, revision: UUID) async throws {
    let current = await service.authSnapshot()
    try Task.checkCancellation()
    guard generation == revision, sameIdentity(snapshot, current) else { throw CancellationError() }
  }
  private func sameIdentity(_ a: AuthSnapshot, _ b: AuthSnapshot) -> Bool {
    a.epoch == b.epoch && a.identityRevision == b.identityRevision && a.token?.mid == b.token?.mid
  }
  private static func message(_ error: Error) -> String {
    if let failure = error as? AuthFailure, case .needsLogin = failure { return "请先登录，再查看消息。" }
    return error.localizedDescription
  }
}
