import Foundation

public struct LiveUserInfo: Sendable, Equatable {
  public let danmakuLength: Int?
  public let gold: Int64
  public let silver: Int64
  public let medal: LiveJSON
  public let raw: LiveJSON
  public init(_ data: LiveJSON) {
    raw = data
    danmakuLength = data["property"]["danmu"]["length"].int64.flatMap {
      $0 > 0 ? Int(exactly: $0) : nil
    }
    gold = data["wallet"]["gold"].int64 ?? 0
    silver = data["wallet"]["silver"].int64 ?? 0
    medal = data["medal"]["curr_weared_v2"]
  }
}
public struct LiveDMConfig: Sendable, Equatable {
  public let groups: [LiveJSON]
  public let modes: [LiveJSON]
  public init(_ data: LiveJSON) {
    groups = data["group"].array ?? []
    modes = data["mode"].array ?? []
  }
}
public struct LiveEmoticonPackage: Sendable, Equatable {
  public let name: String
  public let emoticons: [LiveJSON]
  public init(_ data: LiveJSON) {
    name = data["pkg_name"].string ?? ""
    emoticons = data["emoticons"].array ?? []
  }
}
public struct LiveGift: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let name: String
  /// Gold seeds, not batteries; this is a display price, never a payment receipt.
  public let price: Int64
  public let coinType: String
  public let raw: LiveJSON
  public init?(_ data: LiveJSON) {
    guard let id = data["id"].int64 ?? data["gift_id"].int64, id > 0 else { return nil }
    self.id = id
    raw = data
    name = data["name"].string ?? data["gift_name"].string ?? ""
    price = data["price"].int64 ?? 0
    coinType = data["coin_type"].string ?? "unknown"
  }
  /// Prefer static artwork; reject empty, relative and non-web values before falling back.
  public var imageURL: URL? { Self.imageURL(in: raw) }
  public static func imageURL(in raw: LiveJSON) -> URL? {
    for key in ["img_basic", "webp"] {
      if let url = imageURL(raw[key].string) { return url }
    }
    return nil
  }
  public static func imageURL(_ value: String?) -> URL? {
    guard let value, !value.isEmpty else { return nil }
    let normalized = value.hasPrefix("//") ? "https:" + value : value
    guard let url = URL(string: normalized), ["https", "http"].contains(url.scheme),
      let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }
  /// Intersect the room panel with global metadata; never offer the entire global catalog.
  public static func roomAvailable(panel: LiveJSON, config: LiveJSON) -> [LiveGift] {
    let catalog = Dictionary(
      (config["list"].array ?? []).compactMap(LiveGift.init).map { ($0.id, $0) },
      uniquingKeysWith: { _, last in last })
    var seen: Set<Int64> = []
    let roomList = panel["gift_data"]["room_gift_list"]
    let list = roomList == .null ? panel : roomList
    return ((list["gold_list"].array ?? []) + (list["silver_list"].array ?? [])).compactMap {
      entry in
      guard let id = entry["id"].int64 ?? entry["gift_id"].int64, seen.insert(id).inserted else {
        return nil
      }
      if case .object(let roomFields) = entry, let base = catalog[id],
        case .object(var fields) = base.raw
      {
        fields.merge(roomFields, uniquingKeysWith: { _, room in room })
        return LiveGift(.object(fields))
      }
      return LiveGift(entry)
    }
  }
}
public struct LiveBagItem: Sendable, Equatable {
  public let bagID: Int64
  public let giftID: Int64
  public let count: Int64
  public let expiresAt: Int64?
  public let raw: LiveJSON
  public init?(_ data: LiveJSON) {
    guard let bag = data["bag_id"].int64, let gift = data["gift_id"].int64 else { return nil }
    bagID = bag
    giftID = gift
    count = data["gift_num"].int64 ?? 0
    expiresAt = data["expire_at"].int64
    raw = data
  }
}
public struct LiveSuperChat: Sendable, Equatable, Identifiable {
  public let id: String
  public let uid: Int64
  public let user: String
  public let text: String
  public let price: Int
  public let startTime: Int64
  public let endTime: Int64
  public let raw: LiveJSON
  public init?(_ data: LiveJSON) {
    guard let id = data["id"].string ?? data["id"].int64.map(String.init), !id.isEmpty else {
      return nil
    }
    self.id = id
    uid = data["uid"].int64 ?? 0
    user = data["user_info"]["uname"].string ?? ""
    text = data["message"].string ?? ""
    price = data["price"].int64.flatMap(Int.init(exactly:)) ?? 0
    startTime = data["start_time"].int64 ?? 0
    endTime = data["end_time"].int64 ?? 0
    raw = data
  }
}
public struct LiveLotteryInfo: Sendable, Equatable {
  public let anchor: LiveJSON
  public let redPocket: LiveJSON
  public let raw: LiveJSON
  public init(_ data: LiveJSON) {
    raw = data
    anchor = data["anchor"]
    redPocket = data["popularity_red_pocket"]
  }
}

extension BiliService {
  public func liveUserInfo(roomID: Int64, expectedIdentity: AuthSnapshot) async throws
    -> LiveUserInfo
  {
    LiveUserInfo(
      try await liveRead(
        .infoByUser, fields: ["room_id": String(roomID)], expectedIdentity: expectedIdentity))
  }
  public func liveDMConfig(roomID: Int64, expectedIdentity: AuthSnapshot) async throws
    -> LiveDMConfig
  {
    LiveDMConfig(
      try await liveRead(
        .dmConfig, fields: ["room_id": String(roomID)], expectedIdentity: expectedIdentity))
  }
  public func liveEmoticons(roomID: Int64, expectedIdentity: AuthSnapshot) async throws
    -> [LiveEmoticonPackage]
  {
    let data = try await liveRead(
      .emoticons, fields: ["room_id": String(roomID)], expectedIdentity: expectedIdentity)
    return (data["data"].array ?? data["list"].array ?? []).map(LiveEmoticonPackage.init)
  }
  public func liveRoomGifts(
    roomID: Int64, areaParentID: Int64 = 0, areaID: Int64 = 0, expectedIdentity: AuthSnapshot
  ) async throws -> [LiveGift] {
    let panel = try await liveRead(
      .roomGiftList,
      fields: [
        "room_id": String(roomID), "area_parent_id": String(areaParentID),
        "area_id": String(areaID),
      ], expectedIdentity: expectedIdentity)
    let config = try await liveRead(
      .giftConfig, fields: ["room_id": String(roomID)], expectedIdentity: expectedIdentity)
    return LiveGift.roomAvailable(panel: panel, config: config)
  }
  public func liveBag(roomID: Int64, expectedIdentity: AuthSnapshot) async throws -> [LiveBagItem] {
    let data = try await liveRead(
      .bagList, fields: ["room_id": String(roomID)], expectedIdentity: expectedIdentity)
    return (data["list"].array ?? []).compactMap(LiveBagItem.init)
  }
  public func liveSuperChats(roomID: Int64, expectedIdentity: AuthSnapshot) async throws
    -> [LiveSuperChat]
  {
    let data = try await liveRead(
      .superChatList, fields: ["room_id": String(roomID)], expectedIdentity: expectedIdentity)
    return (data["list"].array ?? []).compactMap(LiveSuperChat.init)
  }
  public func liveLotteryInfo(roomID: Int64, expectedIdentity: AuthSnapshot) async throws
    -> LiveLotteryInfo
  {
    LiveLotteryInfo(
      try await liveRead(
        .lotteryInfo, fields: ["roomid": String(roomID)], expectedIdentity: expectedIdentity))
  }
  private func liveRead(
    _ route: LiveRoute, fields: [String: String], expectedIdentity: AuthSnapshot
  ) async throws -> LiveJSON {
    let response = try await liveRequest(route, fields: fields, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    return try response.checkedData(for: route)
  }
}
