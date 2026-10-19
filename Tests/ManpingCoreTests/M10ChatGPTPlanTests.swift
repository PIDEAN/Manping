import Foundation
import Security
import XCTest
@testable import ManpingCore

/// Synthetic identity provider: RSA key, JWKS, ID-token minting. No real OpenAI endpoint is contacted.
private final class FixtureIdentity: @unchecked Sendable {
  let privateKey: SecKey
  let jwks: Data
  let issuer = "https://auth.fixture.invalid"
  init() throws {
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(key),
      let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { throw XCTSkip("RSA key generation unavailable") }
    privateKey = key
    let (n, e) = try FixtureIdentity.parsePKCS1(der)
    // The production DER builder must reproduce the system's own encoding exactly.
    XCTAssertEqual(ChatGPTIDToken.rsaPublicKeyDER(modulus: n, exponent: e), der)
    jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "fixture-kid", "alg": "RS256",
      "n": ChatGPTPlanPKCE.base64URL(n), "e": ChatGPTPlanPKCE.base64URL(e)]]])
  }
  func token(subject: String = "user-fixture", audience: String, nonce: String?, email: String = "fixture@example.invalid",
    expires: Date = Date().addingTimeInterval(3600), kid: String = "fixture-kid") -> String {
    let header = ChatGPTPlanPKCE.base64URL(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": kid]))
    var claims: [String: Any] = ["iss": issuer, "sub": subject, "aud": audience, "exp": expires.timeIntervalSince1970, "email": email]
    if let nonce { claims["nonce"] = nonce }
    let payload = ChatGPTPlanPKCE.base64URL(try! JSONSerialization.data(withJSONObject: claims))
    let signed = Data((header + "." + payload).utf8)
    let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, nil)! as Data
    return header + "." + payload + "." + ChatGPTPlanPKCE.base64URL(signature)
  }
  static func parsePKCS1(_ der: Data) throws -> (Data, Data) {
    var index = der.startIndex
    func length() -> Int {
      let first = der[index]; index += 1
      guard first & 0x80 != 0 else { return Int(first) }
      var value = 0
      for _ in 0..<Int(first & 0x7f) { value = value << 8 | Int(der[index]); index += 1 }
      return value
    }
    guard der[index] == 0x30 else { throw XCTSkip("unexpected DER") }
    index += 1; _ = length()
    var integers: [Data] = []
    for _ in 0..<2 {
      guard der[index] == 0x02 else { throw XCTSkip("unexpected DER") }
      index += 1; let count = length()
      integers.append(Data(der[index..<(index + count)])); index += count
    }
    return (integers[0], integers[1])
  }
}

/// Routes the auth flow's HTTP requests to fixture responses and records them.
private actor FixtureAuthServer: AIHTTPTransport {
  let identity: FixtureIdentity
  var nonce: String?
  var clientID = "oaiapp_fixture"
  var grantedScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  var refreshError: String?
  var refreshDelay: Duration = .zero
  var failCodeExchangeOnce = false
  private(set) var forms: [[String: String]] = []
  private(set) var paths: [String] = []
  private var refreshCount = 0
  init(identity: FixtureIdentity) { self.identity = identity }
  func setNonce(_ value: String?) { nonce = value }
  func set(scope: String) { grantedScope = scope }
  func set(refreshError: String?) { self.refreshError = refreshError }
  func set(refreshDelay: Duration) { self.refreshDelay = refreshDelay }
  func failNextCodeExchange() { failCodeExchangeOnce = true }
  func refreshes() -> Int { refreshCount }
  func stream(_ request: URLRequest) async throws -> AIHTTPStream {
    let path = request.url?.path ?? ""
    paths.append(path)
    var form: [String: String] = [:]
    if let body = request.httpBody, let text = String(data: body, encoding: .utf8) {
      for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        form[parts[0]] = parts.count > 1 ? parts[1] : ""
      }
      forms.append(form)
    }
    switch path {
    case "/.well-known/openid-configuration":
      return Self.json(200, ["issuer": identity.issuer, "jwks_uri": "https://auth.fixture.invalid/jwks",
        "revocation_endpoint": "https://auth.fixture.invalid/oauth/revoke"])
    case "/jwks": return AIHTTPStream(status: 200, chunks: Self.chunks(identity.jwks))
    case "/oauth/revoke": return Self.json(200, [:])
    case "/oauth/token":
      if form["grant_type"] == "refresh_token" {
        refreshCount += 1
        try await Task.sleep(for: refreshDelay)
        if let refreshError { return Self.json(400, ["error": refreshError]) }
        return Self.json(200, ["access_token": "access-\(refreshCount + 1)", "refresh_token": "refresh-\(refreshCount + 1)",
          "expires_in": 3600, "scope": grantedScope])
      }
      if failCodeExchangeOnce { failCodeExchangeOnce = false; return Self.json(400, ["error": "invalid_grant"]) }
      return Self.json(200, ["access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3600,
        "scope": grantedScope, "id_token": identity.token(audience: form["client_id"] ?? "", nonce: nonce)])
    case "/v1/models":
      return Self.json(200, ["models": [
        ["slug": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol", "visibility": "list"],
        ["slug": "hidden-model", "display_name": "Hidden", "visibility": "hide"],
        ["slug": "gpt-6-luna", "display_name": "GPT-6 Luna", "visibility": "list"]]])
    default: return Self.json(404, [:])
    }
  }
  static func chunks(_ data: Data) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in continuation.yield(data); continuation.finish() }
  }
  static func json(_ status: Int, _ object: [String: Any]) -> AIHTTPStream {
    AIHTTPStream(status: status, chunks: chunks(try! JSONSerialization.data(withJSONObject: object)))
  }
}

/// Plays the browser: reads the authorize URL handed to `open` and answers the loopback callback.
private final class FixtureBrowser: ChatGPTCallbackReceiving, @unchecked Sendable {
  enum Mode { case approve, wrongState, missingClient, otherClient, denied }
  let mode: Mode
  private let lock = NSLock()
  private var authorizeURL: URLComponents?
  private var waiter: CheckedContinuation<URLComponents, Error>?
  init(_ mode: Mode = .approve) { self.mode = mode }
  var lastAuthorize: URLComponents? { lock.withLock { authorizeURL } }
  private var expected = ""
  func start(expectedState: String) async throws -> URL {
    lock.withLock { expected = expectedState }
    return URL(string: "http://127.0.0.1:1455/auth/callback")!
  }
  func open(_ url: URL) {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    var reply = URLComponents(string: "http://127.0.0.1:1455/auth/callback")!
    var items = [URLQueryItem(name: "state", value: mode == .wrongState ? "forged" : query["state"]),
      URLQueryItem(name: "code", value: "fixture-code")]
    if mode == .denied { items = [URLQueryItem(name: "state", value: query["state"]), URLQueryItem(name: "error", value: "access_denied")] }
    if query["client_id"] == "dynamic_agent_client", mode != .missingClient {
      items.append(URLQueryItem(name: "client_id", value: "oaiapp_fixture"))
    }
    if mode == .otherClient { items.append(URLQueryItem(name: "client_id", value: "oaiapp_other")) }
    reply.queryItems = items
    let pending = lock.withLock { () -> CheckedContinuation<URLComponents, Error>? in
      authorizeURL = components; let value = waiter; waiter = nil; return value
    }
    pending?.resume(returning: reply)
    if pending == nil { lock.withLock { stored = reply } }
  }
  private var stored: URLComponents?
  /// Like the real receiver, a callback with another state is ignored (so the attempt times out).
  func callback() async throws -> URLComponents {
    let value: URLComponents = try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let stored { lock.unlock(); continuation.resume(returning: stored); return }
      waiter = continuation; lock.unlock()
    }
    guard value.queryItems?.first(where: { $0.name == "state" })?.value == lock.withLock({ expected }) else {
      try await Task.sleep(for: .seconds(3600)); throw ChatGPTPlanError.timedOut
    }
    return value
  }
  func stop() {}
}

private let fixtureEndpoints = ChatGPTPlanEndpoints(
  authorize: URL(string: "https://auth.fixture.invalid/api/accounts/authorize")!,
  token: URL(string: "https://auth.fixture.invalid/oauth/token")!,
  discovery: URL(string: "https://auth.fixture.invalid/.well-known/openid-configuration")!,
  apiBase: URL(string: "https://api.fixture.invalid/v1")!)

final class M10ChatGPTPlanTests: XCTestCase {
  private func makeAuth(_ browser: FixtureBrowser, store: ChatGPTPlanMemoryStore = ChatGPTPlanMemoryStore(),
    server: FixtureAuthServer) -> ChatGPTPlanAuth {
    ChatGPTPlanAuth(store: store, transport: server, endpoints: fixtureEndpoints, receiverFactory: { browser },
      callbackTimeout: .milliseconds(300))
  }
  /// The nonce is minted by the auth actor; the fixture server learns it from the authorize URL.
  private func signIn(_ auth: ChatGPTPlanAuth, browser: FixtureBrowser, server: FixtureAuthServer) async throws -> ChatGPTPlanAccount {
    try await auth.signIn { url in
      let nonce = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "nonce" }?.value
      await server.setNonce(nonce)
      browser.open(url)
    }
  }

  func testPKCEMatchesRFC7636Vector() {
    XCTAssertEqual(ChatGPTPlanPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    XCTAssertNotEqual(ChatGPTPlanPKCE.randomURLSafe(), ChatGPTPlanPKCE.randomURLSafe())
  }

  func testIDTokenVerificationChecksSignatureIssuerAudienceNonceAndExpiry() throws {
    let identity = try FixtureIdentity()
    let good = identity.token(audience: "oaiapp_fixture", nonce: "n1")
    let claims = try ChatGPTIDToken.verify(good, jwks: identity.jwks, issuer: identity.issuer, audience: "oaiapp_fixture",
      nonce: "n1", now: Date())
    XCTAssertEqual(claims.subject, "user-fixture"); XCTAssertEqual(claims.email, "fixture@example.invalid")
    let cases: [(String, String, String?)] = [
      (good, "oaiapp_other", "n1"),
      (good, "oaiapp_fixture", "n2"),
      (identity.token(audience: "oaiapp_fixture", nonce: "n1", expires: Date().addingTimeInterval(-600)), "oaiapp_fixture", "n1"),
      (identity.token(audience: "oaiapp_fixture", nonce: "n1", kid: "unknown"), "oaiapp_fixture", "n1"),
    ]
    for (token, audience, nonce) in cases {
      XCTAssertThrowsError(try ChatGPTIDToken.verify(token, jwks: identity.jwks, issuer: identity.issuer, audience: audience,
        nonce: nonce, now: Date()))
    }
    // A tampered payload invalidates the signature.
    var parts = good.split(separator: ".").map(String.init)
    parts[1] = ChatGPTPlanPKCE.base64URL(try JSONSerialization.data(withJSONObject: ["iss": identity.issuer, "sub": "attacker",
      "aud": "oaiapp_fixture", "exp": Date().addingTimeInterval(3600).timeIntervalSince1970, "nonce": "n1"]))
    XCTAssertThrowsError(try ChatGPTIDToken.verify(parts.joined(separator: "."), jwks: identity.jwks, issuer: identity.issuer,
      audience: "oaiapp_fixture", nonce: "n1", now: Date()))
    XCTAssertThrowsError(try ChatGPTIDToken.verify(good, jwks: identity.jwks, issuer: "https://other.invalid",
      audience: "oaiapp_fixture", nonce: "n1", now: Date()))
  }

  func testDynamicRegistrationThenReauthorizationFollowsDocumentedParameters() async throws {
    let server = FixtureAuthServer(identity: try FixtureIdentity())
    let store = ChatGPTPlanMemoryStore()
    let browser = FixtureBrowser()
    let auth = makeAuth(browser, store: store, server: server)
    let account = try await signIn(auth, browser: browser, server: server)
    XCTAssertEqual(account.email, "fixture@example.invalid")
    let first = try XCTUnwrap(browser.lastAuthorize)
    let query = Dictionary(uniqueKeysWithValues: (first.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["client_id"], "dynamic_agent_client")
    XCTAssertEqual(query["agent_name_hint"], "满屏")
    XCTAssertEqual(query["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
    XCTAssertEqual(query["resource"], "https://api.fixture.invalid/v1")
    XCTAssertEqual(query["code_challenge_method"], "S256")
    XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
    XCTAssertTrue(query["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true)
    let firstForm = await server.forms.first
    let exchange = try XCTUnwrap(firstForm)
    XCTAssertEqual(exchange["grant_type"], "authorization_code")
    XCTAssertEqual(exchange["client_id"], "oaiapp_fixture")
    XCTAssertEqual(exchange["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
    XCTAssertEqual(exchange["resource"], "https://api.fixture.invalid/v1")
    XCTAssertEqual(ChatGPTPlanPKCE.challenge(for: exchange["code_verifier"] ?? ""), query["code_challenge"])
    XCTAssertNil(exchange["client_secret"])
    let record = try XCTUnwrap(try store.loadRecord())
    XCTAssertEqual(record.clientID, "oaiapp_fixture"); XCTAssertEqual(record.refreshToken, "refresh-1")
    XCTAssertEqual(record.hostID, query["ext_agent_host_id"])
    let models = try await auth.models()
    XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol", "gpt-6-luna"])

    // Returning sign-in reuses the issued client, host ID and ID-token hint; no name hint.
    _ = try await auth.signOut()
    let again = FixtureBrowser()
    let returning = makeAuth(again, store: store, server: server)
    _ = try await signIn(returning, browser: again, server: server)
    let second = Dictionary(uniqueKeysWithValues: (again.lastAuthorize?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(second["client_id"], "oaiapp_fixture")
    XCTAssertNil(second["agent_name_hint"])
    // Signing out clears the ID token, so no stale hint can skip the account chooser.
    XCTAssertNil(second["id_token_hint"])
    XCTAssertEqual(second["ext_agent_host_id"], query["ext_agent_host_id"])
  }

  func testCallbackAndScopeFailuresDoNotStoreCredentials() async throws {
    let identity = try FixtureIdentity()
    for (mode, expected) in [(FixtureBrowser.Mode.wrongState, ChatGPTPlanError.timedOut),
      (.missingClient, .registrationIncomplete), (.denied, .denied)] {
      let server = FixtureAuthServer(identity: identity)
      let store = ChatGPTPlanMemoryStore(), browser = FixtureBrowser(mode)
      do { _ = try await signIn(makeAuth(browser, store: store, server: server), browser: browser, server: server); XCTFail("\(mode)") }
      catch { XCTAssertEqual(error as? ChatGPTPlanError, expected) }
      XCTAssertNil(try store.loadRecord())
    }
    let server = FixtureAuthServer(identity: identity)
    await server.set(scope: "openid profile email offline_access")
    let store = ChatGPTPlanMemoryStore(), browser = FixtureBrowser()
    let auth = makeAuth(browser, store: store, server: server)
    do { _ = try await signIn(auth, browser: browser, server: server); XCTFail("scope") }
    catch { XCTAssertEqual(error as? ChatGPTPlanError, .scopeNotGranted) }
    // The verified identity is kept (so the user can sign out), but no plan inference is allowed.
    XCTAssertEqual(try store.loadRecord()?.clientID, "oaiapp_fixture")
    do { _ = try await auth.accessToken(); XCTFail("token without plan scope") }
    catch { XCTAssertEqual(error as? ChatGPTPlanError, .scopeNotGranted) }
  }

  func testFailedFirstExchangeResumesTheIssuedRegistration() async throws {
    let server = FixtureAuthServer(identity: try FixtureIdentity())
    await server.failNextCodeExchange()
    let store = ChatGPTPlanMemoryStore()
    let first = FixtureBrowser()
    do { _ = try await signIn(makeAuth(first, store: store, server: server), browser: first, server: server); XCTFail() }
    catch { XCTAssertEqual(error as? ChatGPTPlanError, .signInRequired) }
    XCTAssertNil(try store.loadRecord())
    XCTAssertEqual(try store.loadPendingClientID(), "oaiapp_fixture")
    let second = FixtureBrowser()
    _ = try await signIn(makeAuth(second, store: store, server: server), browser: second, server: server)
    let query = Dictionary(uniqueKeysWithValues: (second.lastAuthorize?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["client_id"], "oaiapp_fixture")
    XCTAssertNil(query["agent_name_hint"])
    XCTAssertEqual(try store.loadRecord()?.clientID, "oaiapp_fixture")
    XCTAssertNil(try store.loadPendingClientID())
  }

  func testSignOutDuringRefreshNeverRevivesTheSession() async throws {
    let identity = try FixtureIdentity()
    let record = ChatGPTPlanRecord(issuer: identity.issuer, subject: "s", email: nil, clientID: "oaiapp_fixture",
      hostID: "urn:uuid:fixture", idToken: "id", accessToken: "stale", refreshToken: "refresh-1",
      expiresAt: Date().addingTimeInterval(-5), scopes: [ChatGPTPlanAuth.requiredScope], savedAt: Date())
    let store = ChatGPTPlanMemoryStore(hostID: "urn:uuid:fixture", record: record)
    let server = FixtureAuthServer(identity: identity)
    await server.set(refreshDelay: .milliseconds(300))
    let auth = makeAuth(FixtureBrowser(), store: store, server: server)
    let pending = Task { try await auth.accessToken() }
    try await Task.sleep(for: .milliseconds(80))
    _ = try await auth.signOut()
    do { _ = try await pending.value; XCTFail("late refresh delivered a bearer") } catch {}
    try await Task.sleep(for: .milliseconds(400))
    let stored = try XCTUnwrap(try store.loadRecord())
    XCTAssertNil(stored.accessToken); XCTAssertNil(stored.refreshToken); XCTAssertNil(stored.idToken)
  }

  func testNewSignInSupersedesARefreshInFlight() async throws {
    let identity = try FixtureIdentity()
    let record = ChatGPTPlanRecord(issuer: identity.issuer, subject: "user-fixture", email: nil, clientID: "oaiapp_fixture",
      hostID: "urn:uuid:fixture", idToken: nil, accessToken: "stale", refreshToken: "refresh-old",
      expiresAt: Date().addingTimeInterval(-5), scopes: [ChatGPTPlanAuth.requiredScope], savedAt: Date())
    let store = ChatGPTPlanMemoryStore(hostID: "urn:uuid:fixture", record: record)
    let server = FixtureAuthServer(identity: identity)
    await server.set(refreshDelay: .milliseconds(400))
    let browser = FixtureBrowser()
    let auth = makeAuth(browser, store: store, server: server)
    let stale = Task { try await auth.accessToken() }
    try await Task.sleep(for: .milliseconds(50))
    _ = try await signIn(auth, browser: browser, server: server)
    do { _ = try await stale.value; XCTFail("superseded refresh handed out a bearer") } catch {}
    try await Task.sleep(for: .milliseconds(500))
    // The new sign-in's tokens survive; the old refresh neither overwrote nor cleared them.
    XCTAssertEqual(try store.loadRecord()?.refreshToken, "refresh-1")
    XCTAssertEqual(try store.loadRecord()?.accessToken, "access-1")
  }

  func testRefreshWithoutPlanScopeStillPersistsTheRotation() async throws {
    let identity = try FixtureIdentity()
    let record = ChatGPTPlanRecord(issuer: identity.issuer, subject: "s", email: nil, clientID: "oaiapp_fixture",
      hostID: "urn:uuid:fixture", idToken: nil, accessToken: "stale", refreshToken: "refresh-1",
      expiresAt: Date().addingTimeInterval(-5), scopes: [ChatGPTPlanAuth.requiredScope], savedAt: Date())
    let store = ChatGPTPlanMemoryStore(hostID: "urn:uuid:fixture", record: record)
    let server = FixtureAuthServer(identity: identity)
    await server.set(scope: "openid offline_access")
    do { _ = try await makeAuth(FixtureBrowser(), store: store, server: server).accessToken(); XCTFail() }
    catch { XCTAssertEqual(error as? ChatGPTPlanError, .scopeNotGranted) }
    XCTAssertEqual(try store.loadRecord()?.refreshToken, "refresh-2")
  }

  func testReturningCallbackWithDifferentClientIsRejected() async throws {
    let identity = try FixtureIdentity()
    let record = ChatGPTPlanRecord(issuer: identity.issuer, subject: "user-fixture", email: nil, clientID: "oaiapp_fixture",
      hostID: "urn:uuid:fixture", idToken: nil, accessToken: nil, refreshToken: nil, expiresAt: nil, scopes: [], savedAt: Date())
    let store = ChatGPTPlanMemoryStore(hostID: "urn:uuid:fixture", record: record)
    let server = FixtureAuthServer(identity: identity), browser = FixtureBrowser(.otherClient)
    do { _ = try await signIn(makeAuth(browser, store: store, server: server), browser: browser, server: server); XCTFail() }
    catch { XCTAssertEqual(error as? ChatGPTPlanError, .clientMismatch) }
    XCTAssertEqual(try store.loadRecord(), record)
  }

  func testExpiredTokenRefreshesOnceForConcurrentCallersAndRotates() async throws {
    let identity = try FixtureIdentity()
    let record = ChatGPTPlanRecord(issuer: identity.issuer, subject: "s", email: nil, clientID: "oaiapp_fixture",
      hostID: "urn:uuid:fixture", idToken: nil, accessToken: "stale", refreshToken: "refresh-1",
      expiresAt: Date().addingTimeInterval(-5), scopes: [ChatGPTPlanAuth.requiredScope], savedAt: Date())
    let store = ChatGPTPlanMemoryStore(hostID: "urn:uuid:fixture", record: record)
    let server = FixtureAuthServer(identity: identity)
    await server.set(refreshDelay: .milliseconds(100))
    let auth = makeAuth(FixtureBrowser(), store: store, server: server)
    async let a = auth.accessToken()
    async let b = auth.accessToken()
    let tokens = try await [a, b]
    XCTAssertEqual(Set(tokens), ["access-2"])
    let refreshCount = await server.refreshes()
    XCTAssertEqual(refreshCount, 1)
    XCTAssertEqual(try store.loadRecord()?.refreshToken, "refresh-2")
    let lastForm = await server.forms.last
    let form = try XCTUnwrap(lastForm)
    XCTAssertEqual(form["client_id"], "oaiapp_fixture"); XCTAssertEqual(form["resource"], "https://api.fixture.invalid/v1")
    XCTAssertNil(form["scope"])
  }

  func testUnusableRefreshClearsTokensButKeepsRegistration() async throws {
    let identity = try FixtureIdentity()
    let record = ChatGPTPlanRecord(issuer: identity.issuer, subject: "s", email: nil, clientID: "oaiapp_fixture",
      hostID: "urn:uuid:fixture", idToken: nil, accessToken: "stale", refreshToken: "refresh-1",
      expiresAt: Date().addingTimeInterval(-5), scopes: [ChatGPTPlanAuth.requiredScope], savedAt: Date())
    let store = ChatGPTPlanMemoryStore(hostID: "urn:uuid:fixture", record: record)
    let server = FixtureAuthServer(identity: identity)
    await server.set(refreshError: "refresh_token_reused")
    let auth = makeAuth(FixtureBrowser(), store: store, server: server)
    do { _ = try await auth.accessToken(); XCTFail() } catch { XCTAssertEqual(error as? ChatGPTPlanError, .signInRequired) }
    let stored = try XCTUnwrap(try store.loadRecord())
    XCTAssertNil(stored.accessToken); XCTAssertNil(stored.refreshToken); XCTAssertEqual(stored.clientID, "oaiapp_fixture")
    // A temporary server failure keeps credentials.
    await server.set(refreshError: "server_error")
    let keep = ChatGPTPlanMemoryStore(hostID: "urn:uuid:fixture", record: record)
    do { _ = try await makeAuth(FixtureBrowser(), store: keep, server: server).accessToken(); XCTFail() } catch {}
    XCTAssertEqual(try keep.loadRecord()?.refreshToken, "refresh-1")
  }

  func testSignOutRevokesRefreshTokenAndKeepsMapping() async throws {
    let identity = try FixtureIdentity()
    let record = ChatGPTPlanRecord(issuer: identity.issuer, subject: "s", email: "e", clientID: "oaiapp_fixture",
      hostID: "urn:uuid:fixture", idToken: "id", accessToken: "a", refreshToken: "r",
      expiresAt: Date().addingTimeInterval(3600), scopes: [ChatGPTPlanAuth.requiredScope], savedAt: Date())
    let store = ChatGPTPlanMemoryStore(hostID: "urn:uuid:fixture", record: record)
    let server = FixtureAuthServer(identity: identity)
    let confirmed = try await makeAuth(FixtureBrowser(), store: store, server: server).signOut()
    XCTAssertTrue(confirmed)
    let lastForm = await server.forms.last
    let revoke = try XCTUnwrap(lastForm)
    XCTAssertEqual(revoke["token"], "r"); XCTAssertEqual(revoke["token_type_hint"], "refresh_token")
    XCTAssertEqual(revoke["client_id"], "oaiapp_fixture")
    let stored = try XCTUnwrap(try store.loadRecord())
    XCTAssertFalse(stored.signedIn); XCTAssertEqual(stored.clientID, "oaiapp_fixture"); XCTAssertEqual(try store.loadHostID(), "urn:uuid:fixture")
  }

  func testLoopbackReceiverAcceptsOnlyTheCallbackPathOn127() async throws {
    let receiver = ChatGPTLoopbackReceiver()
    let redirect = try await receiver.start(expectedState: "s1")
    XCTAssertEqual(redirect.host, "127.0.0.1"); XCTAssertEqual(redirect.path, "/auth/callback")
    let session = URLSession(configuration: .ephemeral)
    let (_, miss) = try await session.data(from: URL(string: "http://127.0.0.1:\(redirect.port!)/favicon.ico")!)
    XCTAssertEqual((miss as? HTTPURLResponse)?.statusCode, 404)
    // A forged state arriving first (even before anyone awaits) is refused and does not end the wait.
    let (_, forged) = try await session.data(from: URL(string: redirect.absoluteString + "?code=x&state=forged")!)
    XCTAssertEqual((forged as? HTTPURLResponse)?.statusCode, 400)
    let (_, hit) = try await session.data(from: URL(string: redirect.absoluteString + "?code=c1&state=s1")!)
    XCTAssertEqual((hit as? HTTPURLResponse)?.statusCode, 200)
    let callback = try await receiver.callback()
    XCTAssertEqual(callback.queryItems?.first { $0.name == "code" }?.value, "c1")
    receiver.stop()
    // Many junk requests cannot crowd out the real callback (nothing is buffered).
    let flood = ChatGPTLoopbackReceiver()
    let floodURL = try await flood.start(expectedState: "s2")
    for index in 0..<20 { _ = try await session.data(from: URL(string: floodURL.absoluteString + "?code=j\(index)&state=junk")!) }
    _ = try await session.data(from: URL(string: floodURL.absoluteString + "?code=c2&state=s2")!)
    let real = try await flood.callback()
    XCTAssertEqual(real.queryItems?.first { $0.name == "code" }?.value, "c2")
    flood.stop()
  }
}

/// Responses-API inference for the plan, plus the modernized Claude request/stream handling.
private actor ScriptedTransport: AIHTTPTransport {
  private var responses: [(Int, String)]
  private(set) var requests: [URLRequest] = []
  init(_ responses: [(Int, String)]) { self.responses = responses }
  func stream(_ request: URLRequest) async throws -> AIHTTPStream {
    requests.append(request)
    let (status, body) = responses.removeFirst()
    return AIHTTPStream(status: status, chunks: AsyncThrowingStream { continuation in
      for byte in body.utf8 { continuation.yield(Data([byte])) }
      continuation.finish()
    })
  }
}

final class M10AIProtocolTests: XCTestCase {
  private let plan = AIProviderConfiguration(models: [AIModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol")])
  private static let completed = """
    event: response.created\ndata: {"type":"response.created","response":{"id":"r1"}}\n\n\
    event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"你好"}\n\n\
    event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"，世界"}\n\n\
    event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n
    """
  private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var text = ""; for try await piece in stream { text += piece }; return text
  }

  func testPlanRequestUsesPublicResponsesAPIWithStoreFalseAndStreaming() throws {
    let request = try AIChatRequestPlanner.request(provider: .chatGPTPlan, configuration: plan, secrets: .init(key: "plan-token"),
      model: "gpt-6.1-sol", conversation: AIConversationRequest(system: nil, messages: [.user("总结")]), streaming: false, options: .init(temperature: 0.5, maxTokens: 99))
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer plan-token")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertNil(body["temperature"]); XCTAssertNil(body["max_output_tokens"]); XCTAssertNil(body["max_tokens"])
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertEqual(input.first?["role"] as? String, "user")
    XCTAssertFalse(input.contains { $0["role"] as? String == "system" })
  }

  func testPlanBearerCannotBeRedirectedByPublicConfiguration() throws {
    var hostile = plan; hostile.endpoint = "https://collector.example.invalid/v1"
    let request = try AIChatRequestPlanner.request(provider: .chatGPTPlan, configuration: hostile, secrets: .init(key: "plan-token"),
      model: "gpt-6.1-sol", conversation: AIConversationRequest(system: nil, messages: [.user("p")]))
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
  }

  func testPlanDoneMarkerIsNotSuccessAndTerminalRefreshMeansSignIn() async throws {
    var parser = AIStreamParser(family: .responses)
    _ = try parser.append(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}\n\ndata: [DONE]\n\n".utf8))
    XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? AIChatFailure, .truncatedStream) }
    let rejected = ScriptedTransport([(401, "{}")])
    do {
      _ = try await collect(AIChatClient(transport: rejected).response(provider: .chatGPTPlan, configuration: plan,
        secrets: .init(key: "old"), model: "m", conversation: AIConversationRequest(system: nil, messages: [.user("p")]), refreshBearer: { throw ChatGPTPlanError.signInRequired }))
      XCTFail()
    } catch { XCTAssertEqual(error as? AIChatFailure, .planSignInRequired) }
  }

  func testPlanStreamCompletesOnlyOnResponseCompleted() async throws {
    let client = AIChatClient(transport: ScriptedTransport([(200, Self.completed)]))
    let text = try await collect(client.response(provider: .chatGPTPlan, configuration: plan, secrets: .init(key: "t"),
      model: "gpt-6.1-sol", conversation: AIConversationRequest(system: nil, messages: [.user("p")]), streaming: false))
    XCTAssertEqual(text, "你好，世界")
    var parser = AIStreamParser(family: .responses)
    _ = try parser.append(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}\n\n".utf8))
    XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? AIChatFailure, .truncatedStream) }
  }

  func testPlanErrorsMapToStructuredCodesAndRetryRules() async throws {
    let limit = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n"
    do {
      _ = try await collect(AIChatClient(transport: ScriptedTransport([(200, limit)])).response(provider: .chatGPTPlan,
        configuration: plan, secrets: .init(key: "t"), model: "m", conversation: AIConversationRequest(system: nil, messages: [.user("p")]))); XCTFail()
    } catch { XCTAssertEqual(error as? AIChatFailure, .planUsageLimit) }
    let notEligible = "{\"error\":{\"code\":\"subscription_sharing_user_not_eligible\"}}"
    do {
      _ = try await collect(AIChatClient(transport: ScriptedTransport([(403, notEligible)])).response(provider: .chatGPTPlan,
        configuration: plan, secrets: .init(key: "t"), model: "m", conversation: AIConversationRequest(system: nil, messages: [.user("p")]))); XCTFail()
    } catch { XCTAssertEqual(error as? AIChatFailure, .planNotEligible) }
    // 503 usage-unavailable retries with bounded backoff, then succeeds without changing billing path.
    let busy = ScriptedTransport([(503, "{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}"), (200, Self.completed)])
    let retried = try await collect(AIChatClient(transport: busy).response(provider: .chatGPTPlan, configuration: plan,
      secrets: .init(key: "t"), model: "m", conversation: AIConversationRequest(system: nil, messages: [.user("p")]), retryDelay: .milliseconds(1)))
    XCTAssertEqual(retried, "你好，世界")
    let sentCount = await busy.requests.count
    XCTAssertEqual(sentCount, 2)
    // 401 refreshes the token once and replays with the new bearer.
    let expired = ScriptedTransport([(401, "{}"), (200, Self.completed)])
    _ = try await collect(AIChatClient(transport: expired).response(provider: .chatGPTPlan, configuration: plan,
      secrets: .init(key: "old"), model: "m", conversation: AIConversationRequest(system: nil, messages: [.user("p")]), refreshBearer: { "new" }))
    let replay = await expired.requests.last?.value(forHTTPHeaderField: "Authorization")
    XCTAssertEqual(replay, "Bearer new")
  }

  func testCurrentClaudeModelsGetAdaptiveThinkingEffortAndFallback() throws {
    let request = try AIChatRequestPlanner.request(provider: .anthropic, configuration: .init(), secrets: .init(key: "k"),
      model: "claude-opus-5-5", conversation: AIConversationRequest(system: nil, messages: [.user("p")]), options: .init(temperature: 0.7, effort: "low"))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "adaptive")
    XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
    XCTAssertEqual(body["fallbacks"] as? String, "default")
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
    XCTAssertNil(body["temperature"]); XCTAssertNil(body["budget_tokens"])
    // A custom endpoint (proxy) gets no fallback beta; Haiku has no default fallback.
    let proxy = try AIChatRequestPlanner.request(provider: .anthropic, configuration: .init(endpoint: "https://proxy.example.invalid"),
      secrets: .init(key: "k"), model: "claude-opus-5-5", conversation: AIConversationRequest(system: nil, messages: [.user("p")]))
    XCTAssertNil(proxy.value(forHTTPHeaderField: "anthropic-beta"))
    let haiku = try AIChatRequestPlanner.request(provider: .anthropic, configuration: .init(), secrets: .init(key: "k"),
      model: "claude-haiku-5-5", conversation: AIConversationRequest(system: nil, messages: [.user("p")]))
    let haikuBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(haiku.httpBody)) as? [String: Any])
    XCTAssertNil(haikuBody["fallbacks"]); XCTAssertNotNil(haikuBody["thinking"])
  }

  func testClaudeStreamSkipsThinkingIgnoresUnknownEventsAndReportsRefusal() throws {
    var parser = AIStreamParser(family: .anthropic)
    let stream = """
      event: content_block_start\ndata: {"type":"content_block_start","content_block":{"type":"thinking","thinking":""}}\n\n\
      event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"secret"}}\n\n\
      event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"signature_delta","signature":"x"}}\n\n\
      event: future_event\ndata: {"type":"future_event"}\n\n\
      event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"答案"}}\n\n\
      event: message_stop\ndata: {"type":"message_stop"}\n\n
      """
    var text = try parser.append(Data(stream.utf8)).joined()
    text += try parser.finish().joined()
    XCTAssertEqual(text, "答案")
    var refusal = AIStreamParser(family: .anthropic)
    XCTAssertThrowsError(try refusal.append(Data(
      "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n\n".utf8))) {
      XCTAssertEqual($0 as? AIChatFailure, .refused)
    }
  }

  func testPlanSnapshotCarriesFreshTokenOnlyWhenSignedIn() async throws {
    let identity = try FixtureIdentity()
    let record = ChatGPTPlanRecord(issuer: identity.issuer, subject: "s", email: nil, clientID: "c", hostID: "h", idToken: nil,
      accessToken: "live", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600),
      scopes: [ChatGPTPlanAuth.requiredScope], savedAt: Date())
    let auth = ChatGPTPlanAuth(store: ChatGPTPlanMemoryStore(record: record), transport: FixtureAuthServer(identity: identity),
      endpoints: fixtureEndpoints, receiverFactory: { FixtureBrowser() })
    var configuration = plan; configuration.keyConfigured = true
    let store = AIConfigurationStore.fixture(configurations: [.chatGPTPlan: configuration], chatGPT: auth)
    let providers = try await store.configuredProviders()
    XCTAssertEqual(providers, [.chatGPTPlan])
    let snapshot = try await store.snapshot(for: .chatGPTPlan)
    XCTAssertEqual(snapshot.secrets.key, "live")
    try await store.setChatGPTPlan(signedIn: false, models: [])
    let afterSignOut = try await store.configuredProviders()
    XCTAssertEqual(afterSignOut, [])
  }
}
