import Foundation

// CDN candidate, benchmark and stall-recovery policy. The rules port the logic of
// liiliiliil/bili-cdn-switcher (MIT, see ThirdPartyNotices/BiliCdnSwitcher.md): only
// `*.bilivideo.com` UPOS hosts are candidates, a host swap keeps the signed path and query,
// a two-stage benchmark picks the node, and buffer-trend sampling triggers recovery early.

/// One CDN node host, validated to be a plain `*.bilivideo.com` name.
public struct CDNHost: Hashable, Sendable, Comparable, CustomStringConvertible {
  public let name: String
  public init?(_ value: String) {
    let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !host.isEmpty, host.count <= 253, !host.contains(".."),
      host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }),
      host.hasSuffix(".bilivideo.com") else { return nil }
    name = host
  }
  public var description: String { name }
  public static func < (lhs: CDNHost, rhs: CDNHost) -> Bool { lhs.name < rhs.name }
}

public enum CDNCandidateSource: String, Codable, Sendable, CaseIterable {
  case current, playurl, custom, builtin, learned
  public var title: String {
    switch self {
    case .current: "当前播放"
    case .playurl: "接口签发"
    case .custom: "自定义"
    case .builtin: "内置节点"
    case .learned: "近期学习"
    }
  }
}

public struct CDNCandidate: Hashable, Sendable, Identifiable {
  public var id: String { host.name }
  public let host: CDNHost
  public let label: String
  public let source: CDNCandidateSource
  public var disabled: Bool
  public init(host: CDNHost, label: String? = nil, source: CDNCandidateSource, disabled: Bool = false) {
    self.host = host; self.label = label ?? CDNCatalog.label(for: host); self.source = source; self.disabled = disabled
  }
}

public enum CDNCatalog {
  /// Core UPOS mirrors that accept host-swapped signed paths.
  public static let builtin: [(String, String)] = [
    ("upos-sz-mirrorcos.bilivideo.com", "腾讯云 COS"),
    ("upos-sz-mirrorhw.bilivideo.com", "华为云"),
    ("upos-sz-mirrorali.bilivideo.com", "阿里云"),
    ("upos-tf-all-hw.bilivideo.com", "华为通用"),
    ("upos-tf-all-tx.bilivideo.com", "腾讯通用"),
    ("upos-sz-mirroraliov.bilivideo.com", "阿里云海外"),
    ("upos-sz-mirrorcosov.bilivideo.com", "腾讯云海外"),
    ("upos-sz-mirrorhwov.bilivideo.com", "华为云海外"),
  ]
  public static func label(for host: CDNHost) -> String {
    if let match = builtin.first(where: { $0.0 == host.name }) { return match.1 }
    let first = host.name.split(separator: ".").first.map(String.init) ?? host.name
    if first.contains("mirrorcos") { return "腾讯云 COS" }
    if first.contains("mirrorhw") { return "华为云" }
    if first.contains("mirrorali") { return "阿里云" }
    if first.contains("bstar") { return "海外 bstar" }
    return first
  }

  /// Whether a URL is a host-swappable media URL (not PCDN / P2P / 302 / non-default port).
  public static func isSwappable(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), CDNHost(host) != nil, url.port == nil,
      ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let first = host.split(separator: ".").first.map(String.init) ?? ""
    let path = url.path.lowercased()
    guard path.hasSuffix(".m4s") || path.hasSuffix(".mp4") || path.hasSuffix(".flv") || path.contains("/upgcxcode/") else { return false }
    return !(components?.queryItems?.contains { $0.name == "os" && $0.value == "mcdn" } ?? false)
      && !host.contains(".mcdn.") && !first.contains("302") && host != "upos-sz-mirror14b.bilivideo.com"
  }

  /// Replaces scheme and host only; the signed path and query stay byte-for-byte identical.
  public static func replacingHost(_ url: URL, with host: CDNHost) -> URL? {
    guard isSwappable(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    components.scheme = "https"; components.host = host.name; components.port = nil
    return components.url
  }

  /// Candidate order: current → playurl-issued → custom → builtin → learned, de-duplicated and capped.
  public static func candidates(current: CDNHost?, playurl: [CDNHost], custom: [CDNHost], learned: [CDNHost],
    disabled: Set<CDNHost>, limit: Int = 16) -> [CDNCandidate] {
    var seen = Set<CDNHost>(); var result: [CDNCandidate] = []
    func add(_ host: CDNHost, _ source: CDNCandidateSource, label: String? = nil) {
      guard seen.insert(host).inserted else { return }
      result.append(CDNCandidate(host: host, label: label, source: source, disabled: disabled.contains(host)))
    }
    if let current { add(current, .current) }
    playurl.forEach { add($0, .playurl) }
    custom.forEach { add($0, .custom) }
    builtin.compactMap { item in CDNHost(item.0).map { ($0, item.1) } }.forEach { add($0.0, .builtin, label: $0.1) }
    learned.forEach { add($0, .learned) }
    return Array(result.prefix(limit))
  }

  /// Hosts for the benchmark window: enabled only, current/preferred first, then source priority.
  public static func benchmarkWindow(_ candidates: [CDNCandidate], preferred: CDNHost?, limit: Int = 8) -> [CDNCandidate] {
    let priority: [CDNCandidateSource: Int] = [.current: 0, .playurl: 1, .custom: 2, .builtin: 3, .learned: 4]
    return candidates.enumerated().filter { !$0.element.disabled }
      .sorted { lhs, rhs in
        let left = lhs.element.host == preferred ? -1 : priority[lhs.element.source] ?? 9
        let right = rhs.element.host == preferred ? -1 : priority[rhs.element.source] ?? 9
        return left == right ? lhs.offset < rhs.offset : left < right
      }.prefix(limit).map(\.element)
  }
}

public enum CDNBenchmarkStage: String, Codable, Sendable { case quick, sustained }

public struct CDNBenchmarkResult: Codable, Sendable, Equatable, Identifiable {
  public var id: String { host }
  public let host: String
  public let ok: Bool
  public let stage: CDNBenchmarkStage
  public let status: Int
  public let bytes: Int
  public let ttfbMs: Double
  public let durationMs: Double
  public let error: String?
  public let at: Date
  public var mbps: Double { ok && durationMs > 0 ? Double(bytes) * 8 / durationMs / 1000 : 0 }
  public init(host: String, ok: Bool, stage: CDNBenchmarkStage, status: Int, bytes: Int, ttfbMs: Double,
    durationMs: Double, error: String? = nil, at: Date = Date()) {
    self.host = host; self.ok = ok; self.stage = stage; self.status = status; self.bytes = bytes
    self.ttfbMs = ttfbMs; self.durationMs = durationMs; self.error = error; self.at = at
  }
}

public enum CDNSelection {
  /// Sustained samples outrank quick ones, then throughput, then first-byte latency.
  public static func best(_ results: [CDNBenchmarkResult]) -> CDNBenchmarkResult? {
    results.filter { $0.ok && $0.mbps > 0 && $0.ttfbMs.isFinite }.sorted { lhs, rhs in
      let left = lhs.stage == .sustained ? 2 : 1, right = rhs.stage == .sustained ? 2 : 1
      if left != right { return left > right }
      if lhs.mbps != rhs.mbps { return lhs.mbps > rhs.mbps }
      if lhs.ttfbMs != rhs.ttfbMs { return lhs.ttfbMs < rhs.ttfbMs }
      return lhs.host < rhs.host
    }.first
  }

  /// Keeps the current host unless the best one is at least `improvement` faster (avoids flapping).
  public static func automatic(_ results: [CDNBenchmarkResult], current: String?, improvement: Double = 0.15) -> CDNBenchmarkResult? {
    guard let best = best(results), let current, best.host != current else { return best(results) }
    guard let currentResult = results.first(where: { $0.host == current && $0.ok && $0.mbps > 0 }) else { return best }
    return best.mbps >= currentResult.mbps * (1 + improvement) ? best : currentResult
  }

  /// The next host after a stall: never the current one or the last few stalled hosts.
  public static func recovery(_ results: [CDNBenchmarkResult], current: String?, excluded: [String]) -> CDNBenchmarkResult? {
    let skip = Set(excluded + [current].compactMap { $0 })
    return best(results.filter { !skip.contains($0.host) })
  }

  /// Most recent `limit` stalled hosts, newest last, without duplicates.
  public static func recentStalled(_ hosts: [String], limit: Int = 3) -> [String] {
    var recent: [String] = []
    for host in hosts where !host.isEmpty { recent.removeAll { $0 == host }; recent.append(host) }
    return Array(recent.suffix(max(0, limit)))
  }
}

/// How long an automatic choice stays trusted before the next play re-benchmarks.
public enum CDNRefreshProfile: String, CaseIterable, Sendable, Codable {
  case frequent, balanced, economy
  public var title: String { switch self { case .frequent: "积极"; case .balanced: "平衡"; case .economy: "低频" } }
  public var soft: TimeInterval { switch self { case .frequent: 30 * 60; case .balanced: 90 * 60; case .economy: 6 * 3600 } }
  public var hard: TimeInterval { switch self { case .frequent: 3600; case .balanced: 2 * 3600; case .economy: 12 * 3600 } }
  public enum Age: Equatable, Sendable { case fresh, stale, expired }
  public func age(of date: Date?, now: Date = Date()) -> Age {
    guard let date else { return .expired }
    let age = max(0, now.timeIntervalSince(date))
    return age < soft ? .fresh : age < hard ? .stale : .expired
  }
}

/// One buffer sample from the player, taken about once a second.
public struct PlaybackHealthSample: Sendable, Equatable {
  public let at: TimeInterval
  public let position: Double
  public let bufferedAhead: Double
  public let playing: Bool
  public let seeking: Bool
  public init(at: TimeInterval, position: Double, bufferedAhead: Double, playing: Bool, seeking: Bool = false) {
    self.at = at; self.position = position; self.bufferedAhead = bufferedAhead; self.playing = playing; self.seeking = seeking
  }
}

public enum PlaybackHealth {
  public struct Policy: Sendable {
    public var lowBuffer = 8.0, minimumBuffered = 0.5, minimumDrain = 6.0
    public var minimumWindow = 8.0, maximumWindow = 16.0, minimumAdvance = 6.0
    public var maximumRate = 3.0, minimumSamples = 5, decliningSamples = 5, maximumRebound = 0.5
    public init() {}
  }

  /// True when the forward buffer has been draining steadily while playback advances,
  /// so a better node can be tried before the player actually stalls.
  public static func shouldPreemptivelyRecover(_ samples: [PlaybackHealthSample], policy: Policy = Policy()) -> Bool {
    guard samples.count >= policy.minimumSamples, let current = samples.last, valid(current),
      current.bufferedAhead > policy.minimumBuffered, current.bufferedAhead <= policy.lowBuffer else { return false }
    let recent = samples.filter { valid($0) && $0.at <= current.at && current.at - $0.at <= policy.maximumWindow }
    guard recent.count >= policy.minimumSamples else { return false }
    let baselines = recent.filter { current.at - $0.at >= policy.minimumWindow }
    guard let baseline = baselines.max(by: { $0.bufferedAhead < $1.bufferedAhead }) else { return false }
    let window = recent.filter { $0.at >= baseline.at }
    for (previous, sample) in zip(window, window.dropFirst()) where sample.position + 0.5 < previous.position { return false }
    let declining = Array(recent.suffix(policy.decliningSamples))
    guard declining.count >= policy.decliningSamples else { return false }
    for (previous, sample) in zip(declining, declining.dropFirst()) where sample.bufferedAhead > previous.bufferedAhead + policy.maximumRebound {
      return false
    }
    let elapsed = current.at - baseline.at
    let advance = current.position - baseline.position
    let drain = baseline.bufferedAhead - current.bufferedAhead
    return elapsed > 0 && advance >= policy.minimumAdvance && advance <= elapsed * policy.maximumRate + 2
      && drain >= policy.minimumDrain
  }

  /// Seconds to wait before another recovery: 15 s on the same host, 7 s after any switch.
  public static func cooldownRemaining(now: TimeInterval, lastAt: TimeInterval?, currentHost: String?, lastHost: String?,
    sameHostCooldown: TimeInterval = 15, minimumInterval: TimeInterval = 7) -> TimeInterval {
    guard let lastAt, let currentHost, !currentHost.isEmpty else { return 0 }
    let elapsed = now - lastAt
    let same = currentHost == lastHost ? max(sameHostCooldown - elapsed, 0) : 0
    return max(same, max(minimumInterval - elapsed, 0))
  }

  private static func valid(_ sample: PlaybackHealthSample) -> Bool {
    sample.at.isFinite && sample.position.isFinite && sample.bufferedAhead.isFinite && sample.playing && !sample.seeking
  }
}

/// Demuxer cache sizing from the stream bitrate: enough bytes to hold the read-ahead target,
/// never below the user's own floor and never above a memory ceiling.
public enum SmartCachePolicy {
  public struct Plan: Equatable, Sendable {
    public let forwardBytes: Int
    public let backBytes: Int
    public let readaheadSeconds: Double
    public let pauseWaitSeconds: Double
  }
  /// - Parameters:
  ///   - bitsPerSecond: combined video+audio bandwidth from the manifest.
  ///   - recentStalls: stalls in the last few minutes; more stalls → deeper buffer and longer refill before resuming.
  public static func plan(bitsPerSecond: Int, userForwardMB: Double, userBackMB: Double, userSeconds: Double,
    recentStalls: Int, ceilingMB: Double = 1536) -> Plan {
    let bytesPerSecond = max(Double(bitsPerSecond) / 8, 250_000)
    // The plan owns the read-ahead while smart cache is on: the user's seconds setting (300 s by
    // default) held a whole 4K episode in memory (about 1.4 GB measured) for no benefit on a
    // healthy network. Two minutes is ample; recent stalls deepen it to three.
    _ = userSeconds
    let target: Double = recentStalls > 0 ? 180 : 120
    let needed = bytesPerSecond * target * 1.15
    let forward = min(max(needed, userForwardMB * 1_048_576), ceilingMB * 1_048_576)
    let back = max(userBackMB * 1_048_576, min(bytesPerSecond * 30, 256 * 1_048_576))
    let wait = recentStalls >= 3 ? 5.0 : recentStalls >= 1 ? 3.0 : 1.0
    return Plan(forwardBytes: Int(forward), backBytes: Int(back), readaheadSeconds: target, pauseWaitSeconds: wait)
  }
}
