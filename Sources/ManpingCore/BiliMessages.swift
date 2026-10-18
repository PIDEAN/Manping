import Foundation

extension BiliService {
  public func notificationMessages(_ section: MessageSection, offsetID: Int64 = 0, offsetTime: Int64 = 0,
    expectedIdentity: AuthSnapshot? = nil) async throws -> NotificationPage {
    guard section != .chat, offsetID >= 0, offsetTime >= 0 else {
      throw BiliError.invalidResponse("Invalid notification request")
    }
    let route: BiliAppRoute = section == .reply ? .messageReply : section == .at ? .messageAt : .messageLike
    return try NotificationPage.parse(try await appObject(route,
      fields: ["id": String(offsetID), "\(section.rawValue)_time": String(offsetTime)], expectedIdentity: expectedIdentity), section: section)
  }
  /// Unread counts for the sidebar and Dock badge: replies, @, likes and private messages.
  /// Read-only; nothing is marked read. Private messages need the Web login and count as zero
  /// when it is missing, so the badge still reflects the feed counts.
  public func unreadMessages(expectedIdentity: AuthSnapshot? = nil) async throws -> UnreadMessages {
    let identity = expectedIdentity ?? authSnapshot()
    let feed = try await appObject(.messageUnread, fields: [:], expectedIdentity: identity)
    var chat: Int64 = 0
    if let raw = try? await messageWebREST(.unread, fields: ["unread_type": "0"], expectedIdentity: identity) as? [String: Any] {
      chat = max(0, messageInteger(raw["follow_unread"])) + max(0, messageInteger(raw["unfollow_unread"]))
    }
    return UnreadMessages(reply: max(0, messageInteger(feed["reply"])), at: max(0, messageInteger(feed["at"])),
      like: max(0, messageInteger(feed["like"])), chat: chat)
  }
  public func chatSessions(offset: Int64 = 0, expectedIdentity: AuthSnapshot? = nil) async throws -> ChatSessionPage {
    guard offset >= 0 else { throw BiliError.invalidResponse("Invalid chat offset") }
    guard let raw = try await messageWebREST(.sessions, fields: ["session_type": "1", "group_fold": "1",
      "sort_rule": "2", "end_ts": String(offset)], expectedIdentity: expectedIdentity) as? [String: Any] else {
      throw BiliError.invalidResponse("Invalid chat sessions response")
    }
    let list = raw["session_list"] as? [[String: Any]] ?? []
    let normal = list.filter { messageInteger($0["system_msg_type"]) == 0 && $0["last_msg"] is [String: Any] }
    let ids = normal.map { messageInteger($0["talker_id"]) }.filter { $0 > 0 }
    var people: [Int64: MessageUser] = [:]
    if !ids.isEmpty {
      guard let users = try await messageWebREST(.users, fields: ["uids": Set(ids).sorted().map(String.init).joined(separator: ",")],
        expectedIdentity: expectedIdentity) as? [[String: Any]] else { throw BiliError.invalidResponse("Invalid chat users") }
      for raw in users { let user = MessageUser.parse(raw); people[user.id] = user }
    }
    var known = Set<Int64>()
    let sessions = try normal.compactMap { row -> ChatSession? in
      let id = messageInteger(row["talker_id"])
      guard id > 0, known.insert(id).inserted, let message = row["last_msg"] as? [String: Any] else { return nil }
      return ChatSession(user: people[id] ?? MessageUser(id: id, name: String(id), avatar: nil),
        lastMessage: try ConversationMessage.parse(message), unread: messageInteger(row["unread_count"]),
        timestamp: messageInteger(row["session_ts"]))
    }
    return ChatSessionPage(sessions: sessions, offset: messageInteger(list.last?["session_ts"]),
      hasMore: messageInteger(raw["has_more"]) == 1 && !list.isEmpty)
  }
  public func conversationMessages(talkerID: Int64, beforeSequence: Int64? = nil,
    expectedIdentity: AuthSnapshot? = nil) async throws -> ConversationPage {
    guard talkerID > 0, beforeSequence == nil || beforeSequence! > 0 else {
      throw BiliError.invalidResponse("Invalid conversation request")
    }
    var fields = ["sender_device_id": "1", "talker_id": String(talkerID), "session_type": "1", "size": "100"]
    if let beforeSequence { fields["begin_seqno"] = String(beforeSequence) }
    guard let data = try await messageWebREST(.history, fields: fields, expectedIdentity: expectedIdentity) as? [String: Any] else {
      throw BiliError.invalidResponse("Invalid chat response")
    }
    return try ConversationPage.parse(data)
  }
}

public struct UnreadMessages: Sendable, Equatable {
  public let reply: Int64
  public let at: Int64
  public let like: Int64
  public let chat: Int64
  public init(reply: Int64, at: Int64, like: Int64, chat: Int64) {
    self.reply = reply; self.at = at; self.like = like; self.chat = chat
  }
  public var total: Int64 { reply + at + like + chat }
}
