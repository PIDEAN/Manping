import Foundation
import XCTest
@testable import ManpingCore

private final class M6MessageCredentials: AuthCredentialStore, @unchecked Sendable {
  private var token: AppToken?
  init(expiresAt: Int64 = 9_999_999_999) {
    token = AppToken(mid: 123, accessToken: "fixture-message-access", refreshToken: "fixture-message-refresh", expiresAt: expiresAt)
  }
  func load() -> [HTTPCookie] {
    ["SESSDATA": "fixture-message-cookie", "bili_jct": "fixture-message-csrf"].map { name, value in
      HTTPCookie(properties: [.name: name, .value: value, .domain: ".bilibili.com", .path: "/", .secure: "TRUE"])!
    }
  }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { token }
  func saveToken(_ value: AppToken?) { token = value }
  func clear() { token = nil }
}
private actor M6MessageTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  private let refreshing: Bool
  init(refreshing: Bool = false) { self.refreshing = refreshing }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let parameters = messageFields(request)
    let body: Data
    if refreshing, request.url?.path == "/api/oauth2/refreshToken" {
      body = Data(#"{"code":0,"data":{"mid":123,"access_token":"fixture-message-new-access","refresh_token":"fixture-message-new-refresh","expires_in":86400,"cookie_info":{"cookies":[{"name":"SESSDATA","value":"fixture-message-new-cookie","expires":9999999999},{"name":"bili_jct","value":"fixture-message-new-csrf","expires":9999999999},{"name":"DedeUserID","value":"123","expires":9999999999}]}}}"#.utf8)
    } else if request.url?.path == "/x/web-interface/nav" {
      body = Data(#"{"code":-101,"data":{"wbi_img":{"img_url":"https://fixture.invalid/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://fixture.invalid/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#.utf8)
    } else {
      body = M6MessageFixture.response(path: request.url!.path, parameters: parameters) ?? Data(#"{"code":-404}"#.utf8)
    }
    return AuthHTTPResponse(body: body, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private func messageFields(_ request: URLRequest) -> [String: String] {
  let components: URLComponents
  if let body = request.httpBody {
    components = URLComponents(string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self)
      .replacingOccurrences(of: "+", with: "%20"))!
  }
  else { components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)! }
  return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}
private final class M6MessageClock: @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: TimeInterval = 1000
  func now() -> Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
  func advance(to value: TimeInterval) { lock.withLock { seconds = value } }
}
private func messagePayload(_ path: String, _ fields: [String: String] = [:]) throws -> [String: Any] {
  let body = try XCTUnwrap(M6MessageFixture.response(path: path, parameters: fields))
  return try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["data"] as? [String: Any])
}

final class M6MessageTests: XCTestCase, @unchecked Sendable {
  func testNotificationSDKShapesDeduplicateLikeAndEndEmptyWithoutError() throws {
    for section in [MessageSection.reply, .at, .like] {
      let page = try NotificationPage.parse(messagePayload("/x/msgfeed/\(section.rawValue)", ["id": "0"]), section: section)
      XCTAssertEqual(page.items.count, 8)
      XCTAssertTrue(page.hasMore)
      XCTAssertEqual(page.items.first?.users.first?.id, 50001)
      XCTAssertEqual(page.items.first?.source, "星海游记 · 新的一天")
      let final = try NotificationPage.parse(messagePayload("/x/msgfeed/\(section.rawValue)", ["id": "20"]), section: section)
      XCTAssertFalse(final.hasMore)
    }
    let empty = try NotificationPage.parse(["items": [], "cursor": ["id": 0, "time": 0, "is_end": true]], section: .reply)
    XCTAssertTrue(empty.items.isEmpty)
    XCTAssertFalse(empty.hasMore)
    XCTAssertThrowsError(try NotificationPage.parse([:], section: .like))
  }
  func testConversationReversesWireOrderHandlesImageWithdrawalAndUnsupportedTypes() throws {
    let text = #"{"content":"Hello '!*() & 世界"}"#
    let rows: [[String: Any]] = [
      ["msg_key": 4, "msg_type": 99, "timestamp": 104, "sender_uid": 456, "content": "{}"],
      ["msg_key": 3, "msg_type": 5, "timestamp": 103, "sender_uid": 456, "content": "{}"],
      ["msg_key": 2, "msg_type": 2, "timestamp": 102, "sender_uid": 456, "content": #"{"url":"https://fixture.invalid/cover/1"}"#],
      ["msg_key": 1, "msg_type": 1, "timestamp": 101, "sender_uid": 123, "content": text]]
    let page = try ConversationPage.parse(["messages": rows + [rows[0]], "has_more": 1, "min_seqno": 5, "max_seqno": 9])
    XCTAssertEqual(page.messages.map(\.id), [1, 2, 3, 4])
    XCTAssertEqual(page.messages[0].text, "Hello '!*() & 世界")
    XCTAssertEqual(page.messages[0].senderID, 123)
    XCTAssertEqual(page.messages[1].kind, .image)
    XCTAssertEqual(page.messages[2].kind, .withdrawn)
    XCTAssertEqual(page.messages[3].kind, .unsupported)
    XCTAssertEqual(page.minimumSequence, 5)
    XCTAssertTrue(page.hasMore)
  }
  func testConversationMapsPageEmoteInfosOntoTextMessagesOnly() throws {
    let rows: [[String: Any]] = [
      ["msg_key": 1, "msg_type": 1, "timestamp": 101, "sender_uid": 1, "content": #"{"content":"好耶[doge]"}"#],
      ["msg_key": 2, "msg_type": 2, "timestamp": 102, "sender_uid": 1, "content": #"{"url":"https://fixture.invalid/i/1"}"#]]
    let page = try ConversationPage.parse(["messages": rows, "e_infos": [
      ["text": "[doge]", "url": "http://i0.hdslb.com/bfs/emote/doge.png"], ["url": "https://fixture.invalid/no-text"]]])
    XCTAssertEqual(page.messages[0].emotes, [RPCEmote(text: "[doge]", image: URL(string: "http://i0.hdslb.com/bfs/emote/doge.png"))])
    XCTAssertEqual(RPCEmoteTextSegment.parse(page.messages[0].text, emotes: page.messages[0].emotes).count, 2)
    XCTAssertTrue(page.messages[1].emotes.isEmpty)
  }
  func testStaleCredentialRestoreLeavesANewerIdentityAlone() async throws {
    let service = BiliService(transport: M6MessageTransport(), credentials: M6MessageCredentials())
    let before = await service.authSnapshot()
    // The Keychain read finishes after the user logged out (or signed in elsewhere).
    let stored = try service.loadStoredCredentials()
    try await service.logout()
    let stale = try await service.restore(stored, ifUnchangedSince: before)
    XCTAssertFalse(stale)
    let after = await service.authSnapshot()
    XCTAssertEqual(after.state, .needsLogin)
    let cookies = await service.loginCookies()
    XCTAssertTrue(cookies.isEmpty)
    let fresh = try await service.restore(stored, ifUnchangedSince: after)
    XCTAssertTrue(fresh)
    let restored = await service.authSnapshot()
    XCTAssertNotEqual(restored.state, .needsLogin)
  }
  func testReadRequestsUseSDKContractsAndNeverAcknowledgeOrPOST() async throws {
    let transport = M6MessageTransport()
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    _ = try await service.notificationMessages(.reply, offsetID: 9, offsetTime: 100, expectedIdentity: identity)
    let sessions = try await service.chatSessions(expectedIdentity: identity)
    XCTAssertEqual(sessions.sessions.count, 4)
    _ = try await service.conversationMessages(talkerID: 60001, beforeSequence: 100, expectedIdentity: identity)
    let requests = await transport.requests
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    XCTAssertFalse(requests.contains { $0.url?.path.contains("ack") == true || $0.url?.path.contains("send_msg") == true })
    let notify = try XCTUnwrap(requests.first { $0.url?.path == "/x/msgfeed/reply" })
    XCTAssertEqual(messageFields(notify)["id"], "9")
    XCTAssertEqual(messageFields(notify)["reply_time"], "100")
    XCTAssertEqual(messageFields(notify)["access_key"], "fixture-message-access")
    let history = try XCTUnwrap(requests.first { $0.url?.path == "/svr_sync/v1/svr_sync/fetch_session_msgs" })
    XCTAssertEqual(messageFields(history)["begin_seqno"], "100")
    XCTAssertEqual(messageFields(history)["size"], "100")
    XCTAssertNil(messageFields(history)["access_key"])
    XCTAssertNotNil(messageFields(history)["w_rid"])
    XCTAssertTrue(history.value(forHTTPHeaderField: "Cookie")?.contains("SESSDATA=fixture-message-cookie") == true)
  }
  func testExplicitSendUsesBoundSenderCSRFAndPreservesPunctuation() async throws {
    let transport = M6MessageTransport()
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let content = "Hello '!*() & 世界 + literal+\n第二行"
    let sent = try await service.sendConversationMessage(receiverID: 456, content: content, expectedIdentity: identity)
    XCTAssertEqual(sent.text, content)
    XCTAssertEqual(sent.senderID, 123)
    let requests = await transport.requests
    let post = try XCTUnwrap(requests.first { $0.url?.path == "/web_im/v1/web_im/send_msg" })
    XCTAssertEqual(post.httpMethod, "POST")
    XCTAssertEqual(post.url?.host, "api.vc.bilibili.com")
    let fields = messageFields(post)
    XCTAssertEqual(fields["msg[sender_uid]"], "123")
    XCTAssertEqual(fields["msg[receiver_id]"], "456")
    XCTAssertEqual(fields["csrf"], "fixture-message-csrf")
    XCTAssertNotNil(fields["w_rid"])
    XCTAssertNil(fields["access_key"])
    let encoded = try XCTUnwrap(fields["msg[content]"]?.data(using: .utf8))
    XCTAssertEqual((try JSONSerialization.jsonObject(with: encoded) as? [String: String])?["content"], content)
  }
  func testSendAfterSameIdentityRefreshUsesNewCookieAndMatchingCSRF() async throws {
    let clock = M6MessageClock()
    let transport = M6MessageTransport(refreshing: true)
    let service = BiliService(transport: transport, credentials: M6MessageCredentials(expiresAt: 2000),
      now: { clock.now() })
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    XCTAssertEqual(identity.token?.mid, 123)
    // A loaded conversation keeps its identity snapshot while its token naturally expires.
    clock.advance(to: 3000)
    let content = "Refresh '!*() & 世界 + literal+\n第二行"
    let sent = try await service.sendConversationMessage(receiverID: 456, content: content, expectedIdentity: identity)
    XCTAssertEqual(sent.text, content)
    let requests = await transport.requests
    XCTAssertEqual(requests.filter { $0.url?.path == "/api/oauth2/refreshToken" }.count, 1)
    let post = try XCTUnwrap(requests.first { $0.url?.path == "/web_im/v1/web_im/send_msg" })
    let fields = messageFields(post)
    XCTAssertEqual(post.httpMethod, "POST")
    XCTAssertEqual(fields["msg[sender_uid]"], "123")
    XCTAssertEqual(fields["csrf"], "fixture-message-new-csrf")
    XCTAssertEqual(fields["csrf_token"], "fixture-message-new-csrf")
    XCTAssertNil(fields["access_key"])
    let cookie = try XCTUnwrap(post.value(forHTTPHeaderField: "Cookie"))
    XCTAssertTrue(cookie.contains("SESSDATA=fixture-message-new-cookie"))
    XCTAssertTrue(cookie.contains("bili_jct=fixture-message-new-csrf"))
    XCTAssertFalse(cookie.contains("SESSDATA=fixture-message-cookie"))
    XCTAssertFalse(cookie.contains("bili_jct=fixture-message-csrf"))
    let encoded = try XCTUnwrap(fields["msg[content]"]?.data(using: .utf8))
    XCTAssertEqual((try JSONSerialization.jsonObject(with: encoded) as? [String: String])?["content"], content)
  }
  func testInvalidAndStaleRequestsDoNotSend() async throws {
    let transport = M6MessageTransport()
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    do { _ = try await service.sendConversationMessage(receiverID: 456, content: "  ", expectedIdentity: identity); XCTFail("Empty rejected") }
    catch BiliError.invalidResponse {}
    do { _ = try await service.conversationMessages(talkerID: 0, expectedIdentity: identity); XCTFail("Invalid talker rejected") }
    catch BiliError.invalidResponse {}
    _ = await service.beginLogin()
    do { _ = try await service.sendConversationMessage(receiverID: 456, content: "Hello", expectedIdentity: identity); XCTFail("Stale rejected") }
    catch is CancellationError {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
}
