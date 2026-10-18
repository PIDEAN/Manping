import Foundation
import BiliProtocol
import GRPCCore
import SwiftProtobuf
import XCTest

@testable import ManpingCore

private final class M2Store: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  private var cookies: [HTTPCookie]
  init(token: AppToken? = nil, cookies: [HTTPCookie] = []) { self.token = token; self.cookies = cookies }
  func save(_ cookies: [HTTPCookie]) { lock.withLock { self.cookies = cookies } }
  func load() -> [HTTPCookie] { lock.withLock { cookies } }
  func saveToken(_ value: AppToken?) { lock.withLock { token = value } }
  func loadToken() -> AppToken? { lock.withLock { token } }
  func clear() { saveToken(nil) }
}

private actor M2Transport: AuthTransport {
  struct Reply: Sendable {
    let body: Data
    var status: Int = 200
    var failTransport = false
    init(_ text: String, status: Int = 200, failTransport: Bool = false) {
      body = Data(text.utf8)
      self.status = status
      self.failTransport = failTransport
    }
  }
  var replies: [Reply]
  var requests: [URLRequest] = []
  var paused: Bool
  private var releases: [CheckedContinuation<Void, Never>] = []
  private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
  init(_ replies: [Reply], paused: Bool = false) {
    self.replies = replies
    self.paused = paused
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    guard !replies.isEmpty else { throw URLError(.badServerResponse) }
    let reply = replies.removeFirst()
    let ready = observers.filter { requests.count >= $0.0 }
    observers.removeAll { requests.count >= $0.0 }
    for (_, observer) in ready { observer.resume() }
    if paused { await withCheckedContinuation { releases.append($0) } }
    // Intentionally ignore task cancellation to exercise late success AND late failure.
    if reply.failTransport { throw URLError(.timedOut) }
    return AuthHTTPResponse(
      body: reply.body,
      response: HTTPURLResponse(
        url: request.url!, statusCode: reply.status,
        httpVersion: nil, headerFields: nil)!)
  }
  func waitForRequests(_ count: Int) async {
    if requests.count >= count { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }
  func pause() { paused = true }
  func release() {
    paused = false
    let pending = releases
    releases = []
    for release in pending { release.resume() }
  }
}

private actor M2StateRPC: BiliRPCTransport {
  var calls: [(String, Int64, Int32, [String])] = []
  let includesState: Bool
  init(includesState: Bool = true) { self.includesState = includesState }
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    let view = request as! Bilibili_App_View_V1_ViewReq
    calls.append((descriptor.fullyQualifiedMethod, view.aid, view.fnval,
      Array(metadata[stringValues: "authorization"])))
    var reply = Bilibili_App_View_V1_ViewReply()
    reply.arc.aid = view.aid
    if includesState {
      reply.reqUser.like = 1; reply.reqUser.favorite = 1; reply.reqUser.attention = 2; reply.reqUser.coin = 2
    }
    return try Response(serializedBytes: reply.serializedData())
  }
  func shutdown(grace: Duration) async {}
}

#if DEBUG
private actor M2BrowseRPCTransport: BiliRPCTransport {
  let fixture = M3FixtureRPCTransport()
  var popularIndexes: [Int64] = []
  var rankRegions: [Int32] = []
  var authorization: [String] = []
  let repeatCursor: Bool
  init(repeatCursor: Bool = false) { self.repeatCursor = repeatCursor }
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    authorization += Array(metadata[stringValues: "authorization"])
    if let popular = request as? Bilibili_App_Show_Popular_V1_PopularResultReq {
      popularIndexes.append(popular.idx)
      if repeatCursor {
        var reply = Bilibili_App_Show_Popular_V1_PopularReply()
        var card = Bilibili_App_Card_V1_Card()
        card.hotTopic.base.idx = popular.idx
        reply.items = [card]
        return try Response(serializedBytes: reply.serializedData())
      }
    } else if let rank = request as? Bilibili_App_Show_Rank_V1_RankRegionResultReq {
      rankRegions.append(rank.rid)
    } else { throw BiliRPCError.invalidArgument }
    return try await fixture.unary(request, response: response, descriptor: descriptor, metadata: metadata)
  }
  func shutdown(grace: Duration) async {}
}
#endif

private actor M2OperationStateGate {
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  private var enteredWaiter: CheckedContinuation<Void, Never>?
  private var entered = false
  let failOld: Bool
  init(failOld: Bool) { self.failOld = failOld }
  func load(_ snapshot: AuthSnapshot) async throws -> VideoOperationState {
    if snapshot.token?.mid == 123 {
      await withCheckedContinuation { continuation in
        releaseWaiter = continuation
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
      }
      if failOld { throw URLError(.timedOut) }
      return VideoOperationState(liked: true, following: true, favorited: true)
    }
    return VideoOperationState(liked: false, following: false, favorited: false)
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enteredWaiter = $0 }
  }
  func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor M2InterruptedStateGate {
  private var count = 0
  private var entered = false
  private var enteredWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  private var released = false
  let failOld: Bool
  init(failOld: Bool = false) { self.failOld = failOld }
  func load() async throws -> VideoOperationState {
    count += 1
    if count == 1 {
      await withCheckedContinuation { continuation in
        releaseWaiter = continuation
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
      }
      released = true
      if failOld { throw URLError(.timedOut) }
      return VideoOperationState(liked: true, following: true, favorited: true)
    }
    return VideoOperationState(liked: false, following: false, favorited: false)
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enteredWaiter = $0 }
  }
  func releaseOld() { releaseWaiter?.resume(); releaseWaiter = nil }
  var calls: Int { count }
}

@MainActor private func m2WaitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
  let deadline = Date().addingTimeInterval(2)
  while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
  XCTAssertTrue(condition(), "State transition timed out", file: file, line: line)
}

private let m2Token = AppToken(
  mid: 123, accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: 9_999_999_999
)
private let m2Dash =
  #"{"code":0,"data":{"dash":{"duration":12,"video":[{"id":64,"codecs":"avc1.640028","base_url":"https://video.example/v","bandwidth":100}],"audio":[{"id":30280,"codecs":"mp4a.40.2","base_url":"https://video.example/a","bandwidth":50}]}}}"#
private let m2Nav =
  #"{"code":-101,"data":{"wbi_img":{"img_url":"https://i.example/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i.example/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#
private func m2Fields(_ request: URLRequest) -> [String: String] {
  let raw =
    request.httpMethod == "POST"
    ? String(decoding: request.httpBody ?? Data(), as: UTF8.self) : request.url!.query!
  var result: [String: String] = [:]
  for item in raw.split(separator: "&") {
    let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    func decode(_ part: Substring) -> String {
      String(part).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!
    }
    result[decode(pair[0])] = decode(pair[1])
  }
  return result
}
private func m2Service(_ transport: M2Transport, token: AppToken? = m2Token) async throws
  -> BiliService
{
  let service = BiliService(
    transport: transport, credentials: M2Store(token: token),
    now: { Date(timeIntervalSince1970: 1000) })
  try await service.restoreCookies()
  return service
}
private func m2Object(_ json: String) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private extension BiliService {
  func m2ReadRoute(_ route: BiliAppRoute) async throws -> Int {
    let result = try await appREST(route, fields: ["mid": "999", "up_mid": "999", "vmid": "456"])
    return (result as? [String: Any])?["marker"] as? Int ?? -1
  }
}

final class M2CoreTests: XCTestCase, @unchecked Sendable {
  func testCardMetadataPreservesSourceSubtitleReasonAndPublication() throws {
    let web = try Video.parse(try m2Object(#"{"aid":123,"title":"A","pubdate":"1700000000","subtitle":"8小时前","rcmd_reason":{"content":"很多人点赞"}}"#))
    XCTAssertEqual(web.publishedAt, 1_700_000_000)
    XCTAssertEqual(web.subtitle, "8小时前")
    XCTAssertEqual(web.recommendationReason, "很多人点赞")
    let app = try BiliService.appVideo(try m2Object(#"{"param":"123","title":"A","pubdate":1700000000,"subtitle":"昨天 18:00","rcmd_reason_style":{"text":"6万点赞"}}"#))
    XCTAssertEqual(app.publishedAt, web.publishedAt)
    XCTAssertEqual(app.subtitle, "昨天 18:00")
    XCTAssertEqual(app.recommendationReason, "6万点赞")
    let legacy = try JSONDecoder().decode(Video.self, from: Data(#"{"bvid":"BV1fixture01","title":"Legacy","author":"Owner","duration":90,"views":100}"#.utf8))
    XCTAssertNil(legacy.publishedAt)
    XCTAssertNil(legacy.recommendationReason)
    XCTAssertEqual(try JSONDecoder().decode(Video.self, from: JSONEncoder().encode(app)), app)
  }
  func testPartsPreserveThumbnailBadgeAndCardMetadataWhenSelected() throws {
    let payload = try m2Object(#"{"View":{"aid":123,"title":"Series","cid":456,"pubdate":1700000000,"subtitle":"8小时前","rcmd_reason":{"content":"很多人点赞"},"owner":{"mid":789,"name":"Owner"},"stat":{},"pages":[{"cid":456,"page":1,"part":"First","duration":90,"first_frame":"https://fixture.invalid/cover/1","badge":"会员","stat":{"like":278000,"coin":15000}}]}}"#)
    let details = try VideoDetails.parse(payload)
    XCTAssertEqual(details.parts.first?.cover?.absoluteString, "https://fixture.invalid/cover/1")
    XCTAssertEqual(details.parts.first?.badge, "会员")
    XCTAssertEqual(details.parts.first?.likeCount, 278_000)
    XCTAssertEqual(details.parts.first?.coinCount, 15_000)
    let ordinary = VideoPart(cid: 1, page: 1, title: "UGC", duration: 10)
    XCTAssertNil(ordinary.likeCount)
    XCTAssertNil(ordinary.coinCount)
    let selected = details.selectingPart(cid: 456)
    XCTAssertEqual(selected.video.publishedAt, details.video.publishedAt)
    XCTAssertEqual(selected.video.subtitle, details.video.subtitle)
    XCTAssertEqual(selected.video.recommendationReason, details.video.recommendationReason)
    XCTAssertEqual(selected.parts, details.parts)
  }
  func testVideoStateRPCUsesExactViewRequestAndAuthenticatedReqUser() async throws {
    let http = M2Transport([])
    let service = try await m2Service(http)
    let snapshot = await service.authSnapshot()
    let rpc = M2StateRPC()
    let source = VideoOperationStateSource(auth: service, transport: rpc, installationID: "fixture-operation")
    let state = try await source.load(aid: 789, expectedIdentity: snapshot)
    XCTAssertEqual(state, VideoOperationState(liked: true, following: true, favorited: true, coined: true))
    let calls = await rpc.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.0, "bilibili.app.view.v1.View/View")
    XCTAssertEqual(calls.first?.1, 789)
    XCTAssertEqual(calls.first?.2, 16)
    XCTAssertEqual(calls.first?.3, ["identify_v1 fixture-access"])
    let httpRequests = await http.requests
    XCTAssertTrue(httpRequests.isEmpty)
    await source.shutdown()
  }

  func testMissingReqUserAndMissingWebSessionStayUnknown() async throws {
    let http = M2Transport([])
    let service = try await m2Service(http)
    let snapshot = await service.authSnapshot()
    let source = VideoOperationStateSource(auth: service, transport: M2StateRPC(includesState: false))
    do { _ = try await source.load(aid: 789, expectedIdentity: snapshot); XCTFail("Missing state is unknown") }
    catch BiliError.dependency {}
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty, "Never send anonymous Web state request")
    await source.shutdown()
  }

  func testWebOperationStateUsesWBIAndCookiesWithoutAppToken() async throws {
    let cookie = HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: "SESSDATA", .value: "fixture-cookie"])!
    let transport = M2Transport([.init(m2Nav), .init(#"{"code":0,"data":{"like":true,"attention":true,"favorite":false,"coin":2}}"#)])
    let service = BiliService(transport: transport, credentials: M2Store(token: m2Token, cookies: [cookie]),
      now: { Date(timeIntervalSince1970: 1000) })
    try await service.restoreCookies()
    let snapshot = await service.authSnapshot()
    let state = try await service.webVideoOperationState(aid: 789, expectedIdentity: snapshot)
    XCTAssertTrue(state.liked); XCTAssertTrue(state.following); XCTAssertTrue(state.coined)
    XCTAssertFalse(state.favorited)
    let requests = await transport.requests
    XCTAssertEqual(requests.last?.url?.path, "/x/web-interface/archive/relation")
    XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Cookie"), "SESSDATA=fixture-cookie")
    let fields = m2Fields(requests.last!)
    XCTAssertEqual(fields["aid"], "789"); XCTAssertNotNil(fields["w_rid"])
    XCTAssertNil(fields["access_key"]); XCTAssertNil(fields["sign"])
  }

  func testExpectedIdentityRejectsEveryOperationBeforeSendingForAnotherAccount() async throws {
    let transport = M2Transport([])
    let store = M2Store(token: m2Token)
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    let snapshot = try await service.authorizeAppInteraction()
    store.saveToken(AppToken(mid: 456, accessToken: "fixture-B", refreshToken: "fixture-B-refresh", expiresAt: 9_999_999_999))
    try await service.restoreCookies()
    for kind in 0..<8 {
      do {
        switch kind {
        case 0: try await service.setVideoLiked(aid: 789, liked: false, expectedIdentity: snapshot)
        case 1: try await service.setFollowing(mid: 2, following: false, expectedIdentity: snapshot)
        case 2: try await service.coinVideo(aid: 789, count: 1, alsoLike: false, expectedIdentity: snapshot)
        case 3: try await service.tripleVideo(aid: 789, expectedIdentity: snapshot)
        case 4: try await service.updateVideoFavorite(aid: 789, add: [2], remove: [], expectedIdentity: snapshot)
        case 5: _ = try await service.favoriteFolders(aid: 789, expectedIdentity: snapshot)
        case 6: _ = try await service.authorizeAppInteraction(expectedIdentity: snapshot)
        default: _ = try await service.withRPCIdentity(requireToken: true, expectedIdentity: snapshot) { _ in 1 }
        }
        XCTFail("Old account must reject before network")
      } catch is CancellationError {}
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  @MainActor func testUIExistingStateControlsDirectionAndRefreshesExpiredToken() async throws {
    let transport = M2Transport([
      .init(#"{"code":0,"data":{"mid":123,"access_token":"fixture-refreshed","refresh_token":"fixture-next","expires_in":3600}}"#),
      .init(#"{"code":0}"#), .init(#"{"code":0}"#)])
    let expired = AppToken(mid: 123, accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: 10)
    let service = try await m2Service(transport, token: expired)
    let model = VideoInteractionModel(service: service, stateLoader: { _, _ in
      VideoOperationState(liked: true, following: true, favorited: true)
    })
    model.reset(aid: 789)
    await m2WaitUntil { model.liked == true && !model.stateLoading }
    await model.like(aid: 789)
    await model.follow(mid: 2, aid: 789)
    XCTAssertEqual(model.liked, false); XCTAssertEqual(model.following, false)
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url!.path }, ["/api/oauth2/refreshToken", "/x/v2/view/like", "/x/relation/modify"])
    XCTAssertEqual(m2Fields(requests[1])["like"], "1")
    XCTAssertEqual(m2Fields(requests[2])["act"], "2")
    XCTAssertEqual(m2Fields(requests[1])["access_key"], "fixture-refreshed")
    model.shutdown()
  }

  @MainActor func testUIUnknownStateCannotToggleAndCancelledLoadHasNoAlert() async throws {
    let transport = M2Transport([])
    let service = try await m2Service(transport)
    let model = VideoInteractionModel(service: service, stateLoader: { _, _ in
      try await Task.sleep(for: .seconds(60))
      return VideoOperationState(liked: false, following: false, favorited: false)
    })
    model.reset(aid: 789)
    await model.like(aid: 789); await model.follow(mid: 2, aid: 789)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
    XCTAssertNil(model.liked); XCTAssertNil(model.following)
    model.shutdown()
    await Task.yield()
    XCTAssertFalse(model.busy); XCTAssertFalse(model.stateLoading); XCTAssertNil(model.message)
  }

  @MainActor func testUIIdentityChangeClearsSelectionAndRejectsLateMutationSuccessAndFailure() async throws {
    for reply in [M2Transport.Reply(#"{"code":0}"#), .init(#"{"code":-403}"#), .init("", failTransport: true)] {
      let transport = M2Transport([.init(#"{"code":0,"data":{"list":[{"id":2,"title":"A folder","fav_state":1}]}}"#), reply])
      let store = M2Store(token: m2Token)
      let service = BiliService(transport: transport, credentials: store)
      try await service.restoreCookies()
      let model = VideoInteractionModel(service: service, stateLoader: { _, snapshot in
        if snapshot.token?.mid == 456 {
          try await Task.sleep(for: .seconds(60))
        }
        return VideoOperationState(liked: true, following: true, favorited: true)
      })
      model.reset(aid: 789)
      await m2WaitUntil { model.liked == true }
      let foldersLoaded = await model.loadFolders(aid: 789)
      XCTAssertTrue(foldersLoaded); XCTAssertEqual(model.selectedFolderIDs, [2])
      await transport.pause()
      let pending = Task { await model.like(aid: 789) }
      await transport.waitForRequests(2)
      store.saveToken(AppToken(mid: 456, accessToken: "fixture-B", refreshToken: "fixture-B-refresh", expiresAt: 9_999_999_999))
      try await service.restoreCookies()
      await m2WaitUntil { model.identityGeneration > 0 && model.stateLoading }
      XCTAssertNil(model.liked); XCTAssertNil(model.following); XCTAssertNil(model.favorited)
      XCTAssertTrue(model.folders.isEmpty); XCTAssertTrue(model.selectedFolderIDs.isEmpty)
      XCTAssertFalse(model.busy); XCTAssertNil(model.message)
      await transport.release()
      await pending.value
      XCTAssertNil(model.liked); XCTAssertNil(model.message)
      let saved = await model.saveFolders(aid: 789)
      XCTAssertFalse(saved)
      let requests = await transport.requests
      XCTAssertEqual(requests.count, 2, "No stale folder mutation for B")
      XCTAssertEqual(m2Fields(requests[1])["access_key"], "fixture-access")
      model.shutdown()
    }
  }

  @MainActor func testUIIdentityChangeRejectsLateStateSuccessAndFailure() async throws {
    for fail in [false, true] {
      let transport = M2Transport([])
      let store = M2Store(token: m2Token)
      let service = BiliService(transport: transport, credentials: store)
      try await service.restoreCookies()
      let gate = M2OperationStateGate(failOld: fail)
      let model = VideoInteractionModel(service: service, stateLoader: { _, snapshot in try await gate.load(snapshot) })
      model.reset(aid: 789)
      await gate.waitUntilEntered()
      store.saveToken(AppToken(mid: 456, accessToken: "fixture-B", refreshToken: "fixture-B-refresh", expiresAt: 9_999_999_999))
      try await service.restoreCookies()
      await m2WaitUntil { model.identityGeneration > 0 && model.liked == false }
      await gate.release()
      await Task.yield()
      XCTAssertEqual(model.liked, false); XCTAssertEqual(model.following, false)
      XCTAssertNil(model.message); XCTAssertNil(model.stateError); XCTAssertFalse(model.busy)
      model.shutdown()
    }
  }

  @MainActor func testInterruptedInitialStateRestartsAfterFolderOrCoinSuccessAndFailure() async throws {
    for folder in [false, true] {
      for success in [false, true] {
        for oldFailure in [false, true] {
          let reply = success
            ? (folder ? #"{"code":0,"data":{"list":[{"id":2,"title":"A folder","fav_state":1}]}}"# : #"{"code":0}"#)
            : #"{"code":-403}"#
          let transport = M2Transport([.init(reply)])
          let service = try await m2Service(transport)
          let gate = M2InterruptedStateGate(failOld: oldFailure)
          let model = VideoInteractionModel(service: service, stateLoader: { _, _ in try await gate.load() })
          model.reset(aid: 789)
          await gate.waitUntilEntered()
          if folder { let loaded = await model.loadFolders(aid: 789); XCTAssertEqual(loaded, success) }
          else { await model.coin(aid: 789, count: 1, alsoLike: true) }
          await m2WaitUntil { model.following == false && !model.stateLoading }
          XCTAssertEqual(model.liked, !folder && success)
          XCTAssertEqual(model.favorited, folder && success)
          if folder && success { XCTAssertEqual(model.selectedFolderIDs, [2]) }
          let message = model.message
          await gate.releaseOld()
          // Let the deliberately cancellation-ignoring old loader return to MainActor.
          try await Task.sleep(for: .milliseconds(10))
          XCTAssertEqual(model.liked, !folder && success)
          XCTAssertEqual(model.following, false)
          XCTAssertEqual(model.favorited, folder && success)
          XCTAssertEqual(model.message, message); XCTAssertNil(model.stateError)
          let calls = await gate.calls
          XCTAssertEqual(calls, 2)
          model.shutdown()
        }
      }
    }
  }

  @MainActor func testInterruptedInitialStateAfterTriplePreservesNewTrueFlags() async throws {
    let transport = M2Transport([.init(#"{"code":0}"#)])
    let service = try await m2Service(transport)
    let gate = M2InterruptedStateGate()
    let model = VideoInteractionModel(service: service, stateLoader: { _, _ in try await gate.load() })
    model.reset(aid: 789)
    await gate.waitUntilEntered()
    await model.triple(aid: 789)
    await m2WaitUntil { model.following == false && !model.stateLoading }
    XCTAssertEqual(model.liked, true); XCTAssertEqual(model.favorited, true)
    await gate.releaseOld()
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(model.liked, true); XCTAssertEqual(model.favorited, true)
    XCTAssertEqual(model.following, false); XCTAssertNil(model.stateError)
    model.shutdown()
  }

  @MainActor func testSameIdentityCancelledOperationRestartsInterruptedStateWithoutAlert() async throws {
    let transport = M2Transport([.init(#"{"code":0}"#)], paused: true)
    let service = try await m2Service(transport)
    let gate = M2InterruptedStateGate()
    let model = VideoInteractionModel(service: service, stateLoader: { _, _ in try await gate.load() })
    model.reset(aid: 789)
    await gate.waitUntilEntered()
    let pending = Task { await model.coin(aid: 789, count: 1, alsoLike: true) }
    await transport.waitForRequests(1)
    pending.cancel()
    await transport.release()
    await pending.value
    await m2WaitUntil { model.following == false && !model.stateLoading }
    XCTAssertEqual(model.liked, false); XCTAssertNil(model.message); XCTAssertFalse(model.busy)
    await gate.releaseOld()
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(model.liked, false); XCTAssertEqual(model.following, false)
    let calls = await gate.calls
    XCTAssertEqual(calls, 2)
    model.shutdown()
  }

  @MainActor func testShutdownDuringOperationNeverStartsReplacementStateLoad() async throws {
    let transport = M2Transport([.init(#"{"code":0}"#)], paused: true)
    let service = try await m2Service(transport)
    let gate = M2InterruptedStateGate()
    let model = VideoInteractionModel(service: service, stateLoader: { _, _ in try await gate.load() })
    model.reset(aid: 789)
    await gate.waitUntilEntered()
    let pending = Task { await model.triple(aid: 789) }
    await transport.waitForRequests(1)
    model.shutdown()
    await transport.release(); await pending.value
    await gate.releaseOld()
    try await Task.sleep(for: .milliseconds(10))
    let calls = await gate.calls
    XCTAssertEqual(calls, 1)
    XCTAssertNil(model.liked); XCTAssertFalse(model.busy); XCTAssertNil(model.message)
  }

  private func curatedCookies() -> [HTTPCookie] {
    [("SESSDATA", "fixture-session"), ("bili_jct", "fixture-csrf")].map { name, value in
      HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: name, .value: value])!
    }
  }
  private var curatedReply: String {
    #"{"code":0,"data":{"item":[{"id":123,"bvid":"BV1fixture01","title":"Curated","cid":456,"duration":90,"pubdate":1700000000,"owner":{"mid":789,"name":"Owner"},"stat":{"view":120000},"rcmd_reason":{"content":"推荐理由"}},{"id":123,"title":"Duplicate"}]}}"#
  }
  func testCuratedUsesExactSignedCookieParametersWithoutTokenOrRefresh() async throws {
    let transport = M2Transport([.init(curatedReply)])
    let expired = AppToken(mid: 123, accessToken: "expired-fixture", refreshToken: "fixture-refresh", expiresAt: 999)
    let service = BiliService(transport: transport, credentials: M2Store(token: expired, cookies: curatedCookies()), now: { Date(timeIntervalSince1970: 1000) })
    try await service.restoreCookies()
    let expected = await service.authSnapshot()
    let videos = try await service.curatedPlaylist(expectedIdentity: expected)
    XCTAssertEqual(videos.map(\.aid), [123])
    XCTAssertEqual(videos.first?.author, "Owner")
    XCTAssertEqual(videos.first?.publishedAt, 1_700_000_000)
    XCTAssertEqual(videos.first?.recommendationReason, "推荐理由")
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.host, "api.bilibili.com")
    XCTAssertEqual(request.url?.path, "/x/web-interface/index/top/feed/rcmd")
    XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("SESSDATA=fixture-session") == true)
    let fields = ["fresh_idx": "1", "ps": "10", "plat": "1", "feed_version": "CLIENT_SELECTED", "fresh_type": "0", "web_location": "bilibili-electron", "csrf": "fixture-csrf"]
    XCTAssertEqual(request.url?.query, String(decoding: AppForm.authorized(fields, timestamp: 1000), as: UTF8.self))
    XCTAssertNil(m2Fields(request)["access_key"])
  }
  func testCuratedRejectsMissingWebCookieAndOldContextBeforeSend() async throws {
    let transport = M2Transport([])
    let service = try await m2Service(transport)
    let expected = await service.authSnapshot()
    do {
      _ = try await service.curatedPlaylist(expectedIdentity: expected)
      XCTFail("Web cookies are required even with an App token")
    } catch { XCTAssertTrue(error.localizedDescription.contains("网页登录")) }
    let csrfMissing = BiliService(transport: transport, credentials: M2Store(cookies: [curatedCookies()[0]]))
    try await csrfMissing.restoreCookies()
    do {
      _ = try await csrfMissing.curatedPlaylist(expectedIdentity: await csrfMissing.authSnapshot())
      XCTFail("A session without CSRF must also fail before transport")
    } catch { XCTAssertTrue(error.localizedDescription.contains("网页登录")) }
    _ = await service.beginLogin()
    do {
      _ = try await service.curatedPlaylist(expectedIdentity: expected)
      XCTFail("Old context must fail before transport")
    } catch is CancellationError {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testQueueReadsRejectOldExpectedContextBeforeSending() async throws {
    let transport = M2Transport([])
    let service = try await m2Service(transport)
    let expected = await service.authSnapshot()
    _ = await service.beginLogin()
    let video = Video(bvid: "", title: "Queue", cid: 456, aid: 123)
    do { _ = try await service.videoDetails(video, expectedIdentity: expected); XCTFail("Old queued detail context") } catch is CancellationError {}
    do { _ = try await service.playback(video, expectedIdentity: expected); XCTFail("Old queued playback context") } catch is CancellationError {}
    do { _ = try await service.comments(cid: 456, expectedIdentity: expected); XCTFail("Old queued danmaku read context") } catch is CancellationError {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testCuratedRejectsLateAccountResponseAndDoesNotRetryFailures() async throws {
    let transport = M2Transport([.init(curatedReply)], paused: true)
    let service = BiliService(transport: transport, credentials: M2Store(cookies: curatedCookies()))
    try await service.restoreCookies()
    let expected = await service.authSnapshot()
    let pending = Task { try await service.curatedPlaylist(expectedIdentity: expected) }
    await transport.waitForRequests(1)
    try await service.logout()
    await transport.release()
    do { _ = try await pending.value; XCTFail("Late old-account playlist must be rejected") } catch is CancellationError {}
    for reply in [M2Transport.Reply(#"{"code":-403}"#), M2Transport.Reply(#"{"code":0}"#, status: 503)] {
      let transport = M2Transport([reply])
      let service = BiliService(transport: transport, credentials: M2Store(cookies: curatedCookies()))
      try await service.restoreCookies()
      do { _ = try await service.curatedPlaylist(expectedIdentity: await service.authSnapshot()); XCTFail("Failure should propagate") } catch {}
      let requests = await transport.requests
      XCTAssertEqual(requests.count, 1, "Neither API nor HTTP failure retries")
    }
  }

  func testSeasonContentsIsTheOnlySignedCookieRouteAndKeepsRequestedOwner() async throws {
    let cookie = HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: "SESSDATA", .value: "fixture-cookie"])!
    let transport = M2Transport([.init(#"{"code":0,"data":{"marker":1}}"#), .init(#"{"code":0,"data":{"marker":1}}"#)])
    let service = BiliService(transport: transport, credentials: M2Store(token: m2Token, cookies: [cookie]))
    try await service.restoreCookies()
    _ = try await service.m2ReadRoute(.librarySeasonContents)
    _ = try await service.m2ReadRoute(.libraryContents)
    let requests = await transport.requests
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cookie"), "SESSDATA=fixture-cookie")
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(m2Fields(requests[0])["mid"], "999")
    XCTAssertEqual(m2Fields(requests[0])["access_key"], "fixture-access")
    XCTAssertNotNil(m2Fields(requests[0])["sign"])
  }

  func testLibraryClosedRoutesBindIdentityWithoutCookies() async throws {
    let routes: [BiliAppRoute] = [.followGroups, .followGroupUsers, .followers, .libraryGallery,
      .libraryFolders, .libraryContents, .viewLater, .favoriteBangumi, .favoriteCinema]
    let transport = M2Transport(routes.map { route in
      .init(route == .favoriteBangumi || route == .favoriteCinema
        ? #"{"code":0,"result":{"marker":1}}"# : #"{"code":0,"data":{"marker":1}}"#)
    })
    let service = try await m2Service(transport)
    for route in routes {
      XCTAssertTrue(route.requiresToken)
      XCTAssertFalse(route.isMutation)
      let marker = try await service.m2ReadRoute(route)
      XCTAssertEqual(marker, 1)
    }
    let requests = await transport.requests
    XCTAssertEqual(requests.count, routes.count)
    for (route, request) in zip(routes, requests) {
      XCTAssertEqual(request.url?.host, "api.bilibili.com")
      XCTAssertEqual(request.url?.path, URL(string: route.url)?.path)
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      let fields = m2Fields(request)
      XCTAssertEqual(fields["access_key"], "fixture-access")
      XCTAssertNotNil(fields["sign"])
      if route == .followGroupUsers { XCTAssertEqual(fields["mid"], "123") }
      if route == .libraryGallery || route == .libraryFolders { XCTAssertEqual(fields["up_mid"], "123") }
      if route == .followers { XCTAssertEqual(fields["vmid"], "456") }
    }
    let anonymousTransport = M2Transport([])
    let anonymous = try await m2Service(anonymousTransport, token: nil)
    for route in routes {
      do { _ = try await anonymous.m2ReadRoute(route); XCTFail("Anonymous route must reject") }
      catch is AuthFailure {}
    }
    let anonymousRequests = await anonymousTransport.requests
    XCTAssertTrue(anonymousRequests.isEmpty)
  }

  func testVideoDetailIdentityAndPartSelection() {
    let original = Video(bvid: "BV1fixture001", title: "Detail", cid: 11, aid: 100)
    let details = VideoDetails(
      video: original,
      parts: [VideoPart(cid: 11, page: 1, title: "First", duration: 30),
        VideoPart(cid: 22, page: 2, title: "Second", duration: 60)],
      collections: [], tags: [], related: [], stats: VideoStats(),
      uploader: VideoUploader(mid: 1, name: "Fixture"))
    XCTAssertTrue(details.matches(Video(bvid: "", title: "AV-only card", aid: 100)))
    XCTAssertFalse(details.matches(Video(bvid: "", title: "Other AV card", aid: 200)))
    XCTAssertFalse(details.matches(Video(bvid: original.bvid, title: "Conflicting AV", aid: 200)))
    XCTAssertTrue(details.matches(Video(bvid: original.bvid, title: "BV-only card")))
    XCTAssertFalse(details.matches(Video(bvid: "", title: "No identity")))
    let second = details.selectingPart(cid: 22)
    XCTAssertEqual(second.video.cid, 22)
    XCTAssertEqual(second.video.duration, 60)
    XCTAssertEqual(second.video.aid, 100)
    XCTAssertEqual(second.parts, details.parts)
    XCTAssertEqual(details.selectingPart(cid: 99), details)
  }

  func testAppPlaybackUsesExactSDKParametersAndNoCookies() async throws {
    let transport = M2Transport([.init(m2Dash)])
    let service = try await m2Service(transport)
    let manifest = try await service.playback(Video(bvid: "", title: "AV", cid: 456, aid: 789))
    XCTAssertEqual(manifest.video.first?.quality, 64)
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.host, "api.bilibili.com")
    XCTAssertEqual(request.url?.path, "/x/player/playurl")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    let fields = m2Fields(request)
    let expected = [
      "fnver": "0", "cid": "456", "fourk": "1", "fnval": "4048", "qn": "64", "oType": "json",
      "avid": "789", "mid": "123",
    ]
    XCTAssertEqual(
      request.url?.query,
      String(
        decoding: AppForm.authorized(expected, timestamp: 1000, accessKey: "fixture-access"),
        as: UTF8.self))
    XCTAssertEqual(fields["access_key"], "fixture-access")
  }

  func testAnonymousPlaybackKeepsWBIFallbackAndAid() async throws {
    let transport = M2Transport([.init(m2Nav), .init(m2Dash)])
    let service = try await m2Service(transport, token: nil)
    _ = try await service.playback(Video(bvid: "", title: "AV", cid: 456, aid: 789))
    let requests = await transport.requests
    XCTAssertEqual(requests.last?.url?.path, "/x/player/wbi/playurl")
    let fields = m2Fields(try XCTUnwrap(requests.last))
    XCTAssertEqual(fields["avid"], "789")
    XCTAssertNotNil(fields["w_rid"])
    XCTAssertNil(fields["access_key"])
  }

  func testAppRejectionDoesNotFallBackToAnonymousPlayback() async throws {
    let transport = M2Transport([.init(#"{"code":-403}"#)])
    let service = try await m2Service(transport)
    do {
      _ = try await service.playback(Video(bvid: "", title: "AV", cid: 456, aid: 789))
      XCTFail("Expected rejection")
    } catch BiliError.api(let code, _) { XCTAssertEqual(code, -403) }
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }

  func testExpiredAppTokenRefreshBindsNewTokenAndMid() async throws {
    let refresh =
      #"{"code":0,"data":{"mid":123,"access_token":"fixture-refreshed","refresh_token":"fixture-next","expires_in":3600}}"#
    let transport = M2Transport([.init(refresh), .init(m2Dash)])
    let expired = AppToken(
      mid: 123, accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: 10)
    let service = try await m2Service(transport, token: expired)
    _ = try await service.playback(Video(bvid: "", title: "AV", cid: 456, aid: 789))
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].url?.path, "/api/oauth2/refreshToken")
    XCTAssertEqual(m2Fields(requests[1])["access_key"], "fixture-refreshed")
    XCTAssertEqual(m2Fields(requests[1])["mid"], "123")
  }

  func testEveryMutationUsesExactSDKRouteFieldsAndSignature() async throws {
    let transport = M2Transport(Array(repeating: .init(#"{"code":0}"#), count: 8))
    let service = try await m2Service(transport)
    try await service.setVideoLiked(aid: 789, liked: true)
    try await service.setVideoLiked(aid: 789, liked: false)
    try await service.coinVideo(aid: 789, count: 2, alsoLike: true)
    try await service.coinVideo(aid: 789, count: 1, alsoLike: false)
    try await service.tripleVideo(aid: 789)
    try await service.updateVideoFavorite(aid: 789, add: [22, 11, 22], remove: [33])
    try await service.setFollowing(mid: 456, following: true)
    try await service.setFollowing(mid: 456, following: false)
    let requests = await transport.requests
    let paths = [
      "/x/v2/view/like", "/x/v2/view/like", "/x/v2/view/coin/add", "/x/v2/view/coin/add",
      "/x/v2/view/like/triple", "/x/v3/fav/resource/batch-deal", "/x/relation/modify",
      "/x/relation/modify",
    ]
    let values = [
      ["aid": "789", "like": "0"], ["aid": "789", "like": "1"],
      ["aid": "789", "multiply": "2", "select_like": "1"], ["aid": "789", "multiply": "1"],
      ["aid": "789"], ["resources": "789:2", "add_media_ids": "11,22", "del_media_ids": "33"],
      ["fid": "456", "act": "1"], ["fid": "456", "act": "2"],
    ]
    for (index, request) in requests.enumerated() {
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.url?.path, paths[index])
      XCTAssertEqual(request.url?.host, index < 5 ? "app.bilibili.com" : "api.bilibili.com")
      XCTAssertEqual(
        request.httpBody,
        AppForm.authorized(values[index], timestamp: 1000, accessKey: "fixture-access"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
  }

  func testWatchProgressUsesSDKHistoryReportFields() async throws {
    let transport = M2Transport(Array(repeating: .init(#"{"code":0}"#), count: 2))
    let service = try await m2Service(transport)
    try await service.reportProgress(aid: 789, cid: 456, seconds: 61)
    try await service.reportProgress(aid: 789, cid: 456, seconds: 1300, episode: (id: 3001, season: 42))
    let requests = await transport.requests
    XCTAssertEqual(requests.map(\.url?.path), ["/x/v2/history/report", "/x/v2/history/report"])
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.host == "api.bilibili.com" })
    XCTAssertEqual(requests[0].httpBody, AppForm.authorized(
      ["aid": "789", "cid": "456", "progress": "61", "type": "3"], timestamp: 1000, accessKey: "fixture-access"))
    XCTAssertEqual(requests[1].httpBody, AppForm.authorized(
      ["aid": "789", "cid": "456", "progress": "1300", "type": "4", "epid": "3001", "sid": "42", "sub_type": "1"],
      timestamp: 1000, accessKey: "fixture-access"))
  }

  func testFavoriteFoldersUseAuthenticatedMid() async throws {
    let transport = M2Transport([
      .init(
        #"{"code":0,"data":{"list":[{"id":1,"title":"A","fav_state":1},{"id":2,"title":"B","fav_state":0}]}}"#
      )
    ])
    let service = try await m2Service(transport)
    let folders = try await service.favoriteFolders(aid: 789)
    XCTAssertEqual(folders.map(\.containsVideo), [true, false])
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.path, "/x/v3/fav/folder/created/list-all")
    XCTAssertEqual(m2Fields(request)["up_mid"], "123")
    XCTAssertEqual(m2Fields(request)["rid"], "789")
    XCTAssertEqual(m2Fields(request)["type"], "2")
  }

  func testMutationsRequireAppTokenAndValidateInputBeforeNetwork() async throws {
    let transport = M2Transport([])
    let service = try await m2Service(transport, token: nil)
    for action in 0..<6 {
      do {
        switch action {
        case 0: try await service.setVideoLiked(aid: 1, liked: true)
        case 1: try await service.coinVideo(aid: 1, count: 1, alsoLike: false)
        case 2: try await service.tripleVideo(aid: 1)
        case 3: try await service.updateVideoFavorite(aid: 1, add: [2], remove: [])
        case 4: try await service.setFollowing(mid: 2, following: true)
        default: _ = try await service.favoriteFolders(aid: 1)
        }
        XCTFail("Expected authentication failure")
      } catch AuthFailure.needsLogin {}
    }
    do {
      try await service.coinVideo(aid: 1, count: 3, alsoLike: false)
      XCTFail("Invalid coin count")
    } catch BiliError.invalidResponse {}
    do {
      try await service.updateVideoFavorite(aid: 1, add: [2], remove: [2])
      XCTFail("Overlapping folders")
    } catch BiliError.invalidResponse {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testMutationHTTPAPIAndMalformedResponsesAreFailures() async throws {
    for reply in [
      M2Transport.Reply(#"{"code":-400}"#), .init(#"{"code":0}"#, status: 503),
      .init(#"{"data":{}}"#),
    ] {
      let transport = M2Transport([reply])
      let service = try await m2Service(transport)
      do {
        try await service.tripleVideo(aid: 1)
        XCTFail("Must not report success")
      } catch is BiliError {}
      let requests = await transport.requests
      XCTAssertEqual(requests.count, 1, "Mutations must never retry")
    }
  }

  func testIdentityChangeDiscardsLatePlaybackAndMutationSuccessOrFailure() async throws {
    for mutation in [false, true] {
      for reply in [
        M2Transport.Reply(mutation ? #"{"code":0}"# : m2Dash),
        .init(#"{"code":-403}"#), .init("", failTransport: true),
      ] {
        let transport = M2Transport([reply], paused: true)
        let service = try await m2Service(transport)
        let epoch = await service.beginLogin()
        let task = Task {
          if mutation {
            try await service.tripleVideo(aid: 789)
          } else {
            _ = try await service.playback(Video(bvid: "", title: "AV", cid: 456, aid: 789))
          }
        }
        await transport.waitForRequests(1)
        _ = try await service.synchronizeCookies([], token: epoch)
        await transport.release()
        do {
          try await task.value
          XCTFail("Old identity must be discarded")
        } catch is CancellationError {}
      }
    }
  }

  func testCancelledMutationCannotReportLateSuccess() async throws {
    let transport = M2Transport([.init(#"{"code":0}"#)], paused: true)
    let service = try await m2Service(transport)
    let task = Task { try await service.tripleVideo(aid: 789) }
    await transport.waitForRequests(1)
    task.cancel()
    await transport.release()
    do {
      try await task.value
      XCTFail("Cancelled mutation must not report success")
    } catch is CancellationError {}
  }

  func testLogoutRejectsLatePlaybackError() async throws {
    let transport = M2Transport([.init("", failTransport: true)], paused: true)
    let service = try await m2Service(transport)
    let task = Task { try await service.playback(Video(bvid: "", title: "AV", cid: 456, aid: 789)) }
    await transport.waitForRequests(1)
    try await service.logout()
    await transport.release()
    do {
      _ = try await task.value
      XCTFail("Logged out response must be discarded")
    } catch is CancellationError {}
  }

  func testRefreshRejectedOrIdentityReplacedNeverSendsPlayback() async throws {
    for replace in [false, true] {
      let reply =
        replace
        ? #"{"code":0,"data":{"mid":123,"access_token":"fixture-refreshed","refresh_token":"fixture-next","expires_in":3600}}"#
        : #"{"code":-101}"#
      let transport = M2Transport([.init(reply)], paused: replace)
      let expired = AppToken(
        mid: 123, accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: 10)
      let service = try await m2Service(transport, token: expired)
      let epoch = await service.beginLogin()
      let task = Task {
        try await service.playback(Video(bvid: "", title: "AV", cid: 456, aid: 789))
      }
      if replace {
        await transport.waitForRequests(1)
        _ = try await service.synchronizeCookies([], token: epoch)
        await transport.release()
      }
      do {
        _ = try await task.value
        XCTFail("Refresh failure must not become anonymous playback")
      } catch is CancellationError {}
      let requests = await transport.requests
      XCTAssertEqual(requests.count, 1)
      XCTAssertEqual(requests.first?.url?.path, "/api/oauth2/refreshToken")
    }
  }

  func testRecommendPreservesRawCursorAndAVIdentifiers() async throws {
    let reply =
      #"{"code":0,"data":{"items":[{"card_goto":"av","idx":40,"title":"AV only","cover":"https://i.example/c.jpg","args":{"aid":123,"up_id":456,"up_name":"Owner"},"player_args":{"cid":789,"duration":60}},{"card_goto":"ad","idx":99}]}}"#
    let transport = M2Transport([.init(reply), .init(#"{"code":0,"data":{"items":[]}}"#)])
    let service = try await m2Service(transport, token: nil)
    let page = try await service.recommend()
    XCTAssertEqual(page.items.count, 1)
    XCTAssertEqual(page.items[0].id, "av123")
    XCTAssertEqual(page.items[0].bvid, "")
    XCTAssertEqual(page.items[0].authorID, 456)
    XCTAssertEqual(page.items[0].cid, 789)
    XCTAssertEqual(page.nextCursor, "99")
    _ = try await service.recommend(cursor: page.nextCursor)
    let requests = await transport.requests
    XCTAssertEqual(m2Fields(requests[0])["pull"], "true")
    XCTAssertEqual(m2Fields(requests[0])["column"], "4")
    XCTAssertEqual(m2Fields(requests[1])["idx"], "99")
    XCTAssertEqual(m2Fields(requests[1])["pull"], "false")
    XCTAssertNil(m2Fields(requests[0])["access_key"])
  }

  func testRecommendParsesLiveAppCardShapeWithoutInventingPublicationTime() async throws {
    // Minimal anonymized shape from /x/v2/feed/index (small_cover_v2), not Web stat data.
    let reply = #"{"code":0,"data":{"items":[{"card_type":"small_cover_v2","card_goto":"av","idx":1791899905,"param":"123","cover":"http://i.example/c.jpg","title":"App recommendation","args":{"aid":123,"up_id":456,"up_name":"Fixture creator"},"player_args":{"aid":123,"cid":789,"type":"av","duration":2831},"cover_left_text_1":"14.2万","cover_left_icon_1":1,"cover_left_text_2":"786","cover_left_icon_2":3,"cover_right_text":"47:11","desc_button":{"text":"Fixture creator","uri":"bilibili://space/456","event":"nickname","type":1}}]}}"#
    let transport = M2Transport([.init(reply)])
    let page = try await m2Service(transport, token: nil).recommend()
    let video = try XCTUnwrap(page.items.first)
    XCTAssertEqual(video.id, "av123")
    XCTAssertEqual(video.author, "Fixture creator")
    XCTAssertEqual(video.authorID, 456)
    XCTAssertEqual(video.cid, 789)
    XCTAssertEqual(video.duration, 2831)
    XCTAssertEqual(video.views, 142_000)
    XCTAssertEqual(video.viewsText, "14.2万")
    XCTAssertEqual(video.cover?.absoluteString, "http://i.example/c.jpg")
    XCTAssertNil(video.publishedAt)
    XCTAssertNil(video.subtitle)
    XCTAssertNil(video.recommendationReason)
    XCTAssertEqual(page.nextCursor, "1791899905")
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.path, "/x/v2/feed/index")
    let fields = m2Fields(request)
    XCTAssertEqual(fields["idx"], "0")
    XCTAssertEqual(fields["flush"], "5")
    XCTAssertEqual(fields["device"], "desktop")
    XCTAssertEqual(fields["mobi_app"], "iphone")
    XCTAssertEqual(fields["platform"], "ios")
    XCTAssertEqual(fields["build"], "80200100")
    XCTAssertNil(fields["access_key"])
  }

  func testAppCardCountUnitsAndNumericPartitionFallback() throws {
    for (label, expected) in [("786", 786), ("14.2万", 142_000), ("1.2亿", 120_000_000), ("0", 0)] {
      let video = try BiliService.appVideo([
        "param": "123", "title": "A", "cover_left_text_1": label,
        "cover_left_text_2": "99999",
      ])
      XCTAssertEqual(video.views, expected)
      XCTAssertEqual(video.viewsText, label)
    }
    for label in ["", "invalid", "NaN", "inf", "1e100", "-1"] {
      let video = try BiliService.appVideo([
        "param": "123", "title": "A", "cover_left_text_1": label, "play": "1234",
      ])
      XCTAssertEqual(video.views, 1234)
    }
    let partition = try BiliService.appVideo(["param": "123", "title": "A", "play": 5678])
    XCTAssertEqual(partition.views, 5678)
    XCTAssertNil(partition.viewsText)
  }

  func testPartitionFeedsDeduplicateAndChooseOffsetAndSortRoutes() async throws {
    let raw =
      #"{"code":0,"data":{"new":[{"goto":"av","param":"123","title":"A"}],"recommend":[{"goto":"av","param":"123","title":"A"},{"goto":"av","param":"124","title":"B"}],"cbottom":900}}"#
    let sorted = #"{"code":0,"data":[{"goto":"av","param":"123","title":"A"}]}"#
    let transport = M2Transport([.init(raw), .init(raw), .init(raw), .init(raw), .init(sorted)])
    let service = try await m2Service(transport, token: nil)
    let page = try await service.partitionFeed(rid: 1, child: false, order: .recommended)
    XCTAssertEqual(page.items.map(\.aid), [123, 124])
    XCTAssertEqual(page.nextCursor, "900")
    let repeated = try await service.partitionFeed(
      rid: 1, child: false, order: .recommended, cursor: "900")
    XCTAssertNil(repeated.nextCursor)
    _ = try await service.partitionFeed(rid: 24, child: true, order: .recommended)
    _ = try await service.partitionFeed(rid: 24, child: true, order: .recommended, cursor: "900")
    let last = try await service.partitionFeed(rid: 24, child: true, order: .newest, cursor: "2")
    XCTAssertNil(last.nextCursor)
    let requests = await transport.requests
    XCTAssertEqual(
      requests.map { $0.url!.path },
      [
        "/x/v2/region/dynamic", "/x/v2/region/dynamic/list", "/x/v2/region/dynamic/child",
        "/x/v2/region/dynamic/child/list", "/x/v2/region/show/child/list",
      ])
    XCTAssertEqual(m2Fields(requests[1])["ctime"], "900")
    XCTAssertEqual(m2Fields(requests[4])["pn"], "2")
    XCTAssertEqual(m2Fields(requests[4])["ps"], "30")
    XCTAssertEqual(m2Fields(requests[4])["order"], "senddate")
  }

  func testSortedChildPartitionStartsAtZeroThenAdvancesByOne() async throws {
    let items: [[String: Any]] = (0..<30).map { ["goto": "av", "param": String(123 + $0), "title": "Video \($0)"] }
    let full = String(decoding: try JSONSerialization.data(withJSONObject: ["code": 0, "data": items]), as: UTF8.self)
    let transport = M2Transport([.init(full), .init(full), .init(#"{"code":0,"data":[]}"#)])
    let service = try await m2Service(transport, token: nil)
    let first = try await service.partitionFeed(rid: 24, child: true, order: .newest)
    XCTAssertEqual(first.items.count, 30)
    XCTAssertEqual(first.nextCursor, "1")
    let second = try await service.partitionFeed(rid: 24, child: true, order: .newest, cursor: first.nextCursor)
    XCTAssertEqual(second.nextCursor, "2")
    let last = try await service.partitionFeed(rid: 24, child: true, order: .newest, cursor: second.nextCursor)
    XCTAssertNil(last.nextCursor)
    let requests = await transport.requests
    XCTAssertEqual(requests.map { m2Fields($0)["pn"] }, ["0", "1", "2"])
    XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/x/v2/region/show/child/list" })
    XCTAssertTrue(requests.allSatisfy { m2Fields($0)["order"] == "senddate" })
  }

  #if DEBUG
  func testRPCBrowseSourceUsesInjectedNativeFeedAndRawCursorMetadata() async throws {
    let http = M2Transport([])
    let auth = try await m2Service(http, token: nil)
    let transport = M2BrowseRPCTransport()
    let rpc = NativeBiliRPCService(auth: auth, transport: transport, installationID: "fixture-browse")
    let source = RPCBrowseSource(rpc: rpc)
    let first = try await source.popularFeed()
    XCTAssertEqual(first.items.count, 12)
    XCTAssertEqual(first.nextCursor, "99")
    XCTAssertEqual(first.items.first?.author, "本地样本")
    XCTAssertEqual(first.items.first?.views, 120_000)
    XCTAssertEqual(first.items.first?.subtitle, "8小时前")
    XCTAssertEqual(first.items.first?.recommendationReason, "很多人点赞")
    let second = try await source.popularFeed(cursor: first.nextCursor)
    XCTAssertEqual(second.nextCursor, "199")
    XCTAssertTrue(Set(first.items.map(\.id)).isDisjoint(with: Set(second.items.map(\.id))))
    let last = try await source.popularFeed(cursor: second.nextCursor)
    XCTAssertTrue(last.items.isEmpty)
    XCTAssertNil(last.nextCursor)
    let rank = try await source.rankingFeed(region: 24)
    XCTAssertEqual(rank.items.count, 18)
    XCTAssertNil(rank.nextCursor)
    XCTAssertEqual(rank.items.first?.publishedAt, 1_700_000_000)
    let indexes = await transport.popularIndexes
    let regions = await transport.rankRegions
    let headers = await transport.authorization
    let requests = await http.requests
    XCTAssertEqual(indexes, [0, 99, 199])
    XCTAssertEqual(regions, [24])
    XCTAssertTrue(headers.isEmpty)
    XCTAssertTrue(requests.isEmpty, "No Web fallback or credential refresh for anonymous browse")
    await rpc.shutdown()
  }

  func testRPCBrowseSourceStopsRepeatedRawCursor() async throws {
    let auth = try await m2Service(M2Transport([]), token: nil)
    let transport = M2BrowseRPCTransport(repeatCursor: true)
    let rpc = NativeBiliRPCService(auth: auth, transport: transport, installationID: "fixture-browse")
    let page = try await RPCBrowseSource(rpc: rpc).popularFeed(cursor: "99")
    XCTAssertTrue(page.items.isEmpty)
    XCTAssertNil(page.nextCursor)
    await rpc.shutdown()
  }
  #endif

  func testPartitionIndexExcludesNonVideoSections() async throws {
    let transport = M2Transport([
      .init(
        #"{"code":0,"data":[{"tid":1,"name":"动画","uri":"bilibili://region/1","children":[{"tid":24,"name":"MAD"}]},{"tid":9,"name":"广告","uri":"https://ad.example"}]}"#
      )
    ])
    let service = try await m2Service(transport, token: nil)
    let partitions = try await service.videoPartitions()
    XCTAssertEqual(partitions.map(\.id), [1])
    XCTAssertEqual(partitions.first?.children.first?.id, 24)
  }

  func testDetailParsesPartsCollectionsStatsAndOptionalAvailability() throws {
    let payload = try m2Object(
      #"{"View":{"aid":123,"bvid":"BVfixture","title":"Video","cid":789,"owner":{"mid":456,"name":"Owner"},"stat":{"view":100,"like":8},"pages":[{"cid":789,"page":1,"part":"Part 1","duration":60}],"ugc_season":{"sections":[{"id":9,"title":"Season","episodes":[{"aid":124,"cid":790,"title":"Next","arc":{"duration":20}}]}]}},"Card":{"card":{"name":"Owner detail","fans":42}},"Tags":[{"tag_name":"Tag"}],"Related":[{"aid":125,"title":"Related"}]}"#
    )
    let details = try VideoDetails.parse(payload)
    XCTAssertEqual(details.parts.first?.cid, 789)
    XCTAssertEqual(details.collections.first?.episodes.first?.aid, 124)
    XCTAssertEqual(details.stats.like, 8)
    XCTAssertEqual(details.uploader.followers, 42)
    XCTAssertEqual(details.tags, ["Tag"])
    XCTAssertTrue(details.tagsAvailable)
    var missing = payload
    missing.removeValue(forKey: "Tags")
    missing.removeValue(forKey: "Related")
    let partial = try VideoDetails.parse(missing)
    XCTAssertFalse(partial.tagsAvailable)
    XCTAssertFalse(partial.relatedAvailable)
    XCTAssertThrowsError(try VideoDetails.parse([:]))
    XCTAssertThrowsError(try VideoDetails.parse(["View": ["aid": 123, "title": "bad"]]))
  }

  func testDetailForAidDoesNotResolveBvidPerCard() async throws {
    let reply =
      #"{"code":0,"data":{"view":{"aid":123,"title":"Video","cid":789,"owner":{"mid":456,"name":"Owner"},"stat":{},"pages":[{"cid":789,"page":1,"part":"Part","duration":1}]}}}"#
    let transport = M2Transport([.init(m2Nav), .init(reply)])
    let service = try await m2Service(transport, token: nil)
    _ = try await service.videoDetails(Video(bvid: "", title: "Video", aid: 123))
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].url?.path, "/x/web-interface/wbi/view/detail", "the unsigned path answers HTTP 412 under risk control")
    XCTAssertEqual(m2Fields(requests[1])["aid"], "123")
    XCTAssertNotNil(m2Fields(requests[1])["w_rid"])
  }

  func testManifestPreservesMediaMetadataAndHardwareSelection() throws {
    let object = try m2Object(
      #"{"support_formats":[{"quality":80,"new_description":"1080P","format":"dash"}],"dash":{"duration":30,"video":[{"id":80,"codecs":"hev1","codecid":12,"base_url":"https://v.mcdn.bilivideo.cn/v","backup_url":["https://cdn.example/v","javascript:bad"],"bandwidth":300,"mime_type":"video/mp4","width":1920,"height":1080,"frame_rate":"60","segment_base":{"initialization":"0-100","index_range":"101-200"}},{"id":80,"codecs":"avc1","baseUrl":"https://cdn.example/h264","bandwidth":400},{"id":64,"codecs":"avc1","baseUrl":"https://cdn.example/720","bandwidth":200},{"id":80,"codecs":"av01","baseUrl":"https://cdn.example/av1","bandwidth":100}],"audio":[{"id":30216,"codecs":"mp4a","base_url":"https://cdn.example/a1","bandwidth":60},{"id":30280,"codecs":"mp4a","base_url":"https://cdn.example/a2","bandwidth":50}]}}"#
    )
    let manifest = try PlaybackManifest.parse(object)
    let hevc = try XCTUnwrap(manifest.video.first(where: { $0.codecID == 12 }))
    XCTAssertEqual(hevc.backupURLs.count, 1)
    XCTAssertEqual(hevc.width, 1920)
    XCTAssertEqual(hevc.mimeType, "video/mp4")
    XCTAssertEqual(hevc.frameRate, "60")
    XCTAssertEqual(hevc.segmentBase?.indexRange, "101-200")
    XCTAssertEqual(manifest.formats.first?.description, "1080P")
    let baseline = try PlaybackSelector.select(manifest)
    XCTAssertEqual(baseline.video.codec, "avc1")
    XCTAssertEqual(baseline.audio.quality, 30280)
    let fallback = try PlaybackSelector.select(manifest, preferences: .init(codec: .av1))
    XCTAssertEqual(fallback.video.codec, "avc1")
    let hardware = try PlaybackSelector.select(
      manifest, preferences: .init(codec: .hevc, avoidP2P: true), supportsHardware: { _ in true })
    XCTAssertEqual(hardware.video.codec, "hev1")
    XCTAssertEqual(hardware.videoURL.host, "cdn.example")
    let previous = try PlaybackSelector.select(manifest, preferences: .init(lastQuality: 64))
    XCTAssertEqual(previous.video.quality, 64)
    let explicit = try PlaybackSelector.select(
      manifest, preferences: .init(quality: 80, lastQuality: 64))
    XCTAssertEqual(explicit.video.quality, 80)
    XCTAssertFalse(PlaybackSelector.isP2P(URL(string: "https://mcdn.bilivideo.cn.evil.example/v")!))
  }

  func testWatchProgressIsBoundToTheCheckedAccount() async throws {
    // F7: signed out, nothing is sent.
    let idle = M2Transport([])
    let signedOut = try await m2Service(idle, token: nil)
    let sentSignedOut = try await signedOut.reportProgressForCurrentAccount(aid: 789, cid: 456, seconds: 61)
    XCTAssertFalse(sentSignedOut)
    let idleRequests = await idle.requests
    XCTAssertTrue(idleRequests.isEmpty)

    let transport = M2Transport([.init(#"{"code":0}"#), .init(#"{"code":0}"#)])
    let service = try await m2Service(transport)
    let sent = try await service.reportProgressForCurrentAccount(aid: 789, cid: 456, seconds: 61)
    XCTAssertTrue(sent)
    // A report checked against one identity is dropped once the identity changed.
    let checked = await service.authSnapshot()
    _ = await service.beginLogin()
    do {
      try await service.reportProgress(aid: 789, cid: 456, seconds: 62, expectedIdentity: checked)
      XCTFail("a stale identity must not write progress")
    } catch {}
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.httpBody, AppForm.authorized(
      ["aid": "789", "cid": "456", "progress": "61", "type": "3"], timestamp: 1000, accessKey: "fixture-access"))
  }
}
