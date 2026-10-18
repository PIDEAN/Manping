#if DEBUG
import Foundation
import XCTest
@testable import ManpingCore

private final class LiveDiscoveryStore: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  init(authenticated: Bool) {
    token = authenticated ? AppToken(mid: 123, accessToken: "live-fixture-token",
      refreshToken: "live-fixture-refresh", expiresAt: 9_999_999_999) : nil
  }
  func load() -> [HTTPCookie] {
    ["SESSDATA": "live-fixture-session", "bili_jct": "live-fixture-csrf"].compactMap { name, value in
      HTTPCookie(properties: [.name: name, .value: value, .domain: ".bilibili.com", .path: "/",
        .secure: "TRUE", .expires: Date(timeIntervalSince1970: 9_999_999_999)])
    }
  }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { lock.withLock { token } }
  func saveToken(_ value: AppToken?) { lock.withLock { token = value } }
  func clear() { lock.withLock { token = nil } }
}
private func liveFields(_ request: URLRequest) -> [String: String] {
  Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}
private actor LiveDiscoveryTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  let override: Data?
  private var held: Bool
  private var waiter: CheckedContinuation<Void, Never>?
  private var pending: CheckedContinuation<Void, Never>?
  init(override: Data? = nil, held: Bool = false) { self.override = override; self.held = held }
  func waitForRequest() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() { held = false; pending?.resume(); pending = nil }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request); waiter?.resume(); waiter = nil
    if held { await withCheckedContinuation { pending = $0 } }
    let url = request.url!
    guard let body = override ?? M5LiveFixture.response(path: url.path, parameters: liveFields(request)) else {
      throw URLError(.badServerResponse)
    }
    return AuthHTTPResponse(body: body,
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private func liveService(_ transport: LiveDiscoveryTransport, authenticated: Bool = false) async throws -> BiliService {
  let service = BiliService(transport: transport, credentials: LiveDiscoveryStore(authenticated: authenticated),
    now: { Date(timeIntervalSince1970: 1000) })
  try await service.restoreCookies(); return service
}

final class BiliLiveDiscoveryTests: XCTestCase, @unchecked Sendable {
  func testAreasUseOptionalAppTokenAndNeverCookies() async throws {
    for authenticated in [false, true] {
      let transport = LiveDiscoveryTransport(); let service = try await liveService(transport, authenticated: authenticated)
      let areas = try await service.livePartitions()
      XCTAssertEqual(areas.count, 6); XCTAssertEqual(areas.first?.children.count, 3)
      XCTAssertEqual(areas.first?.children.first?.parentID, 1)
      XCTAssertEqual(areas.first?.children.first?.cover?.host, "fixture.invalid")
      let requests = await transport.requests; let request = try XCTUnwrap(requests.first)
      XCTAssertEqual(request.url?.host, "api.live.bilibili.com")
      XCTAssertEqual(request.url?.path, "/xlive/app-interface/v2/index/getAreaList")
      XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      let fields = liveFields(request)
      XCTAssertEqual(fields["appkey"], "27eb53fc9058f8c3"); XCTAssertNotNil(fields["sign"])
      XCTAssertEqual(fields["access_key"], authenticated ? "live-fixture-token" : nil)
      XCTAssertNil(fields["w_rid"]); XCTAssertNil(fields["csrf"])
    }
  }
  func testRoomsStartAtHTTPPageOneThenUseServerSortType() async throws {
    let transport = LiveDiscoveryTransport(); let service = try await liveService(transport, authenticated: true)
    let area = LivePartition(id: 101, title: "Fixture area", parentID: 1)
    let first = try await service.livePartitionRooms(area: area)
    XCTAssertEqual(first.rooms.count, 12); XCTAssertTrue(first.hasMore); XCTAssertEqual(first.nextPage, 2)
    XCTAssertEqual(first.tags.map(\.sortType), ["", "online", "live_time"])
    XCTAssertEqual(first.rooms.first?.author, "音乐现场")
    XCTAssertEqual(first.rooms.first?.avatar?.host, "fixture.invalid")
    XCTAssertEqual(first.rooms.first?.viewers, 8600)
    let second = try await service.livePartitionRooms(area: area, tag: first.tags[1], page: first.nextPage)
    XCTAssertEqual(second.rooms.first?.id, 5012); XCTAssertEqual(second.nextPage, 3)
    XCTAssertTrue(second.tags.isEmpty)
    let requests = await transport.requests; let fields = liveFields(requests[0])
    XCTAssertEqual(requests[0].url?.path, "/xlive/app-interface/v2/second/getList")
    XCTAssertEqual(fields["page"], "1"); XCTAssertEqual(fields["page_size"], "40")
    XCTAssertEqual(fields["area_id"], "101"); XCTAssertEqual(fields["parent_area_id"], "1")
    XCTAssertEqual(fields["device"], "phone"); XCTAssertNil(fields["sort_type"])
    XCTAssertEqual(liveFields(requests[1])["page"], "2")
    XCTAssertEqual(liveFields(requests[1])["sort_type"], "online")
    XCTAssertEqual(liveFields(requests[1])["access_key"], "live-fixture-token")
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
  }
  func testFeedSeparatesFollowAndSmallCardsWithAnonymousLoginEvent() async throws {
    for authenticated in [false, true] {
      let transport = LiveDiscoveryTransport(); let service = try await liveService(transport, authenticated: authenticated)
      let batch = try await service.liveFeed()
      XCTAssertEqual(batch.rooms.count, 12); XCTAssertEqual(batch.following.count, authenticated ? 3 : 0)
      XCTAssertEqual(batch.rooms.first?.id, 5000); XCTAssertEqual(batch.rooms.first?.viewers, 12_000)
      XCTAssertEqual(batch.rooms[1].viewers, 8600); XCTAssertEqual(batch.rooms.first?.subtitle, "陪伴的声音")
      XCTAssertNil(batch.rooms.first?.avatar)
      XCTAssertEqual(batch.following.first?.avatar?.host, authenticated ? "fixture.invalid" : nil)
      let requests = await transport.requests; let fields = liveFields(requests[0])
      XCTAssertEqual(requests[0].url?.path, "/xlive/app-interface/v2/index/feed")
      XCTAssertEqual(fields["page"], "1"); XCTAssertEqual(fields["relation_page"], "1")
      XCTAssertEqual(fields["scale"], "2"); XCTAssertEqual(fields["device"], "phone")
      XCTAssertEqual(fields["login_event"], authenticated ? "2" : "1")
      XCTAssertEqual(fields["access_key"], authenticated ? "live-fixture-token" : nil)
      XCTAssertNotNil(fields["sign"]); XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
    }
  }
  func testEmptyPagesEndPagingWithoutFabricatedCursor() async throws {
    let transport = LiveDiscoveryTransport(); let service = try await liveService(transport)
    let area = LivePartition(id: 101, title: "Fixture area", parentID: 1)
    let rooms = try await service.livePartitionRooms(area: area, page: 3)
    let feed = try await service.liveFeed(page: 3)
    XCTAssertTrue(rooms.rooms.isEmpty); XCTAssertFalse(rooms.hasMore); XCTAssertEqual(rooms.nextPage, 4)
    XCTAssertTrue(feed.rooms.isEmpty); XCTAssertFalse(feed.hasMore); XCTAssertEqual(feed.nextPage, 4)
  }
  func testEmptyTagMetadataAndOptionalRoomFieldsAreSafe() async throws {
    let data = Data(#"{"code":0,"data":{"list":[{"roomid":"99","title":"Fixture room"}],"new_tags":null}}"#.utf8)
    let service = try await liveService(LiveDiscoveryTransport(override: data))
    let rooms = try await service.livePartitionRooms(area: LivePartition(id: 0, title: "All", parentID: 1))
    XCTAssertEqual(rooms.rooms.first?.id, 99); XCTAssertTrue(rooms.tags.isEmpty)
    XCTAssertNil(rooms.rooms.first?.viewers); XCTAssertNil(rooms.rooms.first?.avatar)
    XCTAssertEqual(rooms.rooms.first?.webURL?.absoluteString, "https://live.bilibili.com/99")
  }
  func testInvalidPagesAndAreasNeverSend() async throws {
    let transport = LiveDiscoveryTransport(); let service = try await liveService(transport)
    let operations: [@Sendable () async throws -> Void] = [
      { _ = try await service.liveFeed(page: 0) },
      { _ = try await service.liveFeed(page: 1_000_001) },
      { _ = try await service.livePartitionRooms(area: LivePartition(id: -1, title: "Invalid", parentID: 1)) },
      { _ = try await service.livePartitionRooms(area: LivePartition(id: 1, title: "Invalid", parentID: -1)) },
      { _ = try await service.livePartitionRooms(area: LivePartition(id: 1, title: "Missing parent")) }
    ]
    for operation in operations {
      do { try await operation(); XCTFail("Expected argument rejection") } catch BiliError.invalidResponse {}
    }
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
  func testStaleExpectedIdentityNeverSendsAnyLiveRoute() async throws {
    let transport = LiveDiscoveryTransport(); let service = try await liveService(transport, authenticated: true)
    let identity = await service.authSnapshot(); try await service.logout()
    let operations: [@Sendable () async throws -> Void] = [
      { _ = try await service.livePartitions(expectedIdentity: identity) },
      { _ = try await service.liveFeed(expectedIdentity: identity) },
      { _ = try await service.livePartitionRooms(area: LivePartition(id: 101, title: "Fixture", parentID: 1), expectedIdentity: identity) }
    ]
    for operation in operations {
      do { try await operation(); XCTFail("Expected identity cancellation") } catch is CancellationError {}
    }
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
  func testLogoutDiscardsLateFeedResponse() async throws {
    let transport = LiveDiscoveryTransport(held: true); let service = try await liveService(transport, authenticated: true)
    let identity = await service.authSnapshot()
    let task = Task { try await service.liveFeed(expectedIdentity: identity) }
    await transport.waitForRequest(); try await service.logout(); await transport.release()
    do { _ = try await task.value; XCTFail("Expected late response cancellation") } catch is CancellationError {}
    let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
  }
  func testCancellingReadDiscardsLateResponse() async throws {
    let transport = LiveDiscoveryTransport(held: true); let service = try await liveService(transport)
    let task = Task { try await service.livePartitions() }
    await transport.waitForRequest(); task.cancel(); await transport.release()
    do { _ = try await task.value; XCTFail("Expected cancelled result") } catch is CancellationError {}
  }
  func testInvalidRoomAndFailedEnvelopeAreNotSilentlyAcceptedOrRetried() async throws {
    for data in [Data(#"{"code":0,"data":{"card_list":[{"card_type":"small_card_v1","card_data":{"small_card_v1":{"id":0,"title":"Invalid"}}}]}}"#.utf8),
      Data(#"{"code":-400,"data":{}}"#.utf8)] {
      let transport = LiveDiscoveryTransport(override: data); let service = try await liveService(transport)
      do { _ = try await service.liveFeed(); XCTFail("Expected invalid response") }
      catch BiliError.invalidResponse {} catch BiliError.api(let code, _) { XCTAssertEqual(code, -400) }
      let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
    }
  }
}
#endif
