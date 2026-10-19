import Foundation

public enum SpaceArchiveOrder: String, CaseIterable, Codable, Sendable {
  case pubdate, click, stow
  public var title: String {
    switch self { case .pubdate: "最新发布"; case .click: "最多播放"; case .stow: "最多收藏" }
  }
}
public enum SpaceArchiveProvider: String, Codable, Sendable { case wbi, appCursor, grpc }
public struct SpaceArchiveQuery: Equatable, Codable, Sendable {
  public var mid: Int64
  public var order: SpaceArchiveOrder
  public var tid: Int
  public var keyword: String
  public var cursor: String?
  public var provider: SpaceArchiveProvider?
  public init(mid: Int64, order: SpaceArchiveOrder = .pubdate, tid: Int = 0,
              keyword: String = "", cursor: String? = nil, provider: SpaceArchiveProvider? = nil) {
    self.mid = mid; self.order = order; self.tid = tid; self.keyword = keyword
    self.cursor = cursor; self.provider = provider
  }
  fileprivate var context: Self { var copy = self; copy.cursor = nil; copy.provider = nil; return copy }
  public var contextKey: String { "\(mid):\(order.rawValue):\(tid):\(keyword):\(provider?.rawValue ?? "auto")" }
}
public struct SpacePartition: Identifiable, Equatable, Sendable {
  public let id: Int
  public let name: String
  public let count: Int
}
public struct SpaceArchivePage: Sendable {
  public let provider: SpaceArchiveProvider
  public let availableOrders: [SpaceArchiveOrder]
  public let supportsPartitions: Bool
  public let order: SpaceArchiveOrder
  public let tid: Int
  public let partitions: [SpacePartition]
  public let videos: [LibraryEntry]
  public let nextCursor: String?
  public let total: Int
  public let restarted: Bool
}
private struct SpaceCursor: Codable {
  let query: SpaceArchiveQuery
  let provider: SpaceArchiveProvider
  let page: Int
  let aid: String
  func encoded() throws -> String {
    let encoder = JSONEncoder()
    // Stable encoding makes a repeated provider cursor detectable across pages.
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self).base64EncodedString()
  }
  static func decode(_ value: String) throws -> Self {
    guard let data = Data(base64Encoded: value), data.count < 8192 else {
      throw BiliError.invalidResponse("Invalid space cursor")
    }
    return try JSONDecoder().decode(Self.self, from: data)
  }
}

public enum SpaceCollectionKind: String, Codable, Sendable { case season, series }
public struct SpaceCollection: Identifiable, Equatable, Sendable {
  public let collectionID: Int64
  public let mid: Int64
  public let kind: SpaceCollectionKind
  public let title: String
  public let cover: URL?
  public let count: Int
  public var id: String { "\(kind.rawValue):\(collectionID)" }
}
public struct SpaceOverview: Sendable {
  public let pinned: [LibraryEntry]
  public let masterpieces: [LibraryEntry]
  public let archiveCount: Int?
  public let collectionCount: Int?
  public let plays: Int?
  public let likes: Int?
}

extension BiliService {
  public nonisolated static func shouldFallbackSpace(_ error: Error) -> Bool {
    switch error { case BiliError.api(-352, _), BiliError.http(412): true; default: false }
  }
  /// The cursor binds the complete requested query and provider. A fallback always starts
  /// at the beginning, and explicitly reports the actual ordering and filtering capability.
  public func spaceArchives(query: SpaceArchiveQuery,
    keywordSource: (@Sendable (Int64, String, Int) async throws -> LibraryPage<LibraryEntry>)? = nil)
    async throws -> SpaceArchivePage {
    guard query.mid > 0, query.tid >= 0 else { throw BiliError.invalidResponse("Invalid space query") }
    let snapshot = authSnapshot()
    let cursor = try query.cursor.map(SpaceCursor.decode)
    if let cursor {
      guard cursor.query == query.context, query.provider == nil || query.provider == cursor.provider else {
        throw BiliError.invalidResponse("Space cursor query mismatch")
      }
    }
    let page = cursor?.page ?? 1
    guard page > 0, page <= 1_000_000 else { throw BiliError.invalidResponse("Invalid space page") }
    let requestedProvider = cursor?.provider ?? query.provider ?? .wbi
    var provider: SpaceArchiveProvider = query.keyword.isEmpty ? requestedProvider : .grpc
    var restarted = false
    var raw: [[String: Any]] = []
    var entries: [LibraryEntry] = []
    var total = 0, hasMore = false
    var partitions: [SpacePartition] = []
    var nextAid = ""
    if provider == .grpc {
      guard let keywordSource else { throw BiliError.dependency("无法初始化投稿搜索服务") }
      let result = try await keywordSource(query.mid, query.keyword, page)
      try checkRESTIdentity(snapshot)
      entries = result.items; total = result.total; hasMore = result.hasMore
    } else if provider == .wbi {
      do {
        let data = try await json("/x/space/wbi/arc/search", params: [
          "mid": String(query.mid), "pn": String(page), "ps": "30", "order": query.order.rawValue,
          "tid": String(query.tid), "keyword": "", "web_location": "1550101", "dm_img_list": "[]",
          "dm_img_str": "V2ViR0w", "dm_cover_img_str": "V2ViR0w", "dm_img_inter": "{\"ds\":[],\"wh\":[0,0,0],\"of\":[0,0,0]}"], signed: true)
        try checkRESTIdentity(snapshot)
        guard let list = data["list"] as? [String: Any], let info = data["page"] as? [String: Any] else {
          throw BiliError.invalidResponse("Missing space archive list/page")
        }
        raw = try Self.libraryList(list, key: "vlist")
        total = JSONValue.int(info["count"]); hasMore = page * 30 < total
        if let tlist = list["tlist"] as? [String: [String: Any]] {
          partitions = tlist.values.compactMap { item in
            guard let tid = JSONValue.int64(item["tid"]), let name = item["name"] as? String else { return nil }
            return SpacePartition(id: Int(tid), name: name, count: JSONValue.int(item["count"]))
          }.sorted { $0.id < $1.id }
        }
      } catch {
        try checkRESTIdentity(snapshot)
        guard Self.shouldFallbackSpace(error) else { throw error }
        provider = .appCursor; restarted = cursor != nil
      }
    }
    let actualOrder: SpaceArchiveOrder = provider == .wbi ? query.order : query.order == .click && provider == .appCursor ? .click : .pubdate
    if provider == .appCursor {
      let aid = requestedProvider == .appCursor ? cursor?.aid ?? "0" : "0"
      let data = try await appObject(.spaceArchiveCursor, fields: ["vmid": String(query.mid),
        "order": actualOrder.rawValue, "ps": "30", "aid": aid], expectedIdentity: snapshot)
      raw = try Self.libraryList(data, key: "item")
      total = JSONValue.int(data["count"])
      hasMore = JSONValue.int(data["has_next"]) == 1 || data["has_next"] as? Bool == true
      nextAid = raw.last?["param"] as? String ?? JSONValue.int64(raw.last?["param"]).map(String.init) ?? ""
      if hasMore && (nextAid.isEmpty || nextAid == aid) { throw BiliError.invalidResponse("Space cursor did not advance") }
    }
    try checkRESTIdentity(snapshot)
    if provider != .grpc { entries = try raw.map { .video(try Self.spaceVideo($0, mid: query.mid)) } }
    let next: String? = hasMore && !entries.isEmpty ? try SpaceCursor(query: query.context,
      provider: provider, page: provider == .appCursor ? 1 : restarted ? 2 : page + 1, aid: nextAid).encoded() : nil
    return SpaceArchivePage(provider: provider,
      availableOrders: provider == .wbi ? SpaceArchiveOrder.allCases : provider == .appCursor ? [.pubdate, .click] : [.pubdate],
      supportsPartitions: provider == .wbi, order: actualOrder, tid: provider == .wbi ? query.tid : 0,
      partitions: partitions, videos: entries, nextCursor: next, total: total, restarted: restarted)
  }
  private static func spaceVideo(_ item: [String: Any], mid: Int64) throws -> Video {
    var item = item
    if item["aid"] == nil { item["aid"] = item["param"] }
    if item["duration"] == nil { item["duration"] = item["length"] }
    if item["cid"] == nil { item["cid"] = item["first_cid"] }
    if item["owner"] == nil && item["mid"] == nil { item["mid"] = mid }
    return try libraryVideo(item)
  }
  public func spaceCollections(mid: Int64, page: Int = 1) async throws -> LibraryPage<SpaceCollection> {
    guard mid > 0, (1...1_000_000).contains(page) else { throw BiliError.invalidResponse("Invalid space collection query") }
    let data = try await json("/x/polymer/web-space/seasons_series_list", params: [
      "mid": String(mid), "page_num": String(page), "page_size": "20"])
    guard let list = data["items_lists"] as? [String: Any] else { throw BiliError.invalidResponse("Missing space collections") }
    var items: [SpaceCollection] = []
    for kind in [SpaceCollectionKind.season, .series] {
      let raw = try Self.libraryList(list, key: kind == .season ? "seasons_list" : "series_list")
      for item in raw {
        guard let meta = item["meta"] as? [String: Any], let id = JSONValue.int64(meta[kind == .season ? "season_id" : "series_id"]),
          id > 0, let name = meta["name"] as? String else { throw BiliError.invalidResponse("Invalid space collection") }
        items.append(SpaceCollection(collectionID: id, mid: mid, kind: kind, title: name,
          cover: JSONValue.url(meta["cover"] ?? (item["archives"] as? [[String: Any]])?.first?["pic"]), count: JSONValue.int(meta["total"])))
      }
    }
    let info = list["page"] as? [String: Any] ?? [:]
    let total = JSONValue.int(info["total"])
    return LibraryPage(items: items, hasMore: page * 20 < total, total: total)
  }
  public func spaceCollectionContents(_ collection: SpaceCollection, descending: Bool = false, page: Int = 1)
    async throws -> LibraryPage<LibraryEntry> {
    guard collection.collectionID > 0, collection.mid > 0, (1...1_000_000).contains(page) else { throw BiliError.invalidResponse("Invalid space collection") }
    let season = collection.kind == .season
    let data = try await json(season ? "/x/polymer/web-space/seasons_archives_list" : "/x/series/archives", params: season ? [
      "mid": String(collection.mid), "season_id": String(collection.collectionID), "page_num": String(page), "page_size": "30",
      "sort_reverse": descending ? "true" : "false"] : ["mid": String(collection.mid), "series_id": String(collection.collectionID),
      "pn": String(page), "ps": "30", "sort": descending ? "desc" : "asc", "only_normal": "true"])
    let raw = try Self.libraryList(data, key: "archives")
    let total = JSONValue.int((data["page"] as? [String: Any])?["total"])
    return LibraryPage(items: try raw.map { .video(try Self.spaceVideo($0, mid: collection.mid)) }, hasMore: page * 30 < total, total: total)
  }
  public func spaceOverview(mid: Int64) async throws -> SpaceOverview {
    guard mid > 0 else { throw BiliError.invalidResponse("Invalid space identifier") }
    let snapshot = authSnapshot()
    let nav = try await json("/x/space/navnum", params: ["mid": String(mid)])
    let top: [String: Any]
    do { top = try await json("/x/space/top/arc", params: ["vmid": String(mid)]) }
    catch BiliError.api(-404, _) { top = [:] }
    // This endpoint's data is an array, unlike the dictionary-only json helper.
    let body = try await data(URL(string: "https://api.bilibili.com/x/space/masterpiece?vmid=\(mid)")!)
    guard let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let code = envelope["code"] as? Int else { throw BiliError.invalidResponse("Invalid masterpieces") }
    guard code == 0 else { throw BiliError.api(code, "请求失败") }
    guard let works = envelope["data"] as? [[String: Any]] else { throw BiliError.invalidResponse("Missing masterpieces") }
    let stats = try await json("/x/space/upstat", params: ["mid": String(mid)])
    try checkRESTIdentity(snapshot)
    return SpaceOverview(pinned: top.isEmpty ? [] : [.video(try Self.spaceVideo(top, mid: mid))],
      masterpieces: try works.map { .video(try Self.spaceVideo($0, mid: mid)) },
      archiveCount: JSONValue.int64(nav["video"]).map(Int.init),
      collectionCount: JSONValue.int64(nav["season_num"]).map { Int($0) + JSONValue.int(nav["series_num"]) },
      plays: JSONValue.int64((stats["archive"] as? [String: Any])?["view"]).map(Int.init),
      likes: JSONValue.int64(stats["likes"]).map(Int.init))
  }
}

/// Reusable injectable cursor collection; preserves partial results on a page failure and
/// rejects a cursor cycle before requesting it again. Cancellation always propagates.
public struct CursorPlaylistPage: Sendable {
  public let page: LibraryPage<LibraryEntry>
  public let nextCursor: String?
  public let restarted: Bool
  public init(page: LibraryPage<LibraryEntry>, nextCursor: String?, restarted: Bool = false) { self.page = page; self.nextCursor = nextCursor; self.restarted = restarted }
}
public struct PlaylistCollectionResult: Sendable {
  public let videos: [Video]
  public let notice: String?
  public let complete: Bool
}
public enum CursorPlaylistCollector {
  public static func collect(limit: Int = PlaylistCollector.defaultLimit,
    progress: @Sendable (Int) async -> Void = { _ in },
    source: @Sendable (String?) async throws -> CursorPlaylistPage) async throws -> PlaylistCollectionResult {
    var collector = PlaylistCollector(limit: limit)
    var cursor: String?, seen = Set<String>()
    do {
      while !collector.finished {
        try Task.checkCancellation()
        let result = try await source(cursor)
        try Task.checkCancellation()
        if result.restarted { collector = PlaylistCollector(limit: limit); seen = [] }
        collector.add(result.page)
        await progress(collector.videos.count)
        guard !collector.finished else { break }
        guard let next = result.nextCursor, seen.insert(next).inserted else {
          throw BiliError.invalidResponse("Playlist cursor did not advance")
        }
        cursor = next
      }
      return PlaylistCollectionResult(videos: collector.videos, notice: collector.truncationNotice, complete: true)
    } catch is CancellationError { throw CancellationError() }
    catch {
      switch error { case is AuthFailure, BiliRPCError.needsLogin, BiliRPCError.authenticationFailure, BiliRPCError.permissionDenied, BiliError.api(-101, _), BiliError.http(401): throw error; default: break }
      return PlaylistCollectionResult(videos: collector.videos, notice: "没能加载完整列表：\(error.localizedDescription)", complete: false)
    }
  }
}
