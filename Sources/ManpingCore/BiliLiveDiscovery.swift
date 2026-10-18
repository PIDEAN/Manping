import Foundation

public struct LivePartition: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let title: String
  public let parentID: Int64?
  public let cover: URL?
  public let children: [LivePartition]
  public init(id: Int64, title: String, parentID: Int64? = nil, cover: URL? = nil,
    children: [LivePartition] = []) {
    self.id = id; self.title = title; self.parentID = parentID; self.cover = cover; self.children = children
  }
}
public struct LiveTag: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let title: String
  public let sortType: String
  public init(id: Int64, title: String, sortType: String) {
    self.id = id; self.title = title; self.sortType = sortType
  }
}
public struct LiveRoom: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let title: String
  public let cover: URL?
  public let authorID: Int64?
  public let author: String
  public let avatar: URL?
  public let subtitle: String
  public let viewers: Double?
  public var webURL: URL? {
    guard id > 0 else { return nil }
    return URL(string: "https://live.bilibili.com/\(id)")
  }
  public init(id: Int64, title: String, cover: URL? = nil, authorID: Int64? = nil,
    author: String = "", avatar: URL? = nil, subtitle: String = "", viewers: Double? = nil) {
    self.id = id; self.title = title; self.cover = cover; self.authorID = authorID
    self.author = author; self.avatar = avatar; self.subtitle = subtitle; self.viewers = viewers
  }
}
public struct LiveRoomPage: Sendable {
  public let rooms: [LiveRoom]
  public let tags: [LiveTag]
  public let nextPage: Int
  public let hasMore: Bool
}
public struct LiveFeedPage: Sendable {
  public let rooms: [LiveRoom]
  public let following: [LiveRoom]
  public let nextPage: Int
  public let hasMore: Bool
}

// Exact BiliKernel 22fdf8ca LiveDiscoveryService/Client. Swift's page parameter
// is the actual HTTP page (one-based), rather than the SDK's prior-page offset.
// All three routes use App signing and optional access_key, without cookies.
extension BiliService {
  public func livePartitions(expectedIdentity: AuthSnapshot? = nil) async throws -> [LivePartition] {
    let identity = expectedIdentity ?? authSnapshot()
    let data = try await appObject(.liveAreas, expectedIdentity: identity)
    return try Self.liveList(data, key: "list").map { group in
      guard let id = JSONValue.int64(group["id"]), id >= 0, let title = group["name"] as? String else {
        throw BiliError.invalidResponse("Invalid live partition")
      }
      let children = try Self.liveList(group, key: "area_list").map { area -> LivePartition in
        guard let areaID = JSONValue.int64(area["id"]), areaID >= 0,
          let name = area["name"] as? String,
          let parent = JSONValue.int64(area["parent_id"]), parent >= 0 else {
          throw BiliError.invalidResponse("Invalid live child partition")
        }
        return LivePartition(id: areaID, title: name, parentID: parent, cover: JSONValue.url(area["pic"]))
      }
      return LivePartition(id: id, title: title, children: children)
    }
  }

  public func livePartitionRooms(area: LivePartition, tag: LiveTag? = nil, page: Int = 1,
    expectedIdentity: AuthSnapshot? = nil) async throws -> LiveRoomPage {
    try livePageNumber(page)
    guard area.id >= 0, let parentID = area.parentID, parentID >= 0 else {
      throw BiliError.invalidResponse("Invalid live area identifier")
    }
    let identity = expectedIdentity ?? authSnapshot()
    var fields = ["page": String(page), "page_size": "40", "area_id": String(area.id),
      "parent_area_id": String(parentID), "device": "phone"]
    if let tag { fields["sort_type"] = tag.sortType }
    let data = try await appObject(.liveRooms, fields: fields, expectedIdentity: identity)
    let raw = try Self.liveList(data, key: "list")
    let tags = try Self.liveList(data, key: "new_tags", optional: true).map { tag -> LiveTag in
      guard let id = JSONValue.int64(tag["id"]), let title = tag["name"] as? String else {
        throw BiliError.invalidResponse("Invalid live sort tag")
      }
      return LiveTag(id: id, title: title, sortType: tag["sort_type"] as? String ?? "")
    }
    // Exact SDK has no cursor/has_more contract and stops on an empty list.
    return LiveRoomPage(rooms: try raw.map { try Self.liveRoom($0, recommended: false) },
      tags: tags, nextPage: page + 1, hasMore: !raw.isEmpty)
  }

  public func liveFeed(page: Int = 1, expectedIdentity: AuthSnapshot? = nil) async throws -> LiveFeedPage {
    try livePageNumber(page)
    let identity = expectedIdentity ?? authSnapshot()
    let data = try await appObject(.liveFeed, fields: ["page": String(page), "relation_page": String(page),
      "scale": "2", "login_event": identity.token == nil ? "1" : "2", "device": "phone"], expectedIdentity: identity)
    var rooms: [LiveRoom] = []; var following: [LiveRoom] = []
    for card in try Self.liveList(data, key: "card_list") {
      let type = card["card_type"] as? String ?? ""
      let body = card["card_data"] as? [String: Any] ?? [:]
      if type.contains("idol"), let list = body["my_idol_v1"] as? [String: Any] {
        following += try Self.liveList(list, key: "list").map { try Self.liveRoom($0, recommended: false) }
      }
      if type.contains("small_card"), let room = body["small_card_v1"] as? [String: Any] {
        rooms.append(try Self.liveRoom(room, recommended: true))
      }
    }
    return LiveFeedPage(rooms: rooms, following: following, nextPage: page + 1, hasMore: !rooms.isEmpty)
  }
  private func livePageNumber(_ page: Int) throws {
    guard (1...1_000_000).contains(page) else { throw BiliError.invalidResponse("Invalid live page") }
  }
  private static func liveList(_ data: [String: Any], key: String, optional: Bool = false) throws -> [[String: Any]] {
    if let list = data[key] as? [[String: Any]] { return list }
    if data[key] is NSNull || (optional && data[key] == nil) { return [] }
    throw BiliError.invalidResponse("Missing live \(key)")
  }
  private static func liveRoom(_ data: [String: Any], recommended: Bool) throws -> LiveRoom {
    guard let id = JSONValue.int64(data[recommended ? "id" : "roomid"]), id > 0,
      let title = data["title"] as? String else { throw BiliError.invalidResponse("Invalid live room") }
    let left = data["cover_left_style"] as? [String: Any]
    let right = data["cover_right_style"] as? [String: Any]
    let viewers: Double?
    if recommended { viewers = liveCount(right?["text"] as? String) }
    else if let value = data["online"] as? NSNumber, value.doubleValue >= 0 { viewers = value.doubleValue }
    else { viewers = liveCount(data["online"] as? String) }
    return LiveRoom(id: id, title: libraryPlain(title), cover: JSONValue.url(data["cover"]),
      authorID: JSONValue.int64(data["uid"]), author: data["uname"] as? String ?? "",
      avatar: recommended ? nil : JSONValue.url(data["face"]),
      subtitle: recommended ? left?["text"] as? String ?? "" : data["area_v2_name"] as? String ?? "",
      viewers: viewers)
  }
  private static func liveCount(_ text: String?) -> Double? {
    guard let text else { return nil }
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
    let multiplier: Double
    if value.hasSuffix("万") { multiplier = 10_000; value.removeLast() }
    else if value.hasSuffix("亿") { multiplier = 100_000_000; value.removeLast() }
    else { multiplier = 1 }
    guard let number = Double(value), number.isFinite, number >= 0 else { return nil }
    let count = number * multiplier
    return count.isFinite ? count : nil
  }
}
