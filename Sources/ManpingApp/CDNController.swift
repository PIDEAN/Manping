import ManpingCore
import Foundation
import Network

/// Chooses CDN nodes for playback, feeds mpv through the multi-node relay, watches buffer
/// health and recovers from stalls. Owned by `AppModel`; ordinary videos and PGC both route
/// their streams through `prepare` and `attach`.
/// Feeds proxied fetch outcomes into the proxy's health, so HTTP and SOCKS proxies get the same
/// "temporarily down" signal as the built-in tunnel.
struct ProxyHealthFetcher: CDNRangeFetching {
  let base: CDNRangeFetching
  let runtime: ProxyRuntime
  func fetch(_ url: URL, range: ClosedRange<Int>, timeout: TimeInterval) async -> CDNFetchOutcome {
    let outcome = await base.fetch(url, range: range, timeout: timeout)
    if outcome.ok { runtime.noteSuccess() }
    // A transport failure (no HTTP status) is the proxy's fault; an HTTP error is the node's.
    else if outcome.status == 0, outcome.error != "已取消" { runtime.noteFailure() }
    return outcome
  }
}

@MainActor final class CDNController: ObservableObject {
  struct Event: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let text: String
  }

  struct Settings: Equatable {
    var auto = true, multiSource = true, stallRecovery = true, smartCache = true, adaptiveQuality = true
    var profile = CDNRefreshProfile.balanced
    var userForwardMB = 300.0, userBackMB = 0.0, userSeconds = 300.0
    init() {}
    init(_ settings: MacSettings) {
      auto = settings.bool(.cdnAuto); multiSource = settings.bool(.cdnMultiSource)
      stallRecovery = settings.bool(.cdnStallRecovery); smartCache = settings.bool(.smartCache)
      adaptiveQuality = settings.bool(.adaptiveQuality)
      profile = CDNRefreshProfile(rawValue: settings.text(.cdnRefresh)) ?? .balanced
      userForwardMB = settings.number(.cacheMB); userBackMB = settings.number(.backCacheMB)
      userSeconds = settings.number(.cacheSeconds)
    }
  }

  /// What the player is currently playing, kept so recovery can rebuild URLs.
  private struct Session {
    weak var player: PlayerModel?
    let video: MediaStream
    let audio: MediaStream?
    let sample: URL?
    let issuedVideo: [URL]
    let issuedAudio: [URL]
    let bitsPerSecond: Int
    let reload: (URL, URL?) -> Void
    let downgrade: () -> Bool
    var relayed: Bool
    var urls: [URL] = []
    var startedAt = Date()
  }

  /// URLs to load plus the ticket `attach` must present. Only the newest prepare gets one.
  struct Prepared {
    let video: URL
    let audio: URL?
    let ticket: Int
  }

  @Published private(set) var settings = Settings()
  @Published private(set) var manualHost: String?
  @Published private(set) var candidates: [CDNCandidate] = []
  @Published private(set) var results: [CDNBenchmarkResult] = []
  @Published private(set) var resultsAt: Date?
  var probing: Bool { activeProbes > 0 }
  @Published private var activeProbes = 0
  @Published private(set) var activeHost: String?
  @Published private(set) var poolHosts: [String] = []
  /// Route keys (`host@proxy`) fetched through the proxy next to the direct pool.
  @Published private(set) var proxiedPoolHosts: [String] = []
  /// Proxied fetching is on for this session (always in `.concurrent`, after a stall in `.onStall`).
  @Published private(set) var proxyActive = false
  @Published private(set) var proxyStatus = "未配置"
  @Published private(set) var mediaRoute = MediaRoute.off
  @Published private(set) var snapshot = RelaySnapshot.empty
  @Published private(set) var events: [Event] = []
  @Published private(set) var bufferAhead: Double = 0
  @Published private(set) var stalls = 0
  @Published private(set) var cachePlan: SmartCachePolicy.Plan?

  let store: CDNStore
  private let fetcher = CDNURLSessionFetcher()
  private let relay: MediaRelay
  private let prober: CDNProber
  private var relayReady = false
  private var session: Session?
  private var monitor: Timer?
  private var samples: [PlaybackHealthSample] = []
  private var stalledSince: Date?
  private var lastSeekAt = Date.distantPast
  private var lastRecovery: (at: Date, host: String)?
  private var recentStalled: [String] = []
  private var stallTimes: [Date] = []
  private var lastDowngrade = Date.distantPast
  private var lastPlaybackTime = 0.0
  /// Set after a single relay node stalled: the pool takes every usable node for this session.
  private var widenPool = false
  private var backgroundProbe: Task<Void, Never>?
  private var proxyProbe: Task<Void, Never>?
  private var proxy: ProxyRuntime?
  private var proxyFetcher: CDNRangeFetching?
  private var proxyProber: CDNProber?
  private var proxyRevision = -1
  /// Proxied routes used until the proxied benchmark has results: the direct pool's best nodes.
  private var provisionalProxied: [CDNHost] = []
  private var lastProxyUsable = false
  /// Consecutive proxied benchmarks with no usable node; drives the retry backoff.
  private var proxyProbeFailures = 0
  private var networkKey = "unknown"
  /// Bumped when the network changes; a benchmark that started on the old network is discarded.
  private var networkEpoch = 0
  /// Each prepare gets a number; a superseded prepare must not overwrite the newer session.
  private var generation = 0
  private var pendingGeneration = -1
  private let pathMonitor = NWPathMonitor()
  private static let poolSize = 4

  init(defaults: UserDefaults = PerformanceEnvironment.defaults) {
    store = CDNStore(defaults: defaults)
    settings = Settings(MacSettings.load(from: defaults))
    relay = MediaRelay(fetcher: fetcher)
    prober = CDNProber(fetcher: fetcher)
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let key = path.availableInterfaces.map { "\($0.type)" }.joined(separator: "+") + (path.isExpensive ? "/metered" : "")
      Task { @MainActor [weak self] in self?.networkChanged(key, satisfied: path.status == .satisfied) }
    }
    pathMonitor.start(queue: DispatchQueue(label: "io.github.pidean.manping.cdn.path"))
  }

  /// `force` re-applies the cache plan after the app re-wrote the user's cache options.
  func apply(_ macSettings: MacSettings, force: Bool = false) {
    let next = Settings(macSettings)
    if force, let player = session?.player { cachePlan = nil; settings = next; applyCache(to: player); return }
    guard next != settings else { return }
    let multiChanged = next.multiSource != settings.multiSource
    settings = next
    if multiChanged, session != nil { log(next.multiSource ? "已开启多节点同时缓冲，下一次加载生效" : "已关闭多节点同时缓冲，下一次加载生效") }
    if let player = session?.player { applyCache(to: player) }
  }

  // MARK: Preparing a stream

  /// Returns the URLs mpv should load for this video/audio pair. With multi-source buffering
  /// they point at the loopback relay; otherwise at the single best node.
  /// `allowProbe: false` (quality changes) reuses existing results instead of waiting for a benchmark.
  /// Streams of the previous load stay registered until `attach`, so the old picture keeps
  /// playing while the new one starts.
  /// Returns nil when a newer prepare (or `detach`) superseded this one: the caller must not load.
  func prepare(video: MediaStream, audio: MediaStream?, avoidP2P: Bool, allowProbe: Bool = true) async -> Prepared? {
    generation += 1
    let current = generation
    backgroundProbe?.cancel(); backgroundProbe = nil
    proxyProbe?.cancel(); proxyProbe = nil
    proxyActive = mediaRoute == .concurrent && proxyUsable
    lastProxyUsable = proxyUsable
    provisionalProxied = []
    let issuedVideo = Self.issued(video, avoidP2P: avoidP2P)
    let issuedAudio = audio.map { Self.issued($0, avoidP2P: avoidP2P) } ?? []
    let sample = issuedVideo.first(where: CDNCatalog.isSwappable)
    let observed = sample?.host.flatMap(CDNHost.init)
    let issuedHosts = (issuedVideo + issuedAudio).compactMap { $0.host.flatMap(CDNHost.init) }
    candidates = CDNCatalog.candidates(current: observed, playurl: issuedHosts, custom: store.custom,
      learned: store.learned(), disabled: store.disabled)
    relay.setDisabled(Set(store.disabled.map(\.name)))

    if allowProbe, settings.auto || manualHost != nil, sample != nil || issuedVideo.count > 1 {
      // The relay recovers from a dead node by itself, so it waits less; the fastest nodes
      // answer first, so even a partial quick round names the right pool.
      await ensureResults(sample: sample, issued: issuedVideo, budgetSeconds: settings.multiSource ? 1.5 : 3.5,
        generation: current)
    } else if results.isEmpty, let cached = store.results(network: networkKey) {
      results = cached.results; resultsAt = cached.at
    }
    // A newer prepare started while this one waited: touch nothing.
    guard current == generation else { return nil }
    let pool = currentPool(issued: issuedVideo, bitsPerSecond: video.bandwidth + (audio?.bandwidth ?? 0))
    poolHosts = pool.map(\.name)
    activeHost = manualHost ?? bestKey(issued: issuedVideo) ?? issuedVideo.first?.host

    if settings.multiSource, await startRelay() {
      guard current == generation else { return nil }
      relay.setHosts(pool, seedMbps: Dictionary(results.filter(\.ok).map { ($0.host, $0.mbps) }, uniquingKeysWith: max))
      if proxyActive {
        provisionalProxied = Array(pool.prefix(2))
        let proxied = proxiedPool()
        relay.setProxiedHosts(proxied.hosts, issued: !proxied.issuedKeys.isEmpty, seedMbps: seed())
        proxiedPoolHosts = proxied.routeKeys
        startProxyProbe(sample: sample, issued: issuedVideo, reason: "代理测速完成")
      } else {
        relay.setProxiedHosts([]); proxiedPoolHosts = []
      }
      relay.markUnreachable(results.filter { !$0.ok }.map(\.host))
      if let videoURL = relay.register(issuedVideo[0], backups: Array(issuedVideo.dropFirst())) {
        let audioURL = issuedAudio.first.flatMap { relay.register($0, backups: Array(issuedAudio.dropFirst())) }
        session = Session(player: nil, video: video, audio: audio, sample: sample, issuedVideo: issuedVideo,
          issuedAudio: issuedAudio, bitsPerSecond: video.bandwidth + (audio?.bandwidth ?? 0), reload: { _, _ in },
          downgrade: { false }, relayed: true, urls: [videoURL] + (audioURL.map { [$0] } ?? []))
        pendingGeneration = current
        log("多节点缓冲：\(pool.isEmpty ? "使用接口签发节点" : pool.map { CDNCatalog.label(for: $0) }.joined(separator: "、"))")
        return Prepared(video: videoURL, audio: issuedAudio.isEmpty ? nil : audioURL, ticket: current)
      }
    }
    let direct = directURLs(issuedVideo: issuedVideo, issuedAudio: issuedAudio, sample: sample)
    session = Session(player: nil, video: video, audio: audio, sample: sample, issuedVideo: issuedVideo,
      issuedAudio: issuedAudio, bitsPerSecond: video.bandwidth + (audio?.bandwidth ?? 0), reload: { _, _ in },
      downgrade: { false }, relayed: false)
    pendingGeneration = current
    if let host = direct.video.host { log("单节点播放：\(CDNHost(host).map(CDNCatalog.label(for:)) ?? host)") }
    return Prepared(video: direct.video, audio: direct.audio, ticket: current)
  }

  /// Starts health monitoring for the player that just loaded the prepared URLs.
  func attach(player: PlayerModel, ticket: Int, reload: @escaping (URL, URL?) -> Void, downgrade: @escaping () -> Bool) {
    // Only the newest prepare may attach; a stale one would bind the wrong URLs to this player.
    guard let previous = session, ticket == generation, pendingGeneration == ticket else { return }
    pendingGeneration = -1
    relay.unregister(keeping: previous.urls)
    session = Session(player: player, video: previous.video, audio: previous.audio, sample: previous.sample,
      issuedVideo: previous.issuedVideo, issuedAudio: previous.issuedAudio, bitsPerSecond: previous.bitsPerSecond,
      reload: reload, downgrade: downgrade, relayed: previous.relayed, urls: previous.urls)
    cachePlan = nil
    samples = []; stalledSince = nil; recentStalled = []; lastPlaybackTime = 0; stalls = 0; stallTimes = []
    widenPool = false
    applyCache(to: player)
    monitor?.invalidate()
    monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    // A stale result keeps the cached choice now and refreshes in the background.
    if settings.auto, manualHost == nil, let resultsAt, settings.profile.age(of: resultsAt) != .fresh {
      refreshInBackground(reason: "结果已过期，后台重新测速")
    }
  }

  func detach() {
    generation += 1
    monitor?.invalidate(); monitor = nil
    backgroundProbe?.cancel(); backgroundProbe = nil
    proxyProbe?.cancel(); proxyProbe = nil
    session = nil
    relay.unregisterAll()
    snapshot = .empty
  }

  func noteSeek() { lastSeekAt = Date(); samples = []; stalledSince = nil }

  // MARK: Manual control

  /// `nil` returns to automatic selection.
  func select(host: String?) {
    manualHost = host
    log(host.map { "手动选择节点：\(CDNHost($0).map(CDNCatalog.label(for:)) ?? $0)" } ?? "恢复自动优选")
    guard let session else { return }
    let pool = currentPool(issued: session.issuedVideo, bitsPerSecond: session.bitsPerSecond)
    poolHosts = pool.map(\.name)
    activeHost = host ?? bestKey(issued: session.issuedVideo)
    if session.relayed {
      relay.setHosts(pool, seedMbps: seed())
    } else {
      reloadDirect(session)
    }
  }

  func reprobe() {
    guard let session else {
      store.clearResults(); results = []; resultsAt = nil
      log("已清除测速结果，下次播放时重新测速")
      return
    }
    backgroundProbe?.cancel()
    let current = generation
    backgroundProbe = Task { [weak self] in
      guard let self else { return }
      await self.benchmark(sample: session.sample, issued: session.issuedVideo, quickOnly: false)
      guard !Task.isCancelled, self.generation == current else { return }
      self.applyPool(reason: "重新测速完成")
      self.backgroundProbe = nil
    }
  }

  func setDisabled(_ host: String, _ disabled: Bool) {
    guard let value = CDNHost(host) else { return }
    store.setDisabled(value, disabled)
    relay.setDisabled(Set(store.disabled.map(\.name)))
    candidates = candidates.map { CDNCandidate(host: $0.host, label: $0.label, source: $0.source,
      disabled: $0.host == value ? disabled : $0.disabled) }
    if disabled, manualHost == host { manualHost = nil }
    applyPool(reason: disabled ? "已停用 \(CDNCatalog.label(for: value))" : "已启用 \(CDNCatalog.label(for: value))")
  }

  @discardableResult func addCustom(_ text: String) -> Bool {
    guard let host = CDNHost(text) else { return false }
    store.addCustom(host)
    if !candidates.contains(where: { $0.host == host }) {
      candidates.append(CDNCandidate(host: host, source: .custom))
    }
    log("已添加自定义节点 \(host.name)，重新测速后参与选择")
    return true
  }

  func removeCustom(_ host: String) {
    guard let value = CDNHost(host) else { return }
    store.removeCustom(value)
    candidates.removeAll { $0.host == value && $0.source == .custom }
  }

  // MARK: Benchmarking

  /// Uses cached results when they are still within the refresh profile (stale ones refresh in
  /// the background after playback starts); otherwise runs the quick round within `budgetSeconds`.
  /// Quick results are published host by host, so a deadline that cuts the round short still
  /// leaves the fastest nodes (which answer first) available for the pool.
  private func ensureResults(sample: URL?, issued: [URL], budgetSeconds: TimeInterval, generation current: Int) async {
    if let cached = store.results(network: networkKey), settings.profile.age(of: cached.at) != .expired {
      results = cached.results; resultsAt = cached.at
      return
    }
    let quickDone = Flag()
    // One task owns both stages, so cancelling `backgroundProbe` stops the whole round.
    backgroundProbe = Task { [weak self] in
      await self?.benchmark(sample: sample, issued: issued, quickOnly: true)
      quickDone.value = true
      guard let self, !Task.isCancelled else { return }
      // Finish the sustained stage in the background and re-weight the pool.
      await self.benchmark(sample: sample, issued: issued, quickOnly: false, finalistsOnly: true)
      guard !Task.isCancelled, self.generation == current else { return }
      self.applyPool(reason: "持续传输复测完成")
      self.backgroundProbe = nil
    }
    let deadline = Date().addingTimeInterval(budgetSeconds)
    while !quickDone.value, Date() < deadline, generation == current, !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    if !quickDone.value, generation == current {
      log("测速未在 \(String(format: "%.1f", budgetSeconds)) 秒内完成，先用已返回的节点开始播放")
    }
  }

  private func benchmark(sample: URL?, issued: [URL], quickOnly: Bool, finalistsOnly: Bool = false) async {
    let window = CDNCatalog.benchmarkWindow(candidates, preferred: manualHost.flatMap(CDNHost.init))
    let targets = sample.map { CDNProber.targets(sample: $0, hosts: window.map(\.host), issued: issued) }
      ?? CDNProber.targets(sample: issued[0], hosts: [], issued: issued)
    guard !targets.isEmpty else { return }
    // Results belong to the network they were measured on; a change mid-round discards them.
    let epoch = networkEpoch, network = networkKey
    activeProbes += 1
    defer { activeProbes -= 1 }
    let publish: @Sendable (CDNBenchmarkResult) async -> Void = { [weak self] result in
      await MainActor.run { [weak self] in
        guard let self, !Task.isCancelled, self.networkEpoch == epoch else { return }
        self.merge([result])
      }
    }
    let round: [CDNBenchmarkResult]
    if finalistsOnly {
      let finals = Set(results.filter(\.ok).sorted { $0.mbps > $1.mbps }.prefix(prober.finalists).map(\.host))
      let picked = targets.filter { finals.contains($0.key) }
      guard !picked.isEmpty else { return }
      round = await prober.sustained(picked)
    } else {
      round = quickOnly ? await prober.quick(targets, onResult: publish) : await prober.benchmark(targets)
    }
    guard !Task.isCancelled, networkEpoch == epoch else { return }
    merge(round)
    // Proxied measurements depend on the proxy, not on this network: keep them out of the store.
    store.saveResults(results.filter { !MediaRelay.isProxyKey($0.host) }, network: network)
    let ok = round.filter(\.ok).count
    log("测速完成：\(ok)/\(round.count) 个节点可用" + (CDNSelection.best(round).map { "，最快 \(label($0.host)) \(String(format: "%.1f", $0.mbps)) Mbps" } ?? ""))
  }

  private func merge(_ round: [CDNBenchmarkResult]) {
    var merged = Dictionary(results.map { ($0.host, $0) }, uniquingKeysWith: { $1 })
    for result in round {
      // A sustained success outranks an older quick sample; failures replace stale successes.
      if let existing = merged[result.host], existing.stage == .sustained, result.stage == .quick, result.ok { continue }
      merged[result.host] = result
    }
    let next = merged.values.sorted { ($0.ok ? 0 : 1, -$0.mbps, $0.host) < ($1.ok ? 0 : 1, -$1.mbps, $1.host) }
    if next != results { results = next }
    resultsAt = Date()
  }

  private func refreshInBackground(reason: String) {
    guard let session, backgroundProbe == nil || backgroundProbe?.isCancelled == true else { return }
    log(reason)
    let current = generation
    backgroundProbe = Task { [weak self] in
      guard let self else { return }
      await self.benchmark(sample: session.sample, issued: session.issuedVideo, quickOnly: false)
      guard !Task.isCancelled, self.generation == current else { return }
      self.applyPool(reason: "后台测速完成")
      self.backgroundProbe = nil
    }
  }

  // MARK: Pool

  /// Hosts the relay should use: the manual choice, or the fastest successful nodes that
  /// are not disabled or recently stalled.
  /// Hosts the relay should use: the manual choice, or the fastest successful nodes that
  /// are not disabled or recently stalled. `bitsPerSecond` is the stream's bitrate: when the
  /// fast nodes together cannot carry it (8K, slow network), slower nodes join the pool.
  private func currentPool(issued: [URL], bitsPerSecond: Int = 0) -> [CDNHost] {
    if let manualHost, let host = CDNHost(manualHost) { return [host] }
    guard settings.auto else { return [] }
    let disabled = store.disabled
    let stalled = Set(recentStalled)
    let speed = Dictionary(results.filter(\.ok).map { ($0.host, $0.mbps) }, uniquingKeysWith: max)
    let ranked = results.filter { $0.ok && $0.mbps > 0 }.sorted { $0.mbps > $1.mbps }
      .compactMap { CDNHost($0.host) }.filter { !disabled.contains($0) }
    let fresh = ranked.filter { !stalled.contains($0.name) }
    let chosen = fresh.isEmpty ? ranked : fresh
    let limit = settings.multiSource ? Self.poolSize : 1
    // Nodes far slower than the best only add latency: keep those within a quarter of it.
    let best = speed[chosen.first?.name ?? ""] ?? 0
    var pool = Array(chosen.filter { (speed[$0.name] ?? 0) >= best * 0.25 }.prefix(limit))
    if pool.isEmpty { pool = Array(chosen.prefix(limit)) }
    // Too little combined bandwidth for the bitrate: add the next fastest usable nodes. With
    // multi-source buffering keep at least two, so a slow chunk always has a measured node to
    // hedge to instead of falling back to the issued URLs.
    let required = widenPool ? .infinity : Double(bitsPerSecond) / 1_000_000 * 1.5
    for host in chosen where pool.count < limit && !pool.contains(host) && (speed[host.name] ?? 0) >= 2 {
      guard pool.count < 2 || pool.reduce(0, { $0 + (speed[$1.name] ?? 0) }) < required else { break }
      pool.append(host)
    }
    return pool
  }

  private func applyPool(reason: String) {
    guard let session else { return }
    let pool = currentPool(issued: session.issuedVideo, bitsPerSecond: session.bitsPerSecond)
    poolHosts = pool.map(\.name)
    let previous = activeHost
    activeHost = manualHost ?? bestKey(issued: session.issuedVideo) ?? previous
    if session.relayed {
      relay.setHosts(pool, seedMbps: seed())
      relay.markUnreachable(results.filter { !$0.ok }.map(\.host))
      let proxied = proxiedPool()
      relay.setProxiedHosts(proxied.hosts, issued: !proxied.issuedKeys.isEmpty, seedMbps: seed())
      proxiedPoolHosts = proxied.routeKeys
      let routes = pool.map { label($0.name) } + proxied.routeKeys.map { label($0) }
      log("\(reason)：节点池 \(routes.joined(separator: "、"))")
    } else if settings.auto, manualHost == nil, let previous, let best = CDNSelection.automatic(results, current: previous),
      best.host != previous {
      log("\(reason)：切换到更快的 \(label(best.host))")
      reloadDirect(session)
    }
  }

  #if DEBUG
  /// Debug playback reports: runs the stall-recovery path as if the player had waited for data.
  func debugSimulateStall() { lastRecovery = nil; recover(reason: "模拟卡顿") }
  #endif

  // MARK: Proxy

  var proxyUsable: Bool { proxyFetcher != nil && proxy?.isAvailable == true }

  /// Installs (or removes) the proxied path. Called at launch and whenever the proxy or its
  /// routing mode changes; a changed proxy invalidates earlier proxied measurements.
  func configureProxy(_ runtime: ProxyRuntime?, media: MediaRoute) {
    proxy = runtime
    mediaRoute = media
    let revision = runtime?.currentRevision ?? -1
    if revision != proxyRevision {
      proxyRevision = revision
      proxyProbe?.cancel(); proxyProbe = nil; proxyProbeFailures = 0
      if let runtime, let configuration = runtime.configuration(.ephemeral) {
        let fetcher = ProxyHealthFetcher(base: CDNURLSessionFetcher(maximumConnectionsPerHost: 4, configuration: configuration),
          runtime: runtime)
        proxyFetcher = fetcher
        proxyProber = CDNProber(fetcher: fetcher)
      } else {
        proxyFetcher = nil; proxyProber = nil
      }
      relay.setProxyFetcher(proxyFetcher)
      let stale = results.filter { MediaRelay.isProxyKey($0.host) }
      if !stale.isEmpty { results.removeAll { MediaRelay.isProxyKey($0.host) } }
    }
    proxyStatus = runtime?.status.message ?? "未配置"
    if media == .off || !proxyUsable { proxyActive = false }
    else if media == .concurrent, !proxyActive, let session, session.relayed {
      proxyActive = true; lastProxyUsable = true
      provisionalProxied = Array(poolHosts.compactMap(CDNHost.init).prefix(2))
      startProxyProbe(sample: session.sample, issued: session.issuedVideo, reason: "代理测速完成")
    }
    if session != nil { applyPool(reason: "代理设置已更新") }
  }

  /// Proxied routes: the fastest proxied measurements (or, before any, the direct pool's best),
  /// plus issued hosts outside the swappable catalog that answered through the proxy.
  private func proxiedPool() -> MediaProxyPolicy.Routes {
    guard proxyActive, proxyUsable, settings.multiSource else { return .none }
    return MediaProxyPolicy.routes(results, provisional: provisionalProxied, disabled: store.disabled)
  }

  /// Quick benchmark of the leading nodes through the proxy, merged next to the direct results.
  private func startProxyProbe(sample: URL?, issued: [URL], reason: String) {
    guard let prober = proxyProber, proxyUsable, !issued.isEmpty else { return }
    proxyProbe?.cancel()
    let current = generation, epoch = networkEpoch, revision = proxyRevision
    let window = CDNCatalog.benchmarkWindow(candidates, preferred: nil).prefix(5)
    let base = sample.map { CDNProber.targets(sample: $0, hosts: window.map(\.host), issued: Array(issued.prefix(1))) }
      ?? CDNProber.targets(sample: issued[0], hosts: [], issued: Array(issued.prefix(1)))
    let targets = base.map { CDNProber.Target(key: MediaRelay.proxyKey($0.key), url: $0.url) }
    guard !targets.isEmpty else { return }
    activeProbes += 1
    proxyProbe = Task { [weak self] in
      let round = await prober.quick(targets)
      guard let self else { return }
      self.activeProbes -= 1
      guard !Task.isCancelled, self.generation == current, self.networkEpoch == epoch, self.proxyRevision == revision else { return }
      self.merge(round)
      let ok = round.filter(\.ok)
      self.log("代理测速：\(ok.count)/\(round.count) 个节点可用" + (CDNSelection.best(ok).map { "，最快 \(self.label($0.host)) \(String(format: "%.1f", $0.mbps)) Mbps" } ?? ""))
      self.applyPool(reason: reason)
      self.proxyProbe = nil
      guard ok.isEmpty else { self.proxyProbeFailures = 0; return }
      // Every proxied node failed while the proxy itself still counts as healthy, so no health
      // flip will ever re-plan it: retry with backoff (15 s, 30 s, 60 s, then every 2 min).
      // A new session, generation, network or proxy configuration cancels or ignores the retry.
      self.proxyProbeFailures += 1
      let delay = min(120, 15 * Double(1 << min(self.proxyProbeFailures - 1, 3)))
      self.proxyProbe = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard let self, !Task.isCancelled, self.generation == current, self.networkEpoch == epoch,
          self.proxyRevision == revision, self.proxyActive, self.proxyUsable, let session = self.session, session.relayed
        else { return }
        self.results.removeAll { MediaRelay.isProxyKey($0.host) && !$0.ok }
        self.startProxyProbe(sample: session.sample, issued: session.issuedVideo, reason: "代理重新测速完成")
      }
    }
  }

  private func seed() -> [String: Double] {
    Dictionary(results.filter(\.ok).map { ($0.host, $0.mbps) }, uniquingKeysWith: max)
  }

  private func bestKey(issued: [URL]) -> String? {
    if let manualHost { return manualHost }
    return CDNSelection.best(results.filter { result in
      !MediaRelay.isProxyKey(result.host) && !store.disabled.contains(where: { $0.name == result.host })
        && !recentStalled.contains(result.host)
    })?.host
  }

  // MARK: Direct (single-node) mode

  private func directURLs(issuedVideo: [URL], issuedAudio: [URL], sample: URL?) -> (video: URL, audio: URL?) {
    let disabled = Set(store.disabled.map(\.name))
    func fallback(_ issued: [URL]) -> URL? {
      issued.first { !disabled.contains($0.host?.lowercased() ?? "") } ?? issued.first
    }
    guard let key = manualHost ?? bestKey(issued: issuedVideo) else {
      return (fallback(issuedVideo) ?? issuedVideo[0], fallback(issuedAudio))
    }
    func resolve(_ issued: [URL]) -> URL? {
      if let match = issued.first(where: { $0.host?.lowercased() == key }) { return match }
      if let host = CDNHost(key), let template = issued.first(where: CDNCatalog.isSwappable) {
        return CDNCatalog.replacingHost(template, with: host)
      }
      return fallback(issued)
    }
    return (resolve(issuedVideo) ?? issuedVideo[0], resolve(issuedAudio))
  }

  private func reloadDirect(_ session: Session) {
    let urls = directURLs(issuedVideo: session.issuedVideo, issuedAudio: session.issuedAudio, sample: session.sample)
    activeHost = urls.video.host
    session.reload(urls.video, urls.audio)
  }

  // MARK: Health monitoring

  private func tick() {
    guard let session, let player = session.player else { monitor?.invalidate(); monitor = nil; return }
    let now = Date()
    let ahead = player.bufferedAhead.isFinite ? max(0, player.bufferedAhead) : 0
    if abs(ahead - bufferAhead) >= 0.5 || (ahead == 0) != (bufferAhead == 0) { bufferAhead = ahead }
    if session.relayed {
      let next = relay.snapshot(now: now)
      if next != snapshot { snapshot = next }
      for host in next.hosts where host.totalBytes > 0 { if let value = CDNHost(host.host) { store.learn(value) } }
    }
    // The proxy went down (or came back): re-plan the proxied part of the pool. Checked in every
    // mode, so a proxy that was down when playback started still joins later in `.concurrent`.
    if session.relayed, proxyUsable != lastProxyUsable {
      lastProxyUsable = proxyUsable
      switch MediaProxyPolicy.healthChanged(route: mediaRoute, active: proxyActive, usable: proxyUsable) {
      case .none: break
      case .deactivate: applyPool(reason: "代理暂时不可用，改为仅直连")
      case .activate, .reprobe:
        proxyActive = true
        // Failures measured during the outage say nothing about the proxy now: use the direct
        // pool's best until the new proxied benchmark answers.
        results.removeAll { MediaRelay.isProxyKey($0.host) && !$0.ok }
        if provisionalProxied.isEmpty { provisionalProxied = Array(poolHosts.compactMap(CDNHost.init).prefix(2)) }
        applyPool(reason: "代理已恢复")
        startProxyProbe(sample: session.sample, issued: session.issuedVideo, reason: "代理测速完成")
      }
    }
    // Large jumps in position are seeks: reset the trend window.
    if abs(player.time - lastPlaybackTime) > 4 { noteSeek() }
    lastPlaybackTime = player.time
    let playing = !player.paused && player.duration > 0
    samples.append(PlaybackHealthSample(at: now.timeIntervalSince1970, position: player.time, bufferedAhead: ahead,
      playing: playing && !player.buffering))
    samples = Array(samples.suffix(20))
    guard settings.stallRecovery, playing else { stalledSince = nil; return }
    // Hard stall: waiting for cache for 2.5 s (4.5 s right after a load or seek).
    if player.buffering {
      if stalledSince == nil { stalledSince = now }
      let grace = now.timeIntervalSince(max(lastSeekAt, session.startedAt)) < 6 ? 4.5 : 2.5
      if let since = stalledSince, now.timeIntervalSince(since) >= grace {
        recover(reason: "播放等待缓冲 \(Int(now.timeIntervalSince(since))) 秒")
        stalledSince = now
      }
    } else {
      stalledSince = nil
      if PlaybackHealth.shouldPreemptivelyRecover(samples) {
        recover(reason: "缓冲持续下降，提前换节点")
        samples = []
      }
    }
  }

  private func recover(reason: String) {
    guard let session, let player = session.player else { return }
    let now = Date()
    let current = slowestPoolHost() ?? activeHost ?? ""
    let wait = PlaybackHealth.cooldownRemaining(now: now.timeIntervalSince1970,
      lastAt: lastRecovery?.at.timeIntervalSince1970, currentHost: current, lastHost: lastRecovery?.host)
    guard wait <= 0 else { return }
    lastRecovery = (now, current)
    stalls += 1
    stallTimes = stallTimes.filter { now.timeIntervalSince($0) < 180 } + [now]
    // A single relay node that stalls is usually the only one carrying the stream: widen the
    // pool instead of dropping it.
    let soleNode = session.relayed && poolHosts.count <= 1
    if soleNode { widenPool = true }
    if !current.isEmpty, !soleNode { recentStalled = CDNSelection.recentStalled(recentStalled + [current]); store.recordStall(current) }
    applyCache(to: player)
    if mediaRoute == .onStall, !proxyActive, proxyUsable {
      if session.relayed {
        proxyActive = true; lastProxyUsable = true
        provisionalProxied = Array(poolHosts.compactMap(CDNHost.init).prefix(2))
        log("\(reason)，启用代理并发")
        startProxyProbe(sample: session.sample, issued: session.issuedVideo, reason: "代理测速完成")
      } else {
        log("\(reason)；代理并发需要开启「多节点同时缓冲」")
      }
    }
    if manualHost != nil {
      log("\(reason)；当前为手动节点，不自动切换")
    } else if session.relayed {
      let before = poolHosts
      applyPool(reason: soleNode ? "\(reason)，扩充节点池" : "\(reason)，暂避 \(label(current))")
      if poolHosts.isEmpty || poolHosts == before { refreshInBackground(reason: "可用节点不足，重新测速") }
    } else if let next = CDNSelection.recovery(results, current: activeHost, excluded: recentStalled) {
      log("\(reason)，切换到 \(label(next.host))")
      reloadDirect(session)
    } else {
      log("\(reason)，没有其他已测速节点，回到接口签发节点并重新测速")
      recentStalled = []
      session.reload(session.issuedVideo[0], session.issuedAudio.first)
      refreshInBackground(reason: "重新测速")
    }
    considerDowngrade(session, now: now)
  }

  /// Steps quality down once when stalls keep coming and all nodes together cannot carry the bitrate.
  private func considerDowngrade(_ session: Session, now: Date) {
    guard settings.adaptiveQuality, stallTimes.count >= 3, now.timeIntervalSince(lastDowngrade) > 120 else { return }
    let capacity = session.relayed ? max(snapshot.combinedMbps, snapshot.hosts.reduce(0) { $0 + $1.estimatedMbps } * 0.8)
      : (results.first { $0.host == activeHost }?.mbps ?? 0)
    let required = Double(session.bitsPerSecond) / 1_000_000
    guard capacity > 0, capacity < required * 1.1 else { return }
    if session.downgrade() {
      lastDowngrade = now; stallTimes = []
      log(String(format: "网络约 %.1f Mbps，低于码率 %.1f Mbps，已自动降低一档画质", capacity, required))
    }
  }

  private func slowestPoolHost() -> String? {
    guard session?.relayed == true else { return activeHost }
    let active = snapshot.hosts.filter { poolHosts.contains($0.host) && $0.totalBytes > 0 }
    return active.min { $0.estimatedMbps < $1.estimatedMbps }?.host
  }

  // MARK: Cache

  private func applyCache(to player: PlayerModel) {
    guard settings.smartCache, let session else { cachePlan = nil; return }
    let recent = stallTimes.filter { Date().timeIntervalSince($0) < 300 }.count
    let plan = SmartCachePolicy.plan(bitsPerSecond: max(session.bitsPerSecond, 1_000_000), userForwardMB: settings.userForwardMB,
      userBackMB: settings.userBackMB, userSeconds: settings.userSeconds, recentStalls: recent)
    guard plan != cachePlan else { return }
    cachePlan = plan
    player.set("cache", "yes")
    player.set("demuxer-max-bytes", String(plan.forwardBytes))
    player.set("demuxer-max-back-bytes", String(plan.backBytes))
    player.set("demuxer-readahead-secs", String(Int(plan.readaheadSeconds)))
    player.set("cache-pause-wait", String(plan.pauseWaitSeconds))
  }

  // MARK: Helpers

  private func networkChanged(_ key: String, satisfied: Bool) {
    proxy?.networkChanged(online: satisfied)
    guard key != networkKey else { return }
    let first = networkKey == "unknown"
    networkKey = key
    guard !first else { return }
    log("网络环境变化，测速结果作废")
    networkEpoch += 1
    backgroundProbe?.cancel(); backgroundProbe = nil
    results = []; resultsAt = nil
    if satisfied, session != nil { refreshInBackground(reason: "网络变化后重新测速") }
  }

  private func startRelay() async -> Bool {
    if relayReady { return true }
    do { _ = try await relay.start(); relayReady = true; return true } catch {
      log("本地缓冲中继启动失败，改用单节点直连")
      return false
    }
  }

  private static func issued(_ stream: MediaStream, avoidP2P: Bool) -> [URL] {
    let all = [stream.url] + stream.backupURLs
    let usable = all.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    guard avoidP2P else { return usable.isEmpty ? all : usable }
    let normal = usable.filter { !PlaybackSelector.isP2P($0) }
    return normal.isEmpty ? (usable.isEmpty ? all : usable) : normal
  }

  @MainActor private final class Flag { var value = false }

  func label(_ host: String) -> String {
    if MediaRelay.isProxyKey(host) { return label(MediaRelay.hostName(ofKey: host)) + " · 代理" }
    if let value = CDNHost(host) { return CDNCatalog.label(for: value) }
    if host.hasSuffix(".akamaized.net") { return "Akamai 海外" }
    return host
  }

  private func log(_ text: String) {
    events.append(Event(at: Date(), text: text))
    if events.count > 60 { events.removeFirst(events.count - 60) }
  }
}
