import Foundation
import XCTest
@testable import ManpingCore

private final class PlaybackFeatureCredentials: AuthCredentialStore, @unchecked Sendable {
  private let includeCSRF: Bool
  private var token: AppToken? = AppToken(mid: 123, accessToken: "fixture-danmaku-access",
    refreshToken: "fixture-danmaku-refresh", expiresAt: 9_999_999_999)
  init(includeCSRF: Bool = true) { self.includeCSRF = includeCSRF }
  func load() -> [HTTPCookie] {
    var values = ["SESSDATA": "fixture-danmaku-cookie"]
    if includeCSRF { values["bili_jct"] = "fixture-danmaku-csrf" }
    return values.map { HTTPCookie(properties: [.name: $0.key, .value: $0.value,
      .domain: ".bilibili.com", .path: "/", .secure: "TRUE"])! }
  }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { token }
  func saveToken(_ token: AppToken?) { self.token = token }
  func clear() { token = nil }
}
private actor PlaybackFeatureTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  var code: Int
  init(code: Int = 0) { self.code = code }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    return AuthHTTPResponse(body: Data("{\"code\":\(code),\"data\":{\"dmid\":\"fixture\"}}".utf8),
      response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private func danmakuFields(_ request: URLRequest) -> [String: String] {
  let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
  return Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}
final class M7PlaybackFeaturesTests: XCTestCase, @unchecked Sendable {
  func testDanmakuMapsExactSDKFieldsAndRejectsInvalidDrafts() throws {
    let draft = try VideoDanmakuDraft(aid: 100, cid: 200, text: "  Hello & 世界  ", seconds: 12.75,
      color: 0x00ff00, standardSize: false, mode: 5)
    XCTAssertEqual(draft.fields(timestampMilliseconds: 321), ["aid": "100", "type": "1", "oid": "200", "msg": "Hello & 世界",
      "progress": "12000", "color": "65280", "fontsize": "18", "mode": "5", "rnd": "321"])
    for seconds in [Double.nan, -Double.infinity, -1] {
      XCTAssertThrowsError(try VideoDanmakuDraft(aid: 1, cid: 2, text: "hello", seconds: seconds))
    }
    XCTAssertThrowsError(try VideoDanmakuDraft(aid: 1, cid: 2, text: String(repeating: "字", count: 101), seconds: 0))
    XCTAssertThrowsError(try VideoDanmakuDraft(aid: 1, cid: 2, text: "hello", seconds: 0, mode: 7))
    XCTAssertThrowsError(try VideoDanmakuDraft(aid: 0, cid: 2, text: "hello", seconds: 0))
  }
  func testDanmakuPOSTIncludesIdentitySignatureAndCurrentCSRF() async throws {
    let transport = PlaybackFeatureTransport()
    let service = BiliService(transport: transport, credentials: PlaybackFeatureCredentials())
    try await service.restoreCookies()
    let snapshot = await service.authSnapshot()
    try await service.sendVideoDanmaku(VideoDanmakuDraft(aid: 100, cid: 200, text: "Hello & 世界", seconds: 3), expectedIdentity: snapshot)
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.last)
    XCTAssertEqual(request.url?.absoluteString, "https://api.bilibili.com/x/v2/dm/post")
    XCTAssertEqual(request.httpMethod, "POST")
    let fields = danmakuFields(request)
    XCTAssertEqual(fields["csrf"], "fixture-danmaku-csrf")
    XCTAssertEqual(fields["msg"], "Hello & 世界")
    XCTAssertEqual(fields["access_key"], "fixture-danmaku-access")
    XCTAssertEqual(fields["progress"], "3000")
    XCTAssertNotNil(fields["sign"])
    XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("SESSDATA=fixture-danmaku-cookie") == true)
  }
  func testMissingCSRFAndStaleIdentityNeverSendWrites() async throws {
    let transport = PlaybackFeatureTransport()
    let service = BiliService(transport: transport, credentials: PlaybackFeatureCredentials(includeCSRF: false))
    try await service.restoreCookies()
    let snapshot = await service.authSnapshot()
    let draft = try VideoDanmakuDraft(aid: 1, cid: 2, text: "fixture", seconds: 0)
    do { try await service.sendVideoDanmaku(draft, expectedIdentity: snapshot); XCTFail("Expected missing CSRF") }
    catch AuthFailure.missingCSRF {} catch { XCTFail("Unexpected \(error)") }
    try await service.logout()
    do { try await service.sendVideoDanmaku(draft, expectedIdentity: snapshot); XCTFail("Expected identity cancellation") }
    catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
    let requests = await transport.requests
    XCTAssertFalse(requests.contains { $0.url?.path == "/x/v2/dm/post" })
  }
  func testDanmakuAPIErrorIsNotReportedAsSuccess() async throws {
    let transport = PlaybackFeatureTransport(code: -101)
    let service = BiliService(transport: transport, credentials: PlaybackFeatureCredentials())
    try await service.restoreCookies()
    let snapshot = await service.authSnapshot()
    do { try await service.sendVideoDanmaku(VideoDanmakuDraft(aid: 1, cid: 2, text: "fixture", seconds: 0), expectedIdentity: snapshot)
      XCTFail("Expected API error")
    } catch BiliError.api(let code, _) { XCTAssertEqual(code, -101) }
  }
  func testChapterParsingPreservesEngineIndexAndFiltersInvalidTimes() throws {
    let chapters = try PlaybackChapter.parse(Data(#"[{"title":"Finale","time":100},{"time":0},{"title":"Invalid","time":-1}]"#.utf8))
    XCTAssertEqual(chapters.map(\.index), [1, 0])
    XCTAssertEqual(chapters.map(\.title), ["章节 2", "Finale"])
    XCTAssertEqual(chapters.map(\.time), [0, 100])
    XCTAssertThrowsError(try PlaybackChapter.parse(Data("{}".utf8)))
    let engine = [PlaybackChapter(index: 0, title: "Embedded", time: 0)]
    XCTAssertEqual(PlaybackChapter.preferred(viewPoints: [], engine: engine), engine)
    let official = PlaybackChapter.preferred(viewPoints: [
      AIViewPoint(id: "ch1", start: 0, end: 85, title: "平台选型与定位"), AIViewPoint(id: "ch2", start: 85, end: 300, title: "模型与优化方案"),
    ], engine: engine)
    XCTAssertEqual(official.map(\.title), ["平台选型与定位", "模型与优化方案"])
    XCTAssertEqual(PlaybackChapter.current(official, at: 254)?.title, "模型与优化方案")
    XCTAssertEqual(PlaybackChapter.current(official, at: 10)?.title, "平台选型与定位")
    XCTAssertNil(PlaybackChapter.current([PlaybackChapter(index: 0, title: "Late", time: 30)], at: 10))
  }
}
