import Foundation

public struct VideoPart: Identifiable, Sendable, Equatable {
  public var id: Int64 { cid }
  public let cid: Int64
  public let page: Int
  public let title: String
  public let duration: Int
  public let cover: URL?
  public let badge: String?
  public let likeCount: Int?
  public let coinCount: Int?
  public init(
    cid: Int64, page: Int, title: String, duration: Int, cover: URL? = nil,
    badge: String? = nil, likeCount: Int? = nil, coinCount: Int? = nil
  ) {
    self.cid = cid
    self.page = page
    self.title = title
    self.duration = duration
    self.cover = cover
    self.badge = badge
    self.likeCount = likeCount
    self.coinCount = coinCount
  }
}

public struct VideoCollectionSection: Identifiable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let episodes: [Video]
  public init(id: String? = nil, title: String, episodes: [Video]) {
    self.id = id ?? title
    self.title = title
    self.episodes = episodes
  }
}

public struct VideoStats: Sendable, Equatable {
  public let view: Int
  public let danmaku: Int
  public let reply: Int
  public let favorite: Int
  public let coin: Int
  public let share: Int
  public let like: Int
  public init(
    view: Int = 0, danmaku: Int = 0, reply: Int = 0, favorite: Int = 0,
    coin: Int = 0, share: Int = 0, like: Int = 0
  ) {
    self.view = view
    self.danmaku = danmaku
    self.reply = reply
    self.favorite = favorite
    self.coin = coin
    self.share = share
    self.like = like
  }
}

public struct VideoUploader: Sendable, Equatable {
  public let mid: Int64
  public let name: String
  public let avatar: URL?
  public let followers: Int
  public init(mid: Int64, name: String, avatar: URL? = nil, followers: Int = 0) {
    self.mid = mid
    self.name = name
    self.avatar = avatar
    self.followers = followers
  }
}

public struct VideoDetails: Sendable, Equatable {
  public let video: Video
  public let parts: [VideoPart]
  public let collections: [VideoCollectionSection]
  public let tags: [String]
  public let related: [Video]
  public let stats: VideoStats
  public let uploader: VideoUploader
  public let tagsAvailable: Bool
  public let relatedAvailable: Bool
  public init(
    video: Video, parts: [VideoPart], collections: [VideoCollectionSection],
    tags: [String], related: [Video], stats: VideoStats, uploader: VideoUploader,
    tagsAvailable: Bool = true, relatedAvailable: Bool = true
  ) {
    self.video = video
    self.parts = parts
    self.collections = collections
    self.tags = tags
    self.related = related
    self.stats = stats
    self.uploader = uploader
    self.tagsAvailable = tagsAvailable
    self.relatedAvailable = relatedAvailable
  }
}

extension VideoDetails {
  /// Feed cards may carry only aid; detail responses can add a BV identifier.
  public func matches(_ candidate: Video) -> Bool {
    if let aid = video.aid, let other = candidate.aid { return aid == other }
    return !video.bvid.isEmpty && video.bvid == candidate.bvid
  }

  public func selectingPart(cid: Int64?) -> VideoDetails {
    guard let cid, let part = parts.first(where: { $0.cid == cid }) else { return self }
    let selected = Video(
      bvid: video.bvid, title: video.title, cover: video.cover, author: video.author,
      duration: part.duration, views: video.views, cid: cid, description: video.description,
      aid: video.aid, authorID: video.authorID, avatar: video.avatar,
      publishedAt: video.publishedAt, subtitle: video.subtitle, recommendationReason: video.recommendationReason)
    return VideoDetails(
      video: selected, parts: parts, collections: collections, tags: tags, related: related,
      stats: stats, uploader: uploader, tagsAvailable: tagsAvailable,
      relatedAvailable: relatedAvailable)
  }

  public static func parse(_ payload: [String: Any]) throws -> VideoDetails {
    guard let view = (payload["View"] ?? payload["view"]) as? [String: Any],
      let aid = JSONValue.int64(view["aid"]), aid > 0,
      let stat = view["stat"] as? [String: Any],
      let owner = view["owner"] as? [String: Any],
      let mid = JSONValue.int64(owner["mid"]), mid > 0,
      let ownerName = owner["name"] as? String,
      let pages = view["pages"] as? [[String: Any]], !pages.isEmpty
    else {
      throw BiliError.invalidResponse("Missing video detail core fields")
    }
    let video = try Video.parse(view)
    let parts = try pages.map { page -> VideoPart in
      guard let cid = JSONValue.int64(page["cid"]), cid > 0,
        let number = page["page"] as? Int, number > 0,
        let title = page["part"] as? String
      else {
        throw BiliError.invalidResponse("Invalid video part")
      }
      let partStats = page["stat"] as? [String: Any]
      return VideoPart(
        cid: cid, page: number, title: title, duration: JSONValue.int(page["duration"]),
        cover: JSONValue.url(page["first_frame"] ?? page["cover"]), badge: page["badge"] as? String,
        likeCount: JSONValue.int64(partStats?["like"]).flatMap(Int.init(exactly:)),
        coinCount: JSONValue.int64(partStats?["coin"]).flatMap(Int.init(exactly:)))
    }
    let season = view["ugc_season"] as? [String: Any]
    let collections = try (season?["sections"] as? [[String: Any]] ?? []).enumerated().map {
      index, section in
      let episodes = try (section["episodes"] as? [[String: Any]] ?? []).map { episode in
        var archive = episode["arc"] as? [String: Any] ?? [:]
        for key in ["aid", "bvid", "cid", "title"] {
          if archive[key] == nil { archive[key] = episode[key] }
        }
        if archive["owner"] == nil { archive["owner"] = owner }
        return try Video.parse(archive)
      }
      return VideoCollectionSection(
        id: JSONValue.int64(section["id"]).map(String.init) ?? "section-\(index)",
        title: section["title"] as? String ?? "合集", episodes: episodes)
    }
    let card = (payload["Card"] ?? payload["card"]) as? [String: Any]
    let user = card?["card"] as? [String: Any]
    let rawTags = (payload["Tags"] ?? payload["tags"]) as? [[String: Any]]
    let tags = rawTags?.compactMap { $0["tag_name"] as? String } ?? []
    let rawRelated = (payload["Related"] ?? payload["related"]) as? [[String: Any]]
    let related = rawRelated?.compactMap { try? Video.parse($0) } ?? []
    return VideoDetails(
      video: video, parts: parts, collections: collections, tags: tags, related: related,
      stats: VideoStats(
        view: JSONValue.int(stat["view"]), danmaku: JSONValue.int(stat["danmaku"]),
        reply: JSONValue.int(stat["reply"]), favorite: JSONValue.int(stat["favorite"]),
        coin: JSONValue.int(stat["coin"]), share: JSONValue.int(stat["share"]),
        like: JSONValue.int(stat["like"])),
      uploader: VideoUploader(
        mid: mid, name: user?["name"] as? String ?? ownerName,
        avatar: JSONValue.url(user?["face"] ?? owner["face"]),
        followers: JSONValue.int(card?["follower"] ?? user?["fans"])),
      tagsAvailable: rawTags != nil && tags.count == rawTags?.count,
      relatedAvailable: rawRelated != nil && related.count == rawRelated?.count)
  }
}

extension BiliService {
  public func videoDetails(_ video: Video, expectedIdentity: AuthSnapshot? = nil) async throws -> VideoDetails {
    try await regionAware { try await unroutedVideoDetails(video, expectedIdentity: expectedIdentity) }
  }
  private func unroutedVideoDetails(_ video: Video, expectedIdentity: AuthSnapshot?) async throws -> VideoDetails {
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    let identity = authSnapshot()
    do {
      try checkRESTIdentity(identity)
      let aid: Int64
      if let value = video.aid, value > 0 {
        aid = value
      } else {
        guard !video.bvid.isEmpty else {
          throw BiliError.invalidResponse("Missing video identifier")
        }
        let resolved = try await detail(video.bvid, expectedIdentity: expectedIdentity)
        try checkRESTIdentity(identity)
        guard let value = resolved.aid, value > 0 else {
          throw BiliError.invalidResponse("Missing aid")
        }
        aid = value
      }
      let payload = try await json(
        "/x/web-interface/wbi/view/detail", params: ["aid": String(aid)], signed: true)
      try checkRESTIdentity(identity)
      return try VideoDetails.parse(payload)
    } catch {
      try checkRESTIdentity(identity)
      throw error
    }
  }
}
