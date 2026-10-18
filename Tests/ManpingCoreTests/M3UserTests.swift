import Foundation
import XCTest
@testable import ManpingCore

private final class M3UserCredentials: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  init(authenticated: Bool) {
    token = authenticated ? AppToken(mid: 123, accessToken: "fixture-user-access",
      refreshToken: "fixture-user-refresh", expiresAt: 9_999_999_999) : nil
  }
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { lock.withLock { token } }
  func saveToken(_ value: AppToken?) { lock.withLock { token = value } }
  func clear() { saveToken(nil) }
}

private actor M3UserTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  let body: Data
  init(body: String = #"{"code":0,"data":{"attribute":2,"special":0}}"#) {
    self.body = Data(body.utf8)
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    return AuthHTTPResponse(body: body,
      response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private func m3UserService(_ transport: M3UserTransport, authenticated: Bool = true) async throws -> BiliService {
  let service = BiliService(transport: transport, credentials: M3UserCredentials(authenticated: authenticated),
    now: { Date(timeIntervalSince1970: 1000) })
  try await service.restoreCookies()
  return service
}
private func m3UserFields(_ request: URLRequest) -> [String: String] {
  let text = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
  let components = text.map { URLComponents(string: "https://fixture.invalid/?\($0)")! }
    ?? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
  return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

final class M3UserTests: XCTestCase, @unchecked Sendable {
  func testUnknownRelationIsNeverAssumedUnfollowed() {
    XCTAssertEqual(BiliUserRelation.parse(["attribute": 0]).isFollowing, false)
    XCTAssertEqual(BiliUserRelation.parse(["attribute": 2]).isFollowing, true)
    XCTAssertEqual(BiliUserRelation.parse(["attribute": 6]), .mutual)
    let unknown: [[String: Any]] = [[:], ["attribute": NSNull()], ["attribute": "bad"],
      ["attribute": 128], ["attribute": 1], ["attribute": 4], ["attribute": 999],
      ["attribute": false], ["attribute": 2.5]]
    for payload in unknown {
      XCTAssertEqual(BiliUserRelation.parse(payload), .unknown)
      XCTAssertNil(BiliUserRelation.parse(payload).isFollowing)
    }
  }

  func testRelationUsesClosedSignedAppGETWithExpectedIdentity() async throws {
    let transport = M3UserTransport(); let service = try await m3UserService(transport)
    let snapshot = await service.authSnapshot()
    let relation = try await service.libraryRelationship(mid: 456, expectedIdentity: snapshot)
    XCTAssertEqual(relation, .following)
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.host, "api.bilibili.com")
    XCTAssertEqual(request.url?.path, "/x/relation")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(m3UserFields(request)["fid"], "456")
    XCTAssertEqual(m3UserFields(request)["access_key"], "fixture-user-access")
    XCTAssertNotNil(m3UserFields(request)["sign"])
    XCTAssertTrue(BiliAppRoute.relationship.requiresToken)
    XCTAssertFalse(BiliAppRoute.relationship.isMutation)
  }

  func testAnonymousInvalidAndStaleRelationNeverSend() async throws {
    let anonymousTransport = M3UserTransport()
    let anonymous = try await m3UserService(anonymousTransport, authenticated: false)
    do { _ = try await anonymous.libraryRelationship(mid: 456); XCTFail("Token required") }
    catch AuthFailure.needsLogin {}
    do { _ = try await anonymous.libraryRelationship(mid: 0); XCTFail("Positive mid required") }
    catch BiliError.invalidResponse {}
    let anonymousRequests = await anonymousTransport.requests
    XCTAssertTrue(anonymousRequests.isEmpty)

    let transport = M3UserTransport(); let service = try await m3UserService(transport)
    let loadedIdentity = await service.authSnapshot()
    _ = await service.beginLogin()
    do { _ = try await service.libraryRelationship(mid: 456, expectedIdentity: loadedIdentity); XCTFail("Stale read") }
    catch is CancellationError {}
    do { try await service.setFollowing(mid: 456, following: true, expectedIdentity: loadedIdentity); XCTFail("Stale mutation") }
    catch is CancellationError {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testMalformedAndRejectedRelationDoNotBecomeKnown() async throws {
    for body in [#"{"code":0,"data":null}"#, #"{"code":-403,"data":{"attribute":2}}"#] {
      let service = try await m3UserService(M3UserTransport(body: body))
      do { _ = try await service.libraryRelationship(mid: 456); XCTFail("Invalid relation response") }
      catch is BiliError {}
    }
    for body in [#"{"code":0,"data":{}}"#, #"{"code":0,"data":{"attribute":128}}"#] {
      let service = try await m3UserService(M3UserTransport(body: body))
      let relation = try await service.libraryRelationship(mid: 456)
      XCTAssertNil(relation.isFollowing)
    }
  }

  func testFixtureFollowWritesUseLoadedIdentityAndExactActions() async throws {
    let transport = M3UserTransport(); let service = try await m3UserService(transport)
    let loaded = await service.authSnapshot()
    _ = try await service.libraryRelationship(mid: 456, expectedIdentity: loaded)
    let authorized = try await service.authorizeAppInteraction(expectedIdentity: loaded)
    try await service.setFollowing(mid: 456, following: true, expectedIdentity: authorized)
    try await service.setFollowing(mid: 456, following: false, expectedIdentity: authorized)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests.dropFirst().map { $0.url?.path }, ["/x/relation/modify", "/x/relation/modify"])
    XCTAssertEqual(requests.dropFirst().map { $0.httpMethod }, ["POST", "POST"])
    XCTAssertEqual(requests.dropFirst().map { m3UserFields($0)["act"] }, ["1", "2"])
    for request in requests.dropFirst() {
      XCTAssertEqual(m3UserFields(request)["fid"], "456")
      XCTAssertNotNil(m3UserFields(request)["sign"])
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
    try await service.logout()
    do { try await service.setFollowing(mid: 456, following: true, expectedIdentity: authorized); XCTFail("Logged-out boundary") }
    catch is CancellationError {}
    let finalRequests = await transport.requests
    XCTAssertEqual(finalRequests.count, 3)
  }
}
