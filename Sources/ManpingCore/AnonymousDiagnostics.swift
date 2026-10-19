import Foundation

/// Deliberately has no backing store. Diagnostic code must never attempt credential access.
public final class DenyCredentialStore: AuthCredentialStore, @unchecked Sendable {
  public enum Failure: Error { case denied }
  private let lock = NSLock()
  private var calls = 0
  public init() {}
  public var callCount: Int { lock.withLock { calls } }
  private func deny() throws -> Never { lock.withLock { calls += 1 }; throw Failure.denied }
  public func save(_ cookies: [HTTPCookie]) throws { try deny() }
  public func load() throws -> [HTTPCookie] { try deny() }
  public func saveToken(_ token: AppToken?) throws { try deny() }
  public func loadToken() throws -> AppToken? { try deny() }
  public func clear() throws { try deny() }
  public func loadAll() throws -> (cookies: [HTTPCookie], token: AppToken?) { try deny() }
}

/// Explicitly scoped to anonymous playback diagnostics. Unknown routes, account credentials
/// and mutations fail before reaching the transport. Responses cannot populate an account jar.
public final class GETOnlyAuditedTransport: AuthTransport, @unchecked Sendable {
  public enum Failure: Error { case rejected, transport, response }
  private let base: any AuthTransport
  private let lock = NSLock()
  private var sent = 0, rejected = 0, nonGET = 0
  private var lastRejection: String?
  public init(base: any AuthTransport) { self.base = base }
  public struct Audit: Sendable {
    public let sent: Int
    public let rejected: Int
    public let nonGET: Int
    /// The policy category of the latest rejected request (field names only).
    public let lastRejection: String?
  }
  public var audit: Audit { lock.withLock { Audit(sent: sent, rejected: rejected, nonGET: nonGET, lastRejection: lastRejection) } }
  private static let api = "api.bilibili.com"
  private static let live = "api.live.bilibili.com"
  private static let paths: [String: [String: Set<String>]] = [
    api: [
      "/x/frontend/finger/spi": [], "/x/web-interface/nav": [],
      "/x/web-interface/wbi/view": ["bvid", "w_rid", "wts"],
      "/x/player/wbi/playurl": ["cid", "qn", "fnval", "fourk", "avid", "bvid", "w_rid", "wts"],
    ],
    live: [
      "/room/v1/Room/room_init": ["id"],
      "/room/v1/Room/get_info": ["room_id"],
      "/live_user/v1/Master/info": ["uid"],
      "/xlive/app-interface/v2/index/feed": ["page", "relation_page", "scale", "login_event", "device", "appkey", "build", "mobi_app", "platform", "ts", "sign"],
      "/xlive/web-room/v2/index/getRoomPlayInfo": ["room_id", "no_playurl", "qn", "codec", "dolby", "format", "only_audio", "protocol", "mask", "panorama"],
    ],
  ]
  private static let headers: Set<String> = ["user-agent", "referer", "accept", "accept-language", "cookie"]
  private static let devices: Set<String> = ["buvid3", "buvid4", "b_nut"]
  public static func allows(_ request: URLRequest) -> Bool { rejection(request) == nil }
  /// Why a request fails the policy, as a fixed category plus the offending field NAME (never a
  /// value): `method`, `url`, `route <path>`, `query <name>`, `header <name>`, `cookie <name>`.
  public static func rejection(_ request: URLRequest) -> String? {
    guard (request.httpMethod ?? "GET") == "GET", request.httpBody == nil, request.httpBodyStream == nil else { return "method" }
    guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "https", let host = parts.host, parts.port == nil || parts.port == 443,
      parts.user == nil, parts.password == nil, parts.fragment == nil,
      parts.percentEncodedPath == parts.path else { return "url" }
    guard let routes = paths[host] else { return "url" }
    guard let queryKeys = routes[parts.path] else { return "route \(parts.path)" }
    var seen: Set<String> = []
    for item in parts.queryItems ?? [] {
      let known = queryKeys.contains(item.name)
      guard known, seen.insert(item.name).inserted,
        let value = item.value, !value.isEmpty, value.utf8.count <= 256,
        !value.contains(where: { $0.isNewline || $0.asciiValue == nil }) else { return "query \(Self.fieldName(item.name))" }
    }
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
      guard headers.contains(name.lowercased()), !value.contains(where: { $0.isNewline }) else {
        return "header \(Self.fieldName(name))"
      }
      if name.lowercased() == "cookie" {
        for raw in value.split(separator: ";", omittingEmptySubsequences: false) {
          let cookie = raw.trimmingCharacters(in: .whitespaces)
          if cookie.isEmpty { continue }
          let pair = cookie.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          guard pair.count == 2, devices.contains(String(pair[0])) else { return "cookie \(Self.fieldName(String(pair[0])))" }
          guard !pair[1].isEmpty, pair[1].utf8.count <= 256,
            pair[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._~-%=".contains($0)) }) else { return "cookie \(Self.fieldName(String(pair[0])))" }
        }
      }
    }
    return nil
  }
  /// A field name for the log: printable ASCII only, at most 32 characters.
  private static func fieldName(_ name: String) -> String {
    String(name.unicodeScalars.filter { $0.isASCII && $0.value > 32 && $0.value < 127 }.prefix(32).map(Character.init))
  }
  public func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    if let reason = Self.rejection(request) {
      lock.withLock { rejected += 1; lastRejection = reason; if (request.httpMethod ?? "GET") != "GET" { nonGET += 1 } }
      throw Failure.rejected
    }
    lock.withLock { sent += 1 }
    let result: AuthHTTPResponse
    do { result = try await base.send(request) }
    catch is CancellationError { throw CancellationError() }
    catch { throw Failure.transport }
    // IsolatedAuthTransport refuses redirects; enforce that contract for injected transports too.
    guard result.response.url == request.url, !(300..<400).contains(result.response.statusCode),
      let url = request.url else { throw Failure.response }
    // Device IDs arrive in finger/spi JSON. No response cookie is needed by this diagnostic.
    let fields = result.response.allHeaderFields.reduce(into: [String: String]()) { output, item in
      if let name = item.key as? String, name.lowercased() != "set-cookie" { output[name] = String(describing: item.value) }
    }
    guard let response = HTTPURLResponse(url: url, statusCode: result.response.statusCode,
      httpVersion: nil, headerFields: fields) else { throw Failure.response }
    return AuthHTTPResponse(body: result.body, response: response)
  }
}
