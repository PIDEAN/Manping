import CryptoKit
import Foundation
import Security

// "Sign in with ChatGPT" plan usage for open-source / locally hosted apps:
// https://developers.openai.com/siwc/token-sharing-open-source
// Only the documented public flow is used: dynamic registration, loopback PKCE,
// the public Responses API. No ChatGPT backend-api, no borrowed client IDs.

public struct ChatGPTPlanEndpoints: Sendable, Equatable {
  public var authorize: URL
  public var token: URL
  public var discovery: URL
  public var apiBase: URL
  public init(authorize: URL, token: URL, discovery: URL, apiBase: URL) {
    self.authorize = authorize; self.token = token; self.discovery = discovery; self.apiBase = apiBase
  }
  public static let production = ChatGPTPlanEndpoints(
    authorize: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
    token: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
    discovery: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!,
    apiBase: URL(string: "https://api.openai.com/v1")!)
  /// The `resource` parameter must equal the Responses API base on every token request.
  public var resource: String { apiBase.absoluteString }
}

/// One stored registration. Tokens are optional: signing out clears them but keeps the
/// account-to-client mapping so the next sign-in reauthorizes the same registration.
public struct ChatGPTPlanRecord: Codable, Sendable, Equatable {
  public var issuer: String
  public var subject: String
  public var email: String?
  public var clientID: String
  public var hostID: String
  public var idToken: String?
  public var accessToken: String?
  public var refreshToken: String?
  public var expiresAt: Date?
  public var scopes: [String]
  public var savedAt: Date
  enum CodingKeys: String, CodingKey {
    case issuer, subject, email, clientID = "client_id", hostID = "ext_agent_host_id", idToken = "id_token"
    case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", scopes, savedAt = "saved_at"
  }
  public var signedIn: Bool { accessToken != nil && refreshToken != nil }
}

public protocol ChatGPTPlanStore: Sendable {
  func loadHostID() throws -> String?
  func saveHostID(_ value: String) throws
  func loadRecord() throws -> ChatGPTPlanRecord?
  func saveRecord(_ record: ChatGPTPlanRecord) throws
  /// Client ID issued by a registration whose first code exchange has not completed yet.
  func loadPendingClientID() throws -> String?
  func savePendingClientID(_ value: String?) throws
}

/// `LocalSecretVault` entries, separate from the API-key provider entries and the Bilibili session.
/// Before 0.1.3 these were Keychain items; each moves over on its first read.
public final class ChatGPTPlanLocalStore: ChatGPTPlanStore, Sendable {
  private let vault: LocalSecretVault
  public init(vault: LocalSecretVault = .shared) { self.vault = vault }
  private func entry(_ account: String) -> (name: String, legacy: LocalSecretVault.LegacyItem) {
    ("ai.chatgpt." + account, .init(service: "io.github.pidean.manping.ai.chatgpt.v1", account: account))
  }
  private func read(_ account: String) throws -> Data? {
    let entry = entry(account)
    guard let data = try vault.read(entry.name, legacy: entry.legacy) else { return nil }
    guard data.count <= 256 * 1024 else { throw AIConfigurationError.corruptConfiguration }
    return data
  }
  private func write(_ data: Data, account: String) throws {
    let entry = entry(account)
    try vault.write(entry.name, data, legacy: entry.legacy)
  }
  public func loadHostID() throws -> String? { try read("host").flatMap { String(data: $0, encoding: .utf8) } }
  public func saveHostID(_ value: String) throws { try write(Data(value.utf8), account: "host") }
  public func loadRecord() throws -> ChatGPTPlanRecord? {
    guard let data = try read("registration") else { return nil }
    do { return try ChatGPTPlanRecord.decoder.decode(ChatGPTPlanRecord.self, from: data) }
    catch { throw AIConfigurationError.corruptConfiguration }
  }
  public func saveRecord(_ record: ChatGPTPlanRecord) throws {
    try write(try ChatGPTPlanRecord.encoder.encode(record), account: "registration")
  }
  public func loadPendingClientID() throws -> String? { try read("pending_client").flatMap { String(data: $0, encoding: .utf8) } }
  public func savePendingClientID(_ value: String?) throws {
    guard let value else {
      let entry = entry("pending_client")
      try vault.delete(entry.name, legacy: entry.legacy)
      return
    }
    try write(Data(value.utf8), account: "pending_client")
  }
}

public final class ChatGPTPlanMemoryStore: ChatGPTPlanStore, @unchecked Sendable {
  private let lock = NSLock()
  private var hostID: String?
  private var record: ChatGPTPlanRecord?
  private var pending: String?
  public init(hostID: String? = nil, record: ChatGPTPlanRecord? = nil) { self.hostID = hostID; self.record = record }
  public func loadPendingClientID() throws -> String? { lock.lock(); defer { lock.unlock() }; return pending }
  public func savePendingClientID(_ value: String?) throws { lock.lock(); defer { lock.unlock() }; pending = value }
  public func loadHostID() throws -> String? { lock.lock(); defer { lock.unlock() }; return hostID }
  public func saveHostID(_ value: String) throws { lock.lock(); defer { lock.unlock() }; hostID = value }
  public func loadRecord() throws -> ChatGPTPlanRecord? { lock.lock(); defer { lock.unlock() }; return record }
  public func saveRecord(_ record: ChatGPTPlanRecord) throws { lock.lock(); defer { lock.unlock() }; self.record = record }
}

extension ChatGPTPlanRecord {
  static let encoder: JSONEncoder = { let value = JSONEncoder(); value.dateEncodingStrategy = .secondsSince1970; return value }()
  static let decoder: JSONDecoder = { let value = JSONDecoder(); value.dateDecodingStrategy = .secondsSince1970; return value }()
}

public enum ChatGPTPlanError: Error, LocalizedError, Equatable, Sendable {
  case signInRequired, cancelled, denied, stateMismatch, registrationIncomplete, clientMismatch
  case invalidIDToken, accountMismatch, scopeNotGranted, timedOut, network, server(Int), invalidResponse
  public var errorDescription: String? {
    switch self {
    case .signInRequired: "ChatGPT 登录已失效，请在 设置 › AI 中重新使用 ChatGPT 账号登录。"
    case .cancelled: "已取消 ChatGPT 登录。"
    case .denied: "未授权使用 ChatGPT 套餐。"
    case .stateMismatch, .clientMismatch: "ChatGPT 登录回调与本次请求不匹配，已拒绝。"
    case .registrationIncomplete: "ChatGPT 应用注册未完成，请重新登录。"
    case .invalidIDToken: "ChatGPT 身份令牌校验失败。"
    case .accountMismatch: "登录的 ChatGPT 账号与当前注册不一致，已拒绝替换凭据。"
    case .scopeNotGranted: "此账号未授予 ChatGPT 套餐用量权限，无法用于 AI 请求。"
    case .timedOut: "等待浏览器登录超时。"
    case .network: "无法连接 ChatGPT 登录服务，请检查网络。"
    case .server(let status): "ChatGPT 登录服务返回错误（HTTP \(status)）。"
    case .invalidResponse: "ChatGPT 登录服务响应格式无效。"
    }
  }
}

/// Receives exactly one OAuth redirect on a 127.0.0.1 loopback listener.
public protocol ChatGPTCallbackReceiving: Sendable {
  /// Starts listening for this attempt's `expectedState` and returns the exact redirect URI
  /// (scheme, host and path fixed; port may vary). Requests with any other state are refused.
  func start(expectedState: String) async throws -> URL
  /// Resolves with the first callback carrying the expected state.
  func callback() async throws -> URLComponents
  func stop()
}

public struct ChatGPTPlanAccount: Sendable, Equatable {
  public let email: String?
  public let subject: String
}

public enum ChatGPTPlanPKCE {
  public static func randomURLSafe(_ count: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return base64URL(Data(bytes))
  }
  public static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
  public static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  public static func decodeBase64URL(_ text: String) -> Data? {
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while value.count % 4 != 0 { value += "=" }
    return Data(base64Encoded: value)
  }
}

/// RS256 ID-token verification against the issuer's published JWKS.
public enum ChatGPTIDToken {
  public struct Claims: Sendable, Equatable {
    public let issuer: String
    public let subject: String
    public let audience: [String]
    public let expiresAt: Date
    public let nonce: String?
    public let email: String?
  }
  public static func verify(_ token: String, jwks: Data, issuer: String, audience: String, nonce: String?, now: Date) throws -> Claims {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let headerData = ChatGPTPlanPKCE.decodeBase64URL(String(parts[0])),
      let payloadData = ChatGPTPlanPKCE.decodeBase64URL(String(parts[1])),
      let signature = ChatGPTPlanPKCE.decodeBase64URL(String(parts[2])),
      let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
      header["alg"] as? String == "RS256",
      let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { throw ChatGPTPlanError.invalidIDToken }
    let key = try publicKey(jwks: jwks, kid: header["kid"] as? String)
    var error: Unmanaged<CFError>?
    guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
      Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, &error) else { throw ChatGPTPlanError.invalidIDToken }
    let audiences: [String] = (payload["aud"] as? [String]) ?? ((payload["aud"] as? String).map { [$0] } ?? [])
    guard let iss = payload["iss"] as? String, iss == issuer, let sub = payload["sub"] as? String, !sub.isEmpty,
      audiences.contains(audience), let exp = (payload["exp"] as? NSNumber)?.doubleValue,
      Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-60) else { throw ChatGPTPlanError.invalidIDToken }
    if let nonce { guard payload["nonce"] as? String == nonce else { throw ChatGPTPlanError.invalidIDToken } }
    return Claims(issuer: iss, subject: sub, audience: audiences, expiresAt: Date(timeIntervalSince1970: exp),
      nonce: payload["nonce"] as? String, email: payload["email"] as? String)
  }
  static func publicKey(jwks: Data, kid: String?) throws -> SecKey {
    guard let object = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any],
      let keys = object["keys"] as? [[String: Any]] else { throw ChatGPTPlanError.invalidIDToken }
    let candidates = keys.filter { $0["kty"] as? String == "RSA" && (kid == nil || $0["kid"] as? String == kid) }
    guard candidates.count == 1, let jwk = candidates.first, let n = (jwk["n"] as? String).flatMap(ChatGPTPlanPKCE.decodeBase64URL),
      let e = (jwk["e"] as? String).flatMap(ChatGPTPlanPKCE.decodeBase64URL) else { throw ChatGPTPlanError.invalidIDToken }
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
    guard let key = SecKeyCreateWithData(rsaPublicKeyDER(modulus: n, exponent: e) as CFData, attributes as CFDictionary, nil) else {
      throw ChatGPTPlanError.invalidIDToken
    }
    return key
  }
  /// PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }.
  public static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
    func length(_ count: Int) -> Data {
      if count < 0x80 { return Data([UInt8(count)]) }
      var value = count, bytes: [UInt8] = []
      while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
      return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    func integer(_ raw: Data) -> Data {
      var bytes = Array(raw.drop(while: { $0 == 0 }))
      if bytes.isEmpty { bytes = [0] }
      if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
      return Data([0x02]) + length(bytes.count) + Data(bytes)
    }
    let body = integer(modulus) + integer(exponent)
    return Data([0x30]) + length(body.count) + body
  }
}

/// Owns the ChatGPT registration and token lifecycle. Refreshes are single-flight because the
/// refresh token rotates; credentials are never logged, and temporary failures never erase them.
public actor ChatGPTPlanAuth {
  public static let requiredScope = "chatgpt.tokens.use.direct"
  static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  private let store: any ChatGPTPlanStore
  private let transport: any AIHTTPTransport
  private let endpoints: ChatGPTPlanEndpoints
  private let receiverFactory: @Sendable () -> any ChatGPTCallbackReceiving
  private let now: @Sendable () -> Date
  private let callbackTimeout: Duration
  private var refreshFlight: Task<ChatGPTPlanRecord, Error>?
  private var signInFlight: Task<ChatGPTPlanAccount, Error>?
  /// Bumped by sign-out. Sign-in and refresh capture it before awaiting the network and
  /// refuse to commit afterwards if it changed, so a late response cannot revive a session.
  private var session: UInt64 = 0

  public init(store: any ChatGPTPlanStore = ChatGPTPlanLocalStore(), transport: any AIHTTPTransport = AIURLSessionTransport(),
    endpoints: ChatGPTPlanEndpoints = .production,
    receiverFactory: @escaping @Sendable () -> any ChatGPTCallbackReceiving = { ChatGPTLoopbackReceiver() },
    now: @escaping @Sendable () -> Date = Date.init, callbackTimeout: Duration = .seconds(300)) {
    self.store = store; self.transport = transport; self.endpoints = endpoints
    self.receiverFactory = receiverFactory; self.now = now; self.callbackTimeout = callbackTimeout
  }

  public func account() throws -> ChatGPTPlanAccount? {
    guard let record = try store.loadRecord(), record.signedIn else { return nil }
    return ChatGPTPlanAccount(email: record.email, subject: record.subject)
  }

  /// Opens the system browser through `open` and waits for the loopback redirect.
  /// Cancelling the caller cancels the attempt (listener closed, nothing stored).
  public func signIn(open: @escaping @Sendable (URL) async -> Void) async throws -> ChatGPTPlanAccount {
    let flight: Task<ChatGPTPlanAccount, Error>
    if let signInFlight { flight = signInFlight }
    else {
      flight = Task { try await performSignIn(open: open) }
      signInFlight = flight
    }
    defer { if signInFlight == flight { signInFlight = nil } }
    return try await withTaskCancellationHandler { try await flight.value } onCancel: { flight.cancel() }
  }

  private func hostID() throws -> String {
    if let existing = try store.loadHostID() { return existing }
    // Opaque per-host identifier (UUIDv4 URN form); never derived from user identity.
    let value = "urn:uuid:" + UUID().uuidString.lowercased()
    try store.saveHostID(value)
    return value
  }

  private func performSignIn(open: @escaping @Sendable (URL) async -> Void) async throws -> ChatGPTPlanAccount {
    let attempt = session
    let previous = try store.loadRecord()
    // A registration whose first code exchange failed is resumed, not registered again.
    let pending = try store.loadPendingClientID()
    let knownClient = previous?.clientID ?? pending
    let host = try hostID()
    let state = ChatGPTPlanPKCE.randomURLSafe(), nonce = ChatGPTPlanPKCE.randomURLSafe()
    let verifier = ChatGPTPlanPKCE.randomURLSafe(48)
    let receiver = receiverFactory()
    defer { receiver.stop() }
    let redirect = try await receiver.start(expectedState: state)
    let registering = knownClient == nil
    var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
    var items = [
      URLQueryItem(name: "client_id", value: knownClient ?? "dynamic_agent_client"),
      URLQueryItem(name: "ext_agent_host_id", value: host),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
      URLQueryItem(name: "scope", value: Self.scope),
      URLQueryItem(name: "resource", value: endpoints.resource),
      URLQueryItem(name: "state", value: state), URLQueryItem(name: "nonce", value: nonce),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: ChatGPTPlanPKCE.challenge(for: verifier)),
    ]
    if registering { items.append(URLQueryItem(name: "agent_name_hint", value: "满屏")) }
    else {
      // Signing out clears the ID token, so no hint is sent after sign-out.
      if let hint = previous?.idToken { items.append(URLQueryItem(name: "id_token_hint", value: hint)) }
      if let email = previous?.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
    }
    components.queryItems = items
    // `+` is a literal in query values; force encoding so scopes and URIs arrive intact.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let authorizeURL = components.url else { throw ChatGPTPlanError.invalidResponse }
    await open(authorizeURL)
    let callback = try await withThrowingTaskGroup(of: URLComponents.self) { group in
      // Requests without this attempt's state are answered and ignored by the receiver.
      group.addTask { try await receiver.callback() }
      let timeout = callbackTimeout
      group.addTask { try await Task.sleep(for: timeout); throw ChatGPTPlanError.timedOut }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    try Task.checkCancellation()
    let query = Dictionary((callback.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    guard query["state"] == state else { throw ChatGPTPlanError.stateMismatch }
    if let error = query["error"] { throw error == "access_denied" ? ChatGPTPlanError.denied : ChatGPTPlanError.invalidResponse }
    guard let code = query["code"], !code.isEmpty else { throw ChatGPTPlanError.invalidResponse }
    let clientID: String
    if let knownClient {
      if let returned = query["client_id"], returned != knownClient { throw ChatGPTPlanError.clientMismatch }
      clientID = knownClient
    } else {
      guard let issued = query["client_id"], !issued.isEmpty, issued != "dynamic_agent_client" else {
        throw ChatGPTPlanError.registrationIncomplete
      }
      clientID = issued
      // Kept separately (not as the active account) so a failed exchange can be retried.
      try store.savePendingClientID(issued)
    }
    let tokens = try await tokenRequest([
      "grant_type": "authorization_code", "client_id": clientID, "code": code, "code_verifier": verifier,
      "redirect_uri": redirect.absoluteString, "resource": endpoints.resource,
    ])
    guard let idToken = tokens.idToken else { throw ChatGPTPlanError.invalidIDToken }
    let discovery = try await discoveryDocument()
    let jwks = try await get(discovery.jwksURI)
    let claims = try ChatGPTIDToken.verify(idToken, jwks: jwks, issuer: discovery.issuer, audience: clientID, nonce: nonce, now: now())
    if let previous, previous.subject != claims.subject { throw ChatGPTPlanError.accountMismatch }
    guard !Task.isCancelled, attempt == session else {
      // Tokens were issued but the attempt was cancelled or superseded: do not keep them.
      if let refresh = tokens.refreshToken { revokeDetached(refresh, clientID: clientID) }
      throw ChatGPTPlanError.cancelled
    }
    let record = ChatGPTPlanRecord(issuer: claims.issuer, subject: claims.subject, email: claims.email, clientID: clientID,
      hostID: host, idToken: idToken, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
      expiresAt: tokens.expiresIn.map { now().addingTimeInterval($0) }, scopes: tokens.scopes, savedAt: now())
    guard record.signedIn else { throw ChatGPTPlanError.invalidResponse }
    // The identity is kept even without plan usage; inference stays disabled until granted.
    // A new session also invalidates any refresh still in flight for the previous tokens.
    session &+= 1; refreshFlight?.cancel(); refreshFlight = nil
    try store.saveRecord(record)
    try store.savePendingClientID(nil)
    guard record.scopes.contains(Self.requiredScope) else { throw ChatGPTPlanError.scopeNotGranted }
    return ChatGPTPlanAccount(email: claims.email, subject: claims.subject)
  }

  /// A bearer token valid for at least another minute, refreshing (single-flight) when needed.
  public func accessToken() async throws -> String {
    guard let record = try store.loadRecord(), record.signedIn, let token = record.accessToken else {
      throw ChatGPTPlanError.signInRequired
    }
    guard record.scopes.contains(Self.requiredScope) else { throw ChatGPTPlanError.scopeNotGranted }
    if let expiry = record.expiresAt, expiry.timeIntervalSince(now()) > 60 { return token }
    return try await freshToken()
  }

  /// Forces a refresh after the API rejected a token that looked unexpired.
  public func refreshAfterRejection() async throws -> String { try await freshToken() }

  /// Hands out a refreshed bearer only if no sign-out or new sign-in happened meanwhile.
  private func freshToken() async throws -> String {
    let current = session
    let record = try await refreshed()
    guard current == session, let token = record.accessToken else { throw ChatGPTPlanError.signInRequired }
    return token
  }

  private func refreshed() async throws -> ChatGPTPlanRecord {
    if let refreshFlight { return try await refreshFlight.value }
    let flight = Task { try await performRefresh() }
    refreshFlight = flight
    defer { if refreshFlight == flight { refreshFlight = nil } }
    return try await flight.value
  }

  private func performRefresh() async throws -> ChatGPTPlanRecord {
    let attempt = session
    guard var record = try store.loadRecord(), let refresh = record.refreshToken else { throw ChatGPTPlanError.signInRequired }
    let tokens: TokenResponse
    do {
      tokens = try await tokenRequest(["grant_type": "refresh_token", "client_id": record.clientID,
        "refresh_token": refresh, "resource": endpoints.resource])
    } catch ChatGPTPlanError.signInRequired {
      guard attempt == session else { throw ChatGPTPlanError.signInRequired }
      // Unusable refresh token: clear tokens, keep the registration for reauthorization.
      record.accessToken = nil; record.refreshToken = nil; record.expiresAt = nil
      try store.saveRecord(record)
      throw ChatGPTPlanError.signInRequired
    }
    guard attempt == session else {
      // Signed out while this refresh was in flight: never store it; revoke the rotated token.
      if let rotated = tokens.refreshToken { revokeDetached(rotated, clientID: record.clientID) }
      throw ChatGPTPlanError.signInRequired
    }
    record.accessToken = tokens.accessToken
    if let rotated = tokens.refreshToken { record.refreshToken = rotated }
    if let idToken = tokens.idToken { record.idToken = idToken }
    record.expiresAt = tokens.expiresIn.map { now().addingTimeInterval($0) }
    if !tokens.scopes.isEmpty { record.scopes = tokens.scopes }
    record.savedAt = now()
    // Persist the rotation before any scope decision: the old refresh token is now spent.
    try store.saveRecord(record)
    guard record.scopes.contains(Self.requiredScope) else { throw ChatGPTPlanError.scopeNotGranted }
    return record
  }

  /// Clears local tokens (including the ID token) first, then revokes the refresh token.
  /// Returns whether remote revocation was confirmed; the client mapping and host ID are kept.
  /// Throws only when the local record could not be cleared.
  @discardableResult public func signOut() async throws -> Bool {
    session &+= 1
    refreshFlight?.cancel(); refreshFlight = nil
    signInFlight?.cancel(); signInFlight = nil
    guard var record = try store.loadRecord() else { return true }
    let refresh = record.refreshToken
    record.accessToken = nil; record.refreshToken = nil; record.expiresAt = nil; record.idToken = nil
    try store.saveRecord(record)
    guard let refresh else { return true }
    return await revoke(refresh, clientID: record.clientID)
  }

  /// Cleanup that must outlive a cancelled sign-in or refresh flight.
  private nonisolated func revokeDetached(_ token: String, clientID: String) {
    Task.detached { [self] in await self.revoke(token, clientID: clientID) }
  }
  @discardableResult func revoke(_ token: String, clientID: String) async -> Bool {
    guard let discovery = try? await discoveryDocument(), let revocation = discovery.revocation else { return false }
    for attempt in 0..<3 {
      do {
        let status = try await postForm(revocation, ["token": token, "token_type_hint": "refresh_token", "client_id": clientID]).status
        if status == 200 { return true }
        if status < 500 { return false }
      } catch {}
      try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
    }
    return false
  }

  /// Models available to the signed-in account (`visibility == "list"`, server order).
  public func models() async throws -> [AIModel] {
    let token = try await accessToken()
    var request = URLRequest(url: endpoints.apiBase.appendingPathComponent("models"), cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 30)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    let response = try await transport.stream(request)
    defer { response.cancel() }
    let data = try await Self.collect(response)
    guard response.status == 200 else {
      if response.status == 401 { throw ChatGPTPlanError.signInRequired }
      throw ChatGPTPlanError.server(response.status)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTPlanError.invalidResponse }
    var seen = Set<String>()
    if let models = object["models"] as? [[String: Any]] {
      return models.compactMap { item -> AIModel? in
        guard (item["visibility"] as? String ?? "list") == "list", let slug = item["slug"] as? String, !slug.isEmpty,
          seen.insert(slug).inserted else { return nil }
        return AIModel(id: slug, name: item["display_name"] as? String ?? slug)
      }
    }
    if let models = object["data"] as? [[String: Any]] {
      return models.compactMap { item in
        guard let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
        return AIModel(id: id, name: item["display_name"] as? String ?? id)
      }
    }
    throw ChatGPTPlanError.invalidResponse
  }

  // MARK: HTTP helpers

  struct TokenResponse {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresIn: Double?
    var scopes: [String]
  }
  struct Discovery { var issuer: String; var jwksURI: URL; var revocation: URL? }

  private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
    let (status, data) = try await postForm(endpoints.token, fields)
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    guard status == 200 else {
      let code = object?["error"] as? String ?? ""
      let unusable = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused"]
      if unusable.contains(code) { throw ChatGPTPlanError.signInRequired }
      throw ChatGPTPlanError.server(status)
    }
    guard let object, let access = object["access_token"] as? String, !access.isEmpty else { throw ChatGPTPlanError.invalidResponse }
    let scopes = (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? []
    return TokenResponse(accessToken: access, refreshToken: object["refresh_token"] as? String,
      idToken: object["id_token"] as? String, expiresIn: (object["expires_in"] as? NSNumber)?.doubleValue, scopes: scopes)
  }

  private func discoveryDocument() async throws -> Discovery {
    let data = try await get(endpoints.discovery)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let issuer = object["issuer"] as? String, let jwks = (object["jwks_uri"] as? String).flatMap(URL.init(string:)),
      Self.trusted(jwks) else { throw ChatGPTPlanError.invalidResponse }
    let revocation = (object["revocation_endpoint"] as? String).flatMap(URL.init(string:)).flatMap { Self.trusted($0) ? $0 : nil }
    return Discovery(issuer: issuer, jwksURI: jwks, revocation: revocation)
  }
  private static func trusted(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost"].contains(host))
  }

  private func get(_ url: URL) async throws -> Data {
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    let response: AIHTTPStream
    do { response = try await transport.stream(request) } catch { throw ChatGPTPlanError.network }
    defer { response.cancel() }
    let data = try await Self.collect(response)
    guard response.status == 200 else { throw ChatGPTPlanError.server(response.status) }
    return data
  }

  private func postForm(_ url: URL, _ fields: [String: String]) async throws -> (status: Int, data: Data) {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
      "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }.joined(separator: "&").utf8)
    let response: AIHTTPStream
    do { response = try await transport.stream(request) } catch { throw ChatGPTPlanError.network }
    defer { response.cancel() }
    return (response.status, try await Self.collect(response))
  }

  static func collect(_ response: AIHTTPStream) async throws -> Data {
    var data = Data()
    do {
      for try await chunk in response.chunks {
        guard data.count + chunk.count <= 1_048_576 else { throw ChatGPTPlanError.invalidResponse }
        data.append(chunk)
      }
    } catch let error as ChatGPTPlanError { throw error } catch { throw ChatGPTPlanError.network }
    return data
  }
}
