import Foundation

public struct BrowseVideoPage: Sendable, Equatable {
  public let items: [Video]
  public let nextCursor: String?
  public init(items: [Video], nextCursor: String? = nil) {
    self.items = items
    self.nextCursor = nextCursor
  }
}

public struct VideoPartition: Identifiable, Sendable, Equatable {
  public let id: Int
  public let title: String
  public let children: [VideoPartition]
  public init(id: Int, title: String, children: [VideoPartition] = []) {
    self.id = id
    self.title = title
    self.children = children
  }
}

public enum PartitionOrder: String, CaseIterable, Sendable {
  case recommended, newest, views, danmaku, favorites, replies
  var parameter: String? {
    switch self {
    case .recommended: nil
    case .newest: "senddate"
    case .views: "view"
    case .danmaku: "danmaku"
    case .favorites: "favorite"
    case .replies: "reply"
    }
  }
}

extension BiliService {
  public func recommend(cursor: String? = nil) async throws -> BrowseVideoPage {
    let index = try browseOffset(cursor)
    let payload = try await appObject(
      .recommend,
      fields: [
        "idx": String(index), "flush": "5", "column": "4", "device": "desktop",
        "pull": index == 0 ? "true" : "false",
      ])
    guard let raw = payload["items"] as? [[String: Any]] else {
      throw BiliError.invalidResponse("Missing recommendation items")
    }
    let items = try raw.filter { $0["card_goto"] as? String == "av" }.map(Self.appVideo)
    // Cursor belongs to the raw feed, including non-video cards at its tail.
    let next = raw.last.flatMap { JSONValue.int64($0["idx"]) }
    return BrowseVideoPage(
      items: items, nextCursor: next.flatMap { $0 > 0 && $0 != index ? String($0) : nil })
  }

  public func videoPartitions() async throws -> [VideoPartition] {
    guard let raw = try await appREST(.partitions) as? [[String: Any]] else {
      throw BiliError.invalidResponse("Missing partition list")
    }
    func parse(_ item: [String: Any]) throws -> VideoPartition {
      guard let id = JSONValue.int64(item["tid"]), id > 0, let title = item["name"] as? String
      else {
        throw BiliError.invalidResponse("Invalid video partition")
      }
      return VideoPartition(
        id: Int(id), title: title,
        children: try (item["children"] as? [[String: Any]] ?? []).map(parse))
    }
    return try raw.filter {
      let uri = $0["uri"] as? String ?? ""
      return uri.hasPrefix("bilibili") && uri.contains("region/")
        && !($0["children"] as? [[String: Any]] ?? []).isEmpty
    }.map(parse)
  }

  public func partitionFeed(
    rid: Int, child: Bool, order: PartitionOrder,
    cursor: String? = nil
  ) async throws -> BrowseVideoPage {
    guard rid > 0 else { throw BiliError.invalidResponse("Invalid partition") }
    var fields = ["rid": String(rid), "pull": "0"]
    if let sort = order.parameter {
      let page = try browseOffset(cursor)
      guard page < Int64.max else { throw BiliError.invalidResponse("Invalid page cursor") }
      fields["order"] = sort
      fields["pn"] = String(page)
      fields["ps"] = "30"
      guard let raw = try await appREST(.childSorted, fields: fields) as? [[String: Any]] else {
        throw BiliError.invalidResponse("Missing ordered partition list")
      }
      return BrowseVideoPage(
        items: try Self.uniqueAppVideos(raw),
        nextCursor: raw.count < 30 ? nil : String(page + 1))
    }
    let offset = try browseOffset(cursor)
    if offset > 0 { fields["ctime"] = String(offset) }
    let route: BiliAppRoute =
      child ? (offset > 0 ? .childMore : .child) : (offset > 0 ? .regionMore : .region)
    let payload = try await appObject(route, fields: fields)
    guard let fresh = payload["new"] as? [[String: Any]] else {
      throw BiliError.invalidResponse("Missing partition items")
    }
    let raw = fresh + (payload["recommend"] as? [[String: Any]] ?? [])
    let next = JSONValue.int64(payload["cbottom"])
    return BrowseVideoPage(
      items: try Self.uniqueAppVideos(raw),
      nextCursor: next.flatMap { $0 > 0 && $0 != offset ? String($0) : nil })
  }

  private func browseOffset(_ cursor: String?) throws -> Int64 {
    guard let cursor else { return 0 }
    guard let value = Int64(cursor), value >= 0 else {
      throw BiliError.invalidResponse("Invalid feed cursor")
    }
    return value
  }
  private static func uniqueAppVideos(_ raw: [[String: Any]]) throws -> [Video] {
    var seen = Set<String>()
    return try raw.filter { ($0["goto"] as? String ?? "av") == "av" }.map(appVideo).filter {
      seen.insert($0.id).inserted
    }
  }
  static func appVideo(_ item: [String: Any]) throws -> Video {
    let args = item["args"] as? [String: Any] ?? [:]
    let player = item["player_args"] as? [String: Any] ?? [:]
    // RecommendCard exposes formatted counts, not the partition card's numeric play field.
    let viewsText = (item["cover_left_text_1"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let aid =
      JSONValue.int64(args["aid"]) ?? JSONValue.int64(player["aid"])
      ?? JSONValue.int64(item["aid"]) ?? JSONValue.int64(item["param"])
    guard let aid, aid > 0, let title = item["title"] as? String else {
      throw BiliError.invalidResponse("Missing App video identifier/title")
    }
    return Video(
      bvid: item["bvid"] as? String ?? "", title: title,
      cover: JSONValue.url(item["cover"] ?? item["pic"]),
      author: args["up_name"] as? String ?? item["name"] as? String ?? "",
      duration: JSONValue.int(player["duration"] ?? item["duration"]),
      views: viewsText.flatMap(appCountNumber) ?? JSONValue.int(item["play"]),
      cid: JSONValue.int64(player["cid"] ?? item["cid"]),
      aid: aid, authorID: JSONValue.int64(args["up_id"] ?? item["mid"]),
      avatar: JSONValue.url(item["face"]), publishedAt: JSONValue.int64(item["pubdate"]),
      subtitle: item["subtitle"] as? String ?? item["right_desc_2"] as? String,
      recommendationReason: (item["rcmd_reason_style"] as? [String: Any])?["text"] as? String
        ?? (item["rcmd_reason"] as? [String: Any])?["content"] as? String
        ?? item["rcmd_reason"] as? String,
      viewsText: viewsText.flatMap { $0.isEmpty ? nil : $0 })
  }

  // Matches BiliKernel's ToCountNumber units; these are approximate API display counts.
  private static func appCountNumber(_ text: String) -> Int? {
    let multiplier: Double = text.hasSuffix("亿") ? 100_000_000 : (text.hasSuffix("万") ? 10_000 : 1)
    let number = multiplier == 1 ? text : String(text.dropLast())
    guard let value = Double(number), value.isFinite, value >= 0,
      value * multiplier < Double(Int.max) else { return nil }
    return Int(value * multiplier)
  }
}
