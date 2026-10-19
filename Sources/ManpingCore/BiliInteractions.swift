import Foundation

public struct FavoriteFolder: Identifiable, Sendable, Equatable {
  public let id: Int64
  public let title: String
  public let containsVideo: Bool
  public init(id: Int64, title: String, containsVideo: Bool) {
    self.id = id
    self.title = title
    self.containsVideo = containsVideo
  }
}

// These paths and parameter mappings follow BiliKernel 22fdf8ca (GPL-3.0).
enum BiliAppRoute {
  case curated, recommend, partitions, region, regionMore, child, childMore, childSorted
  case playback, favoriteFolders, like, coin, triple, favorite, following
  case followGroups, followGroupUsers, followers, libraryGallery, libraryFolders
  case libraryContents, librarySeasonContents, viewLater, favoriteBangumi, favoriteCinema
  case relationship, searchTrending, searchRecommend, spaceArchiveCursor
  case laterDelete, laterClear, favoriteRemove, pgcFavoriteRemove
  case replyLike, replyAdd, danmakuSend
  case pgcTimeline, pgcConditions, pgcIndex, pgcDetails, pgcPlayback
  case pgcOperationState, pgcFollowAdd, pgcFollowDelete, pgcLike, pgcCoin, pgcTriple, pgcFavorite
  case liveAreas, liveRooms, liveFeed
  case articleCategories, articleHotCategories, articleRanking, articleRecommend, articleList, articleView
  case articleLike, articleFavoriteAdd, articleFavoriteDelete
  case messageReply, messageAt, messageLike, messageUnread
  case historyReport
  var url: String {
    switch self {
    case .articleCategories: "https://api.bilibili.com/x/article/categories"
    case .articleHotCategories: "https://api.bilibili.com/x/article/rank/categories"
    case .articleRanking: "https://api.bilibili.com/x/article/rank/list"
    case .articleRecommend: "https://api.bilibili.com/x/article/recommends/plus"
    case .articleList: "https://api.bilibili.com/x/article/recommends"
    case .articleView: "https://api.bilibili.com/x/article/viewinfo"
    case .articleLike: "https://api.bilibili.com/x/article/like"
    case .articleFavoriteAdd: "https://api.bilibili.com/x/article/favorites/add"
    case .articleFavoriteDelete: "https://api.bilibili.com/x/article/favorites/del"
    case .messageReply: "https://api.bilibili.com/x/msgfeed/reply"
    case .messageAt: "https://api.bilibili.com/x/msgfeed/at"
    case .messageLike: "https://api.bilibili.com/x/msgfeed/like"
    case .messageUnread: "https://api.bilibili.com/x/msgfeed/unread"
    case .replyLike: "https://api.bilibili.com/x/v2/reply/action"
    case .replyAdd: "https://api.bilibili.com/x/v2/reply/add"
    case .danmakuSend: "https://api.bilibili.com/x/v2/dm/post"
    case .pgcOperationState: "https://api.bilibili.com/pgc/season/episode/community"
    case .pgcFollowAdd: "https://api.bilibili.com/pgc/app/follow/add"
    case .pgcFollowDelete: "https://api.bilibili.com/pgc/app/follow/del"
    case .pgcLike: "https://app.bilibili.com/x/v2/view/like"
    case .pgcCoin: "https://app.bilibili.com/x/v2/view/coin/add"
    case .pgcTriple: "https://app.bilibili.com/x/v2/view/like/triple"
    case .pgcFavorite: "https://api.bilibili.com/x/v3/fav/resource/batch-deal"
    case .pgcTimeline: "https://api.bilibili.com/pgc/app/timeline"
    case .pgcConditions: "https://api.bilibili.com/pgc/season/index/condition"
    case .pgcIndex: "https://api.bilibili.com/pgc/season/index/result"
    case .pgcDetails: "https://api.bilibili.com/pgc/view/v2/app/season"
    case .pgcPlayback: "https://api.bilibili.com/pgc/player/web/playurl"
    case .liveAreas: "https://api.live.bilibili.com/xlive/app-interface/v2/index/getAreaList"
    case .liveRooms: "https://api.live.bilibili.com/xlive/app-interface/v2/second/getList"
    case .liveFeed: "https://api.live.bilibili.com/xlive/app-interface/v2/index/feed"
    case .curated: "https://api.bilibili.com/x/web-interface/index/top/feed/rcmd"
    case .recommend: "https://app.bilibili.com/x/v2/feed/index"
    case .partitions: "https://app.bilibili.com/x/v2/region/index"
    case .region: "https://app.bilibili.com/x/v2/region/dynamic"
    case .regionMore: "https://app.bilibili.com/x/v2/region/dynamic/list"
    case .child: "https://app.bilibili.com/x/v2/region/dynamic/child"
    case .childMore: "https://app.bilibili.com/x/v2/region/dynamic/child/list"
    case .childSorted: "https://app.bilibili.com/x/v2/region/show/child/list"
    case .playback: "https://api.bilibili.com/x/player/playurl"
    case .favoriteFolders: "https://api.bilibili.com/x/v3/fav/folder/created/list-all"
    case .followGroups: "https://api.bilibili.com/x/relation/tags"
    case .followGroupUsers: "https://api.bilibili.com/x/relation/tag"
    case .followers: "https://api.bilibili.com/x/relation/followers"
    case .libraryGallery: "https://api.bilibili.com/x/v3/fav/folder/space/v2"
    case .libraryFolders: "https://api.bilibili.com/x/v3/fav/folder/created/list-all"
    case .libraryContents: "https://api.bilibili.com/x/v3/fav/resource/list"
    case .librarySeasonContents: "https://api.bilibili.com/x/polymer/web-space/seasons_archives_list"
    case .viewLater: "https://api.bilibili.com/x/v2/history/toview"
    case .favoriteBangumi: "https://api.bilibili.com/pgc/app/follow/v2/bangumi"
    case .favoriteCinema: "https://api.bilibili.com/pgc/app/follow/v2/cinema"
    case .spaceArchiveCursor: "https://app.bilibili.com/x/v2/space/archive/cursor"
    case .relationship: "https://api.bilibili.com/x/relation"
    case .searchTrending: "https://app.bilibili.com/x/v2/search/trending/ranking"
    case .searchRecommend: "https://app.bilibili.com/x/v2/search/recommend"
    case .laterDelete: "https://api.bilibili.com/x/v2/history/toview/del"
    case .laterClear: "https://api.bilibili.com/x/v2/history/toview/clear"
    case .favoriteRemove: "https://api.bilibili.com/x/v3/fav/resource/batch-del"
    case .pgcFavoriteRemove: "https://api.bilibili.com/pgc/app/follow/del"
    case .like: "https://app.bilibili.com/x/v2/view/like"
    case .coin: "https://app.bilibili.com/x/v2/view/coin/add"
    case .triple: "https://app.bilibili.com/x/v2/view/like/triple"
    case .favorite: "https://api.bilibili.com/x/v3/fav/resource/batch-deal"
    case .following: "https://api.bilibili.com/x/relation/modify"
    case .historyReport: "https://api.bilibili.com/x/v2/history/report"
    }
  }
  var isMutation: Bool {
    switch self {
    case .pgcFollowAdd, .pgcFollowDelete, .pgcLike, .pgcCoin, .pgcTriple, .pgcFavorite,
      .like, .coin, .triple, .favorite, .following,
      .laterDelete, .laterClear, .favoriteRemove, .pgcFavoriteRemove, .replyLike, .replyAdd, .danmakuSend, .articleLike, .articleFavoriteAdd, .articleFavoriteDelete,
      .historyReport: true
    default: false
    }
  }
  var requiresToken: Bool {
    switch self {
    case .pgcOperationState, .messageReply, .messageAt, .messageLike, .messageUnread, .playback, .favoriteFolders, .followGroups, .followGroupUsers, .followers, .relationship,
      .libraryGallery, .libraryFolders, .libraryContents, .librarySeasonContents, .viewLater, .favoriteBangumi, .favoriteCinema: true
    default: isMutation
    }
  }
}

extension BiliService {
  public func favoriteFolders(aid: Int64, expectedIdentity: AuthSnapshot? = nil) async throws -> [FavoriteFolder] {
    try positiveIdentifier(aid)
    let data = try await appObject(.favoriteFolders, fields: ["rid": String(aid), "type": "2"], expectedIdentity: expectedIdentity)
    guard let list = data["list"] as? [[String: Any]] else {
      // The API uses null for a user with no folders.
      if data["list"] is NSNull { return [] }
      throw BiliError.invalidResponse("Missing favorite folder list")
    }
    return try list.map {
      guard let id = JSONValue.int64($0["id"]), id > 0, let title = $0["title"] as? String else {
        throw BiliError.invalidResponse("Invalid favorite folder")
      }
      return FavoriteFolder(
        id: id, title: title, containsVideo: JSONValue.int($0["fav_state"]) == 1)
    }
  }
  // The fixed SDK maps isLike=true to like=0; preserve this contract explicitly.
  public func setVideoLiked(aid: Int64, liked: Bool, expectedIdentity: AuthSnapshot? = nil) async throws {
    try positiveIdentifier(aid)
    _ = try await appREST(.like, fields: ["aid": String(aid), "like": liked ? "0" : "1"], expectedIdentity: expectedIdentity)
  }
  public func coinVideo(aid: Int64, count: Int, alsoLike: Bool, expectedIdentity: AuthSnapshot? = nil) async throws {
    try positiveIdentifier(aid)
    guard (1...2).contains(count) else {
      throw BiliError.invalidResponse("Coin count must be 1 or 2")
    }
    var fields = ["aid": String(aid), "multiply": String(count)]
    if alsoLike { fields["select_like"] = "1" }
    _ = try await appREST(.coin, fields: fields, expectedIdentity: expectedIdentity)
  }
  /// Watch progress for the account's history (BiliKernel `ReportProgressAsync`): type 3 for a
  /// video, type 4 with episode and season for PGC.
  public func reportProgress(aid: Int64, cid: Int64, seconds: Int, episode: (id: Int64, season: Int64)? = nil,
    expectedIdentity: AuthSnapshot? = nil) async throws {
    try positiveIdentifier(aid); try positiveIdentifier(cid)
    var fields = ["aid": String(aid), "cid": String(cid), "progress": String(max(0, seconds)), "type": episode == nil ? "3" : "4"]
    if let episode {
      try positiveIdentifier(episode.id); try positiveIdentifier(episode.season)
      fields["epid"] = String(episode.id); fields["sid"] = String(episode.season); fields["sub_type"] = "1"
    }
    _ = try await appREST(.historyReport, fields: fields, expectedIdentity: expectedIdentity)
  }
  /// Watch progress for the account signed in now, bound to that identity: the sign-in check and
  /// the identity check run in one actor step, so a switch to another account before the write
  /// goes out makes it fail instead of landing in the new account's history. Returns false
  /// (nothing sent) while signed out.
  @discardableResult
  public func reportProgressForCurrentAccount(aid: Int64, cid: Int64, seconds: Int,
    episode: (id: Int64, season: Int64)? = nil) async throws -> Bool {
    let identity = authSnapshot()
    guard identity.state != .needsLogin else { return false }
    try await reportProgress(aid: aid, cid: cid, seconds: seconds, episode: episode, expectedIdentity: identity)
    return true
  }
  public func tripleVideo(aid: Int64, expectedIdentity: AuthSnapshot? = nil) async throws {
    try positiveIdentifier(aid)
    _ = try await appREST(.triple, fields: ["aid": String(aid)], expectedIdentity: expectedIdentity)
  }
  public func updateVideoFavorite(aid: Int64, add: [Int64], remove: [Int64], expectedIdentity: AuthSnapshot? = nil) async throws {
    try positiveIdentifier(aid)
    guard add.allSatisfy({ $0 > 0 }), remove.allSatisfy({ $0 > 0 }),
      Set(add).isDisjoint(with: Set(remove)), !add.isEmpty || !remove.isEmpty
    else {
      throw BiliError.invalidResponse("Invalid favorite folder selection")
    }
    var fields = ["resources": "\(aid):2"]
    if !add.isEmpty {
      fields["add_media_ids"] = Array(Set(add)).sorted().map(String.init).joined(separator: ",")
    }
    if !remove.isEmpty {
      fields["del_media_ids"] = Array(Set(remove)).sorted().map(String.init).joined(separator: ",")
    }
    _ = try await appREST(.favorite, fields: fields, expectedIdentity: expectedIdentity)
  }
  public func setFollowing(mid: Int64, following: Bool, expectedIdentity: AuthSnapshot? = nil) async throws {
    try positiveIdentifier(mid)
    _ = try await appREST(.following, fields: ["fid": String(mid), "act": following ? "1" : "2"], expectedIdentity: expectedIdentity)
  }
  private func positiveIdentifier(_ value: Int64) throws {
    guard value > 0 else { throw BiliError.invalidResponse("Invalid identifier") }
  }
}
