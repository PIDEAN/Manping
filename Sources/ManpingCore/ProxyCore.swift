import Foundation

// Proxy / VPN support. Design follows the user's TV project (see docs/Proxy.md): a direct and a
// proxied URLSession side by side, routes decided per request, a built-in Shadowsocks client
// exposed as a local SOCKS5 entry, and a proxied path that fails closed (never silently direct).

public enum ProxyKind: String, Codable, CaseIterable, Sendable, Identifiable {
  case none, http, socks5, shadowsocks
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .none: "不使用"
    case .http: "HTTP / HTTPS 代理"
    case .socks5: "SOCKS5 代理"
    case .shadowsocks: "Shadowsocks（内置）"
    }
  }
}

/// Which Bilibili API requests use the proxy (region-locked mainland content for overseas users).
public enum RegionRoute: String, Codable, CaseIterable, Sendable, Identifiable {
  case off, auto, always
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .off: "关闭"
    case .auto: "遇到地区限制时自动走代理"
    case .always: "所有接口都走代理"
    }
  }
}

/// Whether video data may also be fetched through the proxy, next to the direct CDN nodes.
public enum MediaRoute: String, Codable, CaseIterable, Sendable, Identifiable {
  case off, onStall, concurrent
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .off: "关闭"
    case .onStall: "卡顿时自动启用代理并发"
    case .concurrent: "始终与直连并发"
    }
  }
  public var shortTitle: String {
    switch self {
    case .off: "关闭"
    case .onStall: "卡顿时启用"
    case .concurrent: "始终并发"
    }
  }
}

/// Proxied media routing decisions for a relayed playback session (kept pure for tests).
public enum MediaProxyPolicy {
  public enum HealthChange: Equatable, Sendable { case none, activate, reprobe, deactivate }

  /// What a relayed session does when the proxy's health flips. `active` says whether proxied
  /// fetching is on for the session. In `.concurrent` a proxy that was down when playback started
  /// joins once it recovers; an active one re-measures instead of keeping results from the outage.
  public static func healthChanged(route: MediaRoute, active: Bool, usable: Bool) -> HealthChange {
    guard usable else { return active ? .deactivate : .none }
    if active { return .reprobe }
    return route == .concurrent ? .activate : .none
  }

  public struct Routes: Equatable, Sendable {
    /// Benchmarked nodes fetched through the proxy by host swap.
    public var hosts: [CDNHost]
    /// Route keys (`host@proxy`) of issued hosts that cannot be swapped (e.g. Akamai) and
    /// answered through the proxy: the relay then fetches the issued primary URL through it.
    public var issuedKeys: [String]
    public var routeKeys: [String] { hosts.map { MediaRelay.proxyKey($0.name) } + issuedKeys }
    public static let none = Routes(hosts: [], issuedKeys: [])
    public init(hosts: [CDNHost], issuedKeys: [String]) { self.hosts = hosts; self.issuedKeys = issuedKeys }
  }

  /// The fastest proxied measurements, or `provisional` (the direct pool's best) before any.
  /// Quick reads through a tunnel are dominated by its round trip, so a route only needs to work.
  public static func routes(_ results: [CDNBenchmarkResult], provisional: [CDNHost], disabled: Set<CDNHost>,
    limit: Int = 2) -> Routes {
    let proxied = results.filter { MediaRelay.isProxyKey($0.host) }
    guard !proxied.isEmpty else { return Routes(hosts: Array(provisional.prefix(limit)), issuedKeys: []) }
    let usable = proxied.filter { $0.ok && $0.mbps >= 0.5 }.sorted { $0.mbps > $1.mbps }
    let hosts = usable.compactMap { CDNHost(MediaRelay.hostName(ofKey: $0.host)) }.filter { !disabled.contains($0) }
    let issued = usable.filter { CDNHost(MediaRelay.hostName(ofKey: $0.host)) == nil }.map(\.host)
    return Routes(hosts: Array(hosts.prefix(limit)), issuedKeys: issued)
  }
}

public struct ProxySettings: Codable, Equatable, Sendable {
  public var kind: ProxyKind = .none
  public var host = ""
  public var port = 0
  /// SOCKS5 user name (optional). The password lives in the Keychain, never here.
  public var username = ""
  public var cipher: ShadowsocksTunnel.Cipher = .chacha20
  public var region: RegionRoute = .auto
  public var media: MediaRoute = .onStall
  public init() {}

  public static let defaultsKey = "Manping.proxy.v1"

  public var isConfigured: Bool { kind != .none && Self.validHost(host) && (1...65535).contains(port) }
  public var needsSecret: Bool { kind == .shadowsocks }

  public static func load(from defaults: any PreferencesStore) -> ProxySettings {
    guard let data = defaults.data(forKey: defaultsKey),
      let value = try? JSONDecoder().decode(ProxySettings.self, from: data) else { return ProxySettings() }
    return value
  }
  public func save(to defaults: any PreferencesStore) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
  }

  /// A host name or IPv4/IPv6 literal without scheme, path or spaces.
  public static func validHost(_ value: String) -> Bool {
    let host = value.trimmingCharacters(in: .whitespaces)
    guard !host.isEmpty, host.count <= 253 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]_"))
    return host.unicodeScalars.allSatisfy(allowed.contains) && !host.contains("://")
  }

  /// Settings that change the network path (not the routing modes): a change restarts the tunnel.
  public func connectionSignature(secret: String?) -> String {
    let digest = secret.map { String($0.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16) } ?? "-"
    return "\(kind.rawValue)|\(host)|\(port)|\(username)|\(cipher.rawValue)|\(digest)"
  }
}

/// Request routing for `BiliService`: set by the caller for one task tree.
public enum BiliRoute {
  @TaskLocal public static var viaProxy = false
}

/// Owns the proxy path: starts the Shadowsocks tunnel when needed and hands out URLSession
/// configurations that go through the proxy. A configuration whose path is down points at a
/// refusing local port, so proxied traffic fails instead of leaking out directly.
public final class ProxyRuntime: @unchecked Sendable {
  public struct Status: Sendable, Equatable {
    public var configured = false
    public var running = false
    public var healthy = false
    public var message = ""
  }

  private let lock = NSLock()
  private let tunnel = ShadowsocksTunnel()
  private var settings = ProxySettings()
  private var secret: String?
  private var signature = ""
  /// The tunnel configuration the current settings ask for; rebuild notices for any other are stale.
  private var tunnelConfig: ShadowsocksTunnel.Config?
  private var revision = 0
  private var proxyDictionary: [AnyHashable: Any]?
  private var failures = 0
  private var lastFailure = Date.distantPast
  public var onChange: (@Sendable () -> Void)?

  public init() {
    tunnel.onRebuilt = { [weak self] config, port in self?.tunnelRebuilt(config, port: port) }
  }
  deinit { tunnel.stop() }

  /// Bumps whenever the proxied path changes; holders of proxied sessions rebuild them.
  public var currentRevision: Int { lock.withLock { revision } }
  public var current: ProxySettings { lock.withLock { settings } }

  public var status: Status {
    lock.withLock {
      var value = Status()
      value.configured = settings.isConfigured && (!settings.needsSecret || !(secret ?? "").isEmpty)
      guard value.configured else { value.message = "未配置"; return value }
      switch settings.kind {
      case .shadowsocks:
        value.running = tunnel.isRunning
        value.healthy = value.running && tunnel.healthy
        value.message = !value.running ? "隧道未运行" : value.healthy ? "隧道正常" : "代理服务器暂时连不上"
      default:
        value.running = true
        value.healthy = failures < 3 || Date().timeIntervalSince(lastFailure) > 30
        value.message = value.healthy ? "已启用" : "代理暂时连不上"
      }
      return value
    }
  }

  /// Usable for routing right now.
  public var isAvailable: Bool { status.healthy }

  /// Applies new settings. Only connection changes restart the tunnel; routing modes apply at once.
  public func apply(_ next: ProxySettings, secret nextSecret: String?) throws {
    let nextSignature = next.connectionSignature(secret: nextSecret)
    let wanted = Self.tunnelConfig(next, secret: nextSecret)
    let restart: Bool = lock.withLock {
      settings = next; secret = nextSecret
      guard nextSignature != signature else { return false }
      signature = nextSignature; failures = 0; tunnelConfig = wanted
      return true
    }
    guard restart else { onChange?(); return }
    var dictionary: [AnyHashable: Any]?
    var startError: Error?
    if next.isConfigured {
      switch next.kind {
      case .shadowsocks:
        guard let wanted else { tunnel.stop(); break }
        do {
          let port = try tunnel.start(wanted)
          dictionary = Self.socks(host: "127.0.0.1", port: Int(port), user: nil, password: nil)
        } catch {
          // The tunnel rebuilds itself; until then proxied traffic must fail, not go direct.
          dictionary = Self.refusing
          startError = error
        }
      case .socks5:
        tunnel.stop()
        dictionary = Self.socks(host: next.host, port: next.port, user: next.username.isEmpty ? nil : next.username,
          password: next.username.isEmpty ? nil : nextSecret)
      case .http:
        tunnel.stop()
        dictionary = Self.http(host: next.host, port: next.port)
      case .none:
        tunnel.stop()
      }
    } else {
      tunnel.stop()
    }
    lock.withLock {
      // A newer apply already published its own path; this one must not replace it.
      guard signature == nextSignature else { return }
      proxyDictionary = dictionary; revision += 1
    }
    onChange?()
    if let startError { throw startError }
  }

  /// A copy of `base` that goes through the proxy, or nil when no proxy is configured.
  public func configuration(_ base: URLSessionConfiguration) -> URLSessionConfiguration? {
    guard let dictionary = lock.withLock({ proxyDictionary }) else { return nil }
    let configuration = base.copy() as! URLSessionConfiguration
    configuration.connectionProxyDictionary = dictionary
    return configuration
  }

  /// Consumers report proxied failures so HTTP/SOCKS proxies get the same health signal as the tunnel.
  public func noteFailure() { lock.withLock { failures += 1; lastFailure = Date() } }
  public func noteSuccess() { lock.withLock { failures = 0 } }

  public func networkChanged(online: Bool) {
    tunnel.networkChanged(online: online)
    if online { lock.withLock { failures = 0 } }
  }

  /// A rebuilt tunnel entry. The notice arrives after the tunnel released its operation lock, so
  /// a newer configuration may already be running: only the entry of the wanted configuration
  /// that is still the live port is published (checked and published under one lock).
  func tunnelRebuilt(_ config: ShadowsocksTunnel.Config, port: UInt16) {
    let published: Bool = lock.withLock {
      guard settings.kind == .shadowsocks, config == tunnelConfig, port != 0, tunnel.port == port else { return false }
      proxyDictionary = Self.socks(host: "127.0.0.1", port: Int(port), user: nil, password: nil)
      revision += 1
      return true
    }
    if published { onChange?() }
  }

  static func tunnelConfig(_ settings: ProxySettings, secret: String?) -> ShadowsocksTunnel.Config? {
    guard settings.isConfigured, settings.kind == .shadowsocks, let secret, !secret.isEmpty else { return nil }
    return ShadowsocksTunnel.Config(server: settings.host, port: settings.port, password: secret, cipher: settings.cipher)
  }

  // MARK: Proxy dictionaries

  /// Port 9 (discard) is never listening on loopback: connections are refused at once.
  static var refusing: [AnyHashable: Any] { socks(host: "127.0.0.1", port: 9, user: nil, password: nil) }

  static func socks(host: String, port: Int, user: String?, password: String?) -> [AnyHashable: Any] {
    var dictionary: [AnyHashable: Any] = [
      kCFNetworkProxiesSOCKSEnable as String: 1, kCFNetworkProxiesSOCKSProxy as String: host,
      kCFNetworkProxiesSOCKSPort as String: port,
    ]
    if let user { dictionary[kCFStreamPropertySOCKSUser as String] = user }
    if let password { dictionary[kCFStreamPropertySOCKSPassword as String] = password }
    return dictionary
  }

  static func http(host: String, port: Int) -> [AnyHashable: Any] {
    [
      kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: host,
      kCFNetworkProxiesHTTPPort as String: port,
      "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
    ]
  }
}

/// `BiliService` transport for the proxied path. Rebuilds its session when the proxy changes.
public final class ProxyAuthTransport: AuthTransport, @unchecked Sendable {
  private let runtime: ProxyRuntime
  private let lock = NSLock()
  private var cached: (revision: Int, transport: IsolatedAuthTransport)?
  public init(runtime: ProxyRuntime) { self.runtime = runtime }

  public func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    guard let transport = current() else { throw BiliError.invalidResponse("代理未配置或不可用") }
    do {
      let response = try await transport.send(request)
      runtime.noteSuccess()
      return response
    } catch {
      if (error as? URLError)?.code != .cancelled { runtime.noteFailure() }
      throw error
    }
  }

  private func current() -> IsolatedAuthTransport? {
    let revision = runtime.currentRevision
    return lock.withLock {
      if let cached, cached.revision == revision { return cached.transport }
      guard let configuration = runtime.configuration(.ephemeral) else { cached = nil; return nil }
      configuration.timeoutIntervalForRequest = 20
      let transport = IsolatedAuthTransport(configuration: configuration)
      cached = (revision, transport)
      return transport
    }
  }
}

/// Exit check for the settings page: the zone API reports the country/province of the caller.
public struct ProxyProbeResult: Sendable, Equatable {
  public let ip: String
  public let country: String
  public let province: String
  public let isp: String
  public let milliseconds: Int
  public var inMainland: Bool { country == "中国" && !["香港", "澳门", "台湾"].contains(province) }
  public var summary: String {
    [ip, [country, province].filter { !$0.isEmpty }.joined(separator: " "), isp].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

extension ProxyRuntime {
  /// Requests the zone API through the proxy (or directly with `direct: true`).
  public func probe(direct: Bool = false, timeout: TimeInterval = 10) async throws -> ProxyProbeResult {
    let base = URLSessionConfiguration.ephemeral
    base.timeoutIntervalForRequest = timeout
    base.httpCookieStorage = nil
    let configuration: URLSessionConfiguration
    if direct { configuration = base } else {
      guard let proxied = self.configuration(base) else { throw BiliError.invalidResponse("代理未配置") }
      configuration = proxied
    }
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: URL(string: "https://api.bilibili.com/x/web-interface/zone")!)
    request.setValue(BiliService.browserUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let started = Date()
    let (data, _) = try await session.data(for: request)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let zone = root["data"] as? [String: Any] else { throw BiliError.invalidResponse("出口检测返回异常") }
    if !direct { noteSuccess() }
    return ProxyProbeResult(ip: zone["addr"] as? String ?? "", country: zone["country"] as? String ?? "",
      province: zone["province"] as? String ?? "", isp: zone["isp"] as? String ?? "",
      milliseconds: Int(Date().timeIntervalSince(started) * 1000))
  }
}
