import ManpingCore
import Foundation
import SwiftUI

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
  deinit { observer?.cancel(); listTask?.cancel(); conversationTask?.cancel(); sendTask?.cancel() }
  func cancel() {
    active = false; generation = UUID(); conversationGeneration = UUID()
    listTask?.cancel(); conversationTask?.cancel(); sendTask?.cancel()
    listTask = nil; conversationTask = nil; sendTask = nil
    loading = false; conversationLoading = false; sending = false
  }
  private func clear() {
    cancel(); notifications = []; sessions = []; selected = nil; messages = []; draft = ""
    offsetID = 0; offsetTime = 0; beforeSequence = nil; selectionIdentity = nil
    error = nil; conversationError = nil; hasMore = true; hasOlder = true
  }
  func start(_ section: MessageSection) async {
    clear(); self.section = section; active = true
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
