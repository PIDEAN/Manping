import Foundation

extension BiliService {
  /// Explicit user action only. Loading notifications, sessions or history never invokes this.
  public func sendConversationMessage(receiverID: Int64, content: String, expectedIdentity: AuthSnapshot) async throws -> ConversationMessage {
    try checkRESTIdentity(expectedIdentity)
    guard receiverID > 0, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= 500 else {
      throw BiliError.invalidResponse("消息不能为空，且不能超过 500 字")
    }
    guard let sender = expectedIdentity.token?.mid, sender > 0 else { throw AuthFailure.needsLogin }
    let timestamp = Int64(Date().timeIntervalSince1970)
    let json = try JSONSerialization.data(withJSONObject: ["content": content], options: [.sortedKeys])
    let fields = ["msg[msg_type]": "1", "msg[content]": String(decoding: json, as: UTF8.self),
      "msg[sender_uid]": String(sender), "msg[receiver_id]": String(receiverID), "msg[receiver_type]": "1",
      "msg[receiver_device_id]": "1", "msg[timestamp]": String(timestamp), "msg[msg_status]": "0",
      "msg[dev_id]": "0", "msg[new_face_version]": "1"]
    let response = try await messageWebSend(fields: fields, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    return try ConversationMessage.parse(["msg_key": response["msg_key"] ?? 0,
      "content": response["msg_content"] ?? String(decoding: json, as: UTF8.self),
      "msg_type": 1, "sender_uid": sender, "timestamp": timestamp])
  }
}

/// Process-local exclusion without sharing cancellation between independent callers.
private final class MessageReadOperationGate: @unchecked Sendable {
  static let shared = MessageReadOperationGate()
  private let lock = NSLock()
  private var active = Set<ObjectIdentifier>()
  func acquire(_ service: BiliService) -> Bool { lock.withLock { active.insert(ObjectIdentifier(service)).inserted } }
  func release(_ service: BiliService) { _ = lock.withLock { active.remove(ObjectIdentifier(service)) } }
}

/// Also used by the app's polling coordinator so an old read cannot overwrite an operation.
public struct MessageUnreadGeneration: Sendable {
  private var generation = UUID()
  public init() {}
  @discardableResult public mutating func invalidate() -> UUID { generation = UUID(); return generation }
  public var current: UUID { generation }
  public func accepts(_ candidate: UUID) -> Bool { generation == candidate }
}

extension BiliService {
  /// Explicit user action. Enumerates the entire snapshot before sending any acknowledgements.
  public func markAllMessagesRead(expectedIdentity: AuthSnapshot,
    progress: @Sendable (MessageSection, MessageReadOutcome, MessageUnreadCounts) async -> Void = { _, _, _ in }) async -> MarkAllMessagesReadResult {
    func uniform(_ outcome: MessageReadOutcome) -> MarkAllMessagesReadResult {
      MarkAllMessagesReadResult(outcomes: Dictionary(uniqueKeysWithValues: MessageSection.allCases.map { ($0, outcome) }),
        unread: MessageUnreadCounts())
    }
    guard MessageReadOperationGate.shared.acquire(self) else { return uniform(.unknown) }
    defer { MessageReadOperationGate.shared.release(self) }
    var outcomes: [MessageSection: MessageReadOutcome] = [:]
    var unread = MessageUnreadCounts()
    do {
      try checkRESTIdentity(expectedIdentity)
      var targets: [MessageAcknowledgementTarget] = []
      var enumerationComplete = false
      do {
        targets = try await messageAcknowledgementSnapshot(expectedIdentity: expectedIdentity)
        enumerationComplete = true
      } catch is CancellationError { throw CancellationError() } catch {
        try checkRESTIdentity(expectedIdentity)
      }
      for section in [MessageSection.reply, .at, .like] {
        try checkRESTIdentity(expectedIdentity)
        do { _ = try await notificationMessages(section, expectedIdentity: expectedIdentity) }
        catch is CancellationError { throw CancellationError() } catch { try checkRESTIdentity(expectedIdentity) }
        // List reads may clear a category, but only the server's resulting count confirms it.
        do {
          let feed = try await messageFeedUnread(expectedIdentity: expectedIdentity)
          for (key, value) in feed { unread.values[key] = value }
          let count = feed[section]!
          outcomes[section] = count == 0 ? .success : .partialFailure(count: Int(clamping: count))
        } catch is CancellationError { throw CancellationError() } catch { outcomes[section] = .unknown }
        try checkRESTIdentity(expectedIdentity)
        await progress(section, outcomes[section] ?? .unknown, unread)
        try checkRESTIdentity(expectedIdentity)
      }
      var failures = 0
      if enumerationComplete {
        for target in targets {
          try checkRESTIdentity(expectedIdentity)
          do {
            _ = try await messageWebREST(.updateAcknowledgement, fields: [
              "talker_id": String(target.talkerID), "session_type": String(target.sessionType),
              "ack_seqno": String(target.maxSequence)], expectedIdentity: expectedIdentity)
          } catch is CancellationError { throw CancellationError() } catch { failures += 1 }
          try checkRESTIdentity(expectedIdentity)
        }
      }
      // Refresh feed and chat independently; a failed private read must not erase feed evidence.
      do {
        let feed = try await messageFeedUnread(expectedIdentity: expectedIdentity)
        for (section, count) in feed {
          unread.values[section] = count
          outcomes[section] = count == 0 ? .success : .partialFailure(count: Int(clamping: count))
        }
      } catch is CancellationError { throw CancellationError() } catch {
        for section in [MessageSection.reply, .at, .like] { unread.values[section] = nil; outcomes[section] = .unknown }
      }
      do {
        unread.values[.chat] = try await messageChatUnread(expectedIdentity: expectedIdentity)
        outcomes[.chat] = enumerationComplete ? failures == 0 ? .success : .partialFailure(count: failures) : .unknown
      } catch is CancellationError { throw CancellationError() } catch {
        outcomes[.chat] = failures > 0 ? .partialFailure(count: failures) : .unknown
      }
      try checkRESTIdentity(expectedIdentity)
      await progress(.chat, outcomes[.chat] ?? .unknown, unread)
      try checkRESTIdentity(expectedIdentity)
      return MarkAllMessagesReadResult(outcomes: outcomes, unread: unread)
    } catch {
      return uniform(.cancelled)
    }
  }

  private func messageAcknowledgementSnapshot(expectedIdentity: AuthSnapshot) async throws -> [MessageAcknowledgementTarget] {
    struct Key: Hashable { let talker: Int64; let type: Int64 }
    var seen = Set<Key>(), targets: [MessageAcknowledgementTarget] = []
    // 9 = followed users and system, 2 = unfollowed. Neither query includes dustbin or fan groups.
    for category in ["9", "2"] {
      var cursor: Int64 = 0
      var complete = false
      for _ in 0..<100 {
        try checkRESTIdentity(expectedIdentity)
        guard let raw = try await messageWebREST(.sessions, fields: ["session_type": category,
          "group_fold": "0", "unfollow_fold": "0", "sort_rule": "2", "size": "100", "end_ts": String(cursor)],
          expectedIdentity: expectedIdentity) as? [String: Any] else {
          throw BiliError.invalidResponse("Invalid acknowledgement sessions")
        }
        try checkRESTIdentity(expectedIdentity)
        let more = try messageRequiredCount(raw["has_more"])
        guard more <= 1 else { throw BiliError.invalidResponse("Invalid session continuation") }
        let rows: [[String: Any]]
        if raw["session_list"] == nil || raw["session_list"] is NSNull { rows = [] }
        else if let list = raw["session_list"] as? [[String: Any]] { rows = list }
        else { throw BiliError.invalidResponse("Invalid acknowledgement session list") }
        for row in rows {
          let talker = try messageRequiredCount(row["talker_id"])
          let type = try messageRequiredCount(row["session_type"])
          guard talker > 0, type == 1 || type == 2 else {
            throw BiliError.invalidResponse("Invalid acknowledgement target")
          }
          // The first occurrence fixes the boundary, including an initially read conversation.
          guard seen.insert(Key(talker: talker, type: type)).inserted else { continue }
          let count = try messageRequiredCount(row["unread_count"])
          let maximum = try messageRequiredCount(row["max_seqno"])
          let acknowledged = try messageRequiredCount(row["ack_seqno"])
          guard maximum >= acknowledged else { throw BiliError.invalidResponse("Invalid acknowledgement sequence") }
          if count > 0 {
            guard maximum > 0 else { throw BiliError.invalidResponse("Missing acknowledgement sequence") }
            targets.append(MessageAcknowledgementTarget(talkerID: talker, sessionType: type, maxSequence: maximum))
          }
          guard seen.count <= 10_000 else { throw BiliError.invalidResponse("Too many acknowledgement sessions") }
        }
        if more == 0 { complete = true; break }
        let next = try rows.map { try messageRequiredCount($0["session_ts"]) }.min() ?? 0
        guard next > 0, cursor == 0 || next < cursor else {
          throw BiliError.invalidResponse("Acknowledgement cursor did not advance")
        }
        cursor = next
      }
      guard complete else { throw BiliError.invalidResponse("Acknowledgement enumeration was truncated") }
    }
    return targets
  }
}
