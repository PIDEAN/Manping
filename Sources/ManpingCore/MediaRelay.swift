import Foundation
import Network

/// Per-node transfer statistics shown in the player's CDN panel.
public struct RelayHostStats: Sendable, Identifiable, Equatable {
  public var id: String { host }
  public let host: String
  /// Throughput over the last five seconds.
  public let recentMbps: Double
  /// Smoothed chunk throughput used for scheduling.
  public let estimatedMbps: Double
  public let totalBytes: Int
  public let inflight: Int
  public let failures: Int
  public let coolingDown: Bool
}

public struct RelaySnapshot: Sendable, Equatable {
  public let hosts: [RelayHostStats]
  public let activeConnections: Int
  public let hedgedRequests: Int
  public let retries: Int
  public let totalBytes: Int
  public var combinedMbps: Double { hosts.reduce(0) { $0 + $1.recentMbps } }
  public static let empty = RelaySnapshot(hosts: [], activeConnections: 0, hedgedRequests: 0, retries: 0, totalBytes: 0)
}

/// A loopback HTTP server that mpv reads instead of the CDN. Each stream is cut into fixed
/// chunks that are fetched concurrently from several benchmarked nodes; a slow chunk is
/// re-requested from a second node (hedging) and the first copy wins; failing nodes cool
/// down. Switching nodes therefore never reloads the player: later chunks simply come
/// from other hosts. Only `127.0.0.1` with an unguessable per-stream token is served.
public final class MediaRelay: @unchecked Sendable {
  public enum RelayError: Error { case unavailable, allOriginsFailed, rangeNotSatisfiable, unregistered }

  /// Suffix of a route key for a node reached through the proxy (statistics and pools keep
  /// direct and proxied paths to the same node apart).
  public static let proxySuffix = "@proxy"
  public static func proxyKey(_ host: String) -> String { host + proxySuffix }
  public static func isProxyKey(_ key: String) -> Bool { key.hasSuffix(proxySuffix) }
  public static func hostName(ofKey key: String) -> String {
    isProxyKey(key) ? String(key.dropLast(proxySuffix.count)) : key
  }

  private enum Origin: Hashable {
    /// A benchmarked node reached by swapping the template URL's host.
    case host(CDNHost, proxied: Bool)
    /// A URL issued by the playurl response (primary or backup), used as-is.
    case issued(URL, proxied: Bool)
    var proxied: Bool {
      switch self { case .host(_, let proxied), .issued(_, let proxied): proxied }
    }
    var key: String {
      let name: String
      switch self {
      case .host(let host, _): name = host.name
      case .issued(let url, _): name = url.host?.lowercased() ?? url.absoluteString
      }
      return proxied ? MediaRelay.proxyKey(name) : name
    }
  }

  private final class Source: @unchecked Sendable {
    let token: String
    let template: URL?
    let issued: [URL]
    let retryBudget: RelayRetryBudget
    var expiredStatus = 0
    var totalLength: Int?
    var contentType = "video/mp4"
    var inflight: [Int: Task<Data, Error>] = [:]
    /// Set under the relay lock when the stream is dropped; no new chunk task starts after it.
    var cancelled = false
    init(token: String, template: URL?, issued: [URL], retryBudget: RelayRetryBudget) {
      self.token = token; self.template = template; self.issued = issued; self.retryBudget = retryBudget
    }
  }

  private struct HostState {
    var bytesPerSecond: Double
    var inflight = 0
    var failures = 0
    var consecutiveFailures = 0
    var coolUntil = Date.distantPast
    var totalBytes = 0
    var recent: [(Date, Int)] = []
  }

  public let chunkSize: Int
  private let fetcher: CDNRangeFetching
  private let cacheLimit: Int
  /// A soft budget for starting retries, not a deadline for an already active transfer.
  private let retryStartBudget: Duration
  private let queue = DispatchQueue(label: "io.github.pidean.manping.media-relay")
  private let lock = NSLock()
  private var listener: NWListener?
  private var port: UInt16 = 0
  private var sources: [String: Source] = [:]
  private var activeHosts: [CDNHost] = []
  private var manualHost: String?
  /// Nodes fetched through the proxy, next to the direct pool.
  private var proxiedHosts: [CDNHost] = []
  /// Fetch each stream's issued primary URL through the proxy even without proxied nodes: an
  /// issued host that cannot be swapped (an overseas Akamai URL) has no `CDNHost` of its own.
  private var proxiesIssued = false
  private var proxyFetcher: CDNRangeFetching?
  private var disabledKeys: Set<String> = []
  private var hostStates: [String: HostState] = [:]
  private var cache: [String: Data] = [:]
  private var cacheOrder: [String] = []
  private var cacheBytes = 0
  private var connections = 0
  private var hedges = 0
  private var retries = 0
  private var totalBytes = 0

  /// mpv keeps its own demuxer cache of everything the relay delivers, so the relay only needs
  /// room for the prefetch window (at most 8 chunks) plus a little slack for short seeks.
  public init(fetcher: CDNRangeFetching, chunkSize: Int = 1 << 20, cacheLimit: Int = 48 << 20,
    retryStartBudget: Duration = .seconds(45)) {
    self.fetcher = fetcher; self.chunkSize = chunkSize; self.cacheLimit = cacheLimit
    self.retryStartBudget = max(.zero, retryStartBudget)
  }

  deinit { listener?.cancel() }

  // MARK: Lifecycle

  /// Starts the loopback listener once; later calls return the same port.
  @discardableResult public func start() async throws -> UInt16 {
    if let existing = lock.withLock({ listener != nil ? port : nil }) { return existing }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.acceptLocalOnly = true
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let once = OnceResume(continuation)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: once.resume(listener.port.map { .success($0.rawValue) } ?? .failure(RelayError.unavailable))
        case .failed, .cancelled: once.resume(.failure(RelayError.unavailable))
        default: break
        }
      }
      listener.start(queue: queue)
    }
    lock.withLock { self.listener = listener; self.port = port }
    return port
  }

  public func stop() {
    let current = lock.withLock { () -> NWListener? in
      let value = listener; listener = nil
      sources.values.forEach(drop)
      sources = [:]; cache = [:]; cacheOrder = []; cacheBytes = 0
      return value
    }
    current?.cancel()
  }

  // MARK: Streams and nodes

  /// Registers one media stream (its primary URL and the playurl backups) and returns the
  /// loopback URL mpv should open. Issued URLs stay usable as origins even when they are not
  /// host-swappable (for example an overseas Akamai backup).
  public func register(_ primary: URL, backups: [URL] = [], retryBudget: RelayRetryBudget? = nil) -> URL? {
    let token = Self.token()
    let issued = [primary] + backups.filter { $0 != primary }
    let template = issued.first(where: CDNCatalog.isSwappable)
    let ext = primary.pathExtension.isEmpty ? "m4s" : primary.pathExtension
    return lock.withLock { () -> URL? in
      guard listener != nil, port > 0 else { return nil }
      sources[token] = Source(token: token, template: template, issued: issued, retryBudget: retryBudget ?? RelayRetryBudget(seconds: Double(retryStartBudget.components.seconds) + Double(retryStartBudget.components.attoseconds) / 1e18))
      return URL(string: "http://127.0.0.1:\(port)/r/\(token)/stream.\(ext)")
    }
  }

  /// Safe scalar health signal; never exposes signed origin URLs or credentials.
  public func expiredStatus(for urls: [URL]) -> Int {
    lock.withLock {
      urls.compactMap { $0.pathComponents.count >= 3 ? sources[$0.pathComponents[2]]?.expiredStatus : nil }
        .first(where: { $0 != 0 }) ?? 0
    }
  }

  /// Drops every stream except the given loopback URLs (the ones mpv is playing now).
  public func unregister(keeping urls: [URL]) {
    let keep = Set(urls.compactMap { $0.pathComponents.count >= 3 ? $0.pathComponents[2] : nil })
    lock.withLock {
      for (token, source) in sources where !keep.contains(token) {
        drop(source)
        sources[token] = nil
        let prefix = token + "#"
        for key in cache.keys where key.hasPrefix(prefix) { cacheBytes -= cache.removeValue(forKey: key)?.count ?? 0 }
        cacheOrder.removeAll { $0.hasPrefix(prefix) }
      }
    }
  }

  /// Drops every registered stream (cancelling their prefetches) when playback closes.
  public func unregisterAll() {
    lock.withLock {
      sources.values.forEach(drop)
      sources = [:]; cache = [:]; cacheOrder = []; cacheBytes = 0
    }
  }

  /// Call with the lock held.
  private func drop(_ source: Source) {
    source.cancelled = true
    source.inflight.values.forEach { $0.cancel() }
    source.inflight = [:]
  }

  /// Sets the node pool. `seedMbps` primes scheduling with benchmark results so the
  /// fastest node gets the most chunks from the first second.
  public func setHosts(_ hosts: [CDNHost], seedMbps: [String: Double] = [:]) {
    lock.withLock {
      activeHosts = hosts
      for host in hosts {
        let seed = (seedMbps[host.name] ?? 16) * 125_000
        if var state = hostStates[host.name] {
          if state.totalBytes == 0 { state.bytesPerSecond = seed }
          state.coolUntil = .distantPast; state.consecutiveFailures = 0
          hostStates[host.name] = state
        } else {
          hostStates[host.name] = HostState(bytesPerSecond: seed)
        }
      }
    }
  }

  /// A manual node is a strict origin boundary, including issued and proxied fallbacks.
  public func setManualHost(_ host: String?) {
    lock.withLock { manualHost = host?.lowercased() }
  }

  /// Call with the relay lock held. Rechecked at scheduling and immediately before launch.
  private func permits(_ origin: Origin) -> Bool {
    manualHost == nil || Self.hostName(ofKey: origin.key) == manualHost
  }


  /// The proxied transport (nil turns every proxied route off). Replaced when the proxy changes.
  public func setProxyFetcher(_ fetcher: CDNRangeFetching?) {
    lock.withLock {
      proxyFetcher = fetcher
      if fetcher == nil { proxiedHosts = []; proxiesIssued = false }
    }
  }

  /// Nodes to fetch through the proxy as well. Their statistics live under `proxyKey(host)`.
  /// `issued` also routes each stream's issued primary URL through the proxy when `hosts` is empty.
  public func setProxiedHosts(_ hosts: [CDNHost], issued: Bool = false, seedMbps: [String: Double] = [:]) {
    lock.withLock {
      proxiedHosts = proxyFetcher == nil ? [] : hosts
      proxiesIssued = proxyFetcher != nil && issued
      for host in proxiedHosts {
        let key = Self.proxyKey(host.name)
        let seed = (seedMbps[key] ?? 8) * 125_000
        if var state = hostStates[key] {
          if state.totalBytes == 0 { state.bytesPerSecond = seed }
          state.coolUntil = .distantPast; state.consecutiveFailures = 0
          hostStates[key] = state
        } else {
          hostStates[key] = HostState(bytesPerSecond: seed)
        }
      }
    }
  }
  var proxiedPool: [CDNHost] { lock.withLock { proxiedHosts } }
  var proxiesIssuedPrimary: Bool { lock.withLock { proxiesIssued } }

  /// Nodes the user turned off. They are skipped for issued URLs too, unless nothing else is left.
  public func setDisabled(_ keys: Set<String>) {
    lock.withLock { disabledKeys = keys }
  }

  /// Hosts that failed the benchmark are cooled down so issued-but-dead URLs are tried last.
  public func markUnreachable(_ keys: [String], for seconds: TimeInterval = 600) {
    lock.withLock {
      let until = Date().addingTimeInterval(seconds)
      for key in keys {
        var state = hostStates[key] ?? HostState(bytesPerSecond: 50_000)
        state.coolUntil = until; state.bytesPerSecond = min(state.bytesPerSecond, 50_000)
        hostStates[key] = state
      }
    }
  }

  public func snapshot(now: Date = Date()) -> RelaySnapshot {
    lock.withLock {
      let keys = Set(activeHosts.map(\.name)).union(proxiedHosts.map { Self.proxyKey($0.name) })
        .union(hostStates.filter { $0.value.totalBytes > 0 }.map(\.key))
      let stats = keys.sorted().compactMap { key -> RelayHostStats? in
        guard let state = hostStates[key] else { return nil }
        let window = state.recent.filter { now.timeIntervalSince($0.0) <= 5 }.reduce(0) { $0 + $1.1 }
        return RelayHostStats(host: key, recentMbps: Double(window) * 8 / 5 / 1_000_000,
          estimatedMbps: state.bytesPerSecond * 8 / 1_000_000, totalBytes: state.totalBytes, inflight: state.inflight,
          failures: state.failures, coolingDown: state.coolUntil > now)
      }
      return RelaySnapshot(hosts: stats, activeConnections: connections, hedgedRequests: hedges, retries: retries,
        totalBytes: totalBytes)
    }
  }

  // MARK: HTTP serving

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receiveHeader(connection, buffer: Data())
  }

  private func receiveHeader(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
      guard let self else { connection.cancel(); return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        Task { await self.serve(connection, header: header) }
      } else if error != nil || complete || buffer.count > 32 * 1024 {
        connection.cancel()
      } else {
        self.receiveHeader(connection, buffer: buffer)
      }
    }
  }

  private func serve(_ connection: NWConnection, header: String) async {
    lock.withLock { connections += 1 }
    defer { lock.withLock { connections -= 1 }; connection.cancel() }
    let lines = header.components(separatedBy: "\r\n")
    let parts = lines.first?.split(separator: " ") ?? []
    guard parts.count >= 2, ["GET", "HEAD"].contains(String(parts[0])) else {
      await respond(connection, status: "405 Method Not Allowed"); return
    }
    let pathParts = parts[1].split(separator: "/")
    guard pathParts.count >= 2, pathParts[0] == "r",
      let source = lock.withLock({ sources[String(pathParts[1])] }) else {
      await respond(connection, status: "404 Not Found"); return
    }
    let rangeLine = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
    let requested = rangeLine.flatMap { Self.parseRange($0.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
    // The first chunk also discovers the total length and content type.
    let startIndex = (requested?.start ?? 0) / chunkSize
    func unsatisfiable() -> String? {
      guard let total = lock.withLock({ source.totalLength }), let start = requested?.start, start >= total else { return nil }
      return "Content-Range: bytes */\(total)\r\n"
    }
    if let extra = unsatisfiable() {
      await respond(connection, status: "416 Range Not Satisfiable", extra: extra); return
    }
    let first: Data
    do { first = try await chunk(source, index: startIndex) } catch {
      if let extra = unsatisfiable() {
        await respond(connection, status: "416 Range Not Satisfiable", extra: extra)
      } else if case RelayError.unregistered = error {
        // The stream was replaced (quality change) while mpv was still opening it.
        await respond(connection, status: "404 Not Found")
      } else {
        await respond(connection, status: "502 Bad Gateway")
      }
      return
    }
    guard let total = lock.withLock({ source.totalLength }) else {
      await respond(connection, status: "502 Bad Gateway"); return
    }
    let start = requested?.start ?? 0
    let end = min(requested?.end ?? total - 1, total - 1)
    guard start < total, start <= end else {
      await respond(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(total)\r\n"); return
    }
    let partial = requested != nil
    var head = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
    head += "Content-Type: \(lock.withLock { source.contentType })\r\nAccept-Ranges: bytes\r\n"
    if partial { head += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
    head += "Content-Length: \(end - start + 1)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    guard await send(connection, Data(head.utf8)), parts[0] == "GET" else { return }

    var position = start
    var current: (index: Int, data: Data)? = (startIndex, first)
    while position <= end {
      let index = position / chunkSize
      prefetch(source, after: index, total: total)
      let data: Data
      if let current, current.index == index { data = current.data } else {
        do { data = try await chunk(source, index: index) } catch { return }
      }
      current = nil
      let offset = position - index * chunkSize
      guard offset < data.count else { return }
      let length = min(data.count - offset, end - position + 1)
      guard await send(connection, data.subdata(in: offset..<(offset + length))) else { return }
      position += length
    }
  }

  private func respond(_ connection: NWConnection, status: String, extra: String = "") async {
    _ = await send(connection, Data("HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8))
  }

  private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
    await withCheckedContinuation { continuation in
      connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
    }
  }

  static func parseRange(_ value: String) -> (start: Int, end: Int?)? {
    guard value.lowercased().hasPrefix("bytes=") else { return nil }
    let spec = value.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
    let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2, let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)), start >= 0 else { return nil }
    let end = Int(bounds[1].trimmingCharacters(in: .whitespaces))
    if let end, end < start { return nil }
    return (start, end)
  }

  // MARK: Chunks

  /// Starts the next chunks that are neither cached nor already downloading. A stream never has
  /// more than `window` chunk downloads in flight, so repeated seeks cannot pile up requests.
  private func prefetch(_ source: Source, after index: Int, total: Int) {
    let last = (total - 1) / chunkSize
    guard index < last else { return }
    let wanted: [Int] = lock.withLock {
      guard !source.cancelled else { return [] }
      let window = min(8, max(2, (activeHosts.count + 1) * 2))
      var room = window - source.inflight.count
      var list: [Int] = []
      for next in (index + 1)...min(last, index + window) where room > 0 {
        guard source.inflight[next] == nil, cache[cacheKey(source, next)] == nil else { continue }
        list.append(next); room -= 1
      }
      return list
    }
    for next in wanted {
      Task { _ = try? await self.chunk(source, index: next) }
    }
  }

  private func cacheKey(_ source: Source, _ index: Int) -> String { "\(source.token)#\(index)" }

  private func chunk(_ source: Source, index: Int) async throws -> Data {
    let key = cacheKey(source, index)
    let found: Result<Task<Data, Error>, Error> = lock.withLock {
      if let cached = cache[key] {
        cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
        return .success(Task { cached })
      }
      if let running = source.inflight[index] { return .success(running) }
      guard !source.cancelled else { return .failure(RelayError.unregistered) }
      let created = Task { try await self.download(source, index: index) }
      source.inflight[index] = created
      return .success(created)
    }
    let task = try found.get()
    do {
      let data = try await task.value
      lock.withLock {
        // A later download of the same chunk may have replaced this task; leave that one alone.
        if source.inflight[index] == task { source.inflight[index] = nil }
        guard !source.cancelled, sources[source.token] != nil, cache[key] == nil else { return }
        cache[key] = data; cacheOrder.append(key); cacheBytes += data.count
        while cacheBytes > cacheLimit, let oldest = cacheOrder.first {
          cacheOrder.removeFirst(); cacheBytes -= cache.removeValue(forKey: oldest)?.count ?? 0
        }
      }
      return data
    } catch {
      lock.withLock { if source.inflight[index] == task { source.inflight[index] = nil } }
      throw error
    }
  }

  private func range(for source: Source, index: Int) -> ClosedRange<Int> {
    let start = index * chunkSize
    let end = lock.withLock { source.totalLength }.map { min($0 - 1, start + chunkSize - 1) } ?? start + chunkSize - 1
    return start...max(start, end)
  }

  /// Active nodes first; issued URLs are appended unless their host is already in the pool.
  /// Hosts outside the pool that cooled down hard (dead) are skipped by `pick`.
  private func origins(for source: Source) -> [Origin] {
    lock.withLock {
      var list: [Origin] = source.template == nil ? [] : activeHosts.map { .host($0, proxied: false) }
      for url in source.issued where !list.contains(where: { $0.key == (url.host?.lowercased() ?? "") }) {
        list.append(.issued(url, proxied: false))
      }
      if proxyFetcher != nil, !proxiedHosts.isEmpty || proxiesIssued {
        if source.template != nil { list += proxiedHosts.map { .host($0, proxied: true) } }
        // The issued primary through the proxy too: for overseas viewers it may be the only way in.
        if let primary = source.issued.first, !list.contains(where: { $0.key == MediaRelay.proxyKey(primary.host?.lowercased() ?? "") }) {
          list.append(.issued(primary, proxied: true))
        }
      }
      list = list.filter { permits($0) }
      let allowed = list.filter { !disabledKeys.contains(MediaRelay.hostName(ofKey: $0.key)) }
      return allowed.isEmpty ? list : allowed
    }
  }

  private func url(for origin: Origin, source: Source) -> URL? {
    switch origin {
    case .host(let host, _): source.template.flatMap { CDNCatalog.replacingHost($0, with: host) }
    case .issued(let url, _): url
    }
  }

  /// Best-scoring origin not excluded and not cooling down. Picking also reserves an in-flight
  /// slot under the same lock, so prefetches started together spread across nodes instead of
  /// all choosing the same one.
  private func pick(_ origins: [Origin], excluding: Set<String>) -> Origin? {
    lock.withLock {
      let now = Date()
      let open = origins.filter { permits($0) && !excluding.contains($0.key) }
      let warm = open.filter { (hostStates[$0.key]?.coolUntil ?? .distantPast) <= now }
      let pool = warm.isEmpty ? open : warm
      guard let chosen = pool.max(by: { lhs, rhs in score(lhs) < score(rhs) }) else { return nil }
      hostStates[chosen.key, default: HostState(bytesPerSecond: 2_000_000)].inflight += 1
      return chosen
    }
  }

  private func score(_ origin: Origin) -> Double {
    let state = hostStates[origin.key] ?? HostState(bytesPerSecond: 2_000_000)
    // Issued URLs outside the benchmarked pool are a fallback, not a first choice.
    let inPool = activeHosts.contains { $0.name == origin.key } || proxiedHosts.contains { MediaRelay.proxyKey($0.name) == origin.key }
      || (proxiesIssued && origin.proxied)
    let penalty = { if case .issued = origin, !inPool { return 0.5 } else { return 1.0 } }()
    return state.bytesPerSecond * penalty / Double(state.inflight + 1)
  }

  private func download(_ source: Source, index: Int) async throws -> Data {
    let range = range(for: source, index: index)
    let clock = ContinuousClock()
    var excluded = Set<String>()
    var attempt = 0
    while !source.retryBudget.exhausted {
      try Task.checkCancellation()
      let origins = origins(for: source)
      let attemptStart = ProcessInfo.processInfo.systemUptime
      guard let primary = pick(origins, excluding: excluded) ?? pick(origins, excluding: []) else { break }
      if attempt > 0 { lock.withLock { retries += 1 } }
      let outcome = await hedgedFetch(source: source, range: range, primary: primary, origins: origins, excluded: excluded)
      if let total = outcome.unsatisfiable {
        // The chunk starts past the end of the resource: remember the length and answer 416.
        lock.withLock { if source.totalLength == nil, let total { source.totalLength = total } }
        throw RelayError.rangeNotSatisfiable
      }
      if let (data, total, type) = outcome.success {
        lock.withLock {
          source.expiredStatus = 0
          if source.totalLength == nil { source.totalLength = total }
          if let type, type.hasPrefix("video") || type.hasPrefix("audio") { source.contentType = type }
        }
        return data
      }
      source.retryBudget.recordFailure(from: attemptStart, to: ProcessInfo.processInfo.systemUptime)
      excluded.formUnion(outcome.failed)
      if excluded.count >= origins.count {
        excluded.removeAll()
        // Successful slow requests are never timed out by the retry-start budget.
        let remaining = source.retryBudget.remaining
        guard remaining > 0 else { break }
        let backoff = min(remaining, min(4, 0.4 * Double(attempt + 1)))
        let backoffStart = ProcessInfo.processInfo.systemUptime
        try await clock.sleep(for: .seconds(backoff))
        source.retryBudget.recordFailure(from: backoffStart, to: ProcessInfo.processInfo.systemUptime)
      }
      attempt += 1
    }
    throw RelayError.allOriginsFailed
  }

  private struct HedgeOutcome {
    var success: (Data, Int?, String?)?
    /// Set when a node answered 416; carries the total length from `bytes */total` if given.
    var unsatisfiable: Int??
    var failed: Set<String> = []
  }

  private enum Attempt: Sendable { case done(String, CDNFetchOutcome), timer }

  /// Fetches from `primary`; if it is slower than expected, starts the same range on the next
  /// best origin and keeps whichever finishes first.
  private func hedgedFetch(source: Source, range: ClosedRange<Int>, primary: Origin, origins: [Origin],
    excluded: Set<String>) async -> HedgeOutcome {
    let expected = lock.withLock { Double(range.count) / max(hostStates[primary.key]?.bytesPerSecond ?? 2_000_000, 100_000) }
    // Hedge only clearly slow chunks: about a third of chunks were duplicated at 2.5x/1.2 s.
    let hedgeAfter = min(8, max(2.0, expected * 4))
    let timeout = max(8, expected * 6)
    var outcome = HedgeOutcome()
    await withTaskGroup(of: Attempt.self) { group in
      // `pick` already reserved the in-flight slot; `record` releases it.
      func launch(_ origin: Origin) {
        let transport: CDNRangeFetching? = lock.withLock {
          guard permits(origin) else { return nil }
          return origin.proxied ? proxyFetcher : fetcher
        }
        guard let url = url(for: origin, source: source), let transport else {
          lock.withLock {
            if var state = hostStates[origin.key] { state.inflight = max(0, state.inflight - 1); hostStates[origin.key] = state }
          }
          return
        }
        group.addTask {
          guard !Task.isCancelled, self.lock.withLock({ self.permits(origin) }) else {
            return .done(origin.key, CDNFetchOutcome(status: 0, data: Data(), ttfbMs: 0,
              durationMs: 0, totalLength: nil, contentType: nil, error: "已取消"))
          }
          return .done(origin.key, await transport.fetch(url, range: range, timeout: timeout))
        }
      }
      launch(primary)
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(hedgeAfter * 1_000_000_000))
        return .timer
      }
      var running = 1
      var hedged = false
      while running > 0, let next = await group.next() {
        switch next {
        case .timer:
          guard !hedged, outcome.success == nil,
            let backup = pick(origins, excluding: excluded.union([primary.key])) else { continue }
          hedged = true; running += 1
          lock.withLock { hedges += 1 }
          launch(backup)
        case .done(let key, let result):
          running -= 1
          record(key, result: result, expectedBytes: range.count)
          if [403, 410].contains(result.status) { lock.withLock { source.expiredStatus = result.status } }
          if outcome.success != nil || outcome.unsatisfiable != nil { continue }
          if result.status == 416 {
            outcome.unsatisfiable = .some(result.totalLength)
            group.cancelAll()
            continue
          }
          // Only an exact window counts: the full chunk, or exactly the bytes left before EOF.
          let complete = result.data.count == range.count
            || (result.totalLength.map { range.upperBound >= $0 - 1 && result.data.count == $0 - range.lowerBound } ?? false)
          if result.ok, complete {
            // Cancel the loser but keep draining so its in-flight count is released.
            outcome.success = (result.data, result.totalLength, result.contentType)
            group.cancelAll()
          } else if result.error != "已取消" {
            outcome.failed.insert(key)
          }
        }
      }
      group.cancelAll()
    }
    return outcome
  }

  private func record(_ key: String, result: CDNFetchOutcome, expectedBytes: Int) {
    lock.withLock {
      var state = hostStates[key] ?? HostState(bytesPerSecond: 2_000_000)
      state.inflight = max(0, state.inflight - 1)
      let now = Date()
      if result.ok {
        let seconds = max(result.durationMs / 1000, 0.001)
        let rate = Double(result.data.count) / seconds
        state.bytesPerSecond = state.totalBytes == 0 ? rate : state.bytesPerSecond * 0.7 + rate * 0.3
        state.totalBytes += result.data.count
        state.consecutiveFailures = 0
        state.recent.append((now, result.data.count))
        state.recent.removeAll { now.timeIntervalSince($0.0) > 10 }
        totalBytes += result.data.count
      } else if result.error != "已取消", result.status != 416 {
        state.failures += 1; state.consecutiveFailures += 1
        let hard = [401, 403, 404, 410].contains(result.status)
        state.coolUntil = now.addingTimeInterval(hard ? 120 : min(60, 10 * Double(state.consecutiveFailures)))
        state.bytesPerSecond *= 0.5
      }
      hostStates[key] = state
    }
  }

  private static func token() -> String {
    (0..<4).map { _ in String(UInt32.random(in: .min ... .max), radix: 16) }.joined()
  }
}

private final class OnceResume<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
  func resume(_ result: Result<Value, Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<Value, Error>? in let value = continuation; continuation = nil; return value }
    pending?.resume(with: result)
  }
}
