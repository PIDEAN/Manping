import BiliProtocol
import Foundation
import GRPCCore
import SwiftProtobuf
import XCTest
@testable import ManpingCore

private final class M4Credentials: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  init(authenticated: Bool = true) {
    token = authenticated ? AppToken(mid: 123, accessToken: "fixture-moment-access",
      refreshToken: "fixture-moment-refresh", expiresAt: 9_999_999_999) : nil
  }
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { lock.withLock { token } }
  func saveToken(_ value: AppToken?) { lock.withLock { token = value } }
  func clear() { saveToken(nil) }
}
private actor M4HTTP: AuthTransport {
  private(set) var requests: [URLRequest] = []
  let body: Data
  init(body: String = #"{"code":0,"data":{}}"#) { self.body = Data(body.utf8) }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    return AuthHTTPResponse(body: body,
      response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private actor M4RPC: BiliRPCTransport {
  private(set) var methods: [String] = []
  private(set) var requests: [Data] = []
  private(set) var hasAuth: [Bool] = []
  private(set) var stopped = false
  let reject: Bool
  init(reject: Bool = false) { self.reject = reject }
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    methods.append(descriptor.fullyQualifiedMethod); requests.append(try request.serializedData())
    hasAuth.append(metadata[stringValues: "authorization"].contains { $0.contains("fixture-moment-access") })
    if reject { throw BiliRPCError.permissionDenied }
    return try Response(serializedBytes: Data())
  }
  func shutdown(grace: Duration) async { stopped = true }
}
private func m4Auth(_ http: M4HTTP = M4HTTP(), authenticated: Bool = true) async throws -> BiliService {
  let service = BiliService(transport: http, credentials: M4Credentials(authenticated: authenticated),
    now: { Date(timeIntervalSince1970: 1000) })
  try await service.restoreCookies()
  return service
}
private func m4Fields(_ request: URLRequest) -> [String: String] {
  let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  let decodedSpaces = form.replacingOccurrences(of: "+", with: "%20")
  let fields = URLComponents(string: "https://fixture.invalid/?\(decodedSpaces)")!.queryItems ?? []
  return Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
}

final class M4MomentTests: XCTestCase, @unchecked Sendable {
  func testDynamicThumbUsesExactSDKServiceAndWireActions() async throws {
    let auth = try await m4Auth(); let rpc = M4RPC()
    let service = MomentOperationsService(auth: auth, transport: rpc, installationID: "fixture-installation")
    let expected = await auth.authSnapshot()
    try await service.setLiked(dynamicID: 987, authorID: 456, liked: true, expectedIdentity: expected)
    try await service.setLiked(dynamicID: 987, authorID: 456, liked: false, expectedIdentity: expected)
    let methods = await rpc.methods; let requests = await rpc.requests; let authorized = await rpc.hasAuth
    XCTAssertEqual(methods, Array(repeating: "bilibili.main.dynamic.feed.v1.Feed/DynamicThumb", count: 2))
    XCTAssertEqual(authorized, [true, true])
    let like = try Bilibili_App_Dynamic_V2_DynThumbReq(serializedBytes: requests[0])
    let cancel = try Bilibili_App_Dynamic_V2_DynThumbReq(serializedBytes: requests[1])
    XCTAssertEqual(like.dynID, 987); XCTAssertEqual(like.uid, 456); XCTAssertEqual(like.type, .thumb)
    XCTAssertEqual(cancel.type, .cancel)
    XCTAssertEqual(like.dynType, 0); XCTAssertEqual(like.rid, "")
    await service.shutdown()
    let stopped = await rpc.stopped
    XCTAssertFalse(stopped, "Shared injected transport remains owned by the composition root")
    do { try await service.setLiked(dynamicID: 987, authorID: 456, liked: true, expectedIdentity: expected); XCTFail("Closed service") }
    catch BiliRPCError.shutdown {}
  }

  func testInvalidAnonymousAndStaleDynamicThumbNeverSend() async throws {
    let auth = try await m4Auth(); let rpc = M4RPC()
    let service = MomentOperationsService(auth: auth, transport: rpc, installationID: "fixture")
    let expected = await auth.authSnapshot()
    let invalidIDs: [(Int64, Int64)] = [(0, 456), (987, 0), (-1, 456)]
    for pair in invalidIDs {
      do { try await service.setLiked(dynamicID: pair.0, authorID: pair.1, liked: true, expectedIdentity: expected); XCTFail("Invalid IDs") }
      catch BiliRPCError.invalidArgument {}
    }
    _ = await auth.beginLogin()
    do { try await service.setLiked(dynamicID: 987, authorID: 456, liked: true, expectedIdentity: expected); XCTFail("Stale account") }
    catch is CancellationError {}
    let anonymous = try await m4Auth(authenticated: false)
    let anonymousService = MomentOperationsService(auth: anonymous, transport: rpc, installationID: "fixture")
    let anonymousExpected = await anonymous.authSnapshot()
    do { try await anonymousService.setLiked(dynamicID: 987, authorID: 456, liked: true, expectedIdentity: anonymousExpected); XCTFail("Token required") }
    catch BiliRPCError.needsLogin {}
    let methods = await rpc.methods
    XCTAssertTrue(methods.isEmpty)
  }

  func testDynamicThumbServerRejectionPropagates() async throws {
    let auth = try await m4Auth(); let rpc = M4RPC(reject: true)
    let service = MomentOperationsService(auth: auth, transport: rpc, installationID: "fixture")
    let expected = await auth.authSnapshot()
    do { try await service.setLiked(dynamicID: 987, authorID: 456, liked: true, expectedIdentity: expected); XCTFail("Server rejected") }
    catch BiliRPCError.permissionDenied {}
  }

  func testCommentLikeUsesOIDAndSendPreservesTypedReplyTarget() async throws {
    let http = M4HTTP(); let auth = try await m4Auth(http); let expected = await auth.authSnapshot()
    try await auth.setCommentLiked(oid: 987, targetType: 17, replyID: 100, liked: true, expectedIdentity: expected)
    try await auth.setCommentLiked(oid: 987, targetType: 17, replyID: 100, liked: false, expectedIdentity: expected)
    try await auth.sendComment(message: "fixture & 中文", oid: 987, targetType: 17,
      root: 100, parent: 101, expectedIdentity: expected)
    let requests = await http.requests
    XCTAssertEqual(requests.map { $0.url?.path }, ["/x/v2/reply/action", "/x/v2/reply/action", "/x/v2/reply/add"])
    XCTAssertEqual(m4Fields(requests[0])["oid"], "987")
    XCTAssertNil(m4Fields(requests[0])["od"], "Correct the pinned SDK's misspelled target field")
    XCTAssertEqual(m4Fields(requests[0])["action"], "1")
    XCTAssertEqual(m4Fields(requests[1])["action"], "0")
    let form = m4Fields(requests[2])
    XCTAssertEqual(form["message"], "fixture & 中文"); XCTAssertEqual(form["type"], "17")
    XCTAssertEqual(form["root"], "100"); XCTAssertEqual(form["parent"], "101"); XCTAssertEqual(form["plat"], "3")
    for request in requests {
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(m4Fields(request)["access_key"], "fixture-moment-access")
      XCTAssertNotNil(m4Fields(request)["sign"])
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
  }

  func testInvalidCommentTargetsAndDraftsNeverSend() async throws {
    let http = M4HTTP(); let auth = try await m4Auth(http); let expected = await auth.authSnapshot()
    do { try await auth.setCommentLiked(oid: 0, targetType: 17, replyID: 1, liked: true, expectedIdentity: expected); XCTFail("Invalid target") }
    catch BiliError.invalidResponse {}
    do { try await auth.setCommentLiked(oid: 987, targetType: 0, replyID: 1, liked: true, expectedIdentity: expected); XCTFail("Unknown type") }
    catch BiliError.invalidResponse {}
    do { try await auth.setCommentLiked(oid: 987, targetType: 17, replyID: 0, liked: true, expectedIdentity: expected); XCTFail("Invalid reply") }
    catch BiliError.invalidResponse {}
    for message in [" \n ", String(repeating: "x", count: 1001)] {
      do { try await auth.sendComment(message: message, oid: 987, targetType: 17, expectedIdentity: expected); XCTFail("Invalid text") }
      catch BiliError.invalidResponse {}
    }
    do { try await auth.sendComment(message: "fixture", oid: 987, targetType: 17, root: 0, parent: 1, expectedIdentity: expected); XCTFail("Parent without root") }
    catch BiliError.invalidResponse {}
    try await auth.logout()
    do { try await auth.sendComment(message: "fixture", oid: 987, targetType: 17, expectedIdentity: expected); XCTFail("Stale identity") }
    catch is CancellationError {}
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testRejectedCommentResponseDoesNotReportSuccess() async throws {
    let auth = try await m4Auth(M4HTTP(body: #"{"code":-403,"data":{}}"#))
    let expected = await auth.authSnapshot()
    do { try await auth.sendComment(message: "fixture", oid: 987, targetType: 11, expectedIdentity: expected); XCTFail("Rejected send") }
    catch BiliError.api(let code, _) { XCTAssertEqual(code, -403) }
  }
}
