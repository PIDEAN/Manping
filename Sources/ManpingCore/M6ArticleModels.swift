import Foundation

public struct ArticlePartition: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let title: String
  public let children: [ArticlePartition]
  public init(id: Int64, title: String, children: [ArticlePartition] = []) {
    self.id = id; self.title = title; self.children = children
  }
}

// Exact SDK ArticleSortType values, UI 896a062.
public enum ArticleSort: Int, CaseIterable, Sendable {
  case recommended = 0, newest = 1, reads = 5, replies = 3, likes = 2, favorites = 4
  public var title: String {
    switch self {
    case .recommended: "默认排序"
    case .newest: "最新发布"
    case .reads: "最多阅读"
    case .replies: "最多回复"
    case .likes: "最多点赞"
    case .favorites: "最多收藏"
    }
  }
}

public struct ArticleAuthor: Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let avatar: URL?
  public init(id: Int64 = 0, name: String = "", avatar: URL? = nil) {
    self.id = id; self.name = name; self.avatar = avatar
  }
}

public struct ArticleStats: Equatable, Sendable {
  public let reads: Int
  public let likes: Int
  public let favorites: Int
  public let replies: Int
  public let coins: Int
  public init(reads: Int = 0, likes: Int = 0, favorites: Int = 0, replies: Int = 0, coins: Int = 0) {
    self.reads = reads; self.likes = likes; self.favorites = favorites; self.replies = replies; self.coins = coins
  }
}

public struct ArticleSummary: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let title: String
  public let summary: String
  public let cover: URL?
  public let author: ArticleAuthor
  public let publishedAt: Int64?
  public let stats: ArticleStats
  public let wordCount: Int
  public let partition: ArticlePartition?
  public init(id: Int64, title: String, summary: String = "", cover: URL? = nil,
    author: ArticleAuthor = .init(), publishedAt: Int64? = nil, stats: ArticleStats = .init(),
    wordCount: Int = 0, partition: ArticlePartition? = nil) {
    self.id = id; self.title = title; self.summary = summary; self.cover = cover
    self.author = author; self.publishedAt = publishedAt; self.stats = stats
    self.wordCount = wordCount; self.partition = partition
  }
}

public struct ArticleFeedPage: Equatable, Sendable {
  public let items: [ArticleSummary]
  public let ranks: [ArticleSummary]
  public let hasMore: Bool
  public init(items: [ArticleSummary], ranks: [ArticleSummary] = [], hasMore: Bool) {
    self.items = items; self.ranks = ranks; self.hasMore = hasMore
  }
}

public struct ArticleInlineText: Equatable, Sendable {
  public let text: String
  public let bold: Bool
  public let italic: Bool
  public let link: URL?
  public init(_ text: String, bold: Bool = false, italic: Bool = false, link: URL? = nil) {
    self.text = text; self.bold = bold; self.italic = italic; self.link = link
  }
}

public enum ArticleBodyBlock: Equatable, Sendable {
  case text([ArticleInlineText], heading: Int?)
  case image(URL, caption: String?)
  case divider
}

public struct ArticleDetail: Equatable, Sendable {
  public let article: ArticleSummary
  public let blocks: [ArticleBodyBlock]
  public let tags: [String]
  public let isLiked: Bool
  public let isFavorited: Bool
  public let isFollowing: Bool
  public let contributedCoins: Int
  public let interactionStateAvailable: Bool
  public let metadataWarning: String?
  public init(article: ArticleSummary, blocks: [ArticleBodyBlock], tags: [String] = [],
    isLiked: Bool = false, isFavorited: Bool = false, isFollowing: Bool = false, contributedCoins: Int = 0,
    interactionStateAvailable: Bool = true, metadataWarning: String? = nil) {
    self.article = article; self.blocks = blocks; self.tags = tags
    self.isLiked = isLiked; self.isFavorited = isFavorited; self.isFollowing = isFollowing
    self.contributedCoins = contributedCoins
    self.interactionStateAvailable = interactionStateAvailable; self.metadataWarning = metadataWarning
  }
}

enum ArticleParsing {
  static func partition(_ raw: [String: Any], depth: Int = 0) throws -> ArticlePartition {
    guard depth < 8, let id = JSONValue.int64(raw["id"]), id >= 0,
      let title = raw["name"] as? String else { throw BiliError.invalidResponse("Invalid article partition") }
    let children = raw["children"] as? [[String: Any]] ?? []
    guard children.count <= 200 else { throw BiliError.invalidResponse("Too many article partitions") }
    return ArticlePartition(id: id, title: title, children: try children.map { try partition($0, depth: depth + 1) })
  }
  static func stats(_ raw: [String: Any]) -> ArticleStats {
    ArticleStats(reads: max(0, JSONValue.int(raw["view"])), likes: max(0, JSONValue.int(raw["like"])),
      favorites: max(0, JSONValue.int(raw["favorite"])), replies: max(0, JSONValue.int(raw["reply"])),
      coins: max(0, JSONValue.int(raw["coin"])))
  }
  static func summary(_ raw: [String: Any]) throws -> ArticleSummary {
    guard let id = JSONValue.int64(raw["id"]), id > 0, let title = raw["title"] as? String else {
      throw BiliError.invalidResponse("Invalid article identifier/title")
    }
    let author = raw["author"] as? [String: Any] ?? [:]
    let covers = raw["origin_image_urls"] as? [String] ?? raw["image_urls"] as? [String] ?? []
    return ArticleSummary(id: id, title: title, summary: raw["summary"] as? String ?? "",
      cover: covers.first.flatMap(JSONValue.url) ?? JSONValue.url(raw["banner_url"]),
      author: ArticleAuthor(id: JSONValue.int64(author["mid"]) ?? 0,
        name: author["name"] as? String ?? "", avatar: JSONValue.url(author["face"])),
      publishedAt: JSONValue.int64(raw["publish_time"]).flatMap { $0 > 0 ? $0 : nil },
      stats: stats(raw["stats"] as? [String: Any] ?? [:]), wordCount: JSONValue.int(raw["words"]),
      partition: try (raw["category"] as? [String: Any]).map { try partition($0) })
  }
  static func summaries(_ raw: [[String: Any]]) throws -> [ArticleSummary] {
    guard raw.count <= 1000 else { throw BiliError.invalidResponse("Too many articles") }
    var seen = Set<Int64>()
    return try raw.map(summary).filter { seen.insert($0.id).inserted }
  }
}
