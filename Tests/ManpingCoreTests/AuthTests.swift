import Foundation
import XCTest

@testable import ManpingCore

private final class FixtureStore: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var cookies: [HTTPCookie] = []
  private var token: AppToken?
  func save(_ value: [HTTPCookie]) { lock.withLock { cookies = value } }
  func load() -> [HTTPCookie] { lock.withLock { cookies } }
  func saveToken(_ value: AppToken?) { lock.withLock { token = value } }
  func loadToken() -> AppToken? { lock.withLock { token } }
  func clear() {
    lock.withLock {
      cookies = []
      token = nil
    }
  }
}
private enum FixtureStorageFailure: Error { case denied }
private final class FailingFixtureStore: AuthCredentialStore, @unchecked Sendable {
  let base = FixtureStore()
  private let lock = NSLock()
  var failClear = false
  var failNewToken = false
  private(set) var writes: [String] = []
  func save(_ cookies: [HTTPCookie]) {
    lock.withLock {
      writes.append("cookies")
      base.save(cookies)
    }
  }
  func load() -> [HTTPCookie] { base.load() }
  func saveToken(_ token: AppToken?) throws {
    try lock.withLock {
      writes.append(token == nil ? "clearToken" : "newToken")
      if token == nil && failClear { throw FixtureStorageFailure.denied }
      if token != nil && failNewToken { throw FixtureStorageFailure.denied }
      base.saveToken(token)
    }
  }
  func loadToken() -> AppToken? { base.loadToken() }
  func clear() { base.clear() }
}
private actor FixtureTransport: AuthTransport {
  struct Reply: Sendable {
    let body: Data
    let headers: [String: String]
    let status: Int
    init(_ json: String, headers: [String: String] = [:], status: Int = 200) {
      body = Data(json.utf8)
      self.headers = headers
      self.status = status
    }
  }
  var replies: [Reply]
  var requests: [URLRequest] = []
  var paused = false
  var cancelled = 0
  var failCount = 0
  private var releases: [CheckedContinuation<Void, Never>] = []
  private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
  init(_ replies: [Reply], paused: Bool = false) {
    self.replies = replies
    self.paused = paused
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    if failCount > 0 {
      failCount -= 1
      throw URLError(.timedOut)
    }
    let reply = replies.removeFirst()
    let ready = observers.filter { requests.count >= $0.0 }
    observers.removeAll { requests.count >= $0.0 }
    for (_, observer) in ready { observer.resume() }
    if paused {
      await withTaskCancellationHandler {
        await withCheckedContinuation { releases.append($0) }
      } onCancel: {
        Task { await self.recordCancellation() }
      }
    }
    return AuthHTTPResponse(
      body: reply.body,
      response: HTTPURLResponse(
        url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
    )
  }
  func failNext(_ count: Int) { failCount = count }
  func recordCancellation() { cancelled += 1 }
  func waitForRequests(_ count: Int) async {
    if requests.count >= count { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }
  func release() {
    paused = false
    let pending = releases
    releases = []
    for item in pending { item.resume() }
  }
}
private let qrReply = FixtureTransport.Reply(
  #"{"code":0,"data":{"url":"https://passport.bilibili.com/tv/fixture","auth_code":"fixture-qr"}}"#)
private let tokenReply = FixtureTransport.Reply(
  #"{"code":0,"data":{"mid":123,"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"cookie_info":{"cookies":[{"name":"SESSDATA","value":"fixture-session"},{"name":"bili_jct","value":"fixture-csrf"}]}}}"#
)
private func fixtureCookie(
  _ name: String = "SESSDATA", value: String = "fixture-session", domain: String = ".bilibili.com",
  path: String = "/", expires: Date? = nil, secure: Bool = true
) -> HTTPCookie {
  var properties: [HTTPCookiePropertyKey: Any] = [
    .name: name, .value: value, .domain: domain, .path: path,
  ]
  if secure { properties[.secure] = "TRUE" }
  if let expires { properties[.expires] = expires }
  return HTTPCookie(properties: properties)!
}
private func fields(_ request: URLRequest) -> [String: String] {
  let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  return Dictionary(
    uniqueKeysWithValues: text.split(separator: "&").map {
      let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      func decode(_ value: Substring) -> String {
        String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!
      }
      return (decode(pair[0]), decode(pair[1]))
    })
}

final class AuthTests: XCTestCase, @unchecked Sendable {
  func testWebQRReplacesValidAppIdentityWithWebOnly() async throws {
    let store = FixtureStore()
    store.save([fixtureCookie(value: "fixture-A"), fixtureCookie("DedeUserID", value: "99")])
    store.saveToken(
      AppToken(
        mid: 99, accessToken: "fixture-A-token", refreshToken: "fixture-A-refresh",
        expiresAt: 9_999_999_999))
    let transport = FixtureTransport([
      .init(
        #"{"code":0,"data":{"url":"https://passport.bilibili.com/web/fixture","qrcode_key":"fixture-B-qr"}}"#
      ),
      .init(
        #"{"code":0,"data":{"code":0}}"#,
        headers: ["Set-Cookie": "SESSDATA=fixture-B; Domain=.bilibili.com; Path=/; Secure"]),
    ])
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    let qr = try await service.beginWebQR()
    let status = try await service.pollQR(qr.key, token: qr.token)
    XCTAssertEqual(status, .success)
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .webOnly)
    XCTAssertNil(snapshot.token)
    XCTAssertNil(store.loadToken())
    XCTAssertEqual(store.load().first(where: { $0.name == "SESSDATA" })?.value, "fixture-B")
    XCTAssertFalse(store.load().contains { $0.value == "fixture-A" })
  }
  func testIdentityReplacementRejectsLateRefreshSuccessAndFailure() async throws {
    for reply in [
      tokenReply,
      FixtureTransport.Reply(
        #"{"code":-101}"#,
        headers: ["Set-Cookie": "SESSDATA=fixture-late-A; Domain=.bilibili.com; Path=/; Secure"]),
    ] {
      let store = FixtureStore()
      store.save([fixtureCookie(value: "fixture-A"), fixtureCookie("DedeUserID", value: "123")])
      store.saveToken(
        AppToken(
          mid: 123, accessToken: "fixture-A-token", refreshToken: "fixture-A-refresh", expiresAt: 10
        ))
      let transport = FixtureTransport([reply], paused: true)
      let service = BiliService(transport: transport, credentials: store)
      try await service.restoreCookies()
      let epoch = await service.beginLogin()
      let task = Task { try await service.ensureAppToken() }
      await transport.waitForRequests(1)
      let accepted = try await service.synchronizeCookies(
        [fixtureCookie(value: "fixture-B"), fixtureCookie("DedeUserID", value: "456")], token: epoch
      )
      XCTAssertTrue(accepted)
      await transport.release()
      do {
        _ = try await task.value
        XCTFail("Old refresh must not affect replacement")
      } catch is CancellationError {}
      let snapshot = await service.authSnapshot()
      XCTAssertEqual(snapshot.state, .webOnly)
      XCTAssertNil(snapshot.token)
      XCTAssertNil(store.loadToken())
      XCTAssertEqual(store.load().first(where: { $0.name == "SESSDATA" })?.value, "fixture-B")
      let restored = BiliService(transport: FixtureTransport([]), credentials: store)
      try await restored.restoreCookies()
      let restoredSnapshot = await restored.authSnapshot()
      XCTAssertEqual(restoredSnapshot.state, .webOnly)
    }
  }
  func testLateRefreshFailureCannotClearReplacementAppToken() async throws {
    let store = FixtureStore()
    store.save([fixtureCookie(value: "fixture-A"), fixtureCookie("DedeUserID", value: "99")])
    store.saveToken(
      AppToken(
        mid: 99, accessToken: "fixture-A-token", refreshToken: "fixture-A-refresh", expiresAt: 10))
    let transport = FixtureTransport(
      [.init(#"{"code":-101}"#), qrReply, .init(#"{"code":0}"#), tokenReply], paused: true)
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    let epoch = await service.beginLogin()
    let oldRefresh = Task { try await service.ensureAppToken() }
    await transport.waitForRequests(1)
    _ = try await service.synchronizeCookies(
      [
        fixtureCookie(value: "fixture-B"), fixtureCookie("DedeUserID", value: "123"),
        fixtureCookie("bili_jct", value: "fixture-B-csrf"),
      ], token: epoch)
    await transport.stopPausingNewRequests()
    let authorized = try await service.authorizeWebCookies(token: epoch)
    XCTAssertEqual(authorized.epoch, epoch)
    XCTAssertEqual(authorized.state, .appAuthorized)
    await transport.release()
    do {
      _ = try await oldRefresh.value
      XCTFail("Old refresh failure must cancel")
    } catch is CancellationError {}
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .appAuthorized)
    XCTAssertEqual(snapshot.token?.mid, 123)
    XCTAssertEqual(store.loadToken(), snapshot.token)
  }
  func testTVNewTokenWriteFailureLeavesOnlyNewWebIdentity() async throws {
    let store = FailingFixtureStore()
    store.base.save([fixtureCookie(value: "fixture-A"), fixtureCookie("DedeUserID", value: "99")])
    store.base.saveToken(
      AppToken(
        mid: 99, accessToken: "fixture-A-token", refreshToken: "fixture-A-refresh",
        expiresAt: 9_999_999_999))
    store.failNewToken = true
    let service = BiliService(
      transport: FixtureTransport([qrReply, tokenReply]), credentials: store)
    try await service.restoreCookies()
    let qr = try await service.beginQR()
    do {
      _ = try await service.pollQR(qr.key, token: qr.token)
      XCTFail("New Token write must fail")
    } catch FixtureStorageFailure.denied {}
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .webOnly)
    XCTAssertNil(snapshot.token)
    XCTAssertNil(store.loadToken())
    XCTAssertEqual(store.writes, ["clearToken", "cookies", "newToken", "clearToken"])
    XCTAssertFalse(store.load().contains { $0.value == "fixture-A" })
    let restored = BiliService(transport: FixtureTransport([]), credentials: store)
    try await restored.restoreCookies()
    let restoredSnapshot = await restored.authSnapshot()
    XCTAssertEqual(restoredSnapshot.state, .webOnly)
    XCTAssertNil(restoredSnapshot.token)
  }
  func testOldTokenClearFailureCannotPersistNewCookies() async throws {
    let store = FailingFixtureStore()
    let old = AppToken(
      mid: 99, accessToken: "fixture-A-token", refreshToken: "fixture-A-refresh",
      expiresAt: 9_999_999_999)
    store.base.save([fixtureCookie(value: "fixture-A"), fixtureCookie("DedeUserID", value: "99")])
    store.base.saveToken(old)
    store.failClear = true
    let service = BiliService(
      transport: FixtureTransport([qrReply, tokenReply]), credentials: store)
    try await service.restoreCookies()
    let qr = try await service.beginQR()
    do {
      _ = try await service.pollQR(qr.key, token: qr.token)
      XCTFail("Old Token clear must fail")
    } catch FixtureStorageFailure.denied {}
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .webOnly)
    XCTAssertNil(snapshot.token)
    XCTAssertEqual(store.loadToken(), old)
    XCTAssertEqual(store.writes, ["clearToken"])
    XCTAssertEqual(store.load().first(where: { $0.name == "SESSDATA" })?.value, "fixture-A")
    let restored = BiliService(transport: FixtureTransport([]), credentials: store)
    try await restored.restoreCookies()
    let restoredSnapshot = await restored.authSnapshot()
    XCTAssertEqual(restoredSnapshot.token, old)
    XCTAssertFalse(store.load().contains { $0.value == "fixture-session" })
  }
  func testTVTokenCookieMIDMismatchIsRejectedBeforeCookieWrite() async throws {
    let store = FixtureStore()
    let mismatched = FixtureTransport.Reply(
      #"{"code":0,"data":{"mid":123,"access_token":"fixture-B-token","refresh_token":"fixture-B-refresh","expires_in":3600,"cookie_info":{"cookies":[{"name":"SESSDATA","value":"fixture-B"},{"name":"DedeUserID","value":"456"}]}}}"#
    )
    let service = BiliService(
      transport: FixtureTransport([qrReply, mismatched]), credentials: store)
    let qr = try await service.beginQR()
    do {
      _ = try await service.pollQR(qr.key, token: qr.token)
      XCTFail("MID mismatch must reject")
    } catch AuthFailure.invalidResponse {}
    XCTAssertNil(store.loadToken())
    XCTAssertTrue(store.load().isEmpty)
  }
  func testRestoreQuarantinesMixedPersistedIdentity() async throws {
    let store = FixtureStore()
    store.save([fixtureCookie(value: "fixture-B"), fixtureCookie("DedeUserID", value: "456")])
    store.saveToken(
      AppToken(
        mid: 123, accessToken: "fixture-A-token", refreshToken: "fixture-A-refresh",
        expiresAt: 9_999_999_999))
    let service = BiliService(transport: FixtureTransport([]), credentials: store)
    do {
      try await service.restoreCookies()
      XCTFail("Mixed identity must reject")
    } catch AuthFailure.invalidResponse {}
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .webOnly)
    XCTAssertNil(snapshot.token)
    XCTAssertNil(store.loadToken())
  }
  func testLastWaiterCancellationInterleavesWithNewRegistration() async throws {
    let task = Task<AppToken, Error> {
      try await Task.sleep(for: .seconds(60))
      throw AuthFailure.needsLogin
    }
    let flight = AuthRefreshFlight(task: task)
    let first = UUID()
    let second = UUID()
    XCTAssertTrue(flight.tryRegister(first))
    let preflight = DispatchSemaphore(value: 0)
    let cancelled = DispatchSemaphore(value: 0)
    let registered: Bool = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        // Reproduce the exact former gap: lookup sees a live task, last waiter cancels, then registration runs.
        let wasLive = !task.isCancelled
        preflight.signal()
        let result = cancelled.wait(timeout: .now() + 5)
        continuation.resume(returning: wasLive && result == .success && flight.tryRegister(second))
      }
      DispatchQueue.global().async {
        if preflight.wait(timeout: .now() + 5) == .success {
          flight.remove(first, cancelIfEmpty: true)
        }
        cancelled.signal()
      }
    }
    XCTAssertFalse(registered)
    XCTAssertTrue(task.isCancelled)
    let replacementTask = Task<AppToken, Error> {
      try await Task.sleep(for: .seconds(60))
      throw AuthFailure.needsLogin
    }
    let replacement = AuthRefreshFlight(task: replacementTask)
    XCTAssertTrue(replacement.tryRegister(second))
    replacement.remove(second, cancelIfEmpty: true)
    do {
      _ = try await task.value
      XCTFail("Old flight must cancel")
    } catch is CancellationError {}
    do {
      _ = try await replacementTask.value
      XCTFail("Replacement cleanup must cancel")
    } catch is CancellationError {}
  }
  func testKnownSignatureAndFormEncoding() {
    // Independent Python hashlib oracle: md5(b'a=1&b=two wordsfixture-secret').
    XCTAssertEqual(
      AppForm.signature(["b": "two words", "a": "1"], secret: "fixture-secret"),
      "51a4b26d612892ec3ad7942472006d36")
    XCTAssertEqual(
      String(decoding: AppForm.encoded(["a": "a+b &/=中文", "empty": ""]), as: UTF8.self),
      "a=a%2Bb+%26%2F%3D%E4%B8%AD%E6%96%87&empty=")
    let body = AppForm.authorized(
      ["local_id": "fixture", "access_key": "must-drop"], timestamp: 123)
    var request = URLRequest(url: URL(string: "https://passport.bilibili.com/")!)
    request.httpBody = body
    let parsed = fields(request)
    XCTAssertEqual(parsed["build"], "80200100")
    XCTAssertEqual(parsed["mobi_app"], "iphone")
    XCTAssertEqual(parsed["platform"], "ios")
    XCTAssertEqual(parsed["ts"], "123")
    XCTAssertNil(parsed["access_key"])
    XCTAssertEqual(parsed["sign"]?.count, 32)
  }
  func testCookieDomainPathSecureExpiryAndSetCookie() {
    let now = Date()
    var jar = BiliCookieJar()
    jar.merge([
      fixtureCookie(), fixtureCookie("host", domain: "passport.bilibili.com"),
      fixtureCookie("path", path: "/login"),
      fixtureCookie("dead", expires: now.addingTimeInterval(-10)),
      fixtureCookie("evil", domain: "bilibili.com.evil.test"),
    ])
    XCTAssertEqual(
      Set(jar.matching(URL(string: "https://passport.bilibili.com/login/ok")!).map(\.name)),
      ["SESSDATA", "host", "path"])
    XCTAssertEqual(
      jar.matching(URL(string: "https://api.bilibili.com/loginfoo")!).map(\.name), ["SESSDATA"])
    XCTAssertNil(jar.header(URL(string: "https://evil.test/")!))
    XCTAssertNil(jar.header(URL(string: "http://api.bilibili.com/")!))
    let response = HTTPURLResponse(
      url: URL(string: "https://passport.bilibili.com/")!, statusCode: 200, httpVersion: nil,
      headerFields: ["Set-Cookie": "injected=fixture; Domain=.com; Path=/"])!
    jar.receive(response)
    XCTAssertFalse(jar.cookies.contains { $0.name == "injected" })
    let valid = HTTPURLResponse(
      url: URL(string: "https://passport.bilibili.com/")!, statusCode: 200, httpVersion: nil,
      headerFields: ["Set-Cookie": "accepted=fixture; Domain=.bilibili.com; Path=/; Secure"])!
    jar.receive(valid)
    XCTAssertTrue(jar.cookies.contains { $0.name == "accepted" })
  }
  func testLegacyCookieAndTokenCodecWithoutKeychain() throws {
    let future = Date().addingTimeInterval(4000)
    let data = try CredentialStore.encodeCookies([
      fixtureCookie(expires: future), fixtureCookie("evil", domain: ".evil.test"),
    ])
    let cookies = try CredentialStore.decodeCookies(data)
    XCTAssertEqual(cookies.count, 1)
    XCTAssertEqual(cookies[0].value, "fixture-session")
    XCTAssertTrue(cookies[0].isSecure)
    XCTAssertEqual(
      cookies[0].expiresDate!.timeIntervalSince1970, future.timeIntervalSince1970, accuracy: 1)
    let token = AppToken(
      mid: 123, accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: 12345)
    XCTAssertEqual(
      try JSONDecoder().decode(AppToken.self, from: JSONEncoder().encode(token)), token)
  }
  func testTVQRStatusesSuccessAndTTL() async throws {
    let transport = FixtureTransport([
      qrReply, .init(#"{"code":86039}"#), .init(#"{"code":86090}"#), .init(#"{"code":86038}"#),
      tokenReply,
    ])
    let store = FixtureStore()
    let service = BiliService(
      transport: transport, credentials: store, now: { Date(timeIntervalSince1970: 1000) },
      localID: "fixture-local")
    let qr = try await service.beginQR()
    let waiting = try await service.pollQR(qr.key, token: qr.token)
    let scanned = try await service.pollQR(qr.key, token: qr.token)
    let expired = try await service.pollQR(qr.key, token: qr.token)
    let success = try await service.pollQR(qr.key, token: qr.token)
    XCTAssertEqual(waiting, .waiting)
    XCTAssertEqual(scanned, .scanned)
    XCTAssertEqual(expired, .expired)
    XCTAssertEqual(success, .success)
    XCTAssertEqual(store.loadToken()?.expiresAt, 4600)
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .appAuthorized)
    XCTAssertEqual(snapshot.tokenHeaders["authorization"], "identify_v1 fixture-access")
    let requests = await transport.requests
    XCTAssertEqual(requests[0].url?.path, "/x/passport-tv-login/qrcode/auth_code")
    XCTAssertEqual(requests[0].httpMethod, "POST")
    for request in requests {
      XCTAssertNil(fields(request)["access_key"])
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
  }
  func testWebCookieConversionCSRFWithoutTrailingSemicolon() async throws {
    let transport = FixtureTransport([qrReply, .init(#"{"code":0}"#), tokenReply])
    let store = FixtureStore()
    store.saveToken(
      AppToken(
        mid: 99, accessToken: "fixture-old", refreshToken: "fixture-old-refresh",
        expiresAt: 9_999_999_999))
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    let epoch = await service.beginLogin()
    let accepted = try await service.synchronizeCookies(
      [fixtureCookie(), fixtureCookie("bili_jct", value: "fixture-csrf")], token: epoch)
    XCTAssertTrue(accepted)
    let snapshot = try await service.authorizeWebCookies(token: epoch)
    XCTAssertEqual(snapshot.state, .appAuthorized)
    let requests = await transport.requests
    XCTAssertEqual(requests[1].url?.path, "/x/passport-tv-login/h5/qrcode/confirm")
    XCTAssertEqual(fields(requests[1])["csrf"], "fixture-csrf")
    XCTAssertTrue(
      requests[1].value(forHTTPHeaderField: "Cookie")!.hasSuffix("bili_jct=fixture-csrf"))
    for request in requests { XCTAssertNil(fields(request)["access_key"]) }
  }
  func testConversionFailurePreservesExplicitWebOnly() async throws {
    let transport = FixtureTransport([
      qrReply, .init(#"{"code":-101,"message":"access_token=secret-server-error"}"#),
    ])
    let store = FixtureStore()
    let service = BiliService(transport: transport, credentials: store)
    let epoch = await service.beginLogin()
    _ = try await service.synchronizeCookies(
      [fixtureCookie(), fixtureCookie("bili_jct", value: "fixture-csrf")], token: epoch)
    do {
      _ = try await service.authorizeWebCookies(token: epoch)
      XCTFail("Must reject")
    } catch { XCTAssertFalse(error.localizedDescription.contains("secret-server-error")) }
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .webOnly)
    XCTAssertNil(store.loadToken())
    XCTAssertEqual(store.load().count, 2)
  }
  func testMissingCSRFDoesNotStartNetwork() async throws {
    let transport = FixtureTransport([])
    let service = BiliService(transport: transport, credentials: FixtureStore())
    let epoch = await service.beginLogin()
    _ = try await service.synchronizeCookies([fixtureCookie()], token: epoch)
    do {
      _ = try await service.authorizeWebCookies(token: epoch)
      XCTFail("Must require CSRF")
    } catch AuthFailure.missingCSRF {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testExpiredRefreshSingleFlight() async throws {
    let store = FixtureStore()
    store.saveToken(
      AppToken(
        mid: 123, accessToken: "fixture-old", refreshToken: "fixture-old-refresh", expiresAt: 10))
    let transport = FixtureTransport([tokenReply], paused: true)
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    let first = Task { try await service.ensureAppToken() }
    await transport.waitForRequests(1)
    let second = Task { try await service.ensureAppToken() }
    // The shared task is still held at a deterministic transport barrier.
    await Task.yield()
    await transport.release()
    let tokens = try await (first.value, second.value)
    XCTAssertEqual(tokens.0, tokens.1)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].url?.path, "/api/oauth2/refreshToken")
    XCTAssertEqual(fields(requests[0])["access_key"], "fixture-old")
    XCTAssertEqual(fields(requests[0])["refresh_token"], "fixture-old-refresh")
  }
  func testRefreshRejectedClearsTokenAndNeedsLogin() async throws {
    let store = FixtureStore()
    store.saveToken(
      AppToken(
        mid: 123, accessToken: "fixture-old", refreshToken: "fixture-old-refresh", expiresAt: 10))
    let transport = FixtureTransport([.init(#"{"code":-101}"#)])
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    do {
      _ = try await service.ensureAppToken()
      XCTFail("Must reject")
    } catch AuthFailure.rejected(-101) {}
    XCTAssertNil(store.loadToken())
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .needsLogin)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }
  func testLogoutRejectsLateCookieResponseAndAccountResult() async throws {
    let store = FixtureStore()
    let transport = FixtureTransport(
      [
        .init(
          #"{"code":0,"data":{"uname":"fixture-user"}}"#,
          headers: ["Set-Cookie": "SESSDATA=fixture-late; Domain=.bilibili.com; Path=/; Secure"])
      ], paused: true)
    let service = BiliService(transport: transport, credentials: store)
    let task = Task { try await service.accountName() }
    await transport.waitForRequests(1)
    try await service.logout()
    await transport.release()
    do {
      _ = try await task.value
      XCTFail("Late account result must cancel")
    } catch is CancellationError {}
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .needsLogin)
    XCTAssertTrue(store.load().isEmpty)
  }
  func testLogoutRejectsLateTVTokenAndWKCookies() async throws {
    let store = FixtureStore()
    let transport = FixtureTransport([qrReply, tokenReply])
    let service = BiliService(transport: transport, credentials: store)
    let qr = try await service.beginQR()
    await transport.setPaused()
    let poll = Task { try await service.pollQR(qr.key, token: qr.token) }
    await transport.waitForRequests(2)
    try await service.logout()
    await transport.release()
    do {
      _ = try await poll.value
      XCTFail("Late token must cancel")
    } catch is CancellationError {}
    let accepted = try await service.synchronizeCookies([fixtureCookie()], token: qr.token)
    XCTAssertFalse(accepted)
    XCTAssertNil(store.loadToken())
    XCTAssertTrue(store.load().isEmpty)
  }
  func testCallerCancellationCancelsTransportAndRejectsCookies() async throws {
    let transport = FixtureTransport(
      [
        .init(
          #"{}"#,
          headers: ["Set-Cookie": "SESSDATA=fixture-late; Domain=.bilibili.com; Path=/; Secure"])
      ], paused: true)
    let service = BiliService(transport: transport, credentials: FixtureStore())
    let task = Task { try await service.data(URL(string: "https://passport.bilibili.com/")!) }
    await transport.waitForRequests(1)
    task.cancel()
    await transport.release()
    do {
      _ = try await task.value
      XCTFail("Must cancel")
    } catch is CancellationError {}
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .needsLogin)
  }
  func testLogoutRejectsLateQRGeneration() async throws {
    let store = FixtureStore()
    let transport = FixtureTransport([qrReply], paused: true)
    let service = BiliService(transport: transport, credentials: store)
    let task = Task { try await service.beginQR() }
    await transport.waitForRequests(1)
    try await service.logout()
    await transport.release()
    do {
      _ = try await task.value
      XCTFail("Late QR generation must cancel")
    } catch is CancellationError {}
    XCTAssertNil(store.loadToken())
  }
  func testLogoutRejectsLateRefresh() async throws {
    let store = FixtureStore()
    store.saveToken(
      AppToken(
        mid: 123, accessToken: "fixture-old", refreshToken: "fixture-old-refresh", expiresAt: 10))
    let transport = FixtureTransport([tokenReply], paused: true)
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    let task = Task { try await service.ensureAppToken() }
    await transport.waitForRequests(1)
    try await service.logout()
    await transport.release()
    do {
      _ = try await task.value
      XCTFail("Late refresh must cancel")
    } catch is CancellationError {}
    XCTAssertNil(store.loadToken())
    XCTAssertTrue(store.load().isEmpty)
  }
  func testCancellingOneRefreshWaiterPreservesOtherWaiter() async throws {
    let task = Task<AppToken, Error> {
      try await Task.sleep(for: .seconds(60))
      throw AuthFailure.needsLogin
    }
    let flight = AuthRefreshFlight(task: task)
    let first = UUID()
    let second = UUID()
    XCTAssertTrue(flight.tryRegister(first))
    XCTAssertTrue(flight.tryRegister(second))
    flight.remove(first, cancelIfEmpty: true)
    XCTAssertFalse(task.isCancelled)
    flight.remove(second, cancelIfEmpty: true)
    XCTAssertTrue(task.isCancelled)
    do {
      _ = try await task.value
      XCTFail("Last waiter must cancel")
    } catch is CancellationError {}
  }
  func testAbandonedRefreshCancelsTransportAndCannotSaveToken() async throws {
    let store = FixtureStore()
    let old = AppToken(
      mid: 123, accessToken: "fixture-old", refreshToken: "fixture-old-refresh", expiresAt: 10)
    store.saveToken(old)
    let transport = FixtureTransport([tokenReply], paused: true)
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    let task = Task { try await service.ensureAppToken() }
    await transport.waitForRequests(1)
    task.cancel()
    await transport.release()
    do {
      _ = try await task.value
      XCTFail("Abandoned refresh must cancel")
    } catch is CancellationError {}
    XCTAssertEqual(store.loadToken(), old)
  }
  func testHTTPRejectionIsNotRetriedOrDisplayedVerbatim() async throws {
    let store = FixtureStore()
    store.saveToken(
      AppToken(
        mid: 123, accessToken: "fixture-old", refreshToken: "fixture-old-refresh", expiresAt: 10))
    let transport = FixtureTransport([.init("secret-server-body", status: 401)])
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    do {
      _ = try await service.ensureAppToken()
      XCTFail("Must reject")
    } catch AuthFailure.rejected(let code) { XCTAssertEqual(code, 401) }
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertNil(store.loadToken())
  }
  func testRefreshTransportRetryIsBounded() async throws {
    let store = FixtureStore()
    store.saveToken(
      AppToken(
        mid: 123, accessToken: "fixture-old", refreshToken: "fixture-old-refresh", expiresAt: 10))
    let transport = FixtureTransport([])
    await transport.failNext(3)
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    do {
      _ = try await service.ensureAppToken()
      XCTFail("Must stop retrying")
    } catch AuthFailure.transport {}
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertNil(store.loadToken())
  }
  func testRefreshTransientFailureCanRecover() async throws {
    let store = FixtureStore()
    store.saveToken(
      AppToken(
        mid: 123, accessToken: "fixture-old", refreshToken: "fixture-old-refresh", expiresAt: 10))
    let transport = FixtureTransport([tokenReply])
    await transport.failNext(1)
    let service = BiliService(transport: transport, credentials: store)
    try await service.restoreCookies()
    let token = try await service.ensureAppToken()
    XCTAssertEqual(token.accessToken, "fixture-access")
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
  }
  func testTTLOverflowAndMissingTokenAreRejected() async throws {
    let transport = FixtureTransport([
      qrReply,
      .init(
        #"{"code":0,"data":{"mid":123,"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":9223372036854775807}}"#
      ),
    ])
    let store = FixtureStore()
    let service = BiliService(
      transport: transport, credentials: store, now: { Date(timeIntervalSince1970: 1000) })
    let qr = try await service.beginQR()
    do {
      _ = try await service.pollQR(qr.key, token: qr.token)
      XCTFail("Must reject TTL overflow")
    } catch AuthFailure.invalidResponse {}
    XCTAssertNil(store.loadToken())
    do {
      _ = try await service.ensureAppToken()
      XCTFail("Must require token")
    } catch AuthFailure.needsLogin {}
  }
  func testLegacyWebQRRemainsAvailable() async throws {
    let transport = FixtureTransport([
      .init(
        #"{"code":0,"data":{"url":"https://passport.bilibili.com/web/fixture","qrcode_key":"fixture-web-qr"}}"#
      ),
      .init(
        #"{"code":0,"data":{"code":0}}"#,
        headers: ["Set-Cookie": "SESSDATA=fixture-web; Domain=.bilibili.com; Path=/; Secure"]),
    ])
    let store = FixtureStore()
    let service = BiliService(transport: transport, credentials: store)
    let qr = try await service.beginWebQR()
    let status = try await service.pollQR(qr.key, token: qr.token)
    XCTAssertEqual(status, .success)
    let snapshot = await service.authSnapshot()
    XCTAssertEqual(snapshot.state, .webOnly)
    XCTAssertEqual(store.load().count, 1)
    XCTAssertNil(store.loadToken())
  }
  @MainActor func testUIAndWKCallbackGenerationRejectsLogoutAndDismantle() {
    let gate = AuthCallbackGate()
    let accountGeneration = gate.generation
    gate.invalidate()
    XCTAssertFalse(gate.accepts(accountGeneration))
    let wkGeneration = gate.generation
    gate.invalidate()
    XCTAssertFalse(gate.accepts(wkGeneration))
    XCTAssertTrue(gate.accepts(gate.generation))
  }
  func testSessionIsolation() {
    let config = URLSessionConfiguration.default
    config.httpAdditionalHeaders = ["Cookie": "fixture-global"]
    let transport = IsolatedAuthTransport(configuration: config)
    XCTAssertNil(transport.session.configuration.httpCookieStorage)
    XCTAssertFalse(transport.session.configuration.httpShouldSetCookies)
    XCTAssertNil(transport.session.configuration.httpAdditionalHeaders)
    XCTAssertNotNil(config.httpCookieStorage)
  }
}
extension FixtureTransport {
  fileprivate func stopPausingNewRequests() { paused = false }
  fileprivate func setPaused() { paused = true }
}
