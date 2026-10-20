import BiliProtocol
import Foundation
import SwiftProtobuf

public struct LiveMedal: Sendable, Equatable {
  public let level: Int64
  public let name: String
  public let anchorName: String
  public let anchorID: Int64
  public let color: Int64
  public let borderColor: Int64
  public let startColor: Int64
  public let endColor: Int64
  public let guardLevel: Int64
  public let lighted: Bool
  public init?(_ data: LiveJSON) {
    guard let name = data["medal_name"].string, !name.isEmpty else { return nil }
    self.name = name
    level = data["level"].int64 ?? 0
    anchorName = data["anchor_name"].string ?? ""
    anchorID = data["target_id"].int64 ?? 0
    color = data["medal_color"].int64 ?? 0x3e6fd8
    borderColor = data["medal_color_border"].int64 ?? color
    startColor = data["medal_color_start"].int64 ?? color
    endColor = data["medal_color_end"].int64 ?? color
    guardLevel = data["guard_level"].int64 ?? 0
    lighted = data["is_lighted"].int64 == 1
  }
  init(_ values: [Any]) {
    func value(_ i: Int) -> Any? { values.indices.contains(i) ? values[i] : nil }
    level = JSONValue.int64(value(0)) ?? 0
    name = value(1) as? String ?? ""
    anchorName = value(2) as? String ?? ""
    color = JSONValue.int64(value(4)) ?? 0
    borderColor = JSONValue.int64(value(7)) ?? 0
    startColor = JSONValue.int64(value(8)) ?? 0
    endColor = JSONValue.int64(value(9)) ?? 0
    guardLevel = JSONValue.int64(value(10)) ?? 0
    lighted = JSONValue.int64(value(11)) == 1
    anchorID = JSONValue.int64(value(12)) ?? 0
  }
}
public struct LiveDanmaku: Sendable, Equatable {
  public let uid: Int64
  public let user: String
  public let text: String
  public let color: UInt32
  public let mode: Int64
  public let medal: LiveMedal?
  public let guardLevel: Int64
  public let id: String?
  public let emotes: LiveJSON
  public let roomEmote: LiveJSON
  public let reply: LiveJSON
  public let dmType: Int64
  public let emoticonUnique: String?
  public let timestamp: Int64?
  public init(
    uid: Int64 = 0, user: String, text: String, color: UInt32 = 0xffffff, mode: Int64 = 1,
    medal: LiveMedal? = nil, guardLevel: Int64 = 0, id: String? = nil, emotes: LiveJSON = .null,
    roomEmote: LiveJSON = .null, reply: LiveJSON = .null, dmType: Int64 = 0,
    emoticonUnique: String? = nil, timestamp: Int64? = nil
  ) {
    self.uid = uid
    self.user = user
    self.text = text
    self.color = color
    self.mode = mode
    self.medal = medal
    self.guardLevel = guardLevel
    self.id = id
    self.emotes = emotes
    self.roomEmote = roomEmote
    self.reply = reply
    self.dmType = dmType
    self.emoticonUnique = emoticonUnique
    self.timestamp = timestamp
  }
  public func isOwn(accountMid: Int64?) -> Bool {
    accountMid != nil && uid > 0 && uid == accountMid
  }
}
public struct LiveGiftMessage: Sendable, Equatable {
  public let uid: Int64
  public let user: String
  public let giftID: Int64
  public let name: String
  public var count: Int64
  public let price: Int64
  public var hasKnownTotal: Bool
  public var totalCoin: Int64
  public let coinType: String
  public let tid: String
  public let batchID: String
  public let timestamp: Int64?
  public let raw: LiveJSON
  public var aggregationID: UUID?
  public init(
    uid: Int64 = 0, user: String, giftID: Int64 = 0, name: String, count: Int64 = 1,
    price: Int64 = 0, totalCoin: Int64 = 0, coinType: String = "unknown", tid: String = "",
    batchID: String = "",
    timestamp: Int64? = nil, raw: LiveJSON = .null, hasKnownTotal: Bool? = nil,
    aggregationID: UUID? = nil
  ) {
    self.uid = uid
    self.user = user
    self.giftID = giftID
    self.name = name
    self.count = count
    self.price = price
    self.totalCoin = totalCoin
    self.hasKnownTotal = (hasKnownTotal ?? (totalCoin > 0)) && totalCoin >= 0
    self.coinType = coinType
    self.tid = tid
    self.batchID = batchID
    self.timestamp = timestamp
    self.raw = raw
    self.aggregationID = aggregationID
  }
}
public struct LiveGuardMessage: Sendable, Equatable {
  public let command: String
  public let uid: Int64
  public let user: String
  public let level: Int64
  public let count: Int64
  public let raw: LiveJSON
}
public struct LiveNoticeEvent: Sendable, Equatable {
  public let command: String
  public let data: LiveJSON
}

/// Deduplicate first, then update a bounded, short-lived group. Never invent a dedup key for
/// anonymous gifts: two identical messages without server IDs can be two real gifts.
public struct LiveGiftAggregator: Sendable {
  private struct Group: Sendable {
    var gift: LiveGiftMessage
    var updated: TimeInterval
  }
  private struct Key: Hashable, Sendable {
    let uid: Int64
    let giftID: Int64
    let coin: String
  }
  private var groups: [Key: Group] = [:]
  private var seen: Set<String> = []
  private var order: [String] = []
  public let window: TimeInterval
  public let capacity: Int
  public init(window: TimeInterval = 5, capacity: Int = 4096) {
    self.window = max(0, window)
    self.capacity = max(1, capacity)
  }
  public mutating func ingest(_ gift: LiveGiftMessage, now: TimeInterval) -> LiveGiftMessage? {
    guard gift.count > 0 else { return nil }
    let serverID =
      !gift.tid.isEmpty ? "tid:\(gift.tid)" : (!gift.batchID.isEmpty ? "batch:\(gift.batchID)" : "")
    if !serverID.isEmpty, gift.uid > 0, gift.giftID > 0 {
      let id = "\(gift.uid):\(gift.giftID):\(serverID)"
      guard seen.insert(id).inserted else { return nil }
      order.append(id)
      if order.count > capacity { seen.remove(order.removeFirst()) }
    }
    groups = groups.filter { now - $0.value.updated <= window }
    let key = Key(uid: gift.uid, giftID: gift.giftID, coin: gift.coinType)
    var result = gift
    if gift.uid > 0, gift.giftID > 0, let previous = groups[key], now >= previous.updated,
      now - previous.updated <= window
    {
      let sum = previous.gift.count.addingReportingOverflow(gift.count)
      guard !sum.overflow else { return nil }
      let total = previous.gift.totalCoin.addingReportingOverflow(gift.totalCoin)
      guard !total.overflow else { return nil }
      result.count = sum.partialValue
      result.totalCoin = total.partialValue
      result.hasKnownTotal = previous.gift.hasKnownTotal && gift.hasKnownTotal
      result.aggregationID = previous.gift.aggregationID
    } else {
      result.aggregationID = UUID()
    }
    if groups.count >= capacity, groups[key] == nil { groups.removeAll(keepingCapacity: true) }
    groups[key] = Group(gift: result, updated: now)
    return result
  }
}

public struct LiveChatReducer: Sendable {
  private var gifts = LiveGiftAggregator()
  private var seen: Set<String> = []
  private var order: [String] = []
  public init() {}
  /// Kept across socket reconnects; reset only for a new room/identity session.
  public mutating func ingest(_ event: LiveChatEvent, now: TimeInterval) -> LiveChatEvent? {
    var key: String?
    switch event {
    case .gift(let gift): return gifts.ingest(gift, now: now).map(LiveChatEvent.gift)
    case .danmaku(let message): if let id = message.id, !id.isEmpty { key = "dm:\(id)" }
    case .superChat(let message): key = "sc:\(message.id)"
    default: break
    }
    if let key {
      guard seen.insert(key).inserted else { return nil }
      order.append(key)
      if order.count > 4096 { seen.remove(order.removeFirst()) }
    }
    return event
  }
}

extension LiveChatPacket {
  static func value(_ object: Any?) -> LiveJSON {
    guard let object, JSONSerialization.isValidJSONObject([object]),
      let raw = try? JSONSerialization.data(withJSONObject: [object]),
      let value = try? JSONDecoder().decode([LiveJSON].self, from: raw).first
    else { return .null }
    return value
  }
  static func giftV2(_ base64: String) -> [LiveChatEvent] {
    // Local resource limits, not protocol guarantees. Schema fixed to blivedm/models/pb.py
    // 3bf17fe862b8c2fc6bc04c81c3f0c5db95de93d6: gift_list=10, total_coin=7, rnd=12.
    guard base64.utf8.count <= 1_400_000, let bytes = Data(base64Encoded: base64),
      bytes.count <= 1_048_576
    else { return [] }
    var options = BinaryDecodingOptions()
    options.messageDepthLimit = 16
    options.discardUnknownFields = true
    guard
      let broadcast = try? Bilibili_Live_Gift_V1_SendGiftBroadcast(
        serializedBytes: bytes, options: options),
      broadcast.giftList.count <= 1024
    else { return [] }
    return broadcast.giftList.compactMap { gift in
      guard gift.num > 0 else { return nil }
      return .gift(
        LiveGiftMessage(
          uid: broadcast.uid, user: broadcast.uname, giftID: gift.giftID, name: gift.giftName,
          count: gift.num, price: gift.price, totalCoin: gift.totalCoin, coinType: gift.coinType,
          tid: gift.tid,
          batchID: gift.rnd, timestamp: gift.timestamp == 0 ? nil : gift.timestamp,
          raw: .object([
            "uid": .integer(broadcast.uid), "guard_level": .integer(broadcast.guardLevel),
            "face": .string(broadcast.face), "gift_type": .integer(gift.giftType),
            "action": .string(gift.action),
            "img_basic": .string(gift.giftInfo.imgBasic),
            "medal_info": .object([
              "target_id": .integer(broadcast.medalInfo.targetID),
              "anchor_roomid": .integer(broadcast.medalInfo.anchorRoomid),
              "medal_level": .integer(broadcast.medalInfo.medalLevel),
              "medal_name": .string(broadcast.medalInfo.medalName),
            ]),
            "blind_gift": .object([
              "original_gift_name": .string(broadcast.blindGift.originalGiftName),
              "original_gift_price": .integer(broadcast.blindGift.originalGiftPrice),
            ]),
          ])))
    }
  }
}
