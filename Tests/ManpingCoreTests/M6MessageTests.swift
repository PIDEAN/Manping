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

private actor MarkReadTransport: AuthTransport {
  enum Scenario {
    case normal, partialACK, stalled, exhausted, newMessages, chatFailure, malformedCounts, stickyFeed, feedFailure, blocked
    case singleMalformedCount, blockedFeed, blockedChat, blockedFeedFailure, blockedChatFailure
  }
  private let scenario: Scenario
  private(set) var requests: [URLRequest] = []
  private var acknowledged = Set<Int64>()
  private var feed = ["reply": 3, "at": 1, "like": 12]
  private var pause: CheckedContinuation<Void, Never>?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var didPause = false
  init(_ scenario: Scenario = .normal) { self.scenario = scenario }
  func waitUntilBlocked() async {
    if didPause { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() { pause?.resume(); pause = nil }
  private func row(_ id: Int64, _ sequence: Int64, _ timestamp: Int64) -> [String: Any] {
    // Deliberately no last_msg or user-card data: ACK must not depend on presentation parsing.
    ["talker_id": id, "session_type": 1, "max_seqno": sequence, "ack_seqno": 0,
      "unread_count": 1, "session_ts": timestamp]
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let path = request.url!.path, fields = messageFields(request)
    let blockFeed = [.blockedFeed, .blockedFeedFailure].contains(scenario) && path == "/x/msgfeed/unread"
    let blockChat = [.blockedChat, .blockedChatFailure].contains(scenario) && path.hasSuffix("/single_unread")
    if !didPause && (blockFeed || blockChat) {
      didPause = true
      await withCheckedContinuation { continuation in
        pause = continuation; for waiter in waiters { waiter.resume() }; waiters = []
      }
    }
    let payload: Any
    var code = 0
    switch path {
    case "/x/web-interface/nav":
      payload = ["wbi_img": ["img_url": "https://fixture.invalid/7cd084941338484aae1ad9425b84077c.png",
        "sub_url": "https://fixture.invalid/4932caff0ff746eab6f01bf08b70ac45.png"]]
    case "/session_svr/v1/session_svr/get_sessions":
      if scenario == .blocked, !didPause {
        didPause = true
        await withCheckedContinuation { continuation in
          pause = continuation; for waiter in waiters { waiter.resume() }; waiters = []
        }
      }
      let cursor = Int64(fields["end_ts"] ?? "0") ?? 0
      if scenario == .exhausted {
        payload = ["session_list": [row(1, 10, cursor == 0 ? 10_000 : cursor - 1)], "has_more": 1]
      } else if fields["session_type"] == "2" {
        payload = ["session_list": [row(1, 100, 300), row(3, 30, 100)], "has_more": 0]
      } else if cursor == 0 {
        payload = ["session_list": [row(1, 10, 300)], "has_more": 1]
      } else {
        payload = ["session_list": [row(1, 99, 300), row(2, 20, 200)], "has_more": scenario == .stalled ? 1 : 0]
      }
    case "/session_svr/v1/session_svr/update_ack":
      let id = Int64(fields["talker_id"] ?? "0") ?? 0
      if scenario == .partialACK, id == 2 { code = -500 }
      else { acknowledged.insert(id) }
      payload = [:] as [String: Int]
    case "/session_svr/v1/session_svr/batch_update_dustbin_ack":
      payload = [:] as [String: Int]
    case "/x/msgfeed/reply", "/x/msgfeed/at", "/x/msgfeed/like":
      let category = path.components(separatedBy: "/").last!
      if scenario != .stickyFeed { feed[category] = 0 }
      let page: [String: Any] = ["items": [], "cursor": ["id": 0, "time": 0, "is_end": true]]
      if category == "like" { payload = ["total": page] as [String: Any] }
      else { payload = page }
    case "/x/msgfeed/unread":
      if scenario == .feedFailure || scenario == .blockedFeedFailure { code = -500 }
      if scenario == .malformedCounts { payload = ["reply": false, "at": 0] as [String: Any] }
      else if scenario == .singleMalformedCount { payload = ["reply": false, "at": 1, "like": 12] as [String: Any] }
      else { payload = feed }
    case "/session_svr/v1/session_svr/single_unread":
      if scenario == .chatFailure || scenario == .blockedChatFailure { code = -500 }
      payload = ["follow_unread": scenario == .newMessages && !acknowledged.isEmpty ? 2 : 3 - acknowledged.count,
        "unfollow_unread": 0, "dustbin_unread": 9]
    default: code = -404; payload = [:] as [String: Int]
    }
    let body = try JSONSerialization.data(withJSONObject: ["code": code, "data": payload])
    return AuthHTTPResponse(body: body, response: HTTPURLResponse(url: request.url!, statusCode: 200,
      httpVersion: nil, headerFields: nil)!)
  }
}

extension M6MessageTests {
  func testPartialUnreadCountsKeepFeedWhenChatFails() async throws {
    XCTAssertTrue(MessageUnreadCounts().canMarkAllRead(isRunning: false, needsRetry: false))
    let transport = MarkReadTransport(.chatFailure)
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let unread = try await service.unreadMessageCounts(expectedIdentity: await service.authSnapshot())
    XCTAssertEqual(unread[.reply], 3); XCTAssertEqual(unread[.at], 1); XCTAssertEqual(unread[.like], 12)
    XCTAssertNil(unread[.chat]); XCTAssertNil(unread.total)
    XCTAssertEqual(unread.knownTotal, 16)
    XCTAssertTrue(unread.canMarkAllRead(isRunning: false, needsRetry: false))
    let requests = await transport.requests
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testPartialUnreadCountsKeepChatWhenFeedFails() async throws {
    let service = BiliService(transport: MarkReadTransport(.feedFailure), credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let unread = try await service.unreadMessageCounts(expectedIdentity: await service.authSnapshot())
    XCTAssertNil(unread[.reply]); XCTAssertNil(unread[.at]); XCTAssertNil(unread[.like])
    XCTAssertEqual(unread[.chat], 3); XCTAssertNil(unread.total); XCTAssertEqual(unread.knownTotal, 3)
    XCTAssertTrue(unread.canMarkAllRead(isRunning: false, needsRetry: false))
  }
  func testPartialUnreadCountsKeepValidFeedFields() async throws {
    let service = BiliService(transport: MarkReadTransport(.singleMalformedCount), credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let unread = try await service.unreadMessageCounts(expectedIdentity: await service.authSnapshot())
    XCTAssertNil(unread[.reply]); XCTAssertEqual(unread[.at], 1); XCTAssertEqual(unread[.like], 12)
    XCTAssertEqual(unread[.chat], 3); XCTAssertNil(unread.total); XCTAssertEqual(unread.knownTotal, 16)
  }
  func testUnreadActionAvailabilityDistinguishesUnknownZeroRetryAndRunning() {
    let zero = MessageUnreadCounts(UnreadMessages(reply: 0, at: 0, like: 0, chat: 0))
    let incompleteZero = MessageUnreadCounts(values: [.reply: 0, .at: 0, .like: 0])
    let positive = MessageUnreadCounts(UnreadMessages(reply: 3, at: 1, like: 12, chat: 0))
    XCTAssertFalse(zero.canMarkAllRead(isRunning: false, needsRetry: false))
    XCTAssertTrue(zero.canMarkAllRead(isRunning: false, needsRetry: true))
    XCTAssertTrue(incompleteZero.canMarkAllRead(isRunning: false, needsRetry: false))
    XCTAssertTrue(positive.canMarkAllRead(isRunning: false, needsRetry: false))
    for unread in [MessageUnreadCounts(), zero, incompleteZero, positive] {
      for retry in [false, true] { XCTAssertFalse(unread.canMarkAllRead(isRunning: true, needsRetry: retry)) }
    }
    XCTAssertEqual(MessageUnreadCounts(values: [.reply: Int64.max, .chat: 3]).knownTotal, Int64.max)
  }
  func testUnreadPollTaskCancellationDoesNotPublishPartialCounts() async throws {
    for scenario in [MarkReadTransport.Scenario.blockedFeed, .blockedChat] {
      let transport = MarkReadTransport(scenario)
      let service = BiliService(transport: transport, credentials: M6MessageCredentials())
      try await service.restoreCookies()
      let identity = await service.authSnapshot()
      let task = Task { try await service.unreadMessageCounts(expectedIdentity: identity) }
      await transport.waitUntilBlocked(); task.cancel(); await transport.release()
      do { _ = try await task.value; XCTFail("Cancelled poll must not publish a partial snapshot") }
      catch is CancellationError {}
      let requests = await transport.requests
      if scenario == .blockedFeed { XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("/single_unread") }) }
    }
  }
  func testUnreadPollIdentityChangeDoesNotPublishPartialCounts() async throws {
    for scenario in [MarkReadTransport.Scenario.blockedFeed, .blockedChat, .blockedFeedFailure, .blockedChatFailure] {
      let transport = MarkReadTransport(scenario), credentials = M6MessageCredentials()
      let service = BiliService(transport: transport, credentials: credentials)
      try await service.restoreCookies()
      let identity = await service.authSnapshot()
      let task = Task { try await service.unreadMessageCounts(expectedIdentity: identity) }
      await transport.waitUntilBlocked()
      try await service.logout()
      credentials.saveToken(identity.token)
      try await service.restoreCookies()
      await transport.release()
      do { _ = try await task.value; XCTFail("Stale poll must not publish a partial snapshot") }
      catch is CancellationError {}
      let current = await service.authSnapshot()
      XCTAssertEqual(current.token?.mid, identity.token?.mid)
      XCTAssertNotEqual(current.epoch, identity.epoch)
    }
  }
  func testMarkAllUsesFirstSnapshotSequenceAcrossPagesDeduplicatesAndPOSTsCSRF() async throws {
    let transport = MarkReadTransport()
    let bound = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await bound.restoreCookies()
    let result = await bound.markAllMessagesRead(expectedIdentity: await bound.authSnapshot())
    XCTAssertTrue(MessageSection.allCases.allSatisfy { result.outcomes[$0] == .success })
    XCTAssertEqual(result.unread.total, 0)
    let requests = await transport.requests
    let acknowledgements = requests.filter { $0.url!.path.hasSuffix("/update_ack") }
    XCTAssertEqual(acknowledgements.count, 3)
    XCTAssertEqual(acknowledgements.map { messageFields($0)["ack_seqno"] }, ["10", "20", "30"])
    for request in acknowledgements {
      XCTAssertEqual(request.httpMethod, "POST")
      let fields = messageFields(request)
      XCTAssertEqual(fields["csrf"], "fixture-message-csrf")
      XCTAssertEqual(fields["csrf_token"], "fixture-message-csrf")
      XCTAssertEqual(fields["mobi_app"], "web")
      XCTAssertEqual(fields["session_type"], "1")
      XCTAssertNil(fields["access_key"])
    }
    let sessions = requests.filter { $0.url!.path.hasSuffix("/get_sessions") }
    XCTAssertEqual(Set(sessions.map { messageFields($0)["session_type"] }), ["9", "2"])
    XCTAssertTrue(sessions.allSatisfy { messageFields($0)["group_fold"] == "0" && messageFields($0)["unfollow_fold"] == "0" })
    XCTAssertLessThan(try XCTUnwrap(requests.lastIndex { $0.url!.path.hasSuffix("/get_sessions") }),
      try XCTUnwrap(requests.firstIndex { $0.url!.path.hasSuffix("/update_ack") }))
    XCTAssertFalse(requests.contains { $0.url!.path.contains("dustbin_ack") || $0.url!.path.contains("/cards") })
    XCTAssertTrue(requests.filter { $0.url!.path.hasSuffix("/single_unread") }.allSatisfy { messageFields($0)["show_dustbin"] == "0" })
  }
  func testIncompleteOrNonAdvancingEnumerationNeverAcknowledgesOrReportsChatSuccess() async throws {
    for scenario in [MarkReadTransport.Scenario.stalled, .exhausted] {
      let transport = MarkReadTransport(scenario)
      let bound = BiliService(transport: transport, credentials: M6MessageCredentials())
      try await bound.restoreCookies()
      let result = await bound.markAllMessagesRead(expectedIdentity: await bound.authSnapshot())
      XCTAssertEqual(result.outcomes[.chat], .unknown)
      XCTAssertEqual(result.outcomes[.reply], .success)
      let requests = await transport.requests
      XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
      XCTAssertLessThanOrEqual(requests.filter { $0.url!.path.hasSuffix("/get_sessions") }.count, 100)
    }
  }
  func testMarkAllReportsACKFailureWithoutDiscardingOtherCategories() async throws {
    let transport = MarkReadTransport(.partialACK)
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let result = await service.markAllMessagesRead(expectedIdentity: await service.authSnapshot())
    XCTAssertEqual(result.outcomes[.chat], .partialFailure(count: 1))
    XCTAssertEqual(result.unread[.chat], 1)
    XCTAssertEqual(result.outcomes[.reply], .success)
    XCTAssertEqual(result.outcomes[.at], .success)
    XCTAssertEqual(result.outcomes[.like], .success)
  }
  func testNewMessagesKeepUnreadCountAndNeverAdvanceSnapshotBoundary() async throws {
    let transport = MarkReadTransport(.newMessages)
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let result = await service.markAllMessagesRead(expectedIdentity: await service.authSnapshot())
    XCTAssertEqual(result.outcomes[.chat], .success)
    XCTAssertEqual(result.unread[.chat], 2)
    let requests = await transport.requests
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.map { messageFields($0)["ack_seqno"] }, ["10", "20", "30"])
  }
  func testDuplicateOperationDoesNotPOSTOrCancelOriginal() async throws {
    let transport = MarkReadTransport(.blocked)
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let first = Task { await service.markAllMessagesRead(expectedIdentity: identity) }
    await transport.waitUntilBlocked()
    let second = await service.markAllMessagesRead(expectedIdentity: identity)
    XCTAssertTrue(second.outcomes.values.allSatisfy { $0 == .unknown })
    await transport.release()
    let result = await first.value
    XCTAssertTrue(result.outcomes.values.allSatisfy { $0 == .success })
    let requests = await transport.requests
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 3)
  }
  func testAccountALogoutAccountACancelsOldOperationBeforePOST() async throws {
    let transport = MarkReadTransport(.blocked), credentials = M6MessageCredentials()
    let service = BiliService(transport: transport, credentials: credentials)
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let task = Task { await service.markAllMessagesRead(expectedIdentity: identity) }
    await transport.waitUntilBlocked()
    try await service.logout()
    credentials.saveToken(identity.token)
    try await service.restoreCookies()
    await transport.release()
    let result = await task.value
    XCTAssertTrue(result.outcomes.values.allSatisfy { $0 == .cancelled })
    let current = await service.authSnapshot()
    XCTAssertEqual(current.token?.mid, identity.token?.mid)
    XCTAssertNotEqual(current.epoch, identity.epoch)
    let requests = await transport.requests
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
    XCTAssertNil(result.unread.total)
  }
  func testTaskCancellationStopsBeforeAnyPOST() async throws {
    let transport = MarkReadTransport(.blocked)
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let task = Task { await service.markAllMessagesRead(expectedIdentity: identity) }
    await transport.waitUntilBlocked(); task.cancel(); await transport.release()
    let result = await task.value
    XCTAssertTrue(result.outcomes.values.allSatisfy { $0 == .cancelled })
    let requests = await transport.requests
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
  }
  func testFeedCategoriesUseServerCountsAndMalformedCountsAreUnknown() async throws {
    for scenario in [MarkReadTransport.Scenario.stickyFeed, .malformedCounts] {
      let service = BiliService(transport: MarkReadTransport(scenario), credentials: M6MessageCredentials())
      try await service.restoreCookies()
      let result = await service.markAllMessagesRead(expectedIdentity: await service.authSnapshot())
      if scenario == .stickyFeed {
        XCTAssertEqual(result.outcomes[.reply], .partialFailure(count: 3))
        XCTAssertEqual(result.outcomes[.at], .partialFailure(count: 1))
        XCTAssertEqual(result.outcomes[.like], .partialFailure(count: 12))
      } else {
        XCTAssertEqual(result.outcomes[.reply], .unknown)
        XCTAssertNil(result.unread[.reply])
      }
      XCTAssertEqual(result.outcomes[.chat], .success)
    }
  }
  func testUnreadFailuresAreNotZeroAndCategoriesRefreshIndependently() async throws {
    for scenario in [MarkReadTransport.Scenario.chatFailure, .feedFailure] {
      let service = BiliService(transport: MarkReadTransport(scenario), credentials: M6MessageCredentials())
      try await service.restoreCookies()
      let identity = await service.authSnapshot()
      do { _ = try await service.unreadMessages(expectedIdentity: identity); XCTFail("Unread failure must throw") } catch {}
      let result = await service.markAllMessagesRead(expectedIdentity: identity)
      if scenario == .chatFailure {
        XCTAssertNil(result.unread[.chat]); XCTAssertEqual(result.outcomes[.chat], .unknown)
        XCTAssertEqual(result.outcomes[.reply], .success)
      } else {
        XCTAssertNil(result.unread[.reply]); XCTAssertEqual(result.outcomes[.reply], .unknown)
        XCTAssertEqual(result.outcomes[.chat], .success)
      }
    }
  }
  func testCancellationAtProgressHandoffPreventsAllAcknowledgements() async throws {
    let transport = MarkReadTransport()
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let operation = Task {
      await service.markAllMessagesRead(expectedIdentity: identity) { _, _, _ in
        // Cancel while returning progress across the actor boundary, before any ACK begins.
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    let result = await operation.value
    XCTAssertTrue(result.outcomes.values.allSatisfy { $0 == .cancelled })
    XCTAssertNil(result.unread.total)
    let requests = await transport.requests
    XCTAssertTrue(requests.contains { $0.url!.path == "/x/msgfeed/reply" })
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
  }
  func testUnreadGenerationRejectsPollFromBeforeOperationAndAcceptsFreshRead() {
    var gate = MessageUnreadGeneration()
    let oldPoll = gate.current
    gate.invalidate() // operation starts
    XCTAssertFalse(gate.accepts(oldPoll))
    let freshPoll = gate.invalidate() // operation finishes and immediately starts a new read
    XCTAssertTrue(gate.accepts(freshPoll))
    gate.invalidate() // account changes
    XCTAssertFalse(gate.accepts(freshPoll))
  }
  func testMessageCountParserRejectsMissingBooleanNegativeAndFractionalValues() {
    for value: Any? in [nil, true, false, -1, 1.5, "bad"] { XCTAssertThrowsError(try messageRequiredCount(value)) }
    XCTAssertEqual(try messageRequiredCount("12"), 12)
    XCTAssertEqual(try messageRequiredCount(0), 0)
  }
  func testDustbinRouteUsesPOSTAndBothCSRFFieldsWithoutJoiningMarkAll() async throws {
    let transport = MarkReadTransport()
    let service = BiliService(transport: transport, credentials: M6MessageCredentials())
    try await service.restoreCookies()
    try await service.testDustbinAcknowledgement()
    let requests = await transport.requests
    let post = try XCTUnwrap(requests.first { $0.httpMethod == "POST" })
    XCTAssertTrue(post.url!.path.hasSuffix("/batch_update_dustbin_ack"))
    XCTAssertEqual(messageFields(post)["csrf"], "fixture-message-csrf")
    XCTAssertEqual(messageFields(post)["csrf_token"], "fixture-message-csrf")
  }
}

private extension BiliService {
  func testDustbinAcknowledgement() async throws {
    _ = try await messageWebREST(.batchDustbinAcknowledgement, expectedIdentity: authSnapshot())
  }
}
