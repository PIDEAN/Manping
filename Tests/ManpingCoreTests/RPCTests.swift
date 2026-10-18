import BiliProtocol
import Foundation
import GRPCCore
import SwiftProtobuf
import XCTest

@testable import ManpingCore

private final class RPCCredentialStore: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  init(_ token: AppToken? = nil) { self.token = token }
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { lock.withLock { token } }
  func saveToken(_ token: AppToken?) { lock.withLock { self.token = token } }
  func clear() { lock.withLock { token = nil } }
}
private final class RPCEventCredentialStore: AuthCredentialStore, @unchecked Sendable {
  enum Point { case load, saveCookies, clearToken, clear }
  enum Failure: Error { case rejected }
  private let condition = NSCondition()
  private var token: AppToken?
  private var armed: Point?
  private var entered = false
  private var released = false
  var rejectClearToken = false
  var rejectClear = false
  init(_ token: AppToken?) { self.token = token }
  func arm(_ point: Point) {
    condition.withLock {
      armed = point
      entered = false
      released = false
    }
  }
  var gateEntered: Bool { condition.withLock { entered } }
  func release() {
    condition.withLock {
      released = true
      condition.broadcast()
    }
  }
  private func gate(_ point: Point) {
    condition.lock()
    defer { condition.unlock() }
    guard armed == point else { return }
    armed = nil
    entered = true
    while !released {
      // Bound the fixture even if a failing assertion prevents release.
      if !condition.wait(until: Date().addingTimeInterval(5)) { return }
    }
  }
  func load() -> [HTTPCookie] {
    gate(.load)
    return []
  }
  func save(_ cookies: [HTTPCookie]) { gate(.saveCookies) }
  func loadToken() -> AppToken? { condition.withLock { token } }
  func saveToken(_ token: AppToken?) throws {
    if token == nil {
      gate(.clearToken)
      if rejectClearToken { throw Failure.rejected }
    }
    condition.withLock { self.token = token }
  }
  func clear() throws {
    gate(.clear)
    if rejectClear { throw Failure.rejected }
    condition.withLock { token = nil }
  }
}
private actor RPCNoAuthHTTP: AuthTransport {
  var count = 0
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    count += 1
    // Failed refresh cannot send its previous token to gRPC.
    throw URLError(.cannotConnectToHost)
  }
}
private final class RPCTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1000)
  func now() -> Date { lock.withLock { date } }
  func advance() { lock.withLock { date = Date(timeIntervalSince1970: 2000) } }
}
private actor RPCRejectedRefreshHTTP: AuthTransport {
  var calls = 0
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    calls += 1
    await withCheckedContinuation { releaseContinuation = $0 }
    return AuthHTTPResponse(
      body: Data(#"{"code":-101}"#.utf8),
      response: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
private actor RPCTokenHTTP: AuthTransport {
  var count = 0
  var paused: Bool
  let mismatchedCookies: Bool
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  init(paused: Bool = false, mismatchedCookies: Bool = false) {
    self.paused = paused
    self.mismatchedCookies = mismatchedCookies
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    count += 1
    if paused { await withCheckedContinuation { releaseContinuation = $0 } }
    let tokenJSON =
      mismatchedCookies
      ? #"{"code":0,"data":{"mid":42,"access_token":"fixture-new-access","refresh_token":"fixture-new-refresh","expires_in":3600,"cookie_info":{"cookies":[{"name":"DedeUserID","value":"84"}]}}}"#
      : #"{"code":0,"data":{"mid":42,"access_token":"fixture-new-access","refresh_token":"fixture-new-refresh","expires_in":3600}}"#
    let json =
      request.url!.path.hasSuffix("auth_code")
      ? #"{"code":0,"data":{"auth_code":"fixture-qr","url":"https://example.invalid/qr"}}"#
      : tokenJSON
    return AuthHTTPResponse(
      body: Data(json.utf8),
      response: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
    paused = false
  }
}
private actor RPCFixtureTransport: BiliRPCTransport {
  struct Call: Sendable {
    let path: String
    let body: Data
    let metadata: Metadata
  }
  var calls: [Call] = []
  let replies: [String: Data]
  var paused = false
  var cancels = 0
  var stopped = false
  var error: RPCError?
  private var releases: [CheckedContinuation<Void, Never>] = []
  init(_ replies: [String: Data]) { self.replies = replies }
  func setPaused(_ paused: Bool) { self.paused = paused }
  func setError(_ error: RPCError) { self.error = error }
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    guard !stopped else { throw BiliRPCError.shutdown }
    calls.append(
      Call(
        path: descriptor.fullyQualifiedMethod, body: try request.serializedData(),
        metadata: metadata))
    if paused {
      // Deliberately uncooperative peer fixture: return a late response after cancellation.
      await withTaskCancellationHandler {
        await withCheckedContinuation { releases.append($0) }
      } onCancel: {
        Task { await self.recordCancel() }
      }
    }
    if let error { throw error }
    return try Response(serializedBytes: replies[descriptor.fullyQualifiedMethod] ?? Data())
  }
  func recordCancel() { cancels += 1 }
  func release() {
    let pending = releases
    releases.removeAll()
    for continuation in pending { continuation.resume() }
  }
  func shutdown(grace: Duration) {
    stopped = true
    release()
  }
}

final class RPCTests: XCTestCase, @unchecked Sendable {
  private func nextEvent(_ stream: AsyncStream<AuthIdentityEvent>) async -> Task<
    AuthIdentityEvent?, Never
  > {
    let waiter = Task {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    Task {
      try? await Task.sleep(for: .seconds(2))
      waiter.cancel()
    }
    // Allow next() to suspend before a synchronous actor operation publishes anything.
    try? await Task.sleep(for: .milliseconds(20))
    return waiter
  }
  private func releaseGate(_ store: RPCEventCredentialStore) async throws {
    for _ in 0..<200 {
      if store.gateEntered {
        // An already waiting observer can receive an intermediate event while the mutation blocks.
        for _ in 0..<10 { await Task.yield() }
        store.release()
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    store.release()
    XCTFail("Credential fixture did not enter its gate")
    throw BiliRPCError.deadlineExceeded
  }
  private func data(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "RPC"))
    return try Data(contentsOf: url)
  }
  private func auth(token: AppToken? = nil) async throws -> BiliService {
    let auth = BiliService(transport: RPCNoAuthHTTP(), credentials: RPCCredentialStore(token))
    try await auth.restoreCookies()
    return auth
  }
  private var fakeToken: AppToken {
    AppToken(
      mid: 42, accessToken: "fixture-access", refreshToken: "fixture-refresh",
      expiresAt: 4_000_000_000)
  }
  private func service(_ fixture: RPCFixtureTransport, auth: BiliService) -> NativeBiliRPCService {
    NativeBiliRPCService(
      auth: auth, transport: fixture, installationID: "fixture-installation",
      timeZone: TimeZone(secondsFromGMT: 9 * 3600)!)
  }
  private func waitFor(_ transport: RPCFixtureTransport, calls: Int, cancels: Int = 0) async throws
  {
    for _ in 0..<200 {
      if await transport.calls.count >= calls, await transport.cancels >= cancels { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Fixture did not reach expected calls/cancellations")
    throw BiliRPCError.deadlineExceeded
  }
  func testExactMetadataGoldenAndAnonymousNoOldToken() throws {
    let builder = BiliRPCMetadata(installationID: "fixture-installation")
    let snapshot = AuthSnapshot(
      epoch: 1, identityRevision: 2, state: .appAuthorized, token: fakeToken)
    let headers = try builder.build(snapshot, timestamp: 1_700_000_000)
    XCTAssertEqual(Array(headers[stringValues: "authorization"]), ["identify_v1 fixture-access"])
    XCTAssertEqual(Array(headers[stringValues: "x-bili-mid"]), ["42"])
    XCTAssertEqual(
      try XCTUnwrap(Array(headers[binaryValues: "x-bili-metadata-bin"]).first).count,
      try data("metadata").count)
    XCTAssertEqual(
      Data(try XCTUnwrap(Array(headers[binaryValues: "x-bili-metadata-bin"]).first)),
      try data("metadata"))
    let device = try Bilibili_Metadata_Device_Device(
      serializedBytes: XCTUnwrap(Array(headers[binaryValues: "x-bili-device-bin"]).first))
    XCTAssertEqual(device.build, 6_070_600)
    XCTAssertEqual(device.appID, 1)
    XCTAssertEqual(device.model, "iPhone 14 Pro")
    XCTAssertEqual(device.platform, "iphone")
    let locale = try Bilibili_Metadata_Locale_Locale(
      serializedBytes: XCTUnwrap(Array(headers[binaryValues: "x-bili-locale-bin"]).first))
    XCTAssertEqual(locale.cLocale.language, "zh")
    XCTAssertEqual(locale.sLocale.region, "CN")
    let network = try Bilibili_Metadata_Network_Network(
      serializedBytes: XCTUnwrap(Array(headers[binaryValues: "x-bili-network-bin"]).first))
    XCTAssertEqual(network.type, .wifi)
    XCTAssertEqual(network.oid, "46007")
    XCTAssertEqual(Array(headers[binaryValues: "x-bili-restriction-bin"]), [[]])
    let anonymous = try builder.build(
      AuthSnapshot(epoch: 3, identityRevision: 4, state: .webOnly, token: fakeToken))
    XCTAssertTrue(Array(anonymous[stringValues: "authorization"]).isEmpty)
    let anonMetadata = try Bilibili_Metadata_Metadata(
      serializedBytes: XCTUnwrap(Array(anonymous[binaryValues: "x-bili-metadata-bin"]).first))
    XCTAssertEqual(anonMetadata.accessKey, "")
    XCTAssertEqual(Array(anonymous[stringValues: "x-bili-aurora-eid"]), [""])
    XCTAssertTrue(Array(headers[stringValues: "grpc-timeout"]).isEmpty)
    XCTAssertTrue(Array(headers[stringValues: "transfer-encoding"]).isEmpty)
  }
  func testCommentFixturesAndActualRequestFields() async throws {
    let fixture = RPCFixtureTransport([
      BiliRPCMethod.mainList.rawValue: try data("comments"),
      BiliRPCMethod.detailList.rawValue: try data("details"),
    ])
    let rpc = service(fixture, auth: try await auth())
    let main = try await rpc.comments(oid: 123, sort: .hot, next: 99)
    XCTAssertEqual(main.next, 500)
    XCTAssertFalse(main.isEnd)
    XCTAssertEqual(main.comments.count, 1)
    XCTAssertEqual(main.comments[0].replies[0].root, 101)
    XCTAssertEqual(main.comments[0].emotes[0].text, "[smile]")
    XCTAssertTrue(main.comments[0].liked)
    XCTAssertTrue(try XCTUnwrap(main.pinned).pinned)
    let detail = try await rpc.commentDetails(oid: 123, root: 101, sort: .time, next: 100)
    XCTAssertEqual(detail.comments[0].id, 102)
    XCTAssertEqual(detail.pinned?.id, 101)
    XCTAssertEqual(detail.next, 501)
    XCTAssertTrue(detail.isEnd)
    let calls = await fixture.calls
    XCTAssertEqual(calls[0].path, "bilibili.main.community.reply.v1.Reply/MainList")
    let req = try Bilibili_Main_Community_Reply_V1_MainListReq(serializedBytes: calls[0].body)
    XCTAssertEqual(req.oid, 123)
    XCTAssertEqual(req.type, 1)
    XCTAssertEqual(req.cursor.next, 99)
    XCTAssertEqual(req.cursor.mode.rawValue, 3)
    let sub = try Bilibili_Main_Community_Reply_V1_DetailListReq(serializedBytes: calls[1].body)
    XCTAssertEqual(sub.root, 101)
    XCTAssertEqual(sub.scene.rawValue, 0)
    XCTAssertEqual(sub.cursor.mode.rawValue, 2)
    // Independent field-number fixture: next=1, prev=2, mode=4 (not 3).
    var cursor = Bilibili_Main_Community_Reply_V1_CursorReq()
    cursor.next = 7
    cursor.prev = 8
    cursor.mode = .mainListHot
    XCTAssertEqual(try cursor.serializedData(), Data([0x08, 7, 0x10, 8, 0x20, 3]))
  }
  func testDynamicFixturesAllFiveRequestsPaginationAndUnsupported() async throws {
    let all = try Bilibili_App_Dynamic_V2_DynAllReply(serializedBytes: data("dynamics"))
    var video = Bilibili_App_Dynamic_V2_DynVideoReply()
    video.dynamicList.list = all.dynamicList.list
    video.dynamicList.historyOffset = "video-next"
    video.dynamicList.updateBaseline = "video-baseline"
    video.dynamicList.hasMore_p = true
    var personal = Bilibili_App_Dynamic_V2_DynAllPersonalReply()
    personal.list = all.dynamicList.list
    personal.offset = "personal-next"
    personal.hasMore_p = true
    var space = Bilibili_App_Dynamic_V2_DynSpaceRsp()
    space.list = all.dynamicList.list
    space.historyOffset = "space-next"
    space.hasMore_p = false
    let fixture = RPCFixtureTransport([
      BiliRPCMethod.dynAll.rawValue: try data("dynamics"),
      BiliRPCMethod.dynVideo.rawValue: try video.serializedData(),
      BiliRPCMethod.dynAllPersonal.rawValue: try personal.serializedData(),
      BiliRPCMethod.dynVideoPersonal.rawValue: try personal.serializedData(),
      BiliRPCMethod.dynSpace.rawValue: try space.serializedData(),
    ])
    let rpc = service(fixture, auth: try await auth(token: fakeToken))
    let page = try await rpc.dynamics(.all(offset: "history-fixture", baseline: "old-baseline"))
    XCTAssertEqual(page.items.count, 7)
    XCTAssertEqual(page.historyOffset, "next-fixture")
    XCTAssertEqual(page.updateBaseline, "baseline-fixture")
    XCTAssertTrue(page.hasMore)
    XCTAssertEqual(page.items[0].content, .text)
    guard case .video(let card) = page.items[1].content else { return XCTFail("video") }
    XCTAssertEqual(card.aid, 123)
    XCTAssertEqual(card.bvid, "BV-fixture")
    XCTAssertEqual(card.duration, 120)
    XCTAssertEqual(page.items[1].author?.mid, 42)
    XCTAssertEqual(page.items[1].likes, 5)
    guard case .images(let images) = page.items[2].content else { return XCTFail("draw") }
    XCTAssertEqual(images.count, 1)
    guard case .article(let article) = page.items[3].content else { return XCTFail("article") }
    XCTAssertEqual(article.id, 345)
    guard case .episode(let episode) = page.items[4].content else { return XCTFail("pgc") }
    XCTAssertEqual(episode.episodeID, 789)
    guard case .forward(let original) = page.items[5].content else { return XCTFail("forward") }
    XCTAssertEqual(original.text, "Original")
    XCTAssertEqual(page.items[6].content, .unsupported(type: 7))
    let videoPage = try await rpc.dynamics(.video(offset: "", baseline: "video-old"))
    XCTAssertEqual(videoPage.updateBaseline, "video-baseline")
    let userPage = try await rpc.dynamics(.userAll(mid: 42, offset: "user-old"))
    XCTAssertEqual(userPage.historyOffset, "personal-next")
    _ = try await rpc.dynamics(.userVideo(mid: 42, offset: "video-old"))
    let spacePage = try await rpc.dynamics(.space(mid: 42, historyOffset: "space-old"))
    XCTAssertFalse(spacePage.hasMore)
    let calls = await fixture.calls
    XCTAssertEqual(
      calls.map(\.path),
      [
        "bilibili.app.dynamic.v2.Dynamic/DynAll", "bilibili.app.dynamic.v2.Dynamic/DynVideo",
        "bilibili.app.dynamic.v2.Dynamic/DynAllPersonal",
        "bilibili.app.dynamic.v2.Dynamic/DynVideoPersonal",
        "bilibili.app.dynamic.v2.Dynamic/DynSpace",
      ])
    let req = try Bilibili_App_Dynamic_V2_DynAllReq(serializedBytes: calls[0].body)
    XCTAssertEqual(req.offset, "history-fixture")
    XCTAssertEqual(req.updateBaseline, "old-baseline")
    XCTAssertEqual(req.refreshType, .history)
    XCTAssertEqual(req.localTime, 9)
    let videoReq = try Bilibili_App_Dynamic_V2_DynVideoReq(serializedBytes: calls[1].body)
    XCTAssertEqual(videoReq.refreshType, .new)
    let userReq = try Bilibili_App_Dynamic_V2_DynAllPersonalReq(serializedBytes: calls[2].body)
    XCTAssertEqual(userReq.hostUid, 42)
    XCTAssertEqual(userReq.offset, "user-old")
    let spaceReq = try Bilibili_App_Dynamic_V2_DynSpaceReq(serializedBytes: calls[4].body)
    XCTAssertEqual(spaceReq.historyOffset, "space-old")
    let encoded = try JSONEncoder().encode(page)
    XCTAssertEqual(try JSONDecoder().decode(RPCDynamicPage.self, from: encoded), page)
  }
  func testHistoryPopularRankAndRoutes() async throws {
    let fixture = RPCFixtureTransport([
      BiliRPCMethod.history.rawValue: try data("history"),
      BiliRPCMethod.popular.rawValue: try data("popular"),
      BiliRPCMethod.rank.rawValue: try data("rank"),
    ])
    let rpc = service(fixture, auth: try await auth(token: fakeToken))
    let history = try await rpc.history(business: "archive", max: 600)
    XCTAssertEqual(history.max, 700)
    XCTAssertTrue(history.hasMore)
    XCTAssertEqual(history.items.count, 6)
    guard case .video(let video, let progress) = history.items[0].content else {
      return XCTFail("history video")
    }
    XCTAssertEqual(video.cid, 321)
    XCTAssertEqual(progress, 12)
    guard case .episode = history.items[1].content else { return XCTFail("history episode") }
    guard case .article = history.items[2].content else { return XCTFail("history article") }
    guard case .live = history.items[3].content else { return XCTFail("history live") }
    guard case .course = history.items[4].content else { return XCTFail("history course") }
    XCTAssertEqual(history.items[5].content, .unsupported)
    let popular = try await rpc.popular(index: 800, version: "old-version")
    XCTAssertEqual(popular.nextIndex, 901)
    XCTAssertEqual(popular.version, "fixture-v1")
    XCTAssertEqual(popular.items.count, 2)
    XCTAssertEqual(popular.items[1], .unsupported(kind: "hotTopic"))
    let rank = try await rpc.ranking(region: 21)
    XCTAssertEqual(rank[0].aid, 123)
    let calls = await fixture.calls
    XCTAssertEqual(
      calls.map(\.path),
      [
        "bilibili.app.interface.v1.History/CursorV2", "bilibili.app.show.v1.Popular/Index",
        "bilibili.app.show.v1.Rank/RankRegion",
      ])
    let historyReq = try Bilibili_App_Interfaces_V1_CursorV2Req(serializedBytes: calls[0].body)
    XCTAssertEqual(historyReq.business, "archive")
    XCTAssertEqual(historyReq.cursor.max, 600)
    let popularReq = try Bilibili_App_Show_Popular_V1_PopularResultReq(
      serializedBytes: calls[1].body)
    XCTAssertEqual(popularReq.idx, 800)
    XCTAssertEqual(popularReq.ver, "old-version")
    let rankReq = try Bilibili_App_Show_Rank_V1_RankRegionResultReq(serializedBytes: calls[2].body)
    XCTAssertEqual(rankReq.rid, 21)
    XCTAssertEqual(try rankReq.serializedData(), Data([8, 21]))
  }
  func testNoTokenExpiredTokenPermissionAndMalformedPayload() async throws {
    let fixture = RPCFixtureTransport([:])
    let rpc = service(fixture, auth: try await auth())
    do {
      _ = try await rpc.history()
      XCTFail("login required")
    } catch { XCTAssertEqual(error as? BiliRPCError, .needsLogin) }
    let callCount = await fixture.calls.count
    XCTAssertEqual(callCount, 0)
    var token = fakeToken
    token = AppToken(
      mid: token.mid, accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: 1
    )
    let expiredRPC = service(fixture, auth: try await auth(token: token))
    do {
      _ = try await expiredRPC.history()
      XCTFail("expired refresh")
    } catch { XCTAssertEqual(error as? BiliRPCError, .authenticationFailure) }
    let expiredCount = await fixture.calls.count
    XCTAssertEqual(expiredCount, 0)
    await fixture.setError(
      RPCError(code: .permissionDenied, message: "fixture-access must never appear"))
    do {
      _ = try await rpc.ranking()
      XCTFail("permission")
    } catch {
      XCTAssertEqual(error as? BiliRPCError, .permissionDenied)
      XCTAssertFalse(String(describing: error).contains("fixture-access"))
    }
    XCTAssertThrowsError(
      try BiliRPCAdapter.comments(
        Bilibili_Main_Community_Reply_V1_MainListReply(), oid: 123, type: 1))
    var huge = Bilibili_App_Show_Rank_V1_RankListReply()
    huge.items = Array(repeating: .init(), count: 513)
    XCTAssertThrowsError(try BiliRPCAdapter.ranking(huge)) {
      XCTAssertEqual($0 as? BiliRPCError, .resourceLimit)
    }
  }
  func testLogoutAndBeginLoginCancelLateResponses() async throws {
    for logout in [true, false] {
      for lateFailure in [false, true] {
        let auth = try await auth(token: fakeToken)
        let fixture = RPCFixtureTransport([BiliRPCMethod.rank.rawValue: try data("rank")])
        await fixture.setPaused(true)
        if lateFailure {
          await fixture.setError(RPCError(code: .permissionDenied, message: "fixture late failure"))
        }
        let rpc = service(fixture, auth: auth)
        let task = Task { try await rpc.ranking() }
        try await waitFor(fixture, calls: 1)
        if logout { try await auth.logout() } else { _ = await auth.beginLogin() }
        try await waitFor(fixture, calls: 1, cancels: 1)
        await fixture.release()
        do {
          _ = try await task.value
          XCTFail("late identity")
        } catch { XCTAssertTrue(error is CancellationError) }
        await rpc.shutdown()
      }
    }
  }
  func testCancelOneRPCDoesNotCancelAnotherAndShutdownRejectsCalls() async throws {
    let fixture = RPCFixtureTransport([BiliRPCMethod.rank.rawValue: try data("rank")])
    await fixture.setPaused(true)
    let rpc = service(fixture, auth: try await auth(token: fakeToken))
    let first = Task { try await rpc.ranking(region: 1) }
    let second = Task { try await rpc.ranking(region: 2) }
    try await waitFor(fixture, calls: 2)
    first.cancel()
    try await waitFor(fixture, calls: 2, cancels: 1)
    await fixture.release()
    do {
      _ = try await first.value
      XCTFail("cancelled RPC")
    } catch { XCTAssertTrue(error is CancellationError) }
    let secondValue = try await second.value
    XCTAssertEqual(secondValue.count, 1)
    await rpc.shutdown()
    await rpc.shutdown()
    do {
      _ = try await rpc.ranking()
      XCTFail("shutdown")
    } catch { XCTAssertEqual(error as? BiliRPCError, .shutdown) }
  }
  func testIdentityEventsContainOnlyFinalNonSensitiveState() async throws {
    let auth = try await auth(token: fakeToken)
    let stream = await auth.identityEvents()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()
    XCTAssertEqual(initial?.state, .appAuthorized)
    XCTAssertEqual(initial?.mid, 42)
    _ = await auth.beginLogin()
    let login = await iterator.next()
    XCTAssertEqual(login?.state, .appAuthorized)
    XCTAssertNotEqual(login?.identityRevision, initial?.identityRevision)
    XCTAssertNotEqual(login?.epoch, initial?.epoch)
    try await auth.logout()
    let logout = await iterator.next()
    XCTAssertEqual(logout?.state, .needsLogin)
    XCTAssertNil(logout?.mid)
    XCTAssertFalse(String(describing: logout).contains("fixture-access"))
    let expired = AppToken(
      mid: 42, accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: 1)
    let stale = try await self.auth(token: expired)
    let refreshStream = await stale.identityEvents()
    var refreshIterator = refreshStream.makeAsyncIterator()
    _ = await refreshIterator.next()
    do {
      _ = try await stale.ensureAppToken()
      XCTFail("refresh fixture")
    } catch {}
    let failed = await refreshIterator.next()
    XCTAssertEqual(failed?.state, .needsLogin)
    XCTAssertNil(failed?.mid)
  }

  func testRPCRefreshUsesOneSnapshotAndLoginDuringRefreshNeverSendsRPC() async throws {
    let expired = AppToken(
      mid: 42, accessToken: "fixture-old-access", refreshToken: "fixture-old-refresh", expiresAt: 1)
    for changeIdentity in [false, true] {
      let http = RPCTokenHTTP(paused: true)
      let auth = BiliService(transport: http, credentials: RPCCredentialStore(expired))
      try await auth.restoreCookies()
      let fixture = RPCFixtureTransport([BiliRPCMethod.history.rawValue: try data("history")])
      let rpc = service(fixture, auth: auth)
      let task = Task { try await rpc.history() }
      for _ in 0..<200 {
        if await http.count == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      if changeIdentity { _ = await auth.beginLogin() }
      await http.release()
      if changeIdentity {
        do {
          _ = try await task.value
          XCTFail("stale refresh RPC")
        } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await fixture.calls
        XCTAssertTrue(calls.isEmpty)
      } else {
        _ = try await task.value
        let calls = await fixture.calls
        XCTAssertEqual(
          Array(calls[0].metadata[stringValues: "authorization"]),
          ["identify_v1 fixture-new-access"])
        let metadata = try Bilibili_Metadata_Metadata(
          serializedBytes: XCTUnwrap(
            Array(calls[0].metadata[binaryValues: "x-bili-metadata-bin"]).first))
        XCTAssertEqual(metadata.accessKey, "fixture-new-access")
        XCTAssertEqual(Array(calls[0].metadata[stringValues: "x-bili-mid"]), ["42"])
      }
    }
  }
  func testIdentityEventsRestoreAndCommitFinalState() async throws {
    let http = RPCTokenHTTP()
    let auth = BiliService(transport: http, credentials: RPCCredentialStore(fakeToken))
    let stream = await auth.identityEvents()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()
    XCTAssertEqual(initial?.state, .needsLogin)
    try await auth.restoreCookies()
    let restored = await iterator.next()
    XCTAssertEqual(restored?.state, .appAuthorized)
    XCTAssertEqual(restored?.mid, 42)
    let qr = try await auth.beginQR()
    _ = await iterator.next()
    _ = try await auth.pollQR(qr.key, token: qr.token)
    let committed = await iterator.next()
    XCTAssertEqual(committed?.state, .appAuthorized)
    XCTAssertEqual(committed?.mid, 42)
    XCTAssertNotEqual(committed?.identityRevision, restored?.identityRevision)
    XCTAssertFalse(String(describing: committed).contains("fixture-new-access"))
  }

  func testRefreshFailureCancelsOldRPCButPreservesSharedRefreshFailure() async throws {
    let clock = RPCTestClock()
    let http = RPCRejectedRefreshHTTP()
    let token = AppToken(
      mid: 42, accessToken: "fixture-old-access", refreshToken: "fixture-old-refresh",
      expiresAt: 1500)
    let auth = BiliService(
      transport: http, credentials: RPCCredentialStore(token), now: { clock.now() })
    try await auth.restoreCookies()
    let eventStream = await auth.identityEvents()
    var events = eventStream.makeAsyncIterator()
    let originalEvent = await events.next()
    let failureEventTask = await nextEvent(eventStream)
    let fixture = RPCFixtureTransport([BiliRPCMethod.rank.rawValue: try data("rank")])
    await fixture.setPaused(true)
    let rpc = service(fixture, auth: auth)
    let oldRPC = Task { try await rpc.ranking() }
    try await waitFor(fixture, calls: 1)
    clock.advance()
    let firstRefresh = Task { try await auth.ensureAppToken() }
    for _ in 0..<200 {
      if await http.calls == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let secondRefresh = Task { try await auth.ensureAppToken() }
    // Let the actor enqueue the second waiter before releasing the shared HTTP response.
    for _ in 0..<10 { await Task.yield() }
    await http.release()
    for task in [firstRefresh, secondRefresh] {
      do {
        _ = try await task.value
        XCTFail("refresh rejection")
      } catch AuthFailure.rejected(let code) { XCTAssertEqual(code, -101) } catch {
        XCTFail("Refresh waiter lost its original failure: \(type(of: error))")
      }
    }
    let httpCalls = await http.calls
    XCTAssertEqual(httpCalls, 1)
    try await waitFor(fixture, calls: 1, cancels: 1)
    await fixture.release()
    do {
      _ = try await oldRPC.value
      XCTFail("old token RPC result")
    } catch { XCTAssertTrue(error is CancellationError) }
    let failedEvent = await failureEventTask.value
    XCTAssertNotEqual(originalEvent?.identityRevision, failedEvent?.identityRevision)
    XCTAssertEqual(originalEvent?.epoch, failedEvent?.epoch)
    XCTAssertEqual(failedEvent?.state, .needsLogin)
    XCTAssertNil(failedEvent?.mid)
    await fixture.setPaused(false)
    _ = try await rpc.ranking()
    let calls = await fixture.calls
    XCTAssertTrue(Array(calls[1].metadata[stringValues: "authorization"]).isEmpty)
    let header = try Bilibili_Metadata_Metadata(
      serializedBytes: XCTUnwrap(
        Array(calls[1].metadata[binaryValues: "x-bili-metadata-bin"]).first))
    XCTAssertEqual(header.accessKey, "")
  }

  func testAwaitingIdentityObserverNeverReceivesClearedIntermediateState() async throws {
    let store = RPCEventCredentialStore(fakeToken)
    let auth = BiliService(transport: RPCTokenHTTP(), credentials: store)
    let stream = await auth.identityEvents()
    var initial = stream.makeAsyncIterator()
    _ = await initial.next()
    let restoredEvent = await nextEvent(stream)
    store.arm(.load)
    let restore = Task { try await auth.restoreCookies() }
    try await releaseGate(store)
    try await restore.value
    let restored = await restoredEvent.value
    XCTAssertEqual(restored?.state, .appAuthorized)
    XCTAssertEqual(restored?.mid, 42)

    let loginEvent = await nextEvent(stream)
    let qr = try await auth.beginQR()
    let login = await loginEvent.value
    XCTAssertEqual(login?.state, .appAuthorized)
    XCTAssertEqual(login?.mid, 42)
    XCTAssertNotEqual(login?.epoch, restored?.epoch)

    let committedEvent = await nextEvent(stream)
    store.arm(.saveCookies)
    let commit = Task { try await auth.pollQR(qr.key, token: qr.token) }
    try await releaseGate(store)
    _ = try await commit.value
    let committed = await committedEvent.value
    XCTAssertEqual(committed?.state, .appAuthorized)
    XCTAssertEqual(committed?.mid, 42)
    XCTAssertNotEqual(committed?.identityRevision, login?.identityRevision)
  }

  func testAwaitingIdentityObserverReceivesFinalStateWhenPersistenceFails() async throws {
    for mismatch in [true, false] {
      let store = RPCEventCredentialStore(fakeToken)
      let auth = BiliService(
        transport: RPCTokenHTTP(mismatchedCookies: mismatch), credentials: store)
      try await auth.restoreCookies()
      let qr = try await auth.beginQR()
      let stream = await auth.identityEvents()
      var initial = stream.makeAsyncIterator()
      _ = await initial.next()
      let event = await nextEvent(stream)
      store.rejectClearToken = mismatch
      store.rejectClear = !mismatch
      store.arm(mismatch ? .clearToken : .clear)
      let mutation = Task {
        if mismatch {
          _ = try await auth.pollQR(qr.key, token: qr.token)
        } else {
          try await auth.logout()
        }
      }
      try await releaseGate(store)
      do {
        try await mutation.value
        XCTFail("Persistence must fail")
      } catch { XCTAssertTrue(error is RPCEventCredentialStore.Failure) }
      let final = await event.value
      XCTAssertEqual(final?.state, .needsLogin)
      XCTAssertNil(final?.mid)
      let snapshot = await auth.authSnapshot()
      XCTAssertEqual(final?.state, snapshot.state)
      XCTAssertEqual(final?.identityRevision, snapshot.identityRevision)
      XCTAssertEqual(final?.epoch, snapshot.epoch)
    }
  }

  func testPopularRejectsNonVideoAndBangumiWithoutParsingTheirParam() throws {
    var reply = Bilibili_App_Show_Popular_V1_PopularReply()
    for (kind, uri, param, index) in [
      ("av", "bilibili://video/123", "123", Int64(10)),
      ("article", "bilibili://article/abc", "article-id", Int64(30)),
      ("av", "bilibili://bangumi/play/ep42", "episode-id", Int64(40)),
    ] {
      var video = Bilibili_App_Card_V1_SmallCoverV5()
      video.base.cardGoto = kind
      video.base.uri = uri
      video.base.param = param
      video.base.idx = index
      var card = Bilibili_App_Card_V1_Card()
      card.smallCoverV5 = video
      reply.items.append(card)
    }
    let page = try BiliRPCAdapter.popular(reply)
    XCTAssertEqual(page.items.count, 3)
    guard case .video(let video, _, _) = page.items[0] else { return XCTFail("av card") }
    XCTAssertEqual(video.aid, 123)
    XCTAssertEqual(page.items[1], .unsupported(kind: "smallCoverV5"))
    XCTAssertEqual(page.items[2], .unsupported(kind: "smallCoverV5"))
    XCTAssertEqual(page.nextIndex, 40)
  }

  func testPopularPreservesSchemaBvidDurationAndDurationLabel() throws {
    var video = Bilibili_App_Card_V1_SmallCoverV5()
    video.base.cardGoto = "av"
    video.base.param = "123"
    video.base.playerArgs.cid = 321
    video.base.playerArgs.duration = 125
    video.base.threePointV4.sharePlane.bvid = "BV-fixture-popular"
    video.base.threePointV4.sharePlane.author = "Owner"
    video.base.threePointV4.sharePlane.authorID = 789
    video.base.threePointV4.sharePlane.playNumber = "12.3万次"
    video.rightDesc2 = "UP主 · 8小时前"
    video.rcmdReasonStyle.text = "很多人点赞"
    video.coverRightText1 = "02:05"
    var card = Bilibili_App_Card_V1_Card()
    card.smallCoverV5 = video
    var reply = Bilibili_App_Show_Popular_V1_PopularReply()
    reply.items = [card]
    let decoded = try Bilibili_App_Show_Popular_V1_PopularReply(
      serializedBytes: reply.serializedData())
    let page = try BiliRPCAdapter.popular(decoded)
    guard case .video(let mapped, _, let label) = page.items[0] else {
      return XCTFail("video card")
    }
    XCTAssertEqual(mapped.bvid, "BV-fixture-popular")
    XCTAssertEqual(mapped.duration, 125)
    XCTAssertEqual(mapped.cid, 321)
    XCTAssertEqual(label, "02:05")
    XCTAssertEqual(mapped.author?.name, "Owner")
    XCTAssertEqual(mapped.author?.mid, 789)
    XCTAssertEqual(mapped.views, 123_000)
    XCTAssertEqual(mapped.subtitle, "8小时前")
    XCTAssertEqual(mapped.recommendationReason, "很多人点赞")
    let legacy = try JSONDecoder().decode(RPCVideoCard.self, from: Data(#"{"aid":123,"bvid":"","cid":321,"title":"A","duration":125,"views":100,"uri":""}"#.utf8))
    XCTAssertNil(legacy.publishedAt)
    XCTAssertNil(legacy.subtitle)
  }

  func testPopularTopEntranceStillAdvancesFinalPageCursor() throws {
    var reply = Bilibili_App_Show_Popular_V1_PopularReply()
    var topic = Bilibili_App_Card_V1_Card()
    topic.hotTopic.base.idx = 901
    var entrance = Bilibili_App_Card_V1_Card()
    entrance.popularTopEntrance.base.idx = 1200
    reply.items = [topic, entrance]
    let page = try BiliRPCAdapter.popular(reply)
    XCTAssertEqual(
      page.items, [.unsupported(kind: "hotTopic"), .unsupported(kind: "popularTopEntrance")])
    XCTAssertEqual(page.nextIndex, 1200)
  }

}
