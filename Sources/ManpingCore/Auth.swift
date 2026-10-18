import Foundation

public enum AuthFailure: Error, LocalizedError, Sendable {
  case needsLogin, missingCSRF
  case rejected(Int)
  case invalidResponse, transport, expired
  public var errorDescription: String? {
    switch self {
    case .needsLogin: return "需要重新登录"
    case .missingCSRF: return "网页登录信息不完整，请重新登录"
    case .rejected(let code): return "认证请求失败（\(code)）"
    case .invalidResponse: return "认证响应无效"
    case .transport: return "认证网络请求失败，请重试"
    case .expired: return "二维码已过期，请重新获取"
    }
  }
}

public struct AppToken: Codable, Sendable, Equatable {
  public let mid: Int64
  public let accessToken: String
  public let refreshToken: String
  public let expiresAt: Int64
  public init(mid: Int64, accessToken: String, refreshToken: String, expiresAt: Int64) {
    self.mid = mid
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
  public var isComplete: Bool {
    mid > 0 && !accessToken.isEmpty && !refreshToken.isEmpty && expiresAt > 0
  }
}

public enum AuthorizationState: String, Sendable { case needsLogin, webOnly, appAuthorized }
public struct AuthSnapshot: Sendable {
  public let epoch: UInt64
  public let identityRevision: UInt64
  public let state: AuthorizationState
  public let token: AppToken?
  // Token headers only; BiliRPCMetadata builds the binary gRPC headers from this same snapshot.
  public var tokenHeaders: [String: String] {
    guard let token, state == .appAuthorized else { return [:] }
    return ["authorization": "identify_v1 \(token.accessToken)", "x-bili-mid": String(token.mid)]
  }
}

public enum AppForm {
  // BiliKernel 22fdf8ca, BiliAuthenticator.Extension.cs (GPL-3.0).
  static let appKey = "27eb53fc9058f8c3"
  private static let appSecret = "c2ed53a74eeefe3cf99fbd01d8c9c375"
  public static func signature(_ fields: [String: String], secret: String) -> String {
    WBI.md5(fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&") + secret)
  }
  public static func encoded(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    func encode(_ text: String) -> String {
      text.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(
        of: "%20", with: "+")
    }
    return Data(
      fields.keys.sorted().map { "\(encode($0))=\(encode(fields[$0]!))" }.joined(separator: "&")
        .utf8)
  }
  public static func authorized(
    _ fields: [String: String], timestamp: Int64, accessKey: String? = nil
  ) -> Data {
    var values = fields
    values.removeValue(forKey: "sign")
    values["build"] = "80200100"
    values["appkey"] = appKey
    values["mobi_app"] = "iphone"
    values["platform"] = "ios"
    values["ts"] = String(timestamp)
    if let accessKey {
      values["access_key"] = accessKey
    } else {
      values.removeValue(forKey: "access_key")
    }
    values["sign"] = signature(values, secret: appSecret)
    return encoded(values)
  }
  // Public application signing constants from BiliKernel ApiType.Web; not user credentials.
  public static func webAuthorized(
    _ fields: [String: String], timestampMilliseconds: Int64, accessKey: String? = nil
  ) -> Data {
    var values = fields
    values["sign"] = nil; values["mobi_app"] = nil
    values["appkey"] = "aa1e74ee4874176e"; values["build"] = "80200100"
    values["platform"] = "web"; values["ts"] = String(timestampMilliseconds)
    values["access_key"] = accessKey
    values["sign"] = signature(values, secret: "54e6a9a31b911cd5fc0daa66ebf94bc4")
    return encoded(values)
  }
}

public struct BiliCookieJar: Sendable {
  private(set) var cookies: [HTTPCookie] = []
  public init() {}
  public static func allowedDomain(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    let domain = lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
    guard !domain.hasSuffix("."), !domain.hasPrefix("."), !domain.contains("..") else {
      return false
    }
    return domain == "bilibili.com" || domain.hasSuffix(".bilibili.com")
  }
  public mutating func merge(_ incoming: [HTTPCookie], now: Date = Date()) {
    cookies.removeAll { ($0.expiresDate ?? .distantFuture) <= now }
    for cookie in incoming where Self.allowedDomain(cookie.domain) {
      cookies.removeAll {
        $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
      }
      if (cookie.expiresDate ?? .distantFuture) > now { cookies.append(cookie) }
    }
  }
  public func matching(_ url: URL, now: Date = Date()) -> [HTTPCookie] {
    guard let host = url.host?.lowercased(), Self.allowedDomain(host) else { return [] }
    return cookies.filter { cookie in
      let raw = cookie.domain.lowercased()
      let domain = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
      let hostMatches = host == domain || (raw.hasPrefix(".") && host.hasSuffix("." + domain))
      let path = url.path.isEmpty ? "/" : url.path
      let pathMatches =
        path == cookie.path
        || (path.hasPrefix(cookie.path)
          && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
      return hostMatches && pathMatches && (!cookie.isSecure || url.scheme == "https")
        && (cookie.expiresDate ?? .distantFuture) > now
    }.sorted { $0.path.count > $1.path.count }
  }
  public func header(_ url: URL, now: Date = Date()) -> String? {
    let selected = matching(url, now: now)
    return selected.isEmpty
      ? nil : selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }
  public mutating func receive(_ response: HTTPURLResponse, now: Date = Date()) {
    guard let url = response.url, let host = url.host, Self.allowedDomain(host) else { return }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
      if let key = entry.key as? String { result[key] = String(describing: entry.value) }
    }
    let received = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).filter {
      let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
      return Self.allowedDomain(domain) && (host == domain || host.hasSuffix("." + domain))
    }
    merge(received, now: now)
  }
}

public struct AuthHTTPResponse: Sendable {
  public let body: Data
  public let response: HTTPURLResponse
  public init(body: Data, response: HTTPURLResponse) {
    self.body = body
    self.response = response
  }
}
public protocol AuthTransport: Sendable {
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse
}
private final class AuthRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // Never forward credentials through an automatic redirect.
    completionHandler(nil)
  }
}
public final class IsolatedAuthTransport: AuthTransport, Sendable {
  public let session: URLSession
  public init(configuration: URLSessionConfiguration = .ephemeral) {
    let config = configuration.copy() as! URLSessionConfiguration
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.httpAdditionalHeaders = nil
    session = URLSession(
      configuration: config, delegate: AuthRedirectDelegate(), delegateQueue: nil)
  }
  public func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    let diagnostics = ProcessInfo.processInfo.environment["MANPING_NETWORK_DIAGNOSTICS"] == "1"
    let started = Date()
    func log(status: Int, code: Int?) {
      guard diagnostics else { return }
      let host = request.url?.host ?? ""
      let path = request.url?.path ?? ""
      // Never print query, request/response headers, bodies, or error descriptions.
      print("[network] \(request.httpMethod ?? "GET") \(host) \(path) status=\(status) code=\(code.map(String.init) ?? "none") elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))s")
    }
    do {
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else { throw AuthFailure.invalidResponse }
      let code = diagnostics
        ? ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["code"] as? Int : nil
      log(status: response.statusCode, code: code)
      return AuthHTTPResponse(body: data, response: response)
    } catch {
      log(status: 0, code: (error as NSError).code)
      throw error
    }
  }
}

// Shared by the UI and WebKit callbacks; a logout invalidates results already queued on MainActor.
@MainActor public final class AuthCallbackGate {
  public private(set) var generation: UInt64 = 0
  public init() {}
  public func invalidate() { generation &+= 1 }
  public func accepts(_ captured: UInt64) -> Bool { captured == generation && !Task.isCancelled }
}

// Cancel an abandoned refresh without cancelling a refresh another caller still needs.
final class AuthRefreshFlight: @unchecked Sendable {
  let id = UUID()
  let task: Task<AppToken, Error>
  private let lock = NSLock()
  private var waiters: Set<UUID> = []
  init(task: Task<AppToken, Error>) { self.task = task }
  func tryRegister(_ id: UUID) -> Bool {
    lock.withLock {
      guard !task.isCancelled else { return false }
      waiters.insert(id)
      return true
    }
  }
  func remove(_ id: UUID, cancelIfEmpty: Bool) {
    lock.withLock {
      waiters.remove(id)
      if cancelIfEmpty && waiters.isEmpty { task.cancel() }
    }
  }
  var isEmpty: Bool { lock.withLock { waiters.isEmpty } }
}
