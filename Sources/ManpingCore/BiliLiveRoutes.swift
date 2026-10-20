import Foundation

/// Community contracts are candidates, not captured authenticated evidence. Production gates
/// remain closed until the corresponding operation is verified; see docs/LiveContracts.md.
public enum LiveRoute: String, CaseIterable, Sendable {
  case infoByUser, dmConfig, emoticons, roomGiftList, giftConfig, bagList, superChatList,
    lotteryInfo, medalPanel, danmuInfo
  case sendDanmaku, setDMConfig, sendBag, sendGold, like, wearMedal, takeOffMedal, joinLottery,
    drawRedPocket

  public var path: String {
    switch self {
    case .infoByUser: "/xlive/web-room/v1/index/getInfoByUser"
    case .dmConfig: "/xlive/web-room/v1/dM/GetDMConfigByGroup"
    case .emoticons: "/xlive/web-ucenter/v2/emoticon/GetEmoticons"
    case .roomGiftList: "/xlive/web-room/v1/giftPanel/roomGiftList"
    case .giftConfig: "/xlive/web-room/v1/giftPanel/giftConfig"
    case .bagList: "/xlive/web-room/v1/gift/bag_list"
    case .superChatList: "/av/v1/SuperChat/getMessageList"
    case .lotteryInfo: "/xlive/lottery-interface/v1/lottery/getLotteryInfoWeb"
    case .medalPanel: "/xlive/app-ucenter/v1/fansMedal/panel"
    case .danmuInfo: "/xlive/web-room/v1/index/getDanmuInfo"
    case .sendDanmaku: "/msg/send"
    case .setDMConfig: "/xlive/web-room/v1/dM/AjaxSetConfig"
    case .sendBag: "/xlive/revenue/v2/gift/sendBagMultiUser"
    case .sendGold: "/xlive/revenue/v1/gift/sendGold"
    case .like: "/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3"
    // Captured 2026-10-20 (docs/LiveContracts.md): the web page wears medals through app-ucenter.
    case .wearMedal: "/xlive/app-ucenter/v1/fansMedal/wear"
    case .takeOffMedal: "/xlive/web-room/v1/fansMedal/take_off"
    case .joinLottery: "/xlive/lottery-interface/v1/Anchor/Join"
    case .drawRedPocket: "/xlive/lottery-interface/v1/popularityRedPocket/RedPocketDraw"
    }
  }
  public var url: URL { URL(string: "https://api.live.bilibili.com" + path)! }
  public var isMutation: Bool {
    switch self {
    case .sendDanmaku, .setDMConfig, .sendBag, .sendGold, .like, .wearMedal, .takeOffMedal,
      .joinLottery, .drawRedPocket:
      true
    default: false
    }
  }
  public var method: String { isMutation ? "POST" : "GET" }
  public enum CSRF: Sendable { case none, form, formBoth, query }
  public var csrf: CSRF {
    switch self {
    case .sendDanmaku, .sendGold, .wearMedal, .takeOffMedal, .setDMConfig: .formBoth
    case .joinLottery: .form
    case .sendBag, .like, .drawRedPocket: .query
    default: .none
    }
  }
  /// WBI signs exactly the query fields, never the form body. The ambiguous like route uses
  /// BLTH's query variant; sendGold is still conjectural. Neither is open in production.
  public var signedQuery: Bool {
    switch self {
    case .danmuInfo, .bagList, .sendDanmaku, .sendBag, .sendGold, .like: true
    default: false
    }
  }
  public var queryFields: Set<String> {
    switch self {
    case .infoByUser: ["room_id"]
    case .dmConfig: ["room_id"]
    case .emoticons: ["platform", "room_id"]
    case .roomGiftList: ["platform", "room_id", "area_parent_id", "area_id"]
    case .giftConfig: ["platform", "room_id"]
    case .bagList: ["t", "room_id", "mobi_app", "receive_users", "web_location"]
    case .superChatList: ["room_id"]
    case .lotteryInfo: ["roomid"]
    case .medalPanel: ["page", "page_size", "room_id", "target_id"]
    case .danmuInfo: ["id", "type", "web_location"]
    case .sendDanmaku, .sendGold: ["web_location"]
    case .sendBag:
      [
        "uid", "gift_id", "ruid", "send_ruid", "gift_num", "bag_id", "platform", "biz_code",
        "biz_id", "storm_beat_id", "metadata", "price", "receive_users", "live_statistics",
        "statistics", "web_location",
      ]
    case .like: ["click_time", "room_id", "uid", "anchor_id", "web_location"]
    default: []
    }
  }
  public var bodyFields: Set<String> {
    switch self {
    case .sendDanmaku:
      [
        "bubble", "msg", "color", "mode", "room_type", "jumpfrom", "reply_mid", "reply_attr",
        "replay_dmid", "reply_type", "reply_uname", "statistics", "data_extend", "fontsize", "rnd",
        "roomid", "dm_type", "emoticonOptions",
      ]
    case .setDMConfig: ["room_id", "color", "mode", "visit_id"]
    case .sendGold:
      [
        "uid", "gift_id", "ruid", "send_ruid", "gift_num", "coin_type", "bag_id", "platform",
        "biz_code", "biz_id", "storm_beat_id", "metadata", "price", "receive_users",
        "live_statistics", "statistics",
      ]
    case .wearMedal: ["medal_id", "target_id", "visit_id"]
    case .joinLottery: ["room_id", "id", "platform"]
    case .drawRedPocket: ["uid", "room_id", "ruid", "lot_id", "ts"]
    default: []
    }
  }
  public var requiredFields: Set<String> {
    switch self {
    case .infoByUser, .dmConfig, .emoticons, .roomGiftList, .giftConfig, .bagList, .superChatList:
      ["room_id"]
    case .lotteryInfo: ["roomid"]
    case .medalPanel, .takeOffMedal: []
    case .danmuInfo: ["id"]
    case .sendDanmaku: ["msg", "roomid", "rnd"]
    case .setDMConfig: ["room_id"]
    case .sendBag: ["uid", "gift_id", "ruid", "gift_num", "bag_id", "biz_id"]
    case .sendGold: ["uid", "gift_id", "ruid", "gift_num", "biz_id", "price", "coin_type"]
    case .like: ["click_time", "room_id", "uid", "anchor_id"]
    case .wearMedal: ["medal_id"]
    case .joinLottery: ["room_id", "id"]
    case .drawRedPocket: ["uid", "room_id", "ruid", "lot_id", "ts"]
    }
  }
  public func accepts(_ envelope: LiveEnvelope) -> Bool {
    guard envelope.code == 0 else { return false }
    switch self {
    case .sendDanmaku: return envelope.message.isEmpty
    // Success business receipts for these candidates have not been captured. Unit 2 must
    // inspect their data before granting success; code 0 alone cannot authorize a purchase.
    case .sendGold:
      return envelope.data["total_coin"].int64 != nil && envelope.data["gift_list"].array != nil
    case .joinLottery, .drawRedPocket: return false
    default: return true
    }
  }
  public func fields(_ input: [String: String], timestamp: Int64) throws -> (
    query: [String: String], body: [String: String]
  ) {
    guard Set(input.keys).isSubset(of: queryFields.union(bodyFields)),
      requiredFields.allSatisfy({ !(input[$0] ?? "").isEmpty })
    else { throw LiveRouteError.invalidFields(self) }
    if self == .setDMConfig, (input["color"] == nil) == (input["mode"] == nil) {
      throw LiveRouteError.invalidFields(self)
    }
    if self == .sendDanmaku, input["dm_type"] == "1" {
      guard input["emoticonOptions"] == "[object Object]",
        !input.keys.contains(where: { $0.hasPrefix("reply_") || $0 == "replay_dmid" })
      else { throw LiveRouteError.invalidFields(self) }
    }
    var values: [String: String] = [:]
    switch self {
    case .emoticons, .giftConfig: values = ["platform": "pc"]
    case .roomGiftList: values = ["platform": "pc", "area_parent_id": "0", "area_id": "0"]
    case .bagList:
      values = [
        "t": String(timestamp * 1000), "mobi_app": "web", "receive_users": "[]",
        "web_location": "444.8",
      ]
    case .medalPanel: values = ["page": "1", "page_size": "10"]
    case .danmuInfo: values = ["type": "0", "web_location": "444.8"]
    case .sendDanmaku:
      values = [
        "bubble": "0", "color": "16777215", "mode": "1", "room_type": "0", "jumpfrom": "0",
        "fontsize": "25", "statistics": "{\"appId\":100,\"platform\":5}", "web_location": "444.8",
        "data_extend": "{\"trackid\":\"-99998\"}",
      ]
      // A plain or reply danmaku carries the reply fields (empty when not replying), as the web
      // page sends them; an emoticon danmaku carries none.
      if input["dm_type"] != "1" {
        values.merge(
          ["reply_mid": "0", "reply_attr": "0", "replay_dmid": "", "reply_type": "0", "reply_uname": ""],
          uniquingKeysWith: { old, _ in old })
      }
    case .setDMConfig, .wearMedal: values = ["visit_id": ""]
    case .sendBag, .sendGold:
      values = [
        "send_ruid": "0", "platform": "pc", "biz_code": "Live", "storm_beat_id": "0",
        "metadata": "", "receive_users": "[{\"uid\":\(input["ruid"] ?? "0")}]",
        "live_statistics":
          "{\"pc_client\":\"pcWeb\",\"jumpfrom\":\"-99998\",\"room_category\":\"0\",\"source_event\":0,\"trackid\":\"-99998\"}",
        "statistics": "{\"platform\":5,\"pc_client\":\"pcWeb\",\"appId\":100}",
        "web_location": "444.8",
      ]
      if self == .sendBag { values["price"] = "0" } else { values["bag_id"] = "0" }
    case .like: values = ["web_location": "444.8"]
    case .joinLottery: values = ["platform": "pc"]
    default: break
    }
    values.merge(input, uniquingKeysWith: { _, new in new })
    return (
      values.filter { queryFields.contains($0.key) }, values.filter { bodyFields.contains($0.key) }
    )
  }
}

public struct LiveMutationGate: Sendable {
  private let enabled: Set<LiveRoute>
  public init(enabled: Set<LiveRoute> = []) { self.enabled = enabled }
  /// Routes whose request and success response were captured from the web page on 2026-10-20
  /// (docs/LiveContracts.md). Battery gifts, taking a medal off and activities stay closed.
  public static let production = LiveMutationGate(enabled: [.sendDanmaku, .setDMConfig, .like, .wearMedal, .sendBag])
  public func allows(_ route: LiveRoute) -> Bool { !route.isMutation || enabled.contains(route) }
}
public enum LiveRouteError: Error, Equatable {
  case mutationClosed(LiveRoute)
  case invalidFields(LiveRoute)
  case missingWebIdentity
}

/// JSON model keeps unknown business fields and exact Int64 values; LiveEnvelope retains raw bytes.
public enum LiveJSON: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([LiveJSON])
  case object([String: LiveJSON])
  public init(from decoder: Decoder) throws {
    let box = try decoder.singleValueContainer()
    if box.decodeNil() {
      self = .null
    } else if let value = try? box.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? box.decode(String.self) {
      self = .string(value)
    } else if let value = try? box.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? box.decode(Double.self) {
      self = .number(value)
    } else if let value = try? box.decode([LiveJSON].self) {
      self = .array(value)
    } else {
      self = .object(try box.decode([String: LiveJSON].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var box = encoder.singleValueContainer()
    switch self {
    case .null: try box.encodeNil()
    case .bool(let x): try box.encode(x)
    case .integer(let x): try box.encode(x)
    case .number(let x): try box.encode(x)
    case .string(let x): try box.encode(x)
    case .array(let x): try box.encode(x)
    case .object(let x): try box.encode(x)
    }
  }
  public subscript(_ key: String) -> LiveJSON {
    if case .object(let x) = self { return x[key] ?? .null }
    return .null
  }
  public var array: [LiveJSON]? {
    if case .array(let x) = self { return x }
    return nil
  }
  public var string: String? {
    if case .string(let x) = self { return x }
    return nil
  }
  public var int64: Int64? {
    switch self {
    case .integer(let x): return x
    case .string(let x): return Int64(x)
    case .number(let x): return Int64(exactly: x)
    default: return nil
    }
  }
}
public struct LiveEnvelope: Sendable, Equatable, Decodable {
  public let code: Int
  public let message: String
  public let data: LiveJSON
  public let raw: Data
  public init(from decoder: Decoder) throws {
    let root = try LiveJSON(from: decoder)
    guard let code = root["code"].int64, let exact = Int(exactly: code) else {
      throw BiliError.invalidResponse("Missing live envelope code")
    }
    self.code = exact
    message = root["message"].string ?? root["msg"].string ?? ""
    data = root["data"]
    raw = Data()
  }
  private init(decoded: LiveEnvelope, raw: Data) {
    code = decoded.code
    message = decoded.message
    data = decoded.data
    self.raw = raw
  }
  public static func parse(_ raw: Data) throws -> LiveEnvelope {
    LiveEnvelope(decoded: try JSONDecoder().decode(Self.self, from: raw), raw: raw)
  }
  public func checkedData(for route: LiveRoute) throws -> LiveJSON {
    guard route.accepts(self) else { throw BiliError.api(code, message) }
    return data
  }
}

/// Immutable request prepared with the captured identity; construction stays inside Core.
struct LivePreparedRequest: Sendable {
  let request: URLRequest
  let identity: AuthSnapshot
}
