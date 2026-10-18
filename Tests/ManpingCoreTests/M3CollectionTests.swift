import Foundation
import XCTest
@testable import ManpingCore

private final class CollectionStore: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  private var cookies: [HTTPCookie]
  init(authenticated: Bool = true, expiresAt: Int64 = 9_999_999_999) {
    token = authenticated ? AppToken(mid: 123, accessToken: "collection-fixture-token",
      refreshToken: "collection-fixture-refresh", expiresAt: expiresAt) : nil
    cookies = authenticated ? ["SESSDATA": "collection-fixture-session", "bili_jct": "collection-fixture-csrf",
      "DedeUserID": "123"].compactMap { name, value in
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".bilibili.com", .path: "/",
          .secure: "TRUE", .expires: Date(timeIntervalSince1970: 9_999_999_999)])
      } : []
  }
  func load() -> [HTTPCookie] { lock.withLock { cookies } }
  func save(_ value: [HTTPCookie]) { lock.withLock { cookies = value } }
  func loadToken() -> AppToken? { lock.withLock { token } }
  func saveToken(_ value: AppToken?) { lock.withLock { token = value } }
  func clear() { lock.withLock { token = nil; cookies = [] } }
}

private actor CollectionTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  private var held = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var pending: CheckedContinuation<Void, Never>?
  let rejection: Int?
  init(rejection: Int? = nil, held: Bool = false) { self.rejection = rejection; self.held = held }
  func waitForRequest() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() { held = false; pending?.resume(); pending = nil }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request); waiter?.resume(); waiter = nil
    // Intentionally returns a late response even when the caller was cancelled.
    if held { await withCheckedContinuation { pending = $0 } }
    let url = request.url!
    let body: Data
    if url.path == "/x/web-interface/nav" {
      body = Data(#"{"code":0,"data":{"wbi_img":{"img_url":"https://i.example/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i.example/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#.utf8)
    } else if url.path == "/api/oauth2/refreshToken" {
      body = Data(#"{"code":0,"data":{"mid":123,"access_token":"collection-fixture-renewed","refresh_token":"collection-fixture-renewed-refresh","expires_in":3600}}"#.utf8)
    } else if url.path == "/x/v3/fav/folder/collected/list" {
      let pn = collectionFields(request)["pn"]
      let folder: [String: Any] = ["id": pn == "2" ? 42 : 41, "title": "Collected fixture", "media_count": 1,
        "type": 2, "upper": ["mid": 456]]
      body = try JSONSerialization.data(withJSONObject: ["code": 0,
        "data": ["list": [folder], "count": 21, "has_more": pn != "2"]])
    } else if url.path == "/x/v2/history/toview" {
      body = Data(#"{"code":0,"data":{"list":[{"aid":3,"title":"Later fixture","add_at":1700000000,"owner":{"mid":123,"name":"Fixture","face":"https://fixture.invalid/avatar"}}],"count":41}}"#.utf8)
    } else if url.path == "/x/v3/fav/resource/list" {
      body = Data(#"{"code":0,"data":{"medias":[{"id":8,"type":2,"title":"Favorite fixture","fav_time":1700000000,"upper":{"mid":123,"name":"Fixture","face":"https://fixture.invalid/avatar"}}],"has_more":true,"info":{"media_count":21}}}"#.utf8)
    } else {
      body = try JSONSerialization.data(withJSONObject: ["code": rejection ?? 0, "data": [:]])
    }
    return AuthHTTPResponse(body: body,
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private func collectionFields(_ request: URLRequest) -> [String: String] {
  let query = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
    ?? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
  return Dictionary(uniqueKeysWithValues: query.split(separator: "&").map { field in
    let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    func decode(_ value: Substring) -> String {
      String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(value)
    }
    return (decode(pair[0]), pair.count == 2 ? decode(pair[1]) : "")
  })
}
private func collectionService(_ transport: CollectionTransport, authenticated: Bool = true,
  expiresAt: Int64 = 9_999_999_999) async throws -> BiliService {
  let service = BiliService(transport: transport,
    credentials: CollectionStore(authenticated: authenticated, expiresAt: expiresAt),
    now: { Date(timeIntervalSince1970: 1000) })
  try await service.restoreCookies(); return service
}

final class M3CollectionTests: XCTestCase, @unchecked Sendable {
  func testCollectionReadsKeepAddedTimeAndAvatarWithIdentity() async throws {
    let transport = CollectionTransport(); let service = try await collectionService(transport)
    let identity = await service.authSnapshot()
    let later = try await service.collectionViewLater(expectedIdentity: identity)
    let folder = try BiliService.libraryFolder(["id": 11, "title": "Fixture"], group: "我创建的")
    let favorite = try await service.collectionContents(folder: folder, expectedIdentity: identity)
    XCTAssertTrue(later.hasMore); XCTAssertEqual(later.total, 41)
    XCTAssertTrue(favorite.hasMore); XCTAssertEqual(favorite.total, 21)
    for entry in [try XCTUnwrap(later.items.first), try XCTUnwrap(favorite.items.first)] {
      guard case .video(let video) = entry.destination else { return XCTFail("Expected video") }
      XCTAssertTrue(video.subtitle?.hasSuffix(" 加入") == true)
      XCTAssertEqual(video.avatar?.absoluteString, "https://fixture.invalid/avatar")
      XCTAssertEqual(video.authorID, 123)
    }
    let requests = await transport.requests
    XCTAssertEqual(collectionFields(requests[0])["pn"], "1")
    XCTAssertEqual(collectionFields(requests[0])["ps"], "40")
    XCTAssertEqual(collectionFields(requests[1])["media_id"], "11")
    XCTAssertEqual(collectionFields(requests[1])["ps"], "20")
  }
  func testCollectionReadsRejectInvalidPageAndStaleIdentity() async throws {
    let transport = CollectionTransport(); let service = try await collectionService(transport)
    let identity = await service.authSnapshot()
    do { _ = try await service.collectionViewLater(page: 0, expectedIdentity: identity); XCTFail("Expected invalid page") }
    catch BiliError.invalidResponse {}
    do { _ = try await service.collectionFolders(page: 1_000_001, expectedIdentity: identity); XCTFail("Expected invalid page") }
    catch BiliError.invalidResponse {}
    try await service.logout()
    do { _ = try await service.collectionViewLater(expectedIdentity: identity); XCTFail("Expected identity cancellation") }
    catch is CancellationError {}
    do { _ = try await service.collectionFolders(expectedIdentity: identity); XCTFail("Expected identity cancellation") }
    catch is CancellationError {}
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
  func testMutationsUseExactSignedTokenOnlyPostFields() async throws {
    let transport = CollectionTransport(); let service = try await collectionService(transport)
    let identity = await service.authSnapshot()
    try await service.removeViewLater(aids: [8, 3, 8], expectedIdentity: identity)
    try await service.clearViewLater(expectedIdentity: identity)
    try await service.removeFavoriteVideos(folderID: 11, aids: [8, 3, 8], expectedIdentity: identity)
    try await service.removeFavoritePGC(seasonID: 99, expectedIdentity: identity)
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url!.path }, ["/x/v2/history/toview/del", "/x/v2/history/toview/clear",
      "/x/v3/fav/resource/batch-del", "/pgc/app/follow/del"])
    XCTAssertEqual(collectionFields(requests[0])["aid"], "3,8")
    XCTAssertEqual(collectionFields(requests[1])["clean_type"], "0")
    XCTAssertEqual(collectionFields(requests[2])["resources"], "3:2,8:2")
    XCTAssertEqual(collectionFields(requests[2])["media_id"], "11")
    XCTAssertEqual(collectionFields(requests[3])["season_id"], "99")
    for request in requests {
      XCTAssertEqual(request.httpMethod, "POST"); XCTAssertNil(request.url?.query)
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
      let fields = collectionFields(request)
      XCTAssertEqual(fields["access_key"], "collection-fixture-token")
      XCTAssertEqual(fields["appkey"], "27eb53fc9058f8c3")
      XCTAssertEqual(fields["ts"], "1000"); XCTAssertNotNil(fields["sign"])
      XCTAssertNil(fields["csrf"])
    }
  }
  func testInvalidIdentifiersAndEmptyBatchesNeverSend() async throws {
    let transport = CollectionTransport(); let service = try await collectionService(transport)
    let identity = await service.authSnapshot()
    let operations: [@Sendable () async throws -> Void] = [
      { try await service.removeViewLater(aids: [], expectedIdentity: identity) },
      { try await service.removeViewLater(aids: [1, 0], expectedIdentity: identity) },
      { try await service.removeFavoriteVideos(folderID: 0, aids: [1], expectedIdentity: identity) },
      { try await service.removeFavoriteVideos(folderID: 11, aids: [], expectedIdentity: identity) },
      { try await service.removeFavoriteVideos(folderID: 11, aids: [-1], expectedIdentity: identity) },
      { try await service.removeFavoritePGC(seasonID: 0, expectedIdentity: identity) }
    ]
    for operation in operations {
      do { try await operation(); XCTFail("Expected invalid identifier rejection") }
      catch BiliError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
    }
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
  func testLoggedOutMutationsNeverSend() async throws {
    let transport = CollectionTransport(); let service = try await collectionService(transport, authenticated: false)
    let identity = await service.authSnapshot()
    do { try await service.clearViewLater(expectedIdentity: identity); XCTFail("Expected login requirement") }
    catch AuthFailure.needsLogin {}
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
  func testStaleExpectedIdentityNeverSends() async throws {
    let transport = CollectionTransport(); let service = try await collectionService(transport)
    let identity = await service.authSnapshot(); try await service.logout()
    let operations: [@Sendable () async throws -> Void] = [
      { try await service.removeViewLater(aids: [1], expectedIdentity: identity) },
      { try await service.clearViewLater(expectedIdentity: identity) },
      { try await service.removeFavoriteVideos(folderID: 11, aids: [1], expectedIdentity: identity) },
      { try await service.removeFavoritePGC(seasonID: 99, expectedIdentity: identity) }
    ]
    for operation in operations {
      do { try await operation(); XCTFail("Expected stale identity cancellation") } catch is CancellationError {}
    }
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
  func testExpiredTokenRefreshesBeforeMutation() async throws {
    let transport = CollectionTransport(); let service = try await collectionService(transport, expiresAt: 999)
    let identity = await service.authSnapshot()
    try await service.removeViewLater(aids: [3], expectedIdentity: identity)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].url?.host, "passport.bilibili.com")
    XCTAssertEqual(requests[0].url?.path, "/api/oauth2/refreshToken")
    XCTAssertEqual(requests[1].url?.path, "/x/v2/history/toview/del")
    XCTAssertEqual(collectionFields(requests[1])["access_key"], "collection-fixture-renewed")
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
    let refreshed = await service.authSnapshot()
    XCTAssertEqual(refreshed.epoch, identity.epoch)
    XCTAssertEqual(refreshed.identityRevision, identity.identityRevision)
  }
  func testFailedMutationIsNotRetried() async throws {
    let transport = CollectionTransport(rejection: -400); let service = try await collectionService(transport)
    let identity = await service.authSnapshot()
    do { try await service.removeViewLater(aids: [3], expectedIdentity: identity); XCTFail("Expected API rejection") }
    catch BiliError.api(let code, _) { XCTAssertEqual(code, -400) }
    let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
  }
  func testLogoutDiscardsLateMutationSuccess() async throws {
    let transport = CollectionTransport(held: true); let service = try await collectionService(transport)
    let identity = await service.authSnapshot()
    let task = Task { try await service.removeViewLater(aids: [3], expectedIdentity: identity) }
    await transport.waitForRequest(); try await service.logout(); await transport.release()
    do { try await task.value; XCTFail("Expected late response cancellation") } catch is CancellationError {}
    let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
  }
  func testCancellationDiscardsLateMutationSuccess() async throws {
    let transport = CollectionTransport(held: true); let service = try await collectionService(transport)
    let identity = await service.authSnapshot()
    let task = Task { try await service.clearViewLater(expectedIdentity: identity) }
    await transport.waitForRequest(); task.cancel(); await transport.release()
    do { try await task.value; XCTFail("Expected cancelled response") } catch is CancellationError {}
    let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
  }
  func testCollectedFolderPagingUsesWBIWebCookieWithoutToken() async throws {
    let transport = CollectionTransport(); let service = try await collectionService(transport)
    let identity = await service.authSnapshot()
    let first = try await service.collectionFolders(expectedIdentity: identity)
    let second = try await service.collectionFolders(page: 2, expectedIdentity: identity)
    XCTAssertEqual(first.items.first?.id, 41); XCTAssertTrue(first.hasMore)
    XCTAssertEqual(second.items.first?.id, 42); XCTAssertFalse(second.hasMore)
    XCTAssertEqual(second.items.first?.group, "我收藏的"); XCTAssertEqual(second.total, 21)
    let requests = await transport.requests
    let folders = requests.filter { $0.url?.path == "/x/v3/fav/folder/collected/list" }
    XCTAssertEqual(folders.count, 2)
    XCTAssertEqual(collectionFields(folders[1])["pn"], "2")
    XCTAssertEqual(collectionFields(folders[1])["up_mid"], "123")
    XCTAssertEqual(collectionFields(folders[1])["ps"], "20")
    XCTAssertNotNil(collectionFields(folders[1])["w_rid"])
    XCTAssertNil(collectionFields(folders[1])["access_key"])
    XCTAssertTrue(folders[1].value(forHTTPHeaderField: "Cookie")?.contains("collection-fixture-session") == true)
  }
}
