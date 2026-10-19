import Foundation
import CoreFoundation

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
  /// Followed and unfollowed private messages only; dustbin and fan groups are excluded.
  /// Any unread read failure leaves the caller's previous badge intact.
  public func unreadMessages(expectedIdentity: AuthSnapshot? = nil) async throws -> UnreadMessages {
    let identity = expectedIdentity ?? authSnapshot()
    let feed = try await messageFeedUnread(expectedIdentity: identity)
    let chat = try await messageChatUnread(expectedIdentity: identity)
    try checkRESTIdentity(identity)
    return UnreadMessages(reply: feed[.reply]!, at: feed[.at]!, like: feed[.like]!, chat: chat)
  }
  /// A fresh polling snapshot. Missing categories are unknown; independent reads
  /// and feed fields retain successful evidence without carrying over old counts.
  public func unreadMessageCounts(expectedIdentity: AuthSnapshot? = nil) async throws -> MessageUnreadCounts {
    let identity = expectedIdentity ?? authSnapshot()
    try checkRESTIdentity(identity)
    var unread = MessageUnreadCounts()
    do {
      let feed = try await appObject(.messageUnread, expectedIdentity: identity)
      for section in [MessageSection.reply, .at, .like] {
        do { unread.values[section] = try messageRequiredCount(feed[section.rawValue]) }
        catch { try checkRESTIdentity(identity) }
      }
    } catch is CancellationError { throw CancellationError() }
    catch { try checkRESTIdentity(identity) }
    do { unread.values[.chat] = try await messageChatUnread(expectedIdentity: identity) }
    catch is CancellationError { throw CancellationError() }
    catch { try checkRESTIdentity(identity) }
    try checkRESTIdentity(identity)
    return unread
  }
  func messageFeedUnread(expectedIdentity: AuthSnapshot) async throws -> [MessageSection: Int64] {
    let feed = try await appObject(.messageUnread, expectedIdentity: expectedIdentity)
    return try Dictionary(uniqueKeysWithValues: [MessageSection.reply, .at, .like].map {
      ($0, try messageRequiredCount(feed[$0.rawValue]))
    })
  }
  func messageChatUnread(expectedIdentity: AuthSnapshot) async throws -> Int64 {
    guard let raw = try await messageWebREST(.unread,
      fields: ["unread_type": "0", "show_dustbin": "0"], expectedIdentity: expectedIdentity) as? [String: Any] else {
      throw BiliError.invalidResponse("Invalid unread private messages")
    }
    let followed = try messageRequiredCount(raw["follow_unread"])
    let unfollowed = try messageRequiredCount(raw["unfollow_unread"])
    let (total, overflow) = followed.addingReportingOverflow(unfollowed)
    guard !overflow else { throw BiliError.invalidResponse("Invalid unread private messages") }
    return total
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
        timestamp: messageInteger(row["session_ts"]), sessionType: messageInteger(row["session_type"]),
        maxSequence: messageInteger(row["max_seqno"]), acknowledgedSequence: messageInteger(row["ack_seqno"]))
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
  public var total: Int64 { [reply, at, like, chat].reduce(0) { min(Int64.max - $0, $1) + $0 } }
  public subscript(_ section: MessageSection) -> Int64 {
    switch section { case .reply: reply; case .at: at; case .like: like; case .chat: chat }
  }
}

func messageRequiredCount(_ raw: Any?) throws -> Int64 {
  if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
    throw BiliError.invalidResponse("Invalid boolean message count")
  }
  let value = messageInteger(raw)
  guard value >= 0, raw is String || raw is NSNumber,
    String(value) == (raw as? String) || (raw as? NSNumber)?.stringValue == String(value) else {
    throw BiliError.invalidResponse("Missing or invalid message count")
  }
  return value
}
