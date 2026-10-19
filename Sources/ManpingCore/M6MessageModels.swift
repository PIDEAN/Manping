import Foundation
import CoreFoundation

public enum MessageSection: String, CaseIterable, Sendable {
  case reply, at, like, chat
  public var title: String {
    switch self { case .reply: "回复我的"; case .at: "@我的"; case .like: "收到的赞"; case .chat: "私信" }
  }
}

/// Closed Web routes: history loading never acknowledges or marks a conversation read.
public enum BiliMessageWebRoute: Sendable {
  case sessions, history, users, send, unread, updateAcknowledgement, batchDustbinAcknowledgement
  var isPOST: Bool { self == .send || self == .updateAcknowledgement || self == .batchDustbinAcknowledgement }
  public var url: String {
    let path = switch self {
      case .sessions: "/session_svr/v1/session_svr/get_sessions"
      case .unread: "/session_svr/v1/session_svr/single_unread"
      case .history: "/svr_sync/v1/svr_sync/fetch_session_msgs"
      case .users: "/account/v1/user/cards"
      case .send: "/web_im/v1/web_im/send_msg"
      case .updateAcknowledgement: "/session_svr/v1/session_svr/update_ack"
      case .batchDustbinAcknowledgement: "/session_svr/v1/session_svr/batch_update_dustbin_ack"
    }
    return "https://api.vc.bilibili.com" + path
  }
}

public struct MessageUser: Identifiable, Sendable, Equatable {
  public let id: Int64
  public let name: String
  public let avatar: URL?
  static func parse(_ value: [String: Any]) -> Self {
    Self(id: messageInteger(value["mid"]), name: value["nickname"] as? String ?? value["name"] as? String ?? "用户",
      avatar: URL(string: value["avatar"] as? String ?? value["face"] as? String ?? ""))
  }
}
public struct NotifyMessage: Identifiable, Sendable {
  public let id: Int64
  public let users: [MessageUser]
  public let section: MessageSection
  public let timestamp: Int64
  public let business: String
  public let text: String
  public let source: String
  public let count: Int64
  public let sourceURL: URL?
  static func parse(_ value: [String: Any], section: MessageSection) throws -> Self {
    let id = messageInteger(value["id"])
    guard id > 0, let detail = value["item"] as? [String: Any] else {
      throw BiliError.invalidResponse("Invalid notification item")
    }
    let people = value["users"] as? [[String: Any]] ?? (value["user"] as? [String: Any]).map { [$0] } ?? []
    let title = detail["title"] as? String ?? ""
    let candidate = URL(string: detail["uri"] as? String ?? "")
    return Self(id: id, users: people.map(MessageUser.parse), section: section,
      timestamp: messageInteger(value["\(section.rawValue)_time"]), business: detail["business"] as? String ?? "",
      text: section == .like ? "" : detail["source_content"] as? String ?? "",
      source: title.isEmpty ? detail["desc"] as? String ?? "" : title,
      count: messageInteger(value["counts"]), sourceURL: candidate?.scheme == "https" || candidate?.scheme == "http" ? candidate : nil)
  }
}
public struct NotificationPage: Sendable {
  public let items: [NotifyMessage]
  public let offsetID: Int64
  public let offsetTime: Int64
  public let hasMore: Bool
  public static func parse(_ value: [String: Any], section: MessageSection) throws -> Self {
    guard section != .chat else { throw BiliError.invalidResponse("Invalid notification section") }
    let history = section == .like ? value["total"] as? [String: Any] ?? [:] : value
    guard let cursor = history["cursor"] as? [String: Any] else {
      throw BiliError.invalidResponse("Missing notification cursor")
    }
    let latest = section == .like ? (value["lastest"] as? [String: Any])?["items"] as? [[String: Any]] ?? [] : []
    let raw = latest + (history["items"] as? [[String: Any]] ?? [])
    var known = Set<Int64>()
    let items = try raw.map { try NotifyMessage.parse($0, section: section) }.filter { known.insert($0.id).inserted }
    return Self(items: items, offsetID: messageInteger(cursor["id"]), offsetTime: messageInteger(cursor["time"]),
      hasMore: (cursor["is_end"] as? Bool == false) && !items.isEmpty)
  }
}

public enum ConversationMessageKind: Sendable { case text, image, withdrawn, unsupported }
public struct ConversationMessage: Identifiable, Sendable {
  public let id: Int64
  public let senderID: Int64
  public let timestamp: Int64
  public let kind: ConversationMessageKind
  public let text: String
  public let image: URL?
  /// Page-level `e_infos`; the original maps them onto every text message as inline emotes.
  public var emotes: [RPCEmote] = []
  static func parse(_ raw: [String: Any]) throws -> Self {
    let id = messageInteger(raw["msg_key"])
    guard id > 0 else { throw BiliError.invalidResponse("Missing chat message key") }
    let type = messageInteger(raw["msg_type"])
    let content = (raw["content"] as? String).flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let image = URL(string: content["url"] as? String ?? "")
    return Self(id: id, senderID: messageInteger(raw["sender_uid"]), timestamp: messageInteger(raw["timestamp"]),
      kind: type == 1 ? .text : type == 2 ? .image : type == 5 ? .withdrawn : .unsupported,
      text: content["content"] as? String ?? "", image: image?.scheme == "https" || image?.scheme == "http" ? image : nil)
  }
}
public struct ConversationPage: Sendable {
  public let messages: [ConversationMessage]
  public let minimumSequence: Int64
  public let hasMore: Bool
  public static func parse(_ value: [String: Any]) throws -> Self {
    guard let raw = value["messages"] as? [[String: Any]] else {
      if value["messages"] == nil || value["messages"] is NSNull {
        return Self(messages: [], minimumSequence: 0, hasMore: false)
      }
      throw BiliError.invalidResponse("Invalid conversation list")
    }
    var known = Set<Int64>()
    let decoded: [ConversationMessage] = try raw.map { try ConversationMessage.parse($0) }
    let unique: [ConversationMessage] = decoded.filter { known.insert($0.id).inserted }
    let emotes = (value["e_infos"] as? [[String: Any]] ?? []).compactMap { info -> RPCEmote? in
      guard let text = info["text"] as? String, !text.isEmpty else { return nil }
      return RPCEmote(text: text, image: URL(string: info["url"] as? String ?? ""))
    }
    let parsed: [ConversationMessage] = unique.sorted { first, second in
      if first.timestamp == second.timestamp { return first.id < second.id }
      return first.timestamp < second.timestamp
    }.map { message in
      var message = message
      if message.kind == .text { message.emotes = emotes }
      return message
    }
    return Self(messages: parsed, minimumSequence: messageInteger(value["min_seqno"]),
      hasMore: messageInteger(value["has_more"]) == 1 && !parsed.isEmpty)
  }
}
public struct ChatSession: Identifiable, Sendable {
  public var id: Int64 { user.id }
  public let user: MessageUser
  public let lastMessage: ConversationMessage
  public let unread: Int64
  public let timestamp: Int64
  public var sessionType: Int64 = 1
  public var maxSequence: Int64 = 0
  public var acknowledgedSequence: Int64 = 0
}
public struct ChatSessionPage: Sendable {
  public let sessions: [ChatSession]
  public let offset: Int64
  public let hasMore: Bool
}

func messageInteger(_ value: Any?) -> Int64 {
  if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return 0 }
  return (value as? NSNumber)?.int64Value ?? (value as? String).flatMap(Int64.init) ?? 0
}

/// A fixed acknowledgement boundary; never substitute a message key for a sequence.
public struct MessageAcknowledgementTarget: Sendable, Equatable {
  public let talkerID: Int64
  public let sessionType: Int64
  public let maxSequence: Int64
}
public enum MessageReadOutcome: Sendable, Equatable {
  case success, partialFailure(count: Int), cancelled, unknown
}
/// Missing entries are unknown, never zero. Values always come from unread endpoints.
public struct MessageUnreadCounts: Sendable, Equatable {
  public var values: [MessageSection: Int64]
  public init(values: [MessageSection: Int64] = [:]) { self.values = values }
  public init(_ unread: UnreadMessages) {
    values = Dictionary(uniqueKeysWithValues: MessageSection.allCases.map { ($0, unread[$0]) })
  }
  public subscript(_ section: MessageSection) -> Int64? { values[section] }
  /// A lower bound while any category remains unknown.
  public var knownTotal: Int64 { values.values.reduce(0) { min(Int64.max - $0, $1) + $0 } }
  public var total: Int64? {
    guard values.count == MessageSection.allCases.count else { return nil }
    return knownTotal
  }
  public func canMarkAllRead(isRunning: Bool, needsRetry: Bool) -> Bool {
    !isRunning && (needsRetry || !MessageSection.allCases.allSatisfy { self[$0] == 0 })
  }
}
public struct MarkAllMessagesReadResult: Sendable, Equatable {
  public let outcomes: [MessageSection: MessageReadOutcome]
  public let unread: MessageUnreadCounts
  public init(outcomes: [MessageSection: MessageReadOutcome], unread: MessageUnreadCounts) {
    self.outcomes = outcomes; self.unread = unread
  }
}
