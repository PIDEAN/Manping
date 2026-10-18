import Foundation
import XCTest
@testable import ManpingCore

private final class PGCStore: AuthCredentialStore, @unchecked Sendable {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { AppToken(mid: 123, accessToken: "fixture-pgc", refreshToken: "fixture-refresh", expiresAt: 9_999_999_999) }
  func saveToken(_ token: AppToken?) {}
  func clear() {}
}
private let pgcDetailFixture = #"{"season_id":10,"title":"Fixture series","type":1,"cover":"https://fixture.invalid/cover/1","evaluate":"Description","alias":"Alias","rating":{"score":8.5},"stat":{"views":1000,"likes":100},"user_status":{"follow":1,"progress":{"last_ep_id":112,"last_time":2}},"modules":[{"style":"positive","data":{"episodes":[{"id":111,"aid":789,"cid":456,"ep_index":1,"duration":5000,"long_title":"First","badge":"会员","report":{"epid":111,"season_id":10,"season_type":1},"stat":{"likes":25,"coins":12}},{"id":112,"aid":790,"cid":457,"ep_index":2,"duration":6000,"long_title":"Second","report":{"epid":112,"season_id":10,"season_type":1}}]}},{"style":"season","data":{"seasons":[{"season_id":10,"title":"Season 1"},{"season_id":11,"title":"Season 2"}]}},{"style":"section","title":"Extras","data":{"episodes":[{"id":113,"aid":791,"cid":458,"duration":2000,"long_title":"Extra","report":{"epid":113,"season_id":10,"season_type":1}}]}}],"dialog":{"msg":"Fixture warning"}}"#
// Minimal structure captured from the anonymous signed public endpoint on 2026-10-13;
// identifiers, titles and URLs are synthetic. Page 0 returned {"code":0,"data":{},"message":"success"}.
private let pgcIndexFixture = #"{"code":0,"data":{"has_next":1,"list":[{"badge":"会员","cover":"https://fixture.invalid/cover/1","first_ep":{"cover":"https://fixture.invalid/cover/2","ep_id":111},"index_show":"更新至第12话","score":"8.5","season_id":10,"subTitle":"Fixture subtitle","title":"Index"}],"num":1,"size":30,"total":1845},"message":"success"}"#
// Public type 2/3 response structure captured on 2026-10-13; identifiers and titles are synthetic.
private let pgcTimelineFixtures: [String: String] = [
  "2": #"{"code":0,"message":"success","result":{"current_time_text":"Fixture timeline","navigation_title":"Fixture timeline","data":[{"date_ts":1791302400,"date":"10-7","episodes":[]},{"date_ts":1791388800,"date":"10-8","episodes":[]},{"date_ts":1791475200,"date":"10-9","episodes":[]},{"date_ts":1791561600,"date":"10-10","episodes":[{"season_id":10,"title":"Timeline 10","episode_id":0,"published":0,"pub_time":"19:30","pub_index":"","pub_index_show":"本周停更","pub_ts":1791631800}]},{"date_ts":1791648000,"date":"10-11","episodes":[]},{"date_ts":1791734400,"date":"10-12","episodes":[]},{"date_ts":1791820800,"date":"10-13","episodes":[]},{"date_ts":1791907200,"date":"10-14","episodes":[]},{"date_ts":1791993600,"date":"10-15","episodes":[]},{"date_ts":1792080000,"date":"10-16","episodes":[]},{"date_ts":1792166400,"date":"10-17","episodes":[]},{"date_ts":1792252800,"date":"10-18","episodes":[]},{"date_ts":1792339200,"date":"10-19","episodes":[]}]}}"#,
  "3": #"{"code":0,"message":"success","result":{"current_time_text":"Fixture timeline","navigation_title":"Fixture timeline","data":[{"date_ts":1791302400,"date":"10-7","episodes":[{"season_id":11,"title":"Timeline 11","episode_id":111,"published":1,"pub_time":"10:00","pub_index":"第71话","pub_index_show":"第71话","pub_ts":1791338400}]},{"date_ts":1791388800,"date":"10-8","episodes":[{"season_id":12,"title":"Timeline 12","episode_id":112,"published":1,"pub_time":"19:00","pub_index":"第1089话","pub_index_show":"第1089话","pub_ts":1791457200}]},{"date_ts":1791475200,"date":"10-9","episodes":[{"season_id":13,"title":"Timeline 13","episode_id":113,"published":1,"pub_time":"10:00","pub_index":"第11话","pub_index_show":"第11话","pub_ts":1791511200},{"season_id":14,"title":"Timeline 14","episode_id":114,"published":1,"pub_time":"11:00","pub_index":"第10话","pub_index_show":"第10话","pub_ts":1791514800},{"season_id":15,"title":"Timeline 15","episode_id":115,"published":1,"pub_time":"18:00","pub_index":"第75话","pub_index_show":"第75话","pub_ts":1791540000},{"season_id":16,"title":"Timeline 16","episode_id":116,"published":1,"pub_time":"23:00","pub_index":"第13话","pub_index_show":"第13话","pub_ts":1791558000}]},{"date_ts":1791561600,"date":"10-10","episodes":[{"season_id":17,"title":"Timeline 17","episode_id":117,"published":1,"pub_time":"09:00","pub_index":"第26话","pub_index_show":"第26话","pub_ts":1791594000},{"season_id":18,"title":"Timeline 18","episode_id":118,"published":1,"pub_time":"10:00","pub_index":"第17话","pub_index_show":"第17话","pub_ts":1791597600},{"season_id":19,"title":"Timeline 19","episode_id":119,"published":1,"pub_time":"11:00","pub_index":"第195话","pub_index_show":"第195话","pub_ts":1791601200},{"season_id":12,"title":"Timeline 12","episode_id":120,"published":1,"pub_time":"19:00","pub_index":"第1090话","pub_index_show":"第1090话","pub_ts":1791630000}]},{"date_ts":1791648000,"date":"10-11","episodes":[{"season_id":20,"title":"Timeline 20","episode_id":121,"published":1,"pub_time":"10:00","pub_index":"第13话","pub_index_show":"第13话","pub_ts":1791684000},{"season_id":21,"title":"Timeline 21","episode_id":122,"published":1,"pub_time":"11:00","pub_index":"第104话","pub_index_show":"第104话","pub_ts":1791687600}]},{"date_ts":1791734400,"date":"10-12","episodes":[{"season_id":17,"title":"Timeline 17","episode_id":123,"published":1,"pub_time":"09:00","pub_index":"第27话","pub_index_show":"第27话","pub_ts":1791766800}]},{"date_ts":1791820800,"date":"10-13","episodes":[{"season_id":12,"title":"Timeline 12","episode_id":124,"published":1,"pub_time":"19:00","pub_index":"第1091话","pub_index_show":"第1091话","pub_ts":1791889200}]},{"date_ts":1791907200,"date":"10-14","episodes":[{"season_id":11,"title":"Timeline 11","episode_id":125,"published":0,"pub_time":"10:00","pub_index":"第72话","pub_index_show":"第72话","pub_ts":1791943200}]},{"date_ts":1791993600,"date":"10-15","episodes":[{"season_id":12,"title":"Timeline 12","episode_id":126,"published":0,"pub_time":"19:00","pub_index":"第1092话","pub_index_show":"第1092话","pub_ts":1792062000}]},{"date_ts":1792080000,"date":"10-16","episodes":[{"season_id":13,"title":"Timeline 13","episode_id":127,"published":0,"pub_time":"10:00","pub_index":"第12话","pub_index_show":"第12话","pub_ts":1792116000},{"season_id":14,"title":"Timeline 14","episode_id":128,"published":0,"pub_time":"11:00","pub_index":"第11话","pub_index_show":"第11话","pub_ts":1792119600},{"season_id":15,"title":"Timeline 15","episode_id":129,"published":0,"pub_time":"18:00","pub_index":"第76话","pub_index_show":"第76话","pub_ts":1792144800},{"season_id":16,"title":"Timeline 16","episode_id":130,"published":0,"pub_time":"23:00","pub_index":"第14话","pub_index_show":"第14话","pub_ts":1792162800}]},{"date_ts":1792166400,"date":"10-17","episodes":[{"season_id":17,"title":"Timeline 17","episode_id":131,"published":0,"pub_time":"09:00","pub_index":"第28话","pub_index_show":"第28话","pub_ts":1792198800},{"season_id":19,"title":"Timeline 19","episode_id":132,"published":0,"pub_time":"11:00","pub_index":"第196话","pub_index_show":"第196话","pub_ts":1792206000},{"season_id":12,"title":"Timeline 12","episode_id":133,"published":0,"pub_time":"19:00","pub_index":"第1093话","pub_index_show":"第1093话","pub_ts":1792234800}]},{"date_ts":1792252800,"date":"10-18","episodes":[{"season_id":20,"title":"Timeline 20","episode_id":134,"published":0,"pub_time":"10:00","pub_index":"第14话","pub_index_show":"第14话","pub_ts":1792288800},{"season_id":21,"title":"Timeline 21","episode_id":135,"published":0,"pub_time":"11:00","pub_index":"第105话","pub_index_show":"第105话","pub_ts":1792292400}]},{"date_ts":1792339200,"date":"10-19","episodes":[]}]}}"#
]
private actor PGCTransport: AuthTransport {
  var requests: [URLRequest] = []
  let pause: Bool
  private var release: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  init(pause: Bool = false) { self.pause = pause }
  func entered() async { if !requests.isEmpty { return }; await withCheckedContinuation { observers.append($0) } }
  func resume() { release?.resume(); release = nil }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request); observers.forEach { $0.resume() }; observers = []
    if pause { await withCheckedContinuation { release = $0 } }
    let url = request.url!
    let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    let data: Any; let envelope: String
    switch url.path {
    case "/pgc/app/timeline":
      envelope = "result"
      let captured = try JSONSerialization.jsonObject(with: Data(pgcTimelineFixtures[query["type"] ?? ""]!.utf8)) as! [String: Any]
      data = captured["result"]!
    case "/pgc/season/index/condition":
      envelope = "data"; data = ["order": [["field": "3", "name": "追番数"]],
        "filter": [["field": "year", "name": "年份", "values": [["keyword": "-1", "name": "全部年份"], ["keyword": "[2026,2027)", "name": "2026"]]]]]
    case "/pgc/season/index/result":
      envelope = "data"
      let captured = try JSONSerialization.jsonObject(with: Data(pgcIndexFixture.utf8)) as! [String: Any]
      var page = captured["data"] as! [String: Any]
      page["has_next"] = query["page"] == "1" ? 1 : 0
      page["num"] = Int(query["page"] ?? "") ?? 0
      data = query["page"] == "0" ? [:] : page
    case "/pgc/view/v2/app/season": envelope = "data"; data = try JSONSerialization.jsonObject(with: Data(pgcDetailFixture.utf8))
    case "/pgc/player/web/playurl":
      envelope = "result"; data = ["accept_quality": [80], "accept_description": ["1080P"], "dash": ["duration": 5,
        "video": [["id": 80, "codecs": "avc1.640028", "base_url": "https://fixture.invalid/video", "bandwidth": 1000]],
        "audio": [["id": 30280, "codecs": "mp4a.40.2", "base_url": "https://fixture.invalid/audio", "bandwidth": 100]]]]
    default: throw URLError(.unsupportedURL)
    }
    return AuthHTTPResponse(body: try JSONSerialization.data(withJSONObject: ["code": 0, envelope: data]),
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
final class M5PGCTests: XCTestCase, @unchecked Sendable {
  private func service(_ transport: PGCTransport) async throws -> BiliService {
    let service = BiliService(transport: transport, credentials: PGCStore(), now: { Date(timeIntervalSince1970: 1000) })
    try await service.restoreCookies(); return service
  }
  private func fields(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
  }
  func testDetailModulesKeepEpisodeIDsStatisticsAndHistorySelection() throws {
    let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pgcDetailFixture.utf8)) as? [String: Any])
    let details = try PGCDetails.parse(raw)
    XCTAssertEqual(details.episodes.map(\.id), [111, 112]); XCTAssertEqual(details.episodes.first?.duration, 5)
    XCTAssertEqual(details.episodes.first?.aid, 789); XCTAssertEqual(details.episodes.first?.cid, 456)
    XCTAssertEqual(details.episodes.first?.stats.likes, 25); XCTAssertEqual(details.episodes.first?.stats.coins, 12)
    XCTAssertNil(details.episodes.last?.stats.likes)
    XCTAssertEqual(details.initialEpisode()?.id, 112); XCTAssertEqual(details.initialEpisode(requested: 111)?.id, 111)
    XCTAssertEqual(details.initialEpisode(restoreHistory: false)?.id, 111)
    XCTAssertEqual(details.progressSeconds, 2); XCTAssertEqual(details.seasons.count, 2); XCTAssertEqual(details.extras.first?.episodes.first?.id, 113)
    XCTAssertEqual(details.warning, "Fixture warning"); XCTAssertEqual(details.season.score, 8.5)
  }
  func testTimelineMergesBothTypesByDayAndPublicationTime() async throws {
    let transport = PGCTransport(); let service = try await service(transport); let expected = await service.authSnapshot()
    let bangumi = try await service.pgcTimeline(bangumi: true, expectedIdentity: expected)
    let domestic = try await service.pgcTimeline(bangumi: false, expectedIdentity: expected)
    let merged = PGCTimelineDay.merged([bangumi, domestic])
    XCTAssertEqual(bangumi.count, 13); XCTAssertEqual(domestic.count, 13)
    XCTAssertEqual(bangumi.flatMap(\.seasons).count, 1); XCTAssertEqual(domestic.flatMap(\.seasons).count, 25)
    XCTAssertEqual(merged.count, 13)
    XCTAssertEqual(merged.map { $0.seasons.count }, [1, 1, 4, 5, 2, 1, 1, 1, 1, 4, 3, 2, 0])
    XCTAssertEqual(merged.flatMap(\.seasons).count, 26)
    XCTAssertNil(bangumi.flatMap(\.seasons).first?.episodeID)
    XCTAssertEqual(bangumi.flatMap(\.seasons).first?.subtitle, "19:30 · 本周停更 · 待发布")
    XCTAssertTrue(merged.allSatisfy { day in
      let times = day.seasons.compactMap(\.publishedAt)
      return times == times.sorted()
    })
    XCTAssertEqual(PGCTimelineDay.merged([bangumi, domestic, domestic]), merged)
    // Different date ranges must still retain every returned day and season.
    let partial = PGCTimelineDay.merged([Array(bangumi.dropLast()), Array(domestic.dropFirst())])
    XCTAssertEqual(partial.count, 13); XCTAssertEqual(partial.first?.seasons.count, 0)
    XCTAssertEqual(partial.flatMap(\.seasons).count, 25)
    let requests = await transport.requests
    XCTAssertEqual(requests.map { fields($0)["type"] }, ["2", "3"])
    XCTAssertTrue(requests.allSatisfy { fields($0)["filter_type"] == "0" && $0.value(forHTTPHeaderField: "Cookie") == nil })
  }
  func testIndexUsesLiveResponseShapeAndOneBasedPaginationForEveryCategory() async throws {
    let transport = PGCTransport(); let service = try await service(transport); let expected = await service.authSnapshot()
    for category in PGCCategory.allCases {
      let filters = try await service.pgcFilters(category: category, expectedIdentity: expected)
      XCTAssertEqual(filters.first?.id, "order")
      let selection = Dictionary(uniqueKeysWithValues: filters.map { ($0.id, $0.choices[0].id) })
      let first = try await service.pgcIndex(category: category, filters: filters, selection: selection, expectedIdentity: expected)
      XCTAssertTrue(first.hasMore)
      XCTAssertEqual(first.items.first?.subtitle, "Fixture subtitle"); XCTAssertEqual(first.items.first?.score, 8.5)
      XCTAssertEqual(first.total, 1845)
      let next = try await service.pgcIndex(category: category, filters: filters, selection: selection, page: 2, expectedIdentity: expected)
      XCTAssertFalse(next.hasMore); XCTAssertEqual(next.items.first?.episodeID, 111)
    }
    let requests = await transport.requests
    let index = requests.filter { $0.url!.path.hasSuffix("/result") }
    XCTAssertEqual(index.map { fields($0)["page"] }, ["1", "2", "1", "2", "1", "2", "1", "2"])
    XCTAssertEqual(index.map { fields($0)["pagesize"] }, Array(repeating: "30", count: 8))
    XCTAssertEqual(fields(index[0])["season_type"], "1")
    XCTAssertEqual([index[2], index[4], index[6]].map { fields($0)["index_type"] }, ["2", "5", "3"])
  }
  func testIndexRejectsZeroPageBeforeSending() async throws {
    let transport = PGCTransport(); let service = try await service(transport); let expected = await service.authSnapshot()
    do {
      _ = try await service.pgcIndex(category: .anime, filters: [], selection: [:], page: 0, expectedIdentity: expected)
      XCTFail("Page zero is not supported by the live endpoint")
    } catch BiliError.invalidResponse(let message) { XCTAssertEqual(message, "Invalid PGC index page") }
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
  func testNativePGCPlaybackUsesWebSignAndExactEpisodeParameters() async throws {
    let transport = PGCTransport(); let service = try await service(transport); let expected = await service.authSnapshot()
    let details = try await service.pgcDetails(PGCSelection(seasonID: 10, episodeID: 111), expectedIdentity: expected)
    let manifest = try await service.pgcPlayback(try XCTUnwrap(details.episodes.first), expectedIdentity: expected)
    XCTAssertEqual(manifest.video.first?.quality, 80)
    let requests = await transport.requests
    XCTAssertEqual(fields(requests[0])["autoplay"], "0"); XCTAssertEqual(fields(requests[0])["ep_id"], "111")
    let request = requests[1]; let form = fields(request)
    XCTAssertEqual(form["appkey"], "aa1e74ee4874176e"); XCTAssertEqual(form["platform"], "web"); XCTAssertEqual(form["ts"], "1000000")
    XCTAssertNil(form["mobi_app"]); XCTAssertEqual(form["access_key"], "fixture-pgc")
    XCTAssertEqual(form["cid"], "456"); XCTAssertEqual(form["ep_id"], "111"); XCTAssertEqual(form["season_type"], "1")
    XCTAssertEqual(form["fnval"], "4048"); XCTAssertEqual(form["module"], "bangumi")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    var signed = form; signed["sign"] = nil
    XCTAssertEqual(form["sign"], AppForm.signature(signed, secret: "54e6a9a31b911cd5fc0daa66ebf94bc4"))
  }
  func testExpectedIdentityRejectsLateDetailAndOldPlaybackBeforeSend() async throws {
    let transport = PGCTransport(pause: true); let service = try await service(transport); let expected = await service.authSnapshot()
    let pending = Task { try await service.pgcDetails(PGCSelection(seasonID: 10), expectedIdentity: expected) }
    await transport.entered(); _ = await service.beginLogin(); await transport.resume()
    do { _ = try await pending.value; XCTFail("Old detail response") } catch is CancellationError {}
    let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pgcDetailFixture.utf8)) as? [String: Any])
    let episode = try XCTUnwrap(PGCDetails.parse(raw).episodes.first)
    do { _ = try await service.pgcPlayback(episode, expectedIdentity: expected); XCTFail("Old playback context") } catch is CancellationError {}
    let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
  }
  func testFilterCannotSupplyAuthorizationFieldsAndMissingCIDDoesNotSend() async throws {
    let transport = PGCTransport(); let service = try await service(transport); let expected = await service.authSnapshot()
    let malicious = PGCFilter(id: "access_key", title: "Invalid", choices: [PGCCondition(id: "bad", title: "Bad")])
    do { _ = try await service.pgcIndex(category: .anime, filters: [malicious], selection: ["access_key": "bad"], expectedIdentity: expected); XCTFail("Reserved field") } catch {}
    var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pgcDetailFixture.utf8)) as? [String: Any])
    var modules = raw["modules"] as! [[String: Any]]; var data = modules[0]["data"] as! [String: Any]
    var episodes = data["episodes"] as! [[String: Any]]; episodes[0]["cid"] = 0; data["episodes"] = episodes; modules[0]["data"] = data; raw["modules"] = modules
    let episode = try XCTUnwrap(PGCDetails.parse(raw).episodes.first)
    do { _ = try await service.pgcPlayback(episode, expectedIdentity: expected); XCTFail("Missing media CID") } catch {}
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
}
