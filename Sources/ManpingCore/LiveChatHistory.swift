import Foundation

public struct LiveChatLine: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case danmaku
    case superChat(Int)
    case gift, notice
    case guardPurchase(Int64)
  }
  public let id: Int
  public let user: String
  public let text: String
  public let kind: Kind
  public let group: UUID?
  public let serverID: String?
  public let danmakuID: String?
  public let uid: Int64
  public let medal: LiveMedal?
  public let guardLevel: Int64
  public let emotes: LiveJSON
  public let roomEmote: LiveJSON
  public let reply: LiveJSON
  public let isOwn: Bool
  public let gift: LiveGiftMessage?
}

/// Bounded rich history shared by App and Core tests. Pure mode does not change this store.
public struct LiveChatHistory: Sendable {
  public private(set) var lines: [LiveChatLine] = []
  private var nextID = 0
  private var deletedSuperChats: Set<String> = []
  public init() {}
  public mutating func add(
    user: String, text: String, kind: LiveChatLine.Kind,
    group: UUID? = nil, serverID: String? = nil, danmakuID: String? = nil, uid: Int64 = 0,
    medal: LiveMedal? = nil,
    guardLevel: Int64 = 0, emotes: LiveJSON = .null, roomEmote: LiveJSON = .null,
    reply: LiveJSON = .null, isOwn: Bool = false, gift: LiveGiftMessage? = nil
  ) {
    if let serverID, deletedSuperChats.contains(serverID) { return }
    if let group { lines.removeAll { $0.group == group } }
    if let serverID { lines.removeAll { $0.serverID == serverID } }
    nextID += 1
    lines.append(
      LiveChatLine(
        id: nextID, user: user, text: text, kind: kind, group: group,
        serverID: serverID, danmakuID: danmakuID, uid: uid, medal: medal, guardLevel: guardLevel,
        emotes: emotes,
        roomEmote: roomEmote, reply: reply, isOwn: isOwn, gift: gift))
    if lines.count > 200 { lines.removeFirst(lines.count - 200) }
  }
  public mutating func add(_ message: LiveDanmaku, accountMid: Int64?) {
    add(
      user: message.user, text: message.text, kind: .danmaku, danmakuID: message.id,
      uid: message.uid,
      medal: message.medal, guardLevel: message.guardLevel, emotes: message.emotes,
      roomEmote: message.roomEmote, reply: message.reply,
      isOwn: message.isOwn(accountMid: accountMid))
  }
  public mutating func removeSuperChats(_ ids: [String]) {
    deletedSuperChats.formUnion(ids)
    lines.removeAll { $0.serverID.map(deletedSuperChats.contains) == true }
  }
  public mutating func removeGifts() { lines.removeAll { $0.kind == .gift } }
}
