import Foundation
import XCTest
@testable import ManpingCore

private let subtitleMetadataFixture = Data(#"{"code":0,"data":{"subtitle":{"allow_submit":false,"subtitles":[{"id":101,"lan":"zh-CN","lan_doc":"中文","ai_type":0,"subtitle_url":"http://i0.hdslb.com/bfs/subtitle/fixture-human.json"},{"id":102,"id_str":"102","lan":"zh-Hans","lan_doc":"中文（自动生成）","ai_type":1,"subtitle_url":"//aisubtitle.hdslb.com/bfs/ai_subtitle/prod/fixture-ai.json"}]}}}"#.utf8)
private let subtitleBodyFixture = Data(##"{"font_size":0.4,"font_color":"#FFFFFF","body":[{"from":0.25,"to":1.5,"content":"中文 < & >"},{"from":2,"to":3.25,"content":"Second line"}]}"##.utf8)
private struct SubtitleFixtureCredentials: AuthCredentialStore {
  func load() -> [HTTPCookie] {
    [HTTPCookie(properties: [.name: "SESSDATA", .value: "fixture-subtitle-cookie", .domain: ".bilibili.com", .path: "/", .secure: "TRUE"])!]
  }
  func loadToken() -> AppToken? {
    AppToken(mid: 123, accessToken: "fixture-subtitle-access", refreshToken: "fixture-subtitle-refresh", expiresAt: 9_999_999_999)
  }
  func save(_ cookies: [HTTPCookie]) {}
  func saveToken(_ token: AppToken?) {}
  func clear() {}
}
private actor SubtitleFixtureTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let body = request.url?.path == "/x/player/wbi/v2" ? subtitleMetadataFixture : subtitleBodyFixture
    return AuthHTTPResponse(body: body,
      response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

final class M7DownloadSubtitleTests: XCTestCase, @unchecked Sendable {
  private func tracks() throws -> [DownloadSubtitleTrack] {
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: subtitleMetadataFixture) as? [String: Any])
    return try DownloadSubtitleTrack.parse(XCTUnwrap(root["data"] as? [String: Any]))
  }
  func testSDKIndexShapeLanguagesAIAndHTTPSUpgrade() throws {
    let tracks = try tracks()
    XCTAssertEqual(tracks.map(\.id), ["101", "102"])
    XCTAssertEqual(tracks.map(\.language), ["zh-CN", "zh-Hans"])
    XCTAssertEqual(tracks.map(\.isAI), [false, true])
    XCTAssertEqual(tracks[0].url.absoluteString, "https://i0.hdslb.com/bfs/subtitle/fixture-human.json")
    XCTAssertEqual(tracks[1].url.scheme, "https")
    XCTAssertEqual(DownloadSubtitleTrack.filtered(tracks, filterAI: true).map(\.id), ["101"])
    XCTAssertEqual(DownloadSubtitleTrack.filtered(tracks, filterAI: false).count, 2)
    XCTAssertEqual(try DownloadSubtitleTrack.parse(["subtitle": ["subtitles": []]]), [])
  }
  func testMalformedAndUntrustedURLsCannotBecomeSubtitleRequests() throws {
    for url in ["file:///tmp/subtitle.json", "https://attacker.invalid/bfs/subtitle/1.json",
      "https://i0.hdslb.com.attacker.invalid/bfs/subtitle/1.json", "https://user:pass@i0.hdslb.com/bfs/subtitle/1.json",
      "https://i0.hdslb.com:8443/bfs/subtitle/1.json", "https://i0.hdslb.com/video/1.json",
      "https://i0.hdslb.com/bfs/subtitle/../private.json", "https://i0.hdslb.com/bfs/subtitle/1.json?access_key=fixture"] {
      XCTAssertThrowsError(try DownloadSubtitleTrack.safeURL(url), url)
    }
    XCTAssertThrowsError(try DownloadSubtitleTrack.parse(["subtitle": ["subtitles": [["id": 1, "lan": "zh-CN", "subtitle_url": "https://attacker.invalid/1"]]]]))
    XCTAssertThrowsError(try DownloadSubtitleTrack.parse([:]))
  }
  func testSubtitleBodyProducesActualCuesAndSRT() throws {
    let cues = try DownloadExport.parseSubtitleJSON(subtitleBodyFixture)
    XCTAssertEqual(cues, [DownloadSubtitleCue(start: 0.25, end: 1.5, text: "中文 < & >"),
      DownloadSubtitleCue(start: 2, end: 3.25, text: "Second line")])
    let srt = String(decoding: DownloadExport.subtitleSRT(cues), as: UTF8.self)
    XCTAssertTrue(srt.contains("00:00:00,250 --> 00:00:01,500\n中文 < & >"))
    XCTAssertThrowsError(try DownloadExport.parseSubtitleJSON(Data(#"{"body":[{"from":2,"to":1,"content":"bad"}]}"#.utf8)))
  }
  func testOptionalSubtitleChoiceKeepsLegacyOptionsCompatibleAndNeverPersistsURL() throws {
    let old = DownloadOptions(cid: 100, quality: 80, directory: "/fixture")
    let legacyJSON = try JSONEncoder().encode(old)
    let decoded = try JSONDecoder().decode(DownloadOptions.self, from: legacyJSON)
    XCTAssertNil(decoded.subtitleID); XCTAssertNil(decoded.subtitleLanguage)
    let selected = DownloadOptions(cid: 100, content: .subtitle, directory: "/fixture", subtitleID: "101", subtitleLanguage: "zh-CN")
    let data = try JSONEncoder().encode(selected)
    let restored = try JSONDecoder().decode(DownloadOptions.self, from: data)
    XCTAssertEqual(restored.subtitleID, "101"); XCTAssertEqual(restored.subtitleLanguage, "zh-CN")
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("hdslb"))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("subtitle_url"))
  }
  func testFixedSDKMetadataSignsWithoutTokenAndCDNBodyIsAnonymous() async throws {
    let transport = SubtitleFixtureTransport()
    let service = BiliService(transport: transport, credentials: SubtitleFixtureCredentials())
    try await service.restoreCookies()
    let expected = await service.authSnapshot()
    let tracks = try await service.downloadSubtitleTracks(aid: 100, cid: 200, expectedIdentity: expected)
    let cues = try await service.downloadSubtitleCues(track: tracks[0], expectedIdentity: expected)
    XCTAssertEqual(cues.count, 2)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    let metadata = try XCTUnwrap(requests.first)
    XCTAssertEqual(metadata.url?.host, "api.bilibili.com")
    XCTAssertEqual(metadata.url?.path, "/x/player/wbi/v2")
    let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: metadata.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(fields["aid"], "100"); XCTAssertEqual(fields["cid"], "200")
    XCTAssertEqual(fields["mobi_app"], "iphone"); XCTAssertEqual(fields["platform"], "ios")
    XCTAssertEqual(fields["appkey"], AppForm.appKey)
    XCTAssertNotNil(fields["sign"]); XCTAssertNil(fields["access_key"]); XCTAssertNil(fields["w_rid"])
    XCTAssertTrue(metadata.value(forHTTPHeaderField: "Cookie")?.contains("fixture-subtitle-cookie") == true)
    let cdn = try XCTUnwrap(requests.last)
    XCTAssertEqual(cdn.url?.scheme, "https"); XCTAssertEqual(cdn.url?.host, "i0.hdslb.com")
    XCTAssertNil(cdn.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(cdn.value(forHTTPHeaderField: "Authorization"))
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
  }
  func testInvalidIDsAndStaleIdentityCannotDispatch() async throws {
    let transport = SubtitleFixtureTransport()
    let service = BiliService(transport: transport, credentials: SubtitleFixtureCredentials())
    try await service.restoreCookies()
    let expected = await service.authSnapshot()
    do { _ = try await service.downloadSubtitleTracks(aid: 0, cid: 200, expectedIdentity: expected); XCTFail("Invalid aid") }
    catch BiliError.invalidResponse {}
    _ = await service.beginLogin()
    do { _ = try await service.downloadSubtitleCues(track: tracks()[0], expectedIdentity: expected); XCTFail("Stale identity") }
    catch is CancellationError {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
}
