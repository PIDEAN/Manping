public enum LibraryUserSearchOrder: String, CaseIterable, Sendable {
  case relevance = "0", followers = "fans", level = "level"
}
import Foundation

public enum LibrarySearchType: String, CaseIterable, Sendable {
  case video, user = "bili_user", anime = "media_bangumi", cinema = "media_ft"
  case live = "live_room", article
  public var title: String {
    switch self {
    case .video: "视频"
    case .user: "用户"
    case .anime: "番剧"
    case .cinema: "影视"
    case .live: "直播"
    case .article: "专栏"
    }
  }
}
public enum LibrarySearchOrder: String, CaseIterable, Sendable {
  case relevance = "totalrank", views = "click", danmaku = "dm", newest = "pubdate"
  public var title: String {
    switch self {
    case .relevance: "综合排序"
    case .views: "最多播放"
    case .danmaku: "最多弹幕"
    case .newest: "最新发布"
    }
  }
}
public struct LibraryUser: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let avatar: URL?
  public let signature: String
  public let followers: Int?
  public let following: Int?
  public let videos: Int?
  public let likes: Int?
  public let level: Int
  public let isVIP: Bool
  public let isUpUser: Bool
  public let officialRole: Int?
  public let officialTitle: String?
  public let officialDescription: String?
  public let officialType: Int?
  public let banner: URL?
  public let plays: Int?
  public let isLive: Bool
  public let roomID: Int64?
  public init(id: Int64, name: String, avatar: URL? = nil, signature: String = "",
              followers: Int? = nil, following: Int? = nil, videos: Int? = nil,
              likes: Int? = nil, level: Int = 0, isVIP: Bool = false,
              isUpUser: Bool = false, officialRole: Int? = nil, officialTitle: String? = nil,
              officialDescription: String? = nil, officialType: Int? = nil, banner: URL? = nil,
              plays: Int? = nil, isLive: Bool = false, roomID: Int64? = nil) {
    self.id = id; self.name = name; self.avatar = avatar; self.signature = signature
    self.followers = followers; self.following = following; self.videos = videos
    self.likes = likes; self.level = level; self.isVIP = isVIP
    self.isUpUser = isUpUser; self.officialRole = officialRole; self.officialTitle = officialTitle
    self.officialDescription = officialDescription; self.officialType = officialType
    self.banner = banner; self.plays = plays; self.isLive = isLive; self.roomID = roomID
  }
}
public struct LibraryGroup: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let title: String
  public let count: Int
}
public struct LibraryFolder: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let title: String
  public let cover: URL?
  public let count: Int
  public let ownerID: Int64
  public let isSeason: Bool
  public let group: String
}
public struct LibraryEntry: Identifiable, Equatable, Sendable {
  public enum Destination: Equatable, Sendable {
    case video(Video), user(Int64), web(URL), unavailable
  }
  public let id: String
  public let title: String
  public let subtitle: String
  public let cover: URL?
  public let destination: Destination
  public init(id: String, title: String, subtitle: String = "", cover: URL? = nil,
              destination: Destination) {
    self.id = id; self.title = title; self.subtitle = subtitle
    self.cover = cover; self.destination = destination
  }
  public static func video(_ video: Video, subtitle: String? = nil) -> Self {
    Self(id: video.id, title: video.title, subtitle: subtitle ?? video.author,
         cover: video.cover, destination: .video(video))
  }
}
/// 「全部播放」: gathers a collection's playable videos page by page (up to `limit`), skipping
/// repeated entries, so the queue covers the whole collection rather than what was scrolled.
public struct PlaylistCollector: Sendable {
  public static let defaultLimit = 1000
  public let limit: Int
  public private(set) var videos: [Video] = []
  /// The next page to request, counted from 1.
  public private(set) var nextPage = 1
  public private(set) var finished = false
  /// The collection has more playable videos than `limit`: `videos` holds only the first
  /// `limit` of them. False when the collection ended at or below the limit.
  public private(set) var truncated = false
  private var seen: Set<String> = []
  public init(limit: Int = PlaylistCollector.defaultLimit) { self.limit = max(1, limit) }
  /// Adds one fetched page. The collection is finished after its last page or an empty page,
  /// or as soon as one more playable video than `limit` turns up (then it is `truncated`).
  /// Reaching exactly `limit` at a page boundary keeps reading, so a list that ends there (or
  /// whose later pages hold no new playable video) is not reported as cut short.
  public mutating func add(_ page: LibraryPage<LibraryEntry>) {
    guard !finished else { return }
    for entry in page.items where seen.insert(entry.id).inserted {
      guard case .video(let video) = entry.destination else { continue }
      if videos.count >= limit { truncated = true; finished = true; break }
      videos.append(video)
    }
    nextPage += 1
    if !page.hasMore || page.items.isEmpty { finished = true }
  }
  /// Said beside the player while the collected queue plays: the list was longer than
  /// `limit` and only its first part is playing. Nil when nothing was cut.
  public var truncationNotice: String? {
    truncated ? "列表超过 \(limit) 个视频，已播放前 \(limit) 个。" : nil
  }
}

/// A collected list on its way into the playback queue. `isCurrent` says whether the list it
/// was read from is still the one that asked (its read was not replaced, the page still shows
/// that list to that account); it is asked once more after the last wait, right before the
/// queue changes, so a list that went stale meanwhile never starts.
public struct PlaylistHandoff: Sendable {
  public let videos: [Video]
  public let identity: AuthSnapshot
  /// Shown beside the player while this queue plays (e.g. it was cut short); nil for nothing.
  public let notice: String?
  public let isCurrent: @MainActor @Sendable () -> Bool
  public init(videos: [Video], identity: AuthSnapshot, notice: String? = nil,
              isCurrent: @escaping @MainActor @Sendable () -> Bool) {
    self.videos = videos; self.identity = identity; self.notice = notice; self.isCurrent = isCurrent
  }
  /// Throws `CancellationError` unless the task goes on, `current` is still the account the
  /// list was read for and the list is still current. Nothing may wait between this and the
  /// queue change.
  @MainActor public func confirm(current: AuthSnapshot) throws {
    try Task.checkCancellation()
    guard current.epoch == identity.epoch, current.identityRevision == identity.identityRevision,
      isCurrent() else { throw CancellationError() }
  }
}

/// Which list (and for which account) a 全部播放 result was read from. A result is shown or
/// played only while the page still shows that same list to that same account.
public struct PlaylistContext: Equatable, Sendable {
  /// The list on its page, e.g. `later` or `folder:42`.
  public let list: String
  public let epoch: UInt64
  public let identityRevision: UInt64
  public init(list: String, identity: AuthSnapshot) {
    self.list = list; epoch = identity.epoch; identityRevision = identity.identityRevision
  }
}

public struct LibraryPage<Item: Sendable>: Sendable {
  public let items: [Item]
  public let hasMore: Bool
  public let total: Int
  public init(items: [Item], hasMore: Bool, total: Int = 0) {
    self.items = items; self.hasMore = hasMore; self.total = total
  }
}

extension BiliService {
  // Video follows exact SDK SearchClient. Other types are a Web fallback; the original
  // uses polymer SearchByType with server-provided Nav.Type and opaque pagination.
  public func librarySearch(_ keyword: String, type: LibrarySearchType = .video,
                            order: LibrarySearchOrder = .relevance, page: Int = 1)
    async throws -> LibraryPage<LibraryEntry> {
    if type == .user {
      let result = try await searchUsers(term: keyword, page: page)
      return LibraryPage(items: result.items.map { user in
        LibraryEntry(id: "user\(user.id)", title: user.name, subtitle: user.signature, cover: user.avatar, destination: .user(user.id))
      }, hasMore: result.hasMore, total: result.total)
    }
    try libraryPageNumber(page)
    guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BiliError.invalidResponse("Empty search keyword")
    }
    let data = try await json("/x/web-interface/wbi/search/type", params: [
      "keyword": keyword, "search_type": type.rawValue, "order": order.rawValue,
      "page": String(page)], signed: true)
    let raw = try Self.libraryList(data, key: "result")
    let items = try raw.map { item -> LibraryEntry in
      if type == .video { return .video(try Self.libraryVideo(item)) }
      if type == .user {
        let user = try Self.libraryUser(item)
        return LibraryEntry(id: "user\(user.id)", title: user.name,
                            subtitle: user.signature, cover: user.avatar, destination: .user(user.id))
      }
      let id = JSONValue.int64(item["season_id"] ?? item["roomid"] ?? item["id"])
      guard let id, id > 0, let title = item["title"] as? String else {
        throw BiliError.invalidResponse("Invalid search result")
      }
      let fallback: String
      switch type {
      case .anime, .cinema: fallback = "https://www.bilibili.com/bangumi/play/ss\(id)"
      case .live: fallback = "https://live.bilibili.com/\(id)"
      case .article: fallback = "https://www.bilibili.com/read/cv\(id)"
      default: fallback = ""
      }
      let cover = item["cover"] ?? item["pic"] ?? (item["image_urls"] as? [String])?.first
      return LibraryEntry(id: "\(type.rawValue)\(id)", title: Self.libraryPlain(title),
                          subtitle: item["desc"] as? String ?? item["uname"] as? String ?? "",
                          cover: JSONValue.url(cover),
                          destination: JSONValue.url(fallback).map(LibraryEntry.Destination.web) ?? .unavailable)
    }
    return LibraryPage(items: items, hasMore: page < JSONValue.int(data["numPages"]),
                       total: JSONValue.int(data["numResults"]))
  }
  public func searchUsers(term: String, order: LibraryUserSearchOrder = .relevance, page: Int = 1)
    async throws -> LibraryPage<LibraryUser> {
    try libraryPageNumber(page)
    guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BiliError.invalidResponse("Empty search keyword")
    }
    let data = try await json("/x/web-interface/wbi/search/type", params: [
      "keyword": term, "search_type": "bili_user", "order": order.rawValue,
      "order_sort": "0", "page": String(page)], signed: true)
    return LibraryPage(items: try Self.libraryList(data, key: "result").map(Self.libraryUser),
      hasMore: page < JSONValue.int(data["numPages"]), total: JSONValue.int(data["numResults"]))
  }
  public func libraryProfile(mid: Int64) async throws -> LibraryUser {
    try libraryID(mid)
    let data = try await json("/x/web-interface/card", params: ["mid": String(mid), "photo": "true"])
    guard var card = data["card"] as? [String: Any] else {
      throw BiliError.invalidResponse("Missing user card")
    }
    card["archive_count"] = data["archive_count"]
    // UserCardDetailResponse keeps community counters outside the profile card.
    card["banner"] = (data["space"] as? [String: Any])?["l_img"]
    card["fans"] = data["follower"] ?? data["fans"] ?? card["fans"]
    for key in ["fans", "follow", "like_num"] {
      if let value = data[key] { card[key] = value }
    }
    return try Self.libraryUser(card)
  }
  public func libraryFollowGroups() async throws -> [LibraryGroup] {
    guard let list = try await appREST(.followGroups) as? [[String: Any]] else {
      throw BiliError.invalidResponse("Missing follow groups")
    }
    return try list.map {
      guard let id = JSONValue.int64($0["tagid"]), let title = $0["name"] as? String else {
        throw BiliError.invalidResponse("Invalid follow group")
      }
      return LibraryGroup(id: id, title: title, count: JSONValue.int($0["count"]))
    }
  }
  public func libraryFollowing(group: Int64, page: Int = 1) async throws -> LibraryPage<LibraryUser> {
    try libraryPageNumber(page)
    guard let raw = try await appREST(.followGroupUsers, fields: [
      "tagid": String(group), "pn": String(page)]) as? [[String: Any]] else {
      throw BiliError.invalidResponse("Missing follow group users")
    }
    return LibraryPage(items: try raw.map(Self.libraryUser), hasMore: raw.count >= 50)
  }
  public func libraryFollowers(mid: Int64, page: Int = 1) async throws -> LibraryPage<LibraryUser> {
    try libraryID(mid); try libraryPageNumber(page)
    let data = try await appObject(.followers, fields: ["vmid": String(mid), "pn": String(page)])
    let raw = try Self.libraryList(data)
    let total = JSONValue.int(data["total"])
    return LibraryPage(items: try raw.map(Self.libraryUser), hasMore: page * 50 < total, total: total)
  }
  public func libraryFolders() async throws -> [LibraryFolder] {
    let snapshot = authSnapshot()
    let gallery = try await appObject(.libraryGallery)
    try checkRESTIdentity(snapshot)
    let created = try await appObject(.libraryFolders, fields: ["type": "2"])
    try checkRESTIdentity(snapshot)
    guard let mid = authSnapshot().token?.mid else { throw AuthFailure.needsLogin }
    let collected = try await json("/x/v3/fav/folder/collected/list", params: [
      "up_mid": String(mid), "ps": "20", "pn": "1"], signed: true)
    try checkRESTIdentity(snapshot)
    var folders = try Self.libraryList(created).map { try Self.libraryFolder($0, group: "我创建的") }
    folders += try Self.libraryList(collected).map { try Self.libraryFolder($0, group: "我收藏的") }
    if let spaces = gallery["space_infos"] as? [[String: Any]] {
      for space in spaces where JSONValue.int(space["id"]) != 3 {
        let media = space["mediaListResponse"] as? [String: Any] ?? [:]
        for item in try Self.libraryList(media) where JSONValue.int(item["type"]) == 21 {
          folders.append(try Self.libraryFolder(item, group: space["name"] as? String ?? "合集"))
        }
      }
    }
    var known = Set<Int64>()
    return folders.filter { known.insert($0.id).inserted }
  }
  public func libraryContents(folder: LibraryFolder, page: Int = 1) async throws -> LibraryPage<LibraryEntry> {
    try libraryID(folder.id); try libraryPageNumber(page)
    if folder.isSeason {
      try libraryID(folder.ownerID)
      // The SDK requires App signing and cookies together for this endpoint.
      let data = try await appObject(.librarySeasonContents, fields: [
        "season_id": String(folder.id), "mid": String(folder.ownerID),
        "page_size": "30", "page_num": String(page)])
      let raw = try Self.libraryList(data, key: "archives")
      let total = JSONValue.int((data["page"] as? [String: Any])?["total"])
      return LibraryPage(items: try raw.map { .video(try Self.libraryVideo($0)) },
                         hasMore: page * 30 < total, total: total)
    }
    let data = try await appObject(.libraryContents, fields: [
      "media_id": String(folder.id), "ps": "20", "pn": String(page)])
    let raw = try Self.libraryList(data, key: "medias")
    return LibraryPage(items: try raw.filter { JSONValue.int($0["type"]) == 2 }
      .map { .video(try Self.libraryVideo($0)) },
      hasMore: data["has_more"] as? Bool ?? false,
      total: JSONValue.int((data["info"] as? [String: Any])?["media_count"]))
  }
  public func libraryPGC(cinema: Bool, status: Int = 2, page: Int = 1) async throws -> LibraryPage<LibraryEntry> {
    try libraryPageNumber(page)
    guard (1...3).contains(status) else { throw BiliError.invalidResponse("Invalid PGC status") }
    let data = try await appObject(cinema ? .favoriteCinema : .favoriteBangumi,
      fields: ["pn": String(page), "ps": "20", "status": String(status)])
    let raw = try Self.libraryList(data, key: "follow_list")
    let items = try raw.map { item -> LibraryEntry in
      guard let id = JSONValue.int64(item["season_id"]), id > 0,
            let title = item["title"] as? String else { throw BiliError.invalidResponse("Invalid PGC favorite") }
      let url = JSONValue.url("https://www.bilibili.com/bangumi/play/ss\(id)")!
      return LibraryEntry(id: "season\(id)", title: title,
        subtitle: (item["new_ep"] as? [String: Any])?["index_show"] as? String ?? "",
        cover: JSONValue.url(item["cover"]), destination: .web(url))
    }
    let total = JSONValue.int(data["total"])
    return LibraryPage(items: items, hasMore: page * 20 < total, total: total)
  }
  private func libraryID(_ id: Int64) throws {
    guard id > 0 else { throw BiliError.invalidResponse("Invalid user/library identifier") }
  }
  private func libraryPageNumber(_ page: Int) throws {
    guard (1...1_000_000).contains(page) else { throw BiliError.invalidResponse("Invalid library page") }
  }
  static func libraryPlain(_ text: String) -> String {
    text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
  }
  static func libraryList(_ data: [String: Any], key: String = "list") throws -> [[String: Any]] {
    if let raw = data[key] as? [[String: Any]] { return raw }
    if data[key] is NSNull { return [] }
    throw BiliError.invalidResponse("Missing library \(key)")
  }
  static func libraryUser(_ item: [String: Any]) throws -> LibraryUser {
    guard let id = JSONValue.int64(item["mid"]), id > 0,
          let name = item["uname"] as? String ?? item["name"] as? String else {
      throw BiliError.invalidResponse("Invalid library user")
    }
    let vip = item["vip"] as? [String: Any] ?? [:]
    let level = item["level_info"] as? [String: Any] ?? [:]
    let official = item["Official"] as? [String: Any] ?? item["official_verify"] as? [String: Any] ?? [:]
    func optionalInt(_ value: Any?) -> Int? { JSONValue.int64(value).map(Int.init) }
    return LibraryUser(id: id, name: libraryPlain(name), avatar: JSONValue.url(item["face"] ?? item["upic"]),
      signature: item["sign"] as? String ?? item["usign"] as? String ?? "",
      followers: optionalInt(item["fans"]), following: optionalInt(item["follow"] ?? item["attention"]),
      videos: optionalInt(item["archive_count"] ?? item["videos"]),
      likes: optionalInt(item["like_num"]), level: JSONValue.int(item["level"] ?? level["current_level"]),
      isVIP: JSONValue.int(vip["status"]) >= 1, isUpUser: JSONValue.int(item["is_upuser"]) == 1,
      officialRole: optionalInt(official["role"]), officialTitle: official["title"] as? String,
      officialDescription: official["desc"] as? String, officialType: optionalInt(official["type"]),
      banner: JSONValue.url(item["banner"]), plays: optionalInt(item["plays"]),
      isLive: JSONValue.int(item["is_live"]) == 1, roomID: JSONValue.int64(item["room_id"]))
  }
  static func libraryVideo(_ item: [String: Any]) throws -> Video {
    var normalized = item
    if normalized["aid"] == nil { normalized["aid"] = item["id"] }
    if normalized["pic"] == nil { normalized["pic"] = item["cover"] }
    let owner = item["owner"] as? [String: Any] ?? [:]
    let upper = item["upper"] as? [String: Any] ?? [:]
    var author = owner
    author["mid"] = JSONValue.int64(owner["mid"]) ?? JSONValue.int64(upper["mid"]) ?? JSONValue.int64(item["mid"])
    author["name"] = owner["name"] ?? upper["name"] ?? item["author"]
    author["face"] = owner["face"] ?? upper["face"] ?? item["upic"]
    normalized["owner"] = author
    if let count = item["cnt_info"] as? [String: Any] { normalized["stat"] = ["view": count["play"] ?? 0] }
    if let duration = item["duration"] as? String {
      normalized["duration"] = duration.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }
    return try Video.parse(normalized)
  }
  static func libraryFolder(_ item: [String: Any], group: String) throws -> LibraryFolder {
    guard let id = JSONValue.int64(item["id"]), id > 0, let title = item["title"] as? String else {
      throw BiliError.invalidResponse("Invalid library folder")
    }
    let upper = item["upper"] as? [String: Any] ?? [:]
    return LibraryFolder(id: id, title: title, cover: JSONValue.url(item["cover"]),
      count: JSONValue.int(item["media_count"]), ownerID: JSONValue.int64(upper["mid"] ?? item["mid"]) ?? 0,
      isSeason: JSONValue.int(item["type"]) == 21, group: group)
  }
}
