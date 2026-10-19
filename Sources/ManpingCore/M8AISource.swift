import Foundation

/// What a preset applies to.
public enum AISourceKind: String, Codable, Sendable, CaseIterable, Hashable {
  case video, pgc, article
  public var title: String {
    switch self {
    case .video: "视频"
    case .pgc: "番剧"
    case .article: "专栏"
    }
  }
  /// Video and PGC share time-based materials (subtitles, danmaku, chapters).
  public var isTimeline: Bool { self == .video || self == .pgc }
}

public struct AIVideoInfo: Sendable, Equatable, Codable {
  public var aid: Int64
  public var cid: Int64
  public var bvid: String
  public var title: String
  public var description: String
  public var partTitle: String?
  public var partIndex: Int?
  public var partCount: Int?
  /// Seconds of the current part.
  public var duration: Double
  public var uploaderName: String
  public var uploaderMid: Int64?
  public var followers: Int?
  public var category: VideoCategory?
  public var tags: [String]
  public var views: Int?
  public var danmakuCount: Int?
  public var likes: Int?
  public var publishedAt: Int64?
  public var collectionTitle: String?
  public init(aid: Int64, cid: Int64, bvid: String = "", title: String, description: String = "", partTitle: String? = nil,
    partIndex: Int? = nil, partCount: Int? = nil, duration: Double, uploaderName: String = "", uploaderMid: Int64? = nil,
    followers: Int? = nil, category: VideoCategory? = nil, tags: [String] = [], views: Int? = nil, danmakuCount: Int? = nil,
    likes: Int? = nil, publishedAt: Int64? = nil, collectionTitle: String? = nil) {
    self.aid = aid; self.cid = cid; self.bvid = bvid; self.title = title; self.description = description
    self.partTitle = partTitle; self.partIndex = partIndex; self.partCount = partCount; self.duration = duration
    self.uploaderName = uploaderName; self.uploaderMid = uploaderMid; self.followers = followers; self.category = category
    self.tags = tags; self.views = views; self.danmakuCount = danmakuCount; self.likes = likes; self.publishedAt = publishedAt
    self.collectionTitle = collectionTitle
  }
  /// The current part of a detail response; `cid` selects the part (defaults to the archive's own cid).
  public init(details: VideoDetails, cid: Int64? = nil) {
    let selected = cid ?? details.video.cid ?? details.parts.first?.cid ?? 0
    let part = details.parts.first(where: { $0.cid == selected })
    self.init(aid: details.video.aid ?? 0, cid: selected, bvid: details.video.bvid, title: details.video.title,
      description: details.video.description ?? "", partTitle: details.parts.count > 1 ? part?.title : nil,
      partIndex: details.parts.count > 1 ? part?.page : nil, partCount: details.parts.count > 1 ? details.parts.count : nil,
      duration: Double(part?.duration ?? details.video.duration), uploaderName: details.uploader.name,
      uploaderMid: details.uploader.mid, followers: details.uploader.followers > 0 ? details.uploader.followers : nil,
      category: details.category, tags: details.tags, views: details.stats.view, danmakuCount: details.stats.danmaku,
      likes: details.stats.like, publishedAt: details.video.publishedAt,
      collectionTitle: details.collections.first(where: { $0.episodes.contains(where: { $0.aid == details.video.aid }) })?.title)
  }
}

public struct AIPGCInfo: Sendable, Equatable, Codable {
  public var epid: Int64
  public var aid: Int64
  public var cid: Int64
  public var seasonTitle: String
  public var episodeTitle: String
  public var episodeIndex: Int?
  public var episodeCount: Int?
  public var duration: Double
  public var description: String
  public var staff: String
  public var actors: String
  public var score: Double?
  public init(epid: Int64, aid: Int64, cid: Int64, seasonTitle: String, episodeTitle: String, episodeIndex: Int? = nil,
    episodeCount: Int? = nil, duration: Double, description: String = "", staff: String = "", actors: String = "", score: Double? = nil) {
    self.epid = epid; self.aid = aid; self.cid = cid; self.seasonTitle = seasonTitle; self.episodeTitle = episodeTitle
    self.episodeIndex = episodeIndex; self.episodeCount = episodeCount; self.duration = duration; self.description = description
    self.staff = staff; self.actors = actors; self.score = score
  }
  public init?(details: PGCDetails, episode: PGCEpisode) {
    guard let aid = episode.aid, let cid = episode.cid else { return nil }
    // `PGCEpisode.duration` is already converted to seconds by its parser.
    let seconds = Double(episode.duration)
    self.init(epid: episode.id, aid: aid, cid: cid, seasonTitle: details.season.title, episodeTitle: episode.title,
      episodeIndex: episode.index, episodeCount: details.episodes.count, duration: seconds, description: details.description,
      staff: details.staff, actors: details.actors, score: details.season.score)
  }
}

public struct AIArticleParagraph: Sendable, Equatable, Codable {
  /// Heading level (1…6) or nil for body text.
  public var heading: Int?
  public var text: String
  public init(heading: Int? = nil, text: String) { self.heading = heading; self.text = text }
}

public struct AIArticleInfo: Sendable, Equatable, Codable {
  public var id: Int64
  public var title: String
  public var authorName: String
  public var authorMid: Int64?
  public var category: String?
  public var tags: [String]
  public var paragraphs: [AIArticleParagraph]
  public init(id: Int64, title: String, authorName: String = "", authorMid: Int64? = nil, category: String? = nil,
    tags: [String] = [], paragraphs: [AIArticleParagraph]) {
    self.id = id; self.title = title; self.authorName = authorName; self.authorMid = authorMid
    self.category = category; self.tags = tags; self.paragraphs = paragraphs
  }
  /// Paragraphs and heading levels are kept; whitespace inside a paragraph is collapsed.
  public init(detail: ArticleDetail) {
    let paragraphs = detail.blocks.compactMap { block -> AIArticleParagraph? in
      guard case .text(let spans, let heading) = block else { return nil }
      let text = Self.normalizedArticle(spans.map(\.text).joined())
      return text.isEmpty ? nil : AIArticleParagraph(heading: heading, text: text)
    }
    self.init(id: detail.article.id, title: detail.article.title, authorName: detail.article.author.name,
      authorMid: detail.article.author.id > 0 ? detail.article.author.id : nil, category: detail.article.partition?.title,
      tags: detail.tags, paragraphs: paragraphs)
  }
  static func normalizedArticle(_ text: String) -> String {
    text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public var hasBody: Bool { paragraphs.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

/// The input contract of every AI task. The identifier is typed so a video part, a PGC episode
/// and an article can never share cached results.
public enum AISource: Sendable, Equatable, Codable {
  case video(AIVideoInfo)
  case pgc(AIPGCInfo)
  case article(AIArticleInfo)
  public var kind: AISourceKind {
    switch self { case .video: .video; case .pgc: .pgc; case .article: .article }
  }
  public var identifier: String {
    switch self {
    case .video(let info): "video:\(info.aid):\(info.cid)"
    case .pgc(let info): "pgc:\(info.epid)"
    case .article(let info): "article:\(info.id)"
    }
  }
  public var title: String {
    switch self {
    case .video(let info): info.title
    case .pgc(let info): info.seasonTitle + " " + info.episodeTitle
    case .article(let info): info.title
    }
  }
  /// Seconds of the playable media, nil for articles.
  public var duration: Double? {
    switch self {
    case .video(let info): info.duration
    case .pgc(let info): info.duration
    case .article: nil
    }
  }
  /// aid/cid of timeline media.
  public var media: (aid: Int64, cid: Int64)? {
    switch self {
    case .video(let info): (info.aid, info.cid)
    case .pgc(let info): (info.aid, info.cid)
    case .article: nil
    }
  }
  /// Comment area: archives use type 1, articles type 12.
  public var commentTarget: (oid: Int64, type: Int32) {
    switch self {
    case .video(let info): (info.aid, 1)
    case .pgc(let info): (info.aid, 1)
    case .article(let info): (info.id, 12)
    }
  }
  public var uploaderMid: Int64? {
    switch self {
    case .video(let info): info.uploaderMid
    case .pgc: nil
    case .article(let info): info.authorMid
    }
  }
  /// Partition names used for preset recommendations.
  public var categoryNames: [String] {
    switch self {
    case .video(let info): [info.category?.name].compactMap { $0 } + info.tags
    case .pgc: ["番剧"]
    case .article(let info): [info.category].compactMap { $0 } + info.tags
    }
  }
  public func validate() throws {
    switch self {
    case .video(let info):
      guard info.aid > 0, info.cid > 0 else { throw BiliError.invalidResponse("AI 视频上下文缺少视频或分集标识") }
    case .pgc(let info):
      guard info.epid > 0, info.aid > 0, info.cid > 0 else { throw BiliError.invalidResponse("AI 番剧上下文缺少剧集标识") }
    case .article(let info):
      guard info.id > 0, info.hasBody else { throw BiliError.invalidResponse("文章正文为空，无法生成 AI 响应") }
    }
  }
}

/// One kind of material that may leave the Mac. The user's switch for a kind always wins over a
/// preset's needs.
public enum AIMaterialKind: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
  case metadata, articleBody, subtitles, officialSummary, danmaku, comments, viewerPosition, history
  public var title: String {
    switch self {
    case .metadata: "基本信息"
    case .articleBody: "专栏正文"
    case .subtitles: "字幕"
    case .officialSummary: "官方章节与 AI 总结"
    case .danmaku: "弹幕统计"
    case .comments: "评论精选"
    case .viewerPosition: "当前进度"
    case .history: "对话历史"
    }
  }
  /// Basic information and the article body are the subject itself and cannot be switched off.
  public var isSwitchable: Bool { self != .metadata && self != .articleBody }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
  }
}

/// Which materials may be sent, and how subtitles are chosen.
public struct AIMaterialSettings: Sendable, Equatable, Codable {
  public var disabled: Set<AIMaterialKind>
  /// Preferred subtitle languages, most preferred first (BCP-47 prefixes, e.g. zh-Hans, zh-CN, en).
  public var subtitleLanguages: [String]
  /// 设置 › AI › 使用 AI 字幕 turned off: Bilibili's AI-generated subtitles are never sent.
  /// Independent of 下载 › 隐藏 AI 字幕, which only filters the download and subtitle lists.
  public var excludeAISubtitles: Bool
  public static let defaultLanguages = ["zh-Hans", "zh-CN", "zh", "zh-Hant", "zh-TW", "zh-HK", "en"]
  public init(disabled: Set<AIMaterialKind> = [], subtitleLanguages: [String] = AIMaterialSettings.defaultLanguages,
    excludeAISubtitles: Bool = false) {
    self.disabled = disabled.filter(\.isSwitchable); self.subtitleLanguages = subtitleLanguages
    self.excludeAISubtitles = excludeAISubtitles
  }
  public func allows(_ kind: AIMaterialKind, oneTime: Set<AIMaterialKind> = []) -> Bool {
    !kind.isSwitchable || !disabled.contains(kind) || oneTime.contains(kind)
  }
  public static let disabledKey = "Manping.AI.materials.disabled"
  public static let languagesKey = "Manping.AI.subtitleLanguages"
  public static let excludeAIKey = "Manping.AI.excludeAISubtitles"
  public static func load(_ defaults: UserDefaults) -> AIMaterialSettings {
    let disabled = Set((defaults.stringArray(forKey: disabledKey) ?? []).compactMap(AIMaterialKind.init(rawValue:)))
    let languages = defaults.stringArray(forKey: languagesKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultLanguages
    return AIMaterialSettings(disabled: disabled, subtitleLanguages: languages,
      excludeAISubtitles: defaults.bool(forKey: excludeAIKey))
  }
  public func save(_ defaults: UserDefaults) {
    defaults.set(disabled.map(\.rawValue).sorted(), forKey: Self.disabledKey)
    defaults.set(subtitleLanguages, forKey: Self.languagesKey)
    defaults.set(excludeAISubtitles, forKey: Self.excludeAIKey)
  }
}
