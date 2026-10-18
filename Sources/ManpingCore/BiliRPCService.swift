import BiliProtocol
import Foundation
import SwiftProtobuf

public protocol BiliRPCService: Sendable {
  func comments(oid: Int64, targetType: Int32, sort: RPCCommentSort, next: Int64) async throws
    -> RPCCommentPage
  func commentDetails(oid: Int64, targetType: Int32, root: Int64, sort: RPCCommentSort, next: Int64)
    async throws -> RPCCommentPage
  func dynamics(_ query: RPCDynamicQuery) async throws -> RPCDynamicPage
  func history(business: String, max: Int64) async throws -> RPCHistoryPage
  func popular(index: Int64, version: String) async throws -> RPCPopularPage
  func ranking(region: Int32) async throws -> [RPCVideoCard]
  func shutdown() async
}

public actor NativeBiliRPCService: BiliRPCService {
  private let auth: BiliService
  private let transport: any BiliRPCTransport
  private let metadata: BiliRPCMetadata
  private let localTime: Int32
  private var closed = false

  public init(
    auth: BiliService, transport: any BiliRPCTransport, installationID: String,
    timeZone: TimeZone = .current
  ) {
    self.auth = auth
    self.transport = transport
    metadata = BiliRPCMetadata(installationID: installationID)
    localTime = Int32(timeZone.secondsFromGMT() / 3600)
  }
  // A stable per-installation ID should be supplied by the app composition root, never an account ID.
  public init(auth: BiliService, installationID: String) throws {
    self.auth = auth
    self.transport = try NativeBiliRPCTransport()
    metadata = BiliRPCMetadata(installationID: installationID)
    localTime = Int32(TimeZone.current.secondsFromGMT() / 3600)
  }
  private func call<Req: SwiftProtobuf.Message, Reply: SwiftProtobuf.Message>(
    _ method: BiliRPCMethod, _ request: Req, _ response: Reply.Type, authenticated: Bool
  ) async throws -> Reply {
    guard !closed else { throw BiliRPCError.shutdown }
    let metadata = self.metadata
    let transport = self.transport
    do {
      return try await auth.withRPCIdentity(requireToken: authenticated) { snapshot in
        let headers = try metadata.build(snapshot)
        try Task.checkCancellation()
        return try await transport.unary(
          request, response: response, descriptor: method.descriptor, metadata: headers)
      }
    } catch { throw BiliRPCError.sanitized(error) }
  }
  public func comments(
    oid: Int64, targetType: Int32 = 1, sort: RPCCommentSort = .hot, next: Int64 = 0
  ) async throws -> RPCCommentPage {
    guard oid > 0, targetType > 0, next >= 0 else { throw BiliRPCError.invalidArgument }
    var req = Bilibili_Main_Community_Reply_V1_MainListReq()
    req.oid = oid
    req.type = Int64(targetType)
    req.cursor.next = next
    req.cursor.mode = sort == .time ? .mainListTime : .mainListHot
    let reply = try await call(
      .mainList, req, Bilibili_Main_Community_Reply_V1_MainListReply.self, authenticated: false)
    return try BiliRPCAdapter.comments(reply, oid: oid, type: targetType)
  }
  public func commentDetails(
    oid: Int64, targetType: Int32 = 1, root: Int64, sort: RPCCommentSort = .hot, next: Int64 = 0
  ) async throws -> RPCCommentPage {
    guard oid > 0, targetType > 0, root > 0, next >= 0 else { throw BiliRPCError.invalidArgument }
    var req = Bilibili_Main_Community_Reply_V1_DetailListReq()
    req.oid = oid
    req.type = Int64(targetType)
    req.root = root
    req.scene = .reply
    req.cursor.next = next
    req.cursor.mode = sort == .time ? .mainListTime : .mainListHot
    let reply = try await call(
      .detailList, req, Bilibili_Main_Community_Reply_V1_DetailListReply.self, authenticated: false)
    return try BiliRPCAdapter.comments(reply, oid: oid, type: targetType)
  }
  public func dynamics(_ query: RPCDynamicQuery) async throws -> RPCDynamicPage {
    switch query {
    case .all(let offset, let baseline):
      var req = Bilibili_App_Dynamic_V2_DynAllReq()
      req.offset = offset
      req.updateBaseline = baseline
      req.localTime = localTime
      req.refreshType = offset.isEmpty ? .new : .history
      let reply = try await call(
        .dynAll, req, Bilibili_App_Dynamic_V2_DynAllReply.self, authenticated: true)
      guard reply.hasDynamicList else { throw BiliRPCError.invalidPayload("dynamic.list") }
      return try BiliRPCAdapter.dynamics(
        reply.dynamicList.list, offset: reply.dynamicList.historyOffset,
        baseline: reply.dynamicList.updateBaseline, hasMore: reply.dynamicList.hasMore_p,
        users: reply.upList.list)
    case .video(let offset, let baseline):
      var req = Bilibili_App_Dynamic_V2_DynVideoReq()
      req.offset = offset
      req.updateBaseline = baseline
      req.localTime = localTime
      req.refreshType = offset.isEmpty ? .new : .history
      let reply = try await call(
        .dynVideo, req, Bilibili_App_Dynamic_V2_DynVideoReply.self, authenticated: true)
      guard reply.hasDynamicList else { throw BiliRPCError.invalidPayload("dynamic.list") }
      return try BiliRPCAdapter.dynamics(
        reply.dynamicList.list, offset: reply.dynamicList.historyOffset,
        baseline: reply.dynamicList.updateBaseline, hasMore: reply.dynamicList.hasMore_p,
        users: reply.videoUpList.list)
    case .userAll(let mid, let offset):
      guard mid > 0 else { throw BiliRPCError.invalidArgument }
      var req = Bilibili_App_Dynamic_V2_DynAllPersonalReq()
      req.hostUid = mid
      req.offset = offset
      req.localTime = localTime
      let reply = try await call(
        .dynAllPersonal, req, Bilibili_App_Dynamic_V2_DynAllPersonalReply.self, authenticated: false
      )
      return try BiliRPCAdapter.dynamics(reply.list, offset: reply.offset, hasMore: reply.hasMore_p)
    case .userVideo(let mid, let offset):
      guard mid > 0 else { throw BiliRPCError.invalidArgument }
      var req = Bilibili_App_Dynamic_V2_DynVideoPersonalReq()
      req.hostUid = mid
      req.offset = offset
      req.localTime = localTime
      let reply = try await call(
        .dynVideoPersonal, req, Bilibili_App_Dynamic_V2_DynAllPersonalReply.self,
        authenticated: false)
      return try BiliRPCAdapter.dynamics(reply.list, offset: reply.offset, hasMore: reply.hasMore_p)
    case .space(let mid, let offset):
      guard mid > 0 else { throw BiliRPCError.invalidArgument }
      var req = Bilibili_App_Dynamic_V2_DynSpaceReq()
      req.hostUid = mid
      req.historyOffset = offset
      req.localTime = localTime
      let reply = try await call(
        .dynSpace, req, Bilibili_App_Dynamic_V2_DynSpaceRsp.self, authenticated: true)
      return try BiliRPCAdapter.dynamics(
        reply.list, offset: reply.historyOffset, hasMore: reply.hasMore_p)
    }
  }
  public func history(business: String = "all", max: Int64 = 0) async throws -> RPCHistoryPage {
    guard ["all", "archive", "article", "live"].contains(business), max >= 0 else {
      throw BiliRPCError.invalidArgument
    }
    var req = Bilibili_App_Interfaces_V1_CursorV2Req()
    req.business = business
    req.cursor.max = max
    let reply = try await call(
      .history, req, Bilibili_App_Interfaces_V1_CursorV2Reply.self, authenticated: true)
    return try BiliRPCAdapter.history(reply)
  }
  public func popular(index: Int64 = 0, version: String = "") async throws -> RPCPopularPage {
    guard index >= 0 else { throw BiliRPCError.invalidArgument }
    var req = Bilibili_App_Show_Popular_V1_PopularResultReq()
    req.idx = index
    req.ver = version
    let reply = try await call(
      .popular, req, Bilibili_App_Show_Popular_V1_PopularReply.self, authenticated: false)
    return try BiliRPCAdapter.popular(reply)
  }
  public func ranking(region: Int32 = 0) async throws -> [RPCVideoCard] {
    guard region >= 0 else { throw BiliRPCError.invalidArgument }
    var req = Bilibili_App_Show_Rank_V1_RankRegionResultReq()
    req.rid = region
    let reply = try await call(
      .rank, req, Bilibili_App_Show_Rank_V1_RankListReply.self, authenticated: false)
    return try BiliRPCAdapter.ranking(reply)
  }
  public func shutdown() async {
    closed = true
    await transport.shutdown(grace: .seconds(2))
  }
}
