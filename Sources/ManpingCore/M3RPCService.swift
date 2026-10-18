import BiliProtocol
import Foundation
import GRPCCore
import SwiftProtobuf

// Exact SDK BiliApis uses app.interface.v1 in routes and app.interfaces.v1 in schemas.
public actor LibraryRPCService {
  private let auth: BiliService
  private let transport: any BiliRPCTransport
  private let metadata: BiliRPCMetadata
  public init(auth: BiliService, transport: any BiliRPCTransport, installationID: String) {
    self.auth = auth; self.transport = transport
    metadata = BiliRPCMetadata(installationID: installationID)
  }
  public init(auth: BiliService, installationID: String) throws {
    self.auth = auth; transport = try NativeBiliRPCTransport()
    metadata = BiliRPCMetadata(installationID: installationID)
  }
  private func call<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, service: String, method: String, authenticated: Bool, expectedIdentity: AuthSnapshot? = nil
  ) async throws -> Response {
    let transport = self.transport; let metadata = self.metadata
    let descriptor = MethodDescriptor(fullyQualifiedService: service, method: method, type: .unary)
    do {
      return try await auth.withRPCIdentity(requireToken: authenticated, expectedIdentity: expectedIdentity) { snapshot in
        try await transport.unary(request, response: response, descriptor: descriptor,
                                  metadata: metadata.build(snapshot))
      }
    } catch { throw BiliRPCError.sanitized(error) }
  }
  public func userVideos(mid: Int64, keyword: String = "", page: Int = 1)
    async throws -> LibraryPage<LibraryEntry> {
    guard mid > 0, (1...1_000_000).contains(page) else { throw BiliRPCError.invalidArgument }
    var request = Bilibili_App_Interfaces_V1_SearchArchiveReq()
    request.mid = mid; request.keyword = keyword; request.pn = Int64(page); request.ps = 20
    let reply = try await call(request, response: Bilibili_App_Interfaces_V1_SearchArchiveReply.self,
      service: "bilibili.app.interface.v1.Space", method: "SearchArchive", authenticated: false)
    guard reply.archives.count <= 500 else { throw BiliRPCError.resourceLimit }
    let items = try reply.archives.map { item -> LibraryEntry in
      let arc = item.archive
      guard arc.aid > 0, !arc.title.isEmpty else { throw BiliRPCError.invalidPayload("space.archive") }
      return .video(Video(bvid: "", title: arc.title, cover: JSONValue.url(arc.pic),
        author: arc.author.name, duration: Int(arc.duration), views: Int(arc.stat.view),
        cid: arc.firstCid > 0 ? arc.firstCid : nil, description: arc.desc,
        aid: arc.aid, authorID: arc.author.mid, avatar: JSONValue.url(arc.author.face)))
    }
    return LibraryPage(items: items, hasMore: Int64((page - 1) * 20 + items.count) < reply.total,
                       total: Int(reply.total))
  }
  public func suggestions(keyword: String) async throws -> [LibrarySearchSuggestion] {
    guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, keyword.count <= 1000 else {
      throw BiliRPCError.invalidArgument
    }
    var request = Bilibili_App_Interfaces_V1_SuggestionResult3Req()
    request.keyword = keyword; request.highlight = 0
    let reply = try await call(request, response: Bilibili_App_Interfaces_V1_SuggestionResult3Reply.self,
      service: "bilibili.app.interface.v1.Search", method: "Suggest3", authenticated: false)
    guard reply.list.count <= 200 else { throw BiliRPCError.resourceLimit }
    var known = Set<String>()
    return reply.list.filter { !$0.keyword.isEmpty && known.insert($0.keyword).inserted }
      .map { LibrarySearchSuggestion(title: BiliService.libraryPlain($0.title.isEmpty ? $0.keyword : $0.title), keyword: $0.keyword) }
  }
  public func historyRecords(business: HistoryBusiness, max: Int64 = 0, expectedIdentity: AuthSnapshot) async throws -> RPCHistoryPage {
    guard max >= 0 else { throw BiliRPCError.invalidArgument }
    var request = Bilibili_App_Interfaces_V1_CursorReq()
    request.business = business.rawValue; request.cursor.max = max
    let reply = try await call(request, response: Bilibili_App_Interfaces_V1_CursorV2Reply.self,
      service: "bilibili.app.interface.v1.History", method: "Cursor", authenticated: true,
      expectedIdentity: expectedIdentity)
    return try BiliRPCAdapter.history(reply)
  }
  public func historySearchRecords(keyword: String, page: Int = 1, expectedIdentity: AuthSnapshot) async throws -> HistorySearchPage {
    guard !keyword.isEmpty, keyword.count <= 1000, (1...1_000_000).contains(page) else { throw BiliRPCError.invalidArgument }
    var request = Bilibili_App_Interfaces_V1_SearchReq()
    request.keyword = keyword; request.pn = Int64(page); request.business = "archive"
    let reply = try await call(request, response: Bilibili_App_Interfaces_V1_SearchReply.self,
      service: "bilibili.app.interface.v1.History", method: "Search", authenticated: true,
      expectedIdentity: expectedIdentity)
    var cursor = Bilibili_App_Interfaces_V1_CursorV2Reply()
    cursor.items = reply.items; cursor.hasMore_p = reply.hasMore_p; cursor.cursor.max = 0
    let history = try BiliRPCAdapter.history(cursor)
    return HistorySearchPage(items: history.items, hasMore: reply.hasMore_p, total: Int(reply.page.total))
  }
  public func deleteHistory(_ key: HistoryRecordKey, expectedIdentity: AuthSnapshot) async throws {
    guard key.kid > 0 else { throw BiliRPCError.invalidArgument }
    var request = Bilibili_App_Interfaces_V1_DeleteReq()
    var item = Bilibili_App_Interfaces_V1_HisInfo()
    item.kid = key.kid; item.business = key.business.rawValue; request.hisInfo = [item]
    _ = try await call(request, response: Bilibili_App_Interfaces_V1_NoReply.self,
      service: "bilibili.app.interface.v1.History", method: "Delete", authenticated: true,
      expectedIdentity: expectedIdentity)
  }
  public func clearHistory(_ business: HistoryBusiness, expectedIdentity: AuthSnapshot) async throws {
    var request = Bilibili_App_Interfaces_V1_ClearReq()
    request.business = business.rawValue
    _ = try await call(request, response: Bilibili_App_Interfaces_V1_NoReply.self,
      service: "bilibili.app.interface.v1.History", method: "Clear", authenticated: true,
      expectedIdentity: expectedIdentity)
  }
  public func shutdown() async { await transport.shutdown(grace: .seconds(2)) }
}

extension LibraryEntry {
  public static func rpcVideo(_ card: RPCVideoCard) -> Self {
    .video(Video(bvid: card.bvid, title: card.title, cover: card.cover,
      author: card.author?.name ?? "", duration: Int(card.duration), views: Int(card.views),
      cid: card.cid > 0 ? card.cid : nil, aid: card.aid > 0 ? card.aid : nil,
      authorID: card.author?.mid, avatar: card.author?.avatar, publishedAt: card.publishedAt,
      subtitle: card.subtitle, recommendationReason: card.recommendationReason))
  }
  public static func history(_ item: RPCHistoryItem) -> Self {
    if case .video(let card, let progress) = item.content {
      let entry = rpcVideo(card)
      return Self(id: "\(item.business):\(item.id)", title: entry.title,
        subtitle: progress < 0 ? "已看完" : "已观看 \(progress) 秒", cover: entry.cover,
        destination: entry.destination)
    }
    let cover: URL?
    switch item.content {
    case .episode(let image, _, _, _), .course(let image, _, _, _): cover = image
    case .article(_, let images): cover = images.first
    case .live(_, let image, _): cover = image
    default: cover = nil
    }
    return Self(id: "\(item.business):\(item.id)", title: item.title,
      subtitle: Date(timeIntervalSince1970: Double(item.viewedAt)).formatted(), cover: cover,
      destination: historyURL(item).map(Destination.web) ?? .unavailable)
  }
  private static func historyURL(_ item: RPCHistoryItem) -> URL? {
    if let url = JSONValue.url(item.uri) { return url }
    guard item.id > 0 else { return nil }
    switch item.content {
    case .article: return URL(string: "https://www.bilibili.com/read/cv\(item.id)")
    case .live: return URL(string: "https://live.bilibili.com/\(item.id)")
    case .episode:
      if let range = item.uri.range(of: "ep[0-9]+", options: .regularExpression) {
        return URL(string: "https://www.bilibili.com/bangumi/play/\(item.uri[range])")
      }
      return URL(string: "https://www.bilibili.com/bangumi/play/ss\(item.id)")
    default: return nil
    }
  }
}
