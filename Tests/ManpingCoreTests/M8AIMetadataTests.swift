import Foundation
import XCTest
@testable import ManpingCore

/// Redacted fixtures. The conclusion/get shapes follow external clients; the live contract was not
/// exercised from this repository.
enum AIOfficialFixtures {
  static let withOutline = #"{"code":0,"message":"0","data":{"code":0,"model_result":{"result_type":2,"summary":"UP 主从成都出发，记录前往新都桥的第一天。","outline":[{"title":"出发与准备","part_outline":[{"timestamp":12,"content":"沿 318 国道出发"}],"timestamp":0},{"title":"翻越折多山","part_outline":[{"timestamp":240,"content":"垭口风大"},{"timestamp":300,"content":"下山"}],"timestamp":232}]},"stid":"0","status":0,"like_num":1,"dislike_num":0}}"#
  static let summaryOnly = #"{"code":0,"message":"0","data":{"code":0,"model_result":{"result_type":1,"summary":"只有一段摘要。","outline":null}}}"#
  static let none = #"{"code":0,"message":"0","data":{"code":1,"model_result":null}}"#
  static let unsupported = #"{"code":0,"message":"0","data":{"code":-1,"model_result":null}}"#
  static let signedOut = #"{"code":-101,"message":"账号未登录","ttl":1}"#
  static let player = #"{"code":0,"data":{"subtitle":{"subtitles":[{"id":2,"id_str":"2","lan":"zh-CN","lan_doc":"中文","ai_type":0,"subtitle_url":"https://i0.hdslb.com/bfs/subtitle/fixture.json"}]},"view_points":[{"type":2,"from":0,"to":232,"content":"出发","imgUrl":""},{"type":2,"from":232,"to":618,"content":"翻越折多山"},{"from":700,"to":650,"content":"倒置"},{"from":"x","content":"无效"}]}}"#
  static let playerBadSubtitles = #"{"code":0,"data":{"subtitle":{"subtitles":[{"id":"x","lan":"","subtitle_url":"https://attacker.invalid/1"}]},"view_points":[{"from":0,"to":60,"content":"开头"}]}}"#
}

private actor AIMetadataTransport: AuthTransport {
  private(set) var paths: [String] = []
  private(set) var queries: [[String: String]] = []
  let conclusion: String
  let player: String
  init(conclusion: String = AIOfficialFixtures.withOutline, player: String = AIOfficialFixtures.player) {
    self.conclusion = conclusion; self.player = player
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    let url = request.url!
    paths.append(url.path)
    queries.append(Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { first, _ in first }))
    let body: String
    switch url.path {
    case "/x/player/wbi/v2": body = player
    case "/x/web-interface/nav":
      body = #"{"code":-101,"data":{"wbi_img":{"img_url":"https://i.example/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i.example/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#
    case "/x/web-interface/view/conclusion/get": body = conclusion
    default: body = #"{"body":[{"from":12,"to":18,"content":"字幕"}]}"#
    }
    return AuthHTTPResponse(body: Data(body.utf8), response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private final class AIMetadataCredentials: AuthCredentialStore, @unchecked Sendable {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ token: AppToken?) {}
  func clear() {}
}

/// Hot comments with a controlled failure on either page.
private actor AIPartialCommentsRPC: BiliRPCService {
  let error: any Error
  let failFirst: Bool
  init(error: any Error = BiliRPCError.unavailable, failFirst: Bool = false) {
    self.error = error; self.failFirst = failFirst
  }
  func comments(oid: Int64, targetType: Int32, sort: RPCCommentSort, next: Int64) async throws -> RPCCommentPage {
    guard next == 0, !failFirst else { throw error }
    let author = RPCUser(mid: 1, name: "u", avatar: nil)
    return RPCCommentPage(oid: oid, targetType: targetType, comments: [RPCComment(id: 1, root: 1, author: author, text: "第一页", emotes: [],
      createdAt: 0, likes: 10, replyCount: 0, liked: false, pinned: false, replies: [])], pinned: nil, next: 500, isEnd: false)
  }
  func commentDetails(oid: Int64, targetType: Int32, root: Int64, sort: RPCCommentSort, next: Int64) async throws -> RPCCommentPage { throw BiliRPCError.invalidArgument }
  func dynamics(_ query: RPCDynamicQuery) async throws -> RPCDynamicPage { throw BiliRPCError.invalidArgument }
  func history(business: String, max: Int64) async throws -> RPCHistoryPage { throw BiliRPCError.invalidArgument }
  func popular(index: Int64, version: String) async throws -> RPCPopularPage { throw BiliRPCError.invalidArgument }
  func ranking(region: Int32) async throws -> [RPCVideoCard] { throw BiliRPCError.invalidArgument }
  func shutdown() async {}
}

final class M8AIMetadataTests: XCTestCase, @unchecked Sendable {
  private func object(_ text: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  func testPlayerMetadataParsesFieldsIndependently() throws {
    let data = try XCTUnwrap(object(AIOfficialFixtures.player)["data"] as? [String: Any])
    let metadata = PlayerMetadata.parse(data, aid: 1, cid: 2)
    XCTAssertEqual(metadata.subtitles?.map(\.id), ["2"])
    XCTAssertEqual(metadata.viewPoints, [AIViewPoint(id: "ch1", start: 0, end: 232, title: "出发"),
      AIViewPoint(id: "ch2", start: 232, end: 618, title: "翻越折多山")])
    // A broken subtitle index keeps usable chapters, and the reverse.
    let bad = PlayerMetadata.parse(try XCTUnwrap(object(AIOfficialFixtures.playerBadSubtitles)["data"] as? [String: Any]), aid: 1, cid: 2)
    XCTAssertNil(bad.subtitles); XCTAssertNotNil(bad.subtitleError)
    XCTAssertEqual(bad.viewPoints.count, 1)
    let noPoints = PlayerMetadata.parse(["subtitle": ["subtitles": []]], aid: 1, cid: 2)
    XCTAssertEqual(noPoints.subtitles, []); XCTAssertEqual(noPoints.viewPoints, [])
  }

  func testOneMetadataRequestServesSubtitlesAndChapters() async throws {
    let transport = AIMetadataTransport()
    let service = BiliService(transport: transport, credentials: AIMetadataCredentials())
    let identity = await service.authSnapshot()
    async let first = service.playerMetadata(aid: 100, cid: 200, expectedIdentity: identity)
    async let second = service.downloadSubtitleTracks(aid: 100, cid: 200, expectedIdentity: identity)
    let (metadata, tracks) = try await (first, second)
    XCTAssertEqual(metadata.viewPoints.count, 2)
    XCTAssertEqual(tracks.map(\.id), ["2"])
    _ = try await service.playerMetadata(aid: 100, cid: 200, expectedIdentity: identity)
    var paths = await transport.paths
    XCTAssertEqual(paths.filter { $0 == "/x/player/wbi/v2" }.count, 1)
    // A new identity does not reuse the previous identity's answer.
    _ = await service.beginLogin()
    let next = await service.authSnapshot()
    _ = try await service.playerMetadata(aid: 100, cid: 200, expectedIdentity: next)
    paths = await transport.paths
    XCTAssertEqual(paths.filter { $0 == "/x/player/wbi/v2" }.count, 2)
    // Malformed subtitles still surface as a subtitle error for the track list.
    let broken = BiliService(transport: AIMetadataTransport(player: AIOfficialFixtures.playerBadSubtitles), credentials: AIMetadataCredentials())
    let brokenIdentity = await broken.authSnapshot()
    let chapters = try await broken.playerMetadata(aid: 1, cid: 2, expectedIdentity: brokenIdentity)
    XCTAssertEqual(chapters.viewPoints.count, 1)
    do { _ = try await broken.downloadSubtitleTracks(aid: 1, cid: 2, expectedIdentity: brokenIdentity); XCTFail("Expected subtitle error") }
    catch BiliError.invalidResponse {}
  }

  func testOfficialSummaryStates() throws {
    guard case .available(let summary, let outline?) = AIOfficialSummary.parse(try object(AIOfficialFixtures.withOutline)) else { return XCTFail() }
    XCTAssertTrue(summary.hasPrefix("UP 主从成都出发"))
    XCTAssertEqual(outline.map(\.title), ["出发与准备", "翻越折多山"])
    XCTAssertEqual(outline[1].start, 232)
    XCTAssertEqual(outline[1].points.map(\.id), ["o2.1", "o2.2"])
    guard case .available(_, let none) = AIOfficialSummary.parse(try object(AIOfficialFixtures.summaryOnly)) else { return XCTFail() }
    XCTAssertNil(none)
    if case .unavailable = AIOfficialSummary.parse(try object(AIOfficialFixtures.none)) {} else { XCTFail("No summary") }
    if case .unavailable = AIOfficialSummary.parse(try object(AIOfficialFixtures.unsupported)) {} else { XCTFail("Unsupported") }
    if case .unavailable(let reason) = AIOfficialSummary.parse(try object(AIOfficialFixtures.signedOut)) { XCTAssertTrue(reason.contains("登录")) }
    else { XCTFail("Signed out is unavailable with a reason") }
    if case .retryableError = AIOfficialSummary.parse(try object(#"{"code":-412,"message":"请求被拦截"}"#)) {} else { XCTFail("Risk control is retryable") }
    // Evidence for the outline uses the next section as the end.
    var evidence = AIEvidenceIndex()
    AIContextPack.addOutlineEvidence(AIOfficialSummary.parse(try object(AIOfficialFixtures.withOutline)), duration: 1104, to: &evidence)
    XCTAssertEqual(evidence.ranges["o1"], AITimeRange(start: 0, end: 232))
    XCTAssertEqual(evidence.ranges["o2.2"], AITimeRange(start: 300, end: 1104))
  }

  func testOfficialSummaryRequestIsSignedGETWithCandidateParameters() async throws {
    let transport = AIMetadataTransport(conclusion: AIOfficialFixtures.signedOut)
    let service = BiliService(transport: transport, credentials: AIMetadataCredentials())
    let identity = await service.authSnapshot()
    let result = try await service.officialSummary(aid: 100, cid: 200, bvid: "BV1fixture", uploaderMid: 77, expectedIdentity: identity)
    if case .unavailable = result {} else { XCTFail("Expected signed-out state") }
    let paths = await transport.paths, queries = await transport.queries
    let index = try XCTUnwrap(paths.firstIndex(of: "/x/web-interface/view/conclusion/get"))
    let query = queries[index]
    XCTAssertEqual(query["aid"], "100"); XCTAssertEqual(query["cid"], "200")
    XCTAssertEqual(query["bvid"], "BV1fixture"); XCTAssertEqual(query["up_mid"], "77")
    XCTAssertNotNil(query["w_rid"]); XCTAssertNotNil(query["wts"])
  }

  func testMaterialsThatMayRecoverMarkTheBundleTransient() async throws {
    let video = AISource.video(AIVideoInfo(aid: 100, cid: 200, bvid: "BV1fixture", title: "t", duration: 600, uploaderMid: 77))
    func gather(_ conclusion: String, kinds: Set<AIMaterialKind>, rpc: (any BiliRPCService)? = nil, source: AISource? = nil) async throws -> AIMaterialBundle {
      let service = BiliService(transport: AIMetadataTransport(conclusion: conclusion), credentials: AIMetadataCredentials())
      let identity = await service.authSnapshot()
      return try await AIBiliMaterialProvider(service: service, rpc: rpc).gather(source: source ?? video, kinds: kinds,
        settings: AIMaterialSettings(), identity: identity, fallbackChapters: [], loadedDanmaku: nil)
    }
    // The official summary could not be read right now: shown as such, read again next time.
    let failed = try await gather(#"{"code":-500,"message":"busy"}"#, kinds: [.officialSummary])
    if case .retryableError? = failed.official {} else { XCTFail("\(String(describing: failed.official))") }
    XCTAssertTrue(failed.transient)
    let read = try await gather(AIOfficialFixtures.withOutline, kinds: [.officialSummary])
    XCTAssertEqual(read.official?.isAvailable, true)
    XCTAssertFalse(read.transient)
    let none = try await gather(AIOfficialFixtures.none, kinds: [.officialSummary])
    XCTAssertFalse(none.transient)
    // Only the first comment page arrived: used now, both read again next time.
    let partial = try await gather(AIOfficialFixtures.withOutline, kinds: [.comments], rpc: AIPartialCommentsRPC())
    XCTAssertEqual(partial.comments?.items.count, 1)
    XCTAssertTrue(partial.transient)
  }

  private func commentFailureCases() -> [(any Error, Bool)] {
    [(BiliRPCError.serverStatus(12002), false), (BiliRPCError.permissionDenied, false),
      (BiliRPCError.needsLogin, false), (BiliRPCError.invalidArgument, false),
      (BiliRPCError.unavailable, true), (BiliRPCError.deadlineExceeded, true), (BiliRPCError.resourceLimit, true),
      (URLError(.timedOut), true), (URLError(.networkConnectionLost), true),
      (URLError(.badURL), false), (URLError(.unsupportedURL), false)]
  }

  private func gatherComments(error: any Error, failFirst: Bool) async throws -> AIMaterialBundle {
    let service = BiliService(transport: AIMetadataTransport(), credentials: AIMetadataCredentials())
    let source = AISource.article(AIArticleInfo(id: 5, title: "t", paragraphs: [AIArticleParagraph(text: "正文")]))
    return try await AIBiliMaterialProvider(service: service, rpc: AIPartialCommentsRPC(error: error, failFirst: failFirst))
      .gather(source: source, kinds: [.comments], settings: AIMaterialSettings(), identity: await service.authSnapshot(),
        fallbackChapters: [], loadedDanmaku: nil)
  }

  func testFirstCommentPageFailureIsTransientOnlyWhenRecoverable() async throws {
    for (error, transient) in commentFailureCases() {
      let bundle = try await gatherComments(error: error, failFirst: true)
      XCTAssertEqual(bundle.transient, transient, "\(error)")
      XCTAssertNil(bundle.comments)
      XCTAssertEqual(bundle.commentsNote, "没能读取评论")
    }
  }

  func testSecondCommentPageFailureKeepsPartialDigestAndRecoveryState() async throws {
    for (error, transient) in commentFailureCases() {
      let bundle = try await gatherComments(error: error, failFirst: false)
      XCTAssertEqual(bundle.transient, transient, "\(error)")
      XCTAssertEqual(bundle.comments?.partial, true)
      XCTAssertEqual(bundle.comments?.pagesLoaded, 1)
      XCTAssertEqual(bundle.comments?.items.map(\.text), ["第一页"])
      XCTAssertNil(bundle.commentsNote)
    }
  }

}
