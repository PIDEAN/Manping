import Foundation

public enum PGCCategory: String, CaseIterable, Sendable {
  case anime, movie, tv, documentary
  public var title: String {
    switch self { case .anime: "动漫索引"; case .movie: "电影"; case .tv: "电视剧"; case .documentary: "纪录片" }
  }
  var fields: [String: String] {
    switch self {
    case .anime: ["season_type": "1", "type": "0"]
    case .movie: ["index_type": "2", "type": "0"]
    case .tv: ["index_type": "5", "type": "0"]
    case .documentary: ["index_type": "3", "type": "0"]
    }
  }
}
public struct PGCSelection: Hashable, Sendable {
  public let seasonID: Int64?
  public let episodeID: Int64?
  public init(seasonID: Int64? = nil, episodeID: Int64? = nil) {
    self.seasonID = seasonID; self.episodeID = episodeID
  }
  var valid: Bool {
    (seasonID != nil || episodeID != nil) && seasonID.map { $0 > 0 } != false && episodeID.map { $0 > 0 } != false
  }
}
public struct PGCCondition: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public init(id: String, title: String) { self.id = id; self.title = title }
}
public struct PGCFilter: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let choices: [PGCCondition]
  public init(id: String, title: String, choices: [PGCCondition]) { self.id = id; self.title = title; self.choices = choices }
}
public struct PGCSeason: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let title: String
  public let cover: URL?
  public let subtitle: String
  public let badge: String?
  public let episodeID: Int64?
  public let score: Double?
  public let publishedAt: Int64?
  public var selection: PGCSelection { PGCSelection(seasonID: id, episodeID: episodeID) }
  public init(id: Int64, title: String, cover: URL? = nil, subtitle: String = "", badge: String? = nil,
              episodeID: Int64? = nil, score: Double? = nil, publishedAt: Int64? = nil) {
    self.id = id; self.title = title; self.cover = cover; self.subtitle = subtitle; self.badge = badge
    self.episodeID = episodeID; self.score = score; self.publishedAt = publishedAt
  }
}
public struct PGCTimelineDay: Identifiable, Equatable, Sendable {
  public var id: Int64 { timestamp }
  public let timestamp: Int64
  public let title: String
  public let isToday: Bool
  public let seasons: [PGCSeason]
  public static func merged(_ lists: [[Self]]) -> [Self] {
    let grouped = Dictionary(grouping: lists.flatMap { $0 }, by: \.timestamp)
    return grouped.keys.sorted().map { timestamp in
      let days = grouped[timestamp]!
      var known = Set<Int64>()
      let seasons = days.flatMap(\.seasons).filter { known.insert($0.id).inserted }
        .sorted { ($0.publishedAt ?? 0) < ($1.publishedAt ?? 0) }
      return Self(timestamp: timestamp, title: days[0].title, isToday: days.contains(where: \.isToday), seasons: seasons)
    }
  }
}
public struct PGCIndexPage: Sendable {
  public let items: [PGCSeason]
  public let hasMore: Bool
  public let total: Int
}
public struct PGCStats: Sendable, Equatable {
  public let views: Int64?
  public let danmaku: Int64?
  public let likes: Int64?
  public let coins: Int64?
  public let replies: Int64?
  public let favorites: Int64?
  public let followers: Int64?
  static func parse(_ raw: [String: Any], season: Bool = false) -> Self {
    Self(views: JSONValue.int64(raw[season ? "views" : "play"]), danmaku: JSONValue.int64(raw["danmakus"]),
         likes: JSONValue.int64(raw["likes"]), coins: JSONValue.int64(raw["coins"]), replies: JSONValue.int64(raw["reply"]),
         favorites: JSONValue.int64(raw["favorite"]), followers: JSONValue.int64(raw["favorites"]))
  }
}
public struct PGCEpisode: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let seasonID: Int64
  public let seasonType: Int
  public let aid: Int64?
  public let cid: Int64?
  public let bvid: String
  public let index: Int
  public let title: String
  public let subtitle: String
  public let duration: Int
  public let cover: URL?
  public let badge: String?
  public let stats: PGCStats
  public var publicURL: URL { URL(string: "https://www.bilibili.com/bangumi/play/ep\(id)")! }
  static func parse(_ raw: [String: Any], seasonID: Int64, seasonType: Int) throws -> Self {
    let report = raw["report"] as? [String: Any] ?? [:]
    guard let id = JSONValue.int64(report["epid"] ?? raw["id"]), id > 0 else { throw BiliError.invalidResponse("Invalid PGC episode") }
    let sid = JSONValue.int64(report["season_id"]) ?? seasonID
    let type = JSONValue.int(report["season_type"] ?? seasonType)
    guard sid > 0, type > 0 else { throw BiliError.invalidResponse("Invalid PGC season reference") }
    let longTitle = raw["long_title"] as? String ?? ""
    let title = longTitle.isEmpty ? raw["share_copy"] as? String ?? raw["title"] as? String ?? "" : longTitle
    guard !title.isEmpty else { throw BiliError.invalidResponse("Missing PGC episode title") }
    return Self(id: id, seasonID: sid, seasonType: type, aid: JSONValue.int64(raw["aid"] ?? report["aid"]).flatMap { $0 > 0 ? $0 : nil },
      cid: JSONValue.int64(raw["cid"]).flatMap { $0 > 0 ? $0 : nil }, bvid: raw["bvid"] as? String ?? "",
      index: JSONValue.int(raw["ep_index"]), title: title, subtitle: raw["subtitle"] as? String ?? "",
      duration: max(0, JSONValue.int(raw["duration"]) / 1000), cover: JSONValue.url(raw["cover"]), badge: raw["badge"] as? String,
      stats: .parse(raw["stat"] as? [String: Any] ?? [:]))
  }
}
public struct PGCExtraSection: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let episodes: [PGCEpisode]
}
public struct PGCDetails: Equatable, Sendable {
  public let season: PGCSeason
  public let description: String
  public let alias: String
  public let staff: String
  public let actors: String
  public let stats: PGCStats
  public let followed: Bool?
  public let episodes: [PGCEpisode]
  public let seasons: [PGCSeason]
  public let extras: [PGCExtraSection]
  public let progressEpisodeID: Int64?
  public let progressSeconds: Int
  public let warning: String?
  public func initialEpisode(requested: Int64? = nil, restoreHistory: Bool = true) -> PGCEpisode? {
    if let requested, let episode = episodes.first(where: { $0.id == requested }) { return episode }
    if restoreHistory, let progressEpisodeID, let episode = episodes.first(where: { $0.id == progressEpisodeID }) { return episode }
    return episodes.first
  }
  public static func parse(_ raw: [String: Any]) throws -> Self {
    guard let sid = JSONValue.int64(raw["season_id"]), sid > 0, let title = raw["title"] as? String, !title.isEmpty else {
      throw BiliError.invalidResponse("Missing PGC season detail")
    }
    let type = max(1, JSONValue.int(raw["type"]))
    let rating = raw["rating"] as? [String: Any] ?? [:]
    let season = PGCSeason(id: sid, title: title, cover: JSONValue.url(raw["cover"]), subtitle: raw["subtitle"] as? String ?? "",
      badge: raw["badge"] as? String, score: (rating["score"] as? NSNumber)?.doubleValue)
    let modules = raw["modules"] as? [[String: Any]] ?? []
    var episodes: [PGCEpisode] = []; var seasons: [PGCSeason] = []; var extras: [PGCExtraSection] = []
    for (index, module) in modules.enumerated() {
      let data = module["data"] as? [String: Any] ?? [:]
      switch module["style"] as? String {
      case "positive": episodes += try (data["episodes"] as? [[String: Any]] ?? []).map { try PGCEpisode.parse($0, seasonID: sid, seasonType: type) }
      case "section":
        let extra = try (data["episodes"] as? [[String: Any]] ?? []).map { try PGCEpisode.parse($0, seasonID: sid, seasonType: type) }
        if !extra.isEmpty { extras.append(PGCExtraSection(id: "section-\(index)", title: module["title"] as? String ?? "花絮", episodes: extra)) }
      case "season":
        seasons += (data["seasons"] as? [[String: Any]] ?? []).compactMap { item in
          guard let id = JSONValue.int64(item["season_id"]), id > 0 else { return nil }
          return PGCSeason(id: id, title: item["title"] as? String ?? item["season_title"] as? String ?? "", cover: JSONValue.url(item["cover"]), badge: item["badge"] as? String)
        }
      default: break
      }
    }
    var known = Set<Int64>(); episodes = episodes.filter { known.insert($0.id).inserted }
    let status = raw["user_status"] as? [String: Any] ?? [:]
    let progress = status["progress"] as? [String: Any] ?? [:]
    var progressEpisode = JSONValue.int64(progress["last_ep_id"])
    if !episodes.contains(where: { $0.id == progressEpisode }), let number = progress["last_ep_index"] as? String {
      progressEpisode = episodes.first { String($0.index) == number }?.id
    }
    let warning = (raw["warning"] as? [String: Any])?["msg"] as? String
      ?? (raw["dialog"] as? [String: Any])?["msg"] as? String
    return Self(season: season, description: raw["evaluate"] as? String ?? "", alias: raw["alias"] as? String ?? "",
      staff: (raw["staff"] as? [String: Any])?["info"] as? String ?? "", actors: (raw["actor"] as? [String: Any])?["info"] as? String ?? "",
      stats: .parse(raw["stat"] as? [String: Any] ?? [:], season: true), followed: JSONValue.int64(status["follow"]).map { $0 == 1 },
      episodes: episodes, seasons: seasons, extras: extras, progressEpisodeID: progressEpisode,
      progressSeconds: JSONValue.int(progress["last_time"]), warning: warning)
  }
}
