import Foundation

public struct RPCUser: Codable, Sendable, Equatable {
  public let mid: Int64
  public let name: String
  public let avatar: URL?
}
public struct RPCEmote: Codable, Sendable, Equatable {
  public let text: String
  public let image: URL?
}
/// Ordered text/image runs. Only exact bracketed tokens present in the message are images.
public enum RPCEmoteTextSegment: Equatable, Sendable {
  case text(String)
  case emote(token: String, image: URL)

  public static func parse(_ text: String, emotes: [RPCEmote]) -> [Self] {
    var mapped: [String: URL] = [:]
    for emote in emotes where emote.text.hasPrefix("[") && emote.text.hasSuffix("]") {
      if let image = emote.image, mapped[emote.text] == nil { mapped[emote.text] = image }
    }
    var runs: [Self] = []
    var plain = ""
    var cursor = text.startIndex
    while cursor < text.endIndex {
      if text[cursor] == "[", let close = text[cursor...].firstIndex(of: "]") {
        let end = text.index(after: close)
        let token = String(text[cursor..<end])
        if let image = mapped[token] {
          if !plain.isEmpty { runs.append(.text(plain)); plain = "" }
          runs.append(.emote(token: token, image: image)); cursor = end; continue
        }
        plain.append(contentsOf: token); cursor = end; continue
      }
      plain.append(text[cursor]); cursor = text.index(after: cursor)
    }
    if !plain.isEmpty { runs.append(.text(plain)) }
    return runs
  }
}
public struct RPCComment: Codable, Sendable, Equatable {
  public let id: Int64
  public let root: Int64
  public let author: RPCUser
  public let text: String
  public let emotes: [RPCEmote]
  public let createdAt: Int64
  public let likes: Int64
  public let replyCount: Int64
  public let liked: Bool
  public let pinned: Bool
  public let replies: [RPCComment]
}
public struct RPCCommentPage: Codable, Sendable, Equatable {
  public let oid: Int64
  public let targetType: Int32
  public let comments: [RPCComment]
  public let pinned: RPCComment?
  public let next: Int64
  public let isEnd: Bool
}
public enum RPCCommentSort: Sendable { case time, hot }

public struct RPCVideoCard: Codable, Sendable, Equatable {
  public let aid: Int64
  public let bvid: String
  public let cid: Int64
  public let title: String
  public let cover: URL?
  public let author: RPCUser?
  public let duration: Int64
  public let views: Int64
  public let uri: String
  public let publishedAt: Int64?
  public let subtitle: String?
  public let recommendationReason: String?
  public init(
    aid: Int64, bvid: String, cid: Int64, title: String, cover: URL?, author: RPCUser?,
    duration: Int64, views: Int64, uri: String, publishedAt: Int64? = nil,
    subtitle: String? = nil, recommendationReason: String? = nil
  ) {
    self.aid = aid; self.bvid = bvid; self.cid = cid; self.title = title; self.cover = cover
    self.author = author; self.duration = duration; self.views = views; self.uri = uri
    self.publishedAt = publishedAt; self.subtitle = subtitle; self.recommendationReason = recommendationReason
  }
}
public struct RPCArticleCard: Codable, Sendable, Equatable {
  public let id: Int64
  public let title: String
  public let text: String
  public let covers: [URL]
  public let uri: String
}
public struct RPCEpisodeCard: Codable, Sendable, Equatable {
  public let aid: Int64
  public let cid: Int64
  public let episodeID: Int64
  public let seasonID: Int64
  public let title: String
  public let cover: URL?
  public let uri: String
}
public indirect enum RPCDynamicContent: Codable, Sendable, Equatable {
  case text
  case video(RPCVideoCard)
  case episode(RPCEpisodeCard)
  case images([URL])
  case article(RPCArticleCard)
  case forward(RPCDynamic)
  case unsupported(type: Int)
}
public struct RPCDynamic: Codable, Sendable, Equatable {
  public let id: String
  public let author: RPCUser?
  public let timeLabel: String
  public let text: String
  public let emotes: [RPCEmote]
  public let likes: Int64
  public let replies: Int64
  public let reposts: Int64
  public let liked: Bool
  public let commentTargetType: Int32
  public let commentTargetID: String
  public let content: RPCDynamicContent
}
public struct RPCDynamicProfile: Identifiable, Codable, Sendable, Equatable {
  public let id: Int64
  public let name: String
  public let avatar: URL?
  public let hasUnread: Bool
  public let isLive: Bool
  public let liveURL: URL?
  public init(id: Int64, name: String, avatar: URL?, hasUnread: Bool, isLive: Bool, liveURL: URL?) {
    self.id = id; self.name = name; self.avatar = avatar; self.hasUnread = hasUnread
    self.isLive = isLive; self.liveURL = liveURL
  }
}
public struct RPCDynamicPage: Codable, Sendable, Equatable {
  public let items: [RPCDynamic]
  public let historyOffset: String
  public let updateBaseline: String
  public let hasMore: Bool
  public let users: [RPCDynamicProfile]
  public init(items: [RPCDynamic], historyOffset: String, updateBaseline: String, hasMore: Bool,
    users: [RPCDynamicProfile] = []) {
    self.items = items; self.historyOffset = historyOffset; self.updateBaseline = updateBaseline
    self.hasMore = hasMore; self.users = users
  }
}
public enum RPCDynamicQuery: Sendable {
  case all(offset: String, baseline: String)
  case video(offset: String, baseline: String)
  case userAll(mid: Int64, offset: String)
  case userVideo(mid: Int64, offset: String)
  case space(mid: Int64, historyOffset: String)
}
public enum RPCHistoryContent: Codable, Sendable, Equatable {
  case video(RPCVideoCard, progress: Int64)
  case episode(cover: URL?, progress: Int64, duration: Int64, subtitle: String)
  case article(author: RPCUser, covers: [URL])
  case live(author: RPCUser, cover: URL?, status: Int32)
  case course(cover: URL?, progress: Int64, duration: Int64, subtitle: String)
  case unsupported
}
public struct RPCHistoryItem: Codable, Sendable, Equatable {
  public let id: Int64
  public let oid: Int64
  public let business: String
  public let title: String
  public let uri: String
  public let viewedAt: Int64
  public let content: RPCHistoryContent
}
public struct RPCHistoryPage: Codable, Sendable, Equatable {
  public let items: [RPCHistoryItem]
  public let max: Int64
  public let hasMore: Bool
}
public enum RPCPopularItem: Codable, Sendable, Equatable {
  case video(RPCVideoCard, index: Int64, durationLabel: String)
  case unsupported(kind: String)
}
public struct RPCPopularPage: Codable, Sendable, Equatable {
  public let items: [RPCPopularItem]
  // nil means the schema did not provide a continuation; do not infer end-of-feed from it.
  public let nextIndex: Int64?
  public let version: String
}
