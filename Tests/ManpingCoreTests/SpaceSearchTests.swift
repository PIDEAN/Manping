import Foundation
import XCTest
@testable import ManpingCore

private struct SpaceSearchStore: AuthCredentialStore {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ token: AppToken?) {}
  func clear() {}
}
private actor SpaceSearchTransport: AuthTransport {
  var requests: [URLRequest] = []
  let code: Int?
  let secondPageOnly: Bool
  let status: Int
  let cycle: Bool
  init(code: Int? = nil, secondPageOnly: Bool = false, status: Int = 200, cycle: Bool = false) {
    self.code = code; self.secondPageOnly = secondPageOnly; self.status = status; self.cycle = cycle
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let url = request.url!
    let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    var http = 200
    let body: Data
    if url.path == "/x/web-interface/nav" {
      body = Data(#"{"code":0,"data":{"wbi_img":{"img_url":"https://i.example/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i.example/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#.utf8)
    } else if cycle, url.path == "/x/v2/space/archive/cursor" {
      let next = fields["aid"] == "1" ? "2" : "1"
      body = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["count": 100, "has_next": 1,
        "item": [["param": next, "title": "Cycle", "cover": "https://fixture.invalid/cover/1"]]]])
    } else if url.path == "/x/space/wbi/arc/search", !secondPageOnly || fields["pn"] == "2", let code {
      http = status
      body = try JSONSerialization.data(withJSONObject: ["code": code, "data": [:]])
    } else { body = M3Fixture.uiResponse(path: url.path, parameters: fields)! }
    return AuthHTTPResponse(body: body, response: HTTPURLResponse(url: url, statusCode: http, httpVersion: nil, headerFields: nil)!)
  }
  func appRequests() -> [URLRequest] { requests.filter { $0.url!.path == "/x/v2/space/archive/cursor" } }
}
private actor PlaylistPageSource {
  var calls: [String?] = []
  let loop: Bool
  init(loop: Bool = false) { self.loop = loop }
  func fetch(_ cursor: String?) throws -> CursorPlaylistPage {
    calls.append(cursor)
    if cursor != nil && !loop { throw URLError(.networkConnectionLost) }
    let entry = LibraryEntry.video(Video(bvid: "", title: "Page", aid: Int64(calls.count)))
    return CursorPlaylistPage(page: LibraryPage(items: [entry], hasMore: true), nextCursor: "same")
  }
}
final class SpaceSearchTests: XCTestCase, @unchecked Sendable {
  func testFallbackWhitelistOnlyRiskControl() {
    XCTAssertTrue(BiliService.shouldFallbackSpace(BiliError.api(-352, "risk")))
    XCTAssertTrue(BiliService.shouldFallbackSpace(BiliError.http(412)))
    for error in ([BiliError.api(-101, "auth"), BiliError.http(401), BiliError.http(500), BiliError.invalidResponse("parse"), CancellationError(), AuthFailure.needsLogin] as [Error]) {
      XCTAssertFalse(BiliService.shouldFallbackSpace(error))
    }
  }
  func testFallbackChangesCapabilitiesResetsAndContinuesAppCursor() async throws {
    let transport = SpaceSearchTransport(code: -352, secondPageOnly: true)
    let service = BiliService(transport: transport, credentials: SpaceSearchStore())
    var query = SpaceArchiveQuery(mid: 10001, order: .stow, tid: 160)
    let first = try await service.spaceArchives(query: query)
    XCTAssertEqual(first.provider, .wbi); XCTAssertTrue(first.supportsPartitions)
    XCTAssertEqual(first.availableOrders, [.pubdate, .click, .stow]); XCTAssertNotNil(first.nextCursor)
    query.cursor = first.nextCursor
    let fallback = try await service.spaceArchives(query: query)
    XCTAssertEqual(fallback.provider, .appCursor); XCTAssertTrue(fallback.restarted)
    XCTAssertEqual(fallback.order, .pubdate); XCTAssertEqual(fallback.tid, 0)
    XCTAssertEqual(fallback.availableOrders, [.pubdate, .click]); XCTAssertFalse(fallback.supportsPartitions)
    XCTAssertEqual(fallback.videos.first?.id, first.videos.first?.id)
    query.cursor = fallback.nextCursor
    let second = try await service.spaceArchives(query: query)
    XCTAssertEqual(second.provider, .appCursor); XCTAssertFalse(second.restarted)
    XCTAssertEqual(second.videos.count, 10); XCTAssertNil(second.nextCursor)
    let requests = await transport.appRequests()
    let fields = requests.map { Dictionary(uniqueKeysWithValues: (URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) }
    XCTAssertEqual(fields.map { $0["aid"] }, ["0", "818"])
    XCTAssertNotNil(fields[0]["sign"]); XCTAssertNil(fields[0]["access_key"])
  }
  func testAppAidCycleProducesRepeatedOpaqueCursorAndCollectionStops() async throws {
    let transport = SpaceSearchTransport(cycle: true)
    let service = BiliService(transport: transport, credentials: SpaceSearchStore())
    let first = try await service.spaceArchives(query: SpaceArchiveQuery(mid: 123, provider: .appCursor))
    let second = try await service.spaceArchives(query: SpaceArchiveQuery(mid: 123, cursor: first.nextCursor))
    let third = try await service.spaceArchives(query: SpaceArchiveQuery(mid: 123, cursor: second.nextCursor))
    XCTAssertEqual(first.nextCursor, third.nextCursor)
    let result = try await CursorPlaylistCollector.collect { cursor in
      let page = try await service.spaceArchives(query: SpaceArchiveQuery(mid: 123, cursor: cursor, provider: cursor == nil ? .appCursor : nil))
      return CursorPlaylistPage(page: LibraryPage(items: page.videos, hasMore: page.nextCursor != nil), nextCursor: page.nextCursor)
    }
    XCTAssertFalse(result.complete); XCTAssertEqual(result.videos.count, 2)
  }
  func testHTTP412FallbackAndAuthenticationErrorPropagates() async throws {
    let risk = SpaceSearchTransport(code: -1, status: 412)
    let page = try await BiliService(transport: risk, credentials: SpaceSearchStore()).spaceArchives(query: SpaceArchiveQuery(mid: 123))
    XCTAssertEqual(page.provider, .appCursor)
    let auth = SpaceSearchTransport(code: -101)
    do {
      _ = try await BiliService(transport: auth, credentials: SpaceSearchStore()).spaceArchives(query: SpaceArchiveQuery(mid: 123))
      XCTFail("Must preserve authentication error")
    } catch BiliError.api(-101, _) {}
    let app = await auth.appRequests(); XCTAssertTrue(app.isEmpty)
  }
  func testCursorBindsKeywordSortPartitionAndProvider() async throws {
    let service = BiliService(transport: SpaceSearchTransport(), credentials: SpaceSearchStore())
    let first = try await service.spaceArchives(query: SpaceArchiveQuery(mid: 123))
    for query in [SpaceArchiveQuery(mid: 456, cursor: first.nextCursor),
      SpaceArchiveQuery(mid: 123, order: .click, cursor: first.nextCursor),
      SpaceArchiveQuery(mid: 123, tid: 160, cursor: first.nextCursor),
      SpaceArchiveQuery(mid: 123, keyword: "new", cursor: first.nextCursor),
      SpaceArchiveQuery(mid: 123, cursor: first.nextCursor, provider: .appCursor)] {
      do { _ = try await service.spaceArchives(query: query); XCTFail("Changed query must reject cursor") }
      catch BiliError.invalidResponse {}
    }
  }
  func testKeywordUsesInjectedGRPCAndReturnsActualCapabilities() async throws {
    let service = BiliService(transport: SpaceSearchTransport(), credentials: SpaceSearchStore())
    let result = try await service.spaceArchives(query: SpaceArchiveQuery(mid: 123, order: .stow, tid: 160, keyword: "test")) { mid, keyword, page in
      XCTAssertEqual(mid, 123); XCTAssertEqual(keyword, "test"); XCTAssertEqual(page, 1)
      return LibraryPage(items: [], hasMore: false, total: 0)
    }
    XCTAssertEqual(result.provider, .grpc); XCTAssertEqual(result.availableOrders, [.pubdate]); XCTAssertEqual(result.tid, 0)
  }
  func testCollectorSecondPageFailureKeepsPartialVideos() async throws {
    let source = PlaylistPageSource()
    let result = try await CursorPlaylistCollector.collect { try await source.fetch($0) }
    XCTAssertFalse(result.complete); XCTAssertEqual(result.videos.count, 1); XCTAssertNotNil(result.notice)
  }
  func testCollectorStopsCursorCycleBeforeThirdRequest() async throws {
    let source = PlaylistPageSource(loop: true)
    let result = try await CursorPlaylistCollector.collect { try await source.fetch($0) }
    XCTAssertFalse(result.complete); XCTAssertEqual(result.videos.count, 2)
    let calls = await source.calls; XCTAssertEqual(calls.count, 2)
  }
  func testCollectorProviderRestartReplacesPreviouslyGatheredVideos() async throws {
    let result = try await CursorPlaylistCollector.collect { cursor in
      let index = cursor == nil ? 1 : cursor == "first" ? 2 : 3
      let entry = LibraryEntry.video(Video(bvid: "", title: "Page", aid: Int64(index)))
      return CursorPlaylistPage(page: LibraryPage(items: [entry], hasMore: index < 3),
        nextCursor: index == 1 ? "first" : index == 2 ? "second" : nil, restarted: index == 2)
    }
    XCTAssertTrue(result.complete); XCTAssertEqual(result.videos.map(\.aid), [2, 3])
  }
  func testCollectorAuthenticationFailurePropagates() async throws {
    do { _ = try await CursorPlaylistCollector.collect { _ in throw BiliError.api(-101, "auth") }; XCTFail("auth") }
    catch BiliError.api(-101, _) {}
    do { _ = try await CursorPlaylistCollector.collect { _ in throw AuthFailure.needsLogin }; XCTFail("auth") }
    catch AuthFailure.needsLogin {}
  }
  func testCollectorCancellationPropagates() async throws {
    do { _ = try await CursorPlaylistCollector.collect { _ in throw CancellationError() }; XCTFail("cancel") }
    catch is CancellationError {}
  }
  func testSeasonSeriesKeepDistinctIDsAndServerSort() async throws {
    let transport = SpaceSearchTransport()
    let service = BiliService(transport: transport, credentials: SpaceSearchStore())
    let page = try await service.spaceCollections(mid: 123)
    XCTAssertEqual(page.items.map(\.id), ["season:22", "series:22"]); XCTAssertFalse(page.hasMore)
    for item in page.items {
      let first = try await service.spaceCollectionContents(item, descending: true)
      let second = try await service.spaceCollectionContents(item, descending: true, page: 2)
      XCTAssertEqual(first.items.count, 30); XCTAssertEqual(second.items.count, 10)
      XCTAssertNotEqual(first.items.first?.id, second.items.first?.id)
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.contains { $0.url!.absoluteString.contains("sort_reverse=true") })
    XCTAssertTrue(requests.contains { $0.url!.absoluteString.contains("sort=desc") })
    XCTAssertTrue(requests.allSatisfy { !$0.url!.absoluteString.contains("access_key") })
  }
  func testOptionalProfileStatsAndOfficialFields() throws {
    let empty = try BiliService.libraryUser(["mid": 123, "name": "Empty"])
    XCTAssertNil(empty.followers); XCTAssertNil(empty.following); XCTAssertNil(empty.videos); XCTAssertNil(empty.likes); XCTAssertNil(empty.plays)
    let profile = try BiliService.libraryUser(["mid": 123, "name": "Profile", "Official": ["role": 2, "type": 0, "title": "Title", "desc": "Verified"]])
    XCTAssertEqual(profile.officialRole, 2); XCTAssertEqual(profile.officialDescription, "Verified")
  }
  func testSearchAuthorFallbackOrderAndProtocolRelativeAvatar() throws {
    let base: [String: Any] = ["aid": 1, "title": "Video", "mid": 9, "upic": "//fixture.invalid/avatar/1"]
    XCTAssertEqual(try BiliService.libraryVideo(base).authorID, 9)
    XCTAssertEqual(try BiliService.libraryVideo(base).avatar?.scheme, "https")
    var item = base; item["upper"] = ["mid": 8]; XCTAssertEqual(try BiliService.libraryVideo(item).authorID, 8)
    item["owner"] = ["mid": 7]; XCTAssertEqual(try BiliService.libraryVideo(item).authorID, 7)
  }
  func testSearchUsersKeepsFullFieldsAndUsesOwnSort() async throws {
    let transport = SpaceSearchTransport()
    let service = BiliService(transport: transport, credentials: SpaceSearchStore())
    let result = try await service.searchUsers(term: "fixture", order: .followers)
    let user = try XCTUnwrap(result.items.first)
    XCTAssertEqual(user.level, 6); XCTAssertTrue(user.isUpUser); XCTAssertEqual(user.followers, 12000)
    XCTAssertNotNil(user.officialType); XCTAssertEqual(user.roomID, 88); XCTAssertEqual(user.avatar?.scheme, "https")
    let requests = await transport.requests
    let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(fields["order"], "fans"); XCTAssertEqual(fields["order_sort"], "0")
  }
}
