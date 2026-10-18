import Foundation
import XCTest

@testable import ManpingCore

final class CDNTests: XCTestCase {
  private let sample = URL(string: "https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/12/34/567/567-1-100110.m4s?e=ig8euxZM2rNcNbdlhoNvNC8BqJIzNbfqXBvEuENvNC8aNEVEtEvE9IMvXBvE2ENvNCImNEVEIj0Y2J_aug859r1qXg8xNEVE5XREto8GuFGv2U7SuxI72X6fTr859r1qXg8gNEVE5XREto8z5JZC2X2gkX5L5F1eTX1jkXlsTXHeux_f2o859IB_&deadline=1760000000&gen=playurlv3&os=cosovbv&oi=0&platform=pc&upsig=abcdef&uparams=e,deadline&mid=0&bvc=vod&nettype=0&orderid=0,3&buvid=&build=0&f=u_0_0&agrr=1&bw=1000&logo=80000000")!

  func testHostValidationAcceptsOnlyPlainBilivideoNames() {
    XCTAssertEqual(CDNHost(" UPOS-SZ-MIRRORHW.bilivideo.com. ")?.name, "upos-sz-mirrorhw.bilivideo.com")
    XCTAssertNil(CDNHost("https://upos-sz-mirrorhw.bilivideo.com"))
    XCTAssertNil(CDNHost("upos-sz-mirrorhw.bilivideo.com:443"))
    XCTAssertNil(CDNHost("evil.example.com"))
    XCTAssertNil(CDNHost("a..bilivideo.com"))
    XCTAssertNil(CDNHost("bilivideo.com.evil.com"))
  }

  func testHostSwapKeepsSignedPathAndQuery() throws {
    let host = try XCTUnwrap(CDNHost("upos-sz-mirrorhw.bilivideo.com"))
    let swapped = try XCTUnwrap(CDNCatalog.replacingHost(sample, with: host))
    XCTAssertEqual(swapped.host, "upos-sz-mirrorhw.bilivideo.com")
    XCTAssertEqual(swapped.path, sample.path)
    XCTAssertEqual(swapped.query, sample.query)
    XCTAssertEqual(swapped.scheme, "https")
  }

  func testSwappableRejectsPCDNPortsAndForeignHosts() {
    XCTAssertTrue(CDNCatalog.isSwappable(sample))
    XCTAssertFalse(CDNCatalog.isSwappable(URL(string: "https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/1.m4s")!))
    XCTAssertFalse(CDNCatalog.isSwappable(URL(string: "https://upos-sz-mirrorcos.bilivideo.com:8082/upgcxcode/1.m4s")!))
    XCTAssertFalse(CDNCatalog.isSwappable(URL(string: "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/1.m4s")!))
    XCTAssertFalse(CDNCatalog.isSwappable(URL(string: "https://upos-sz-302ppio.bilivideo.com/upgcxcode/1.m4s")!))
    XCTAssertFalse(CDNCatalog.isSwappable(URL(string: "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1.m4s?os=mcdn")!))
    XCTAssertFalse(CDNCatalog.isSwappable(URL(string: "https://upos-sz-mirrorcos.bilivideo.com/index.html")!))
  }

  func testCandidatesOrderDeduplicateAndMarkDisabled() throws {
    let current = try XCTUnwrap(CDNHost("upos-sz-mirrorcosov.bilivideo.com"))
    let custom = try XCTUnwrap(CDNHost("upos-sz-mirrorhw.bilivideo.com"))
    let learned = try XCTUnwrap(CDNHost("upos-sz-estgoss.bilivideo.com"))
    let list = CDNCatalog.candidates(current: current, playurl: [current], custom: [custom], learned: [learned],
      disabled: [custom])
    XCTAssertEqual(list.first?.host, current)
    XCTAssertEqual(list.first?.source, .current)
    XCTAssertEqual(list[1].host, custom)
    XCTAssertTrue(list[1].disabled)
    XCTAssertEqual(list.filter { $0.host == custom }.count, 1, "custom host also in builtin list stays unique")
    XCTAssertEqual(list.last?.host, learned)
    let window = CDNCatalog.benchmarkWindow(list, preferred: learned, limit: 3)
    XCTAssertEqual(window.first?.host, learned, "preferred host is benchmarked first")
    XCTAssertFalse(window.contains { $0.disabled })
    XCTAssertEqual(window.count, 3)
  }

  private func result(_ host: String, _ mbps: Double, stage: CDNBenchmarkStage = .sustained, ok: Bool = true, ttfb: Double = 100) -> CDNBenchmarkResult {
    // mbps = bytes * 8 / ms / 1000 → bytes = mbps * ms * 125 with 1000 ms duration.
    CDNBenchmarkResult(host: host, ok: ok, stage: stage, status: ok ? 206 : 403, bytes: Int(mbps * 125_000), ttfbMs: ttfb, durationMs: 1000)
  }

  func testSelectionPrefersSustainedThenSpeedAndAvoidsFlapping() {
    let results = [result("a", 50, stage: .quick), result("b", 20), result("c", 18), result("d", 99, ok: false)]
    XCTAssertEqual(CDNSelection.best(results)?.host, "b", "sustained samples outrank faster quick ones")
    XCTAssertEqual(CDNSelection.automatic(results, current: "c")?.host, "c", "b is only 11% faster: keep c")
    XCTAssertEqual(CDNSelection.automatic([result("b", 24), result("c", 18)], current: "c")?.host, "b")
    XCTAssertEqual(CDNSelection.recovery(results, current: "b", excluded: ["c"])?.host, "a")
    XCTAssertNil(CDNSelection.recovery([result("b", 20)], current: "b", excluded: []))
    XCTAssertEqual(CDNSelection.recentStalled(["a", "b", "a", "c", "d"], limit: 3), ["a", "c", "d"])
  }

  func testRefreshProfileAges() {
    let now = Date()
    XCTAssertEqual(CDNRefreshProfile.balanced.age(of: now.addingTimeInterval(-60), now: now), .fresh)
    XCTAssertEqual(CDNRefreshProfile.balanced.age(of: now.addingTimeInterval(-100 * 60), now: now), .stale)
    XCTAssertEqual(CDNRefreshProfile.balanced.age(of: now.addingTimeInterval(-3 * 3600), now: now), .expired)
    XCTAssertEqual(CDNRefreshProfile.frequent.age(of: nil, now: now), .expired)
  }

  func testPreemptiveRecoveryNeedsSteadyDrain() {
    // Buffer drains 1 s per second while playback advances 1 s per second.
    let draining = (0..<12).map { second in
      PlaybackHealthSample(at: Double(second), position: Double(second), bufferedAhead: 16 - Double(second) * 1.0, playing: true)
    }
    XCTAssertTrue(PlaybackHealth.shouldPreemptivelyRecover(Array(draining.prefix(11))))
    // A rebound in the last samples means data is arriving again.
    var rebound = Array(draining.prefix(11))
    rebound[9] = PlaybackHealthSample(at: 9, position: 9, bufferedAhead: 9, playing: true)
    XCTAssertFalse(PlaybackHealth.shouldPreemptivelyRecover(rebound))
    // Healthy buffer above the low-water mark.
    let healthy = (0..<12).map { PlaybackHealthSample(at: Double($0), position: Double($0), bufferedAhead: 30, playing: true) }
    XCTAssertFalse(PlaybackHealth.shouldPreemptivelyRecover(healthy))
    // A backwards seek invalidates the window.
    var seek = Array(draining.prefix(11))
    seek[6] = PlaybackHealthSample(at: 6, position: 1, bufferedAhead: 10, playing: true)
    XCTAssertFalse(PlaybackHealth.shouldPreemptivelyRecover(seek))
  }

  func testRecoveryCooldown() {
    XCTAssertEqual(PlaybackHealth.cooldownRemaining(now: 100, lastAt: 95, currentHost: "a", lastHost: "a"), 10)
    XCTAssertEqual(PlaybackHealth.cooldownRemaining(now: 100, lastAt: 95, currentHost: "b", lastHost: "a"), 2)
    XCTAssertEqual(PlaybackHealth.cooldownRemaining(now: 100, lastAt: 80, currentHost: "a", lastHost: "a"), 0)
    XCTAssertEqual(PlaybackHealth.cooldownRemaining(now: 100, lastAt: nil, currentHost: "a", lastHost: nil), 0)
  }

  func testSmartCacheScalesWithBitrateAndStalls() {
    let calm = SmartCachePolicy.plan(bitsPerSecond: 40_000_000, userForwardMB: 300, userBackMB: 0, userSeconds: 60, recentStalls: 0)
    XCTAssertEqual(calm.readaheadSeconds, 120)
    XCTAssertGreaterThan(calm.forwardBytes, 300 * 1_048_576, "4K bitrate needs more than the 300 MB floor")
    XCTAssertEqual(calm.pauseWaitSeconds, 1)
    let rough = SmartCachePolicy.plan(bitsPerSecond: 40_000_000, userForwardMB: 300, userBackMB: 0, userSeconds: 60, recentStalls: 3)
    XCTAssertEqual(rough.readaheadSeconds, 180)
    XCTAssertEqual(rough.pauseWaitSeconds, 5)
    XCTAssertLessThanOrEqual(rough.forwardBytes, 1536 * 1_048_576)
    let defaults = SmartCachePolicy.plan(bitsPerSecond: 20_000_000, userForwardMB: 300, userBackMB: 0, userSeconds: 300, recentStalls: 0)
    XCTAssertEqual(defaults.readaheadSeconds, 120, "the 300 s default no longer buffers whole 4K episodes")
    XCTAssertLessThan(defaults.forwardBytes, 400 * 1_048_576)
    let small = SmartCachePolicy.plan(bitsPerSecond: 1_000_000, userForwardMB: 300, userBackMB: 0, userSeconds: 60, recentStalls: 0)
    XCTAssertEqual(small.forwardBytes, 300 * 1_048_576, "the user's cache size is a floor")
  }

  func testStoreLearnsCapsAndScopesResultsByNetwork() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "cdn-store-\(UUID().uuidString)"))
    let store = CDNStore(defaults: defaults)
    let now = Date()
    for index in 0..<30 { store.learn(try XCTUnwrap(CDNHost("upos-\(index).bilivideo.com")), now: now.addingTimeInterval(Double(index))) }
    XCTAssertEqual(store.learned(now: now.addingTimeInterval(40)).count, CDNStore.learnedLimit)
    XCTAssertTrue(store.learned(now: now.addingTimeInterval(31 * 24 * 3600)).isEmpty, "learned hosts expire after 30 days")
    store.saveResults([result("a", 10)], network: "wifi")
    XCTAssertNotNil(store.results(network: "wifi"))
    XCTAssertNil(store.results(network: "cellular"))
    let host = try XCTUnwrap(CDNHost("upos-sz-mirrorhw.bilivideo.com"))
    store.setDisabled(host, true)
    XCTAssertTrue(CDNStore(defaults: defaults).disabled.contains(host), "state persists")
  }

  func testTwoStageBenchmarkKeepsFinalistsSustained() async throws {
    let fetcher = FakeFetcher(total: 4 << 20) { host in host.contains("mirrorhw") ? 0.002 : host.contains("mirrorali") ? 0.05 : 0.01 }
    fetcher.failing = ["upos-sz-mirrorcos.bilivideo.com"]
    var prober = CDNProber(fetcher: fetcher)
    prober.finalists = 2
    let hosts = ["upos-sz-mirrorhw.bilivideo.com", "upos-sz-mirrorali.bilivideo.com", "upos-sz-mirrorcos.bilivideo.com",
      "upos-tf-all-tx.bilivideo.com"].compactMap(CDNHost.init)
    let issued = URL(string: "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/x.m4s")!
    let targets = CDNProber.targets(sample: sample, hosts: hosts, issued: [issued])
    XCTAssertEqual(targets.count, 5, "issued foreign backup is benchmarked as-is")
    let results = await prober.benchmark(targets)
    XCTAssertEqual(results.count, 5)
    XCTAssertEqual(results.filter { $0.stage == .sustained }.count, 2)
    XCTAssertFalse(try XCTUnwrap(results.first { $0.host == "upos-sz-mirrorcos.bilivideo.com" }).ok)
    XCTAssertEqual(CDNSelection.best(results)?.host, "upos-sz-mirrorhw.bilivideo.com")
  }

  func testRelayServesFullAndRangedReadsAcrossNodes() async throws {
    let total = 3 * (1 << 20) + 12_345
    let fetcher = FakeFetcher(total: total) { _ in 0.03 }
    fetcher.failing = ["upos-sz-mirrorcos.bilivideo.com"]
    let relay = MediaRelay(fetcher: fetcher, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    // The failing node is seeded fastest so it is tried first, fails, and cools down.
    relay.setHosts(["upos-sz-mirrorhw.bilivideo.com", "upos-sz-mirrorcos.bilivideo.com", "upos-tf-all-tx.bilivideo.com"]
      .compactMap(CDNHost.init), seedMbps: ["upos-sz-mirrorcos.bilivideo.com": 100, "upos-sz-mirrorhw.bilivideo.com": 40,
        "upos-tf-all-tx.bilivideo.com": 40])
    let local = try XCTUnwrap(relay.register(sample))
    XCTAssertEqual(local.host, "127.0.0.1")

    let (full, response) = try await URLSession.shared.data(from: local)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(full.count, total)
    XCTAssertTrue(full == FakeFetcher.bytes(0..<total), "bytes arrive in order and intact")

    var request = URLRequest(url: local)
    request.setValue("bytes=1000000-1300000", forHTTPHeaderField: "Range")
    let (part, partial) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(partial as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 206)
    XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 1000000-1300000/\(total)")
    XCTAssertTrue(part == FakeFetcher.bytes(1_000_000..<1_300_001))

    let snapshot = relay.snapshot()
    let served = snapshot.hosts.filter { $0.totalBytes > 0 }.map(\.host)
    XCTAssertTrue(served.contains("upos-sz-mirrorhw.bilivideo.com"))
    XCTAssertTrue(served.contains("upos-tf-all-tx.bilivideo.com"), "chunks are spread over several nodes")
    XCTAssertFalse(served.contains("upos-sz-mirrorcos.bilivideo.com"))
    XCTAssertTrue(snapshot.hosts.first { $0.host == "upos-sz-mirrorcos.bilivideo.com" }?.coolingDown ?? false)

    var bad = URLRequest(url: local.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("nope/stream.m4s"))
    bad.httpMethod = "GET"
    let (_, missing) = try await URLSession.shared.data(for: bad)
    XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404, "unknown tokens are refused")
  }

  func testRelayHedgesASlowNode() async throws {
    let total = 2 * (1 << 20)
    let fetcher = FakeFetcher(total: total) { host in host.contains("mirrorcos") ? 3.0 : 0 }
    let relay = MediaRelay(fetcher: fetcher, chunkSize: 512 * 1024)
    try await relay.start()
    defer { relay.stop() }
    // The slow node looks fastest, so it is picked first and must be hedged.
    relay.setHosts(["upos-sz-mirrorcos.bilivideo.com", "upos-sz-mirrorhw.bilivideo.com"].compactMap(CDNHost.init),
      seedMbps: ["upos-sz-mirrorcos.bilivideo.com": 500, "upos-sz-mirrorhw.bilivideo.com": 10])
    let local = try XCTUnwrap(relay.register(sample))
    let started = Date()
    let (data, _) = try await URLSession.shared.data(from: local)
    XCTAssertEqual(data.count, total)
    XCTAssertLessThan(Date().timeIntervalSince(started), 6, "hedged chunks do not wait for the slow node")
    XCTAssertGreaterThan(relay.snapshot().hedgedRequests, 0)
  }

  func testRelaySurvivesANodeDyingMidStream() async throws {
    let total = 4 * (1 << 20)
    let fetcher = FakeFetcher(total: total) { _ in 0.01 }
    fetcher.failAfter = ["upos-sz-mirrorhw.bilivideo.com": 2]
    let relay = MediaRelay(fetcher: fetcher, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    relay.setHosts(["upos-sz-mirrorhw.bilivideo.com", "upos-tf-all-tx.bilivideo.com"].compactMap(CDNHost.init),
      seedMbps: ["upos-sz-mirrorhw.bilivideo.com": 200, "upos-tf-all-tx.bilivideo.com": 20])
    let local = try XCTUnwrap(relay.register(sample))
    let (data, _) = try await URLSession.shared.data(from: local)
    XCTAssertEqual(data.count, total)
    XCTAssertTrue(data == FakeFetcher.bytes(0..<total), "a node failing mid-stream never corrupts or truncates the stream")
    let snapshot = relay.snapshot()
    XCTAssertTrue(snapshot.hosts.first { $0.host == "upos-sz-mirrorhw.bilivideo.com" }?.coolingDown ?? false)
    XCTAssertGreaterThan(snapshot.hosts.first { $0.host == "upos-tf-all-tx.bilivideo.com" }?.totalBytes ?? 0, 0)
  }

  func testRangeParsing() {
    XCTAssertEqual(MediaRelay.parseRange("bytes=0-")?.start, 0)
    XCTAssertNil(MediaRelay.parseRange("bytes=0-")?.end)
    XCTAssertEqual(MediaRelay.parseRange("bytes=10-20")?.end, 20)
    XCTAssertNil(MediaRelay.parseRange("bytes=20-10"))
    XCTAssertNil(MediaRelay.parseRange("items=0-1"))
    XCTAssertNil(MediaRelay.parseRange("bytes=-500"))
  }

  // MARK: Review regressions

  func testRangeLoaderRejectsIgnoredRangesAndCapsTheBody() {
    // A node that ignores Range on a later window is refused from the response head.
    let later = RangeLoader(range: 1000...1999)
    XCTAssertEqual(later.accept(status: 200, contentType: "video/mp4", contentRange: nil, contentLength: 900_000_000),
      "节点不支持分段请求")
    // A 200 for a window starting at zero keeps only the window, however big the body is.
    let first = RangeLoader(range: 0...1023)
    XCTAssertNil(first.accept(status: 200, contentType: "video/mp4", contentRange: nil, contentLength: 900_000_000))
    XCTAssertFalse(first.append(Data(count: 1000)))
    XCTAssertTrue(first.append(Data(count: 64 * 1024)), "the window is complete at 1024 bytes")
    // A 206 that starts or ends elsewhere is refused.
    XCTAssertEqual(RangeLoader(range: 1000...1999).accept(status: 206, contentType: "video/mp4",
      contentRange: "bytes 0-999/5000", contentLength: 1000), "分段范围不符")
    XCTAssertEqual(RangeLoader(range: 1000...1999).accept(status: 206, contentType: "video/mp4",
      contentRange: "bytes 1000-1499/5000", contentLength: 500), "分段范围不符")
    // The last window may end at EOF.
    XCTAssertNil(RangeLoader(range: 4000...4999).accept(status: 206, contentType: "video/mp4",
      contentRange: "bytes 4000-4499/4500", contentLength: 500))
    XCTAssertEqual(RangeLoader(range: 0...9).accept(status: 404, contentType: "text/html", contentRange: nil, contentLength: 10), "HTTP 404")
    XCTAssertEqual(RangeLoader(range: 0...9).accept(status: 206, contentType: "text/html; charset=utf-8",
      contentRange: "bytes 0-9/10", contentLength: 10), "返回内容不是媒体")
  }

  func testRangeLoaderReportsShortBodies() async {
    let loader = RangeLoader(range: 0...999)
    XCTAssertNil(loader.accept(status: 206, contentType: "video/mp4", contentRange: "bytes 0-999/9000", contentLength: 1000))
    _ = loader.append(Data(count: 400))
    loader.complete(error: nil)
    let outcome = await withCheckedContinuation { continuation in
      loader.begin(continuation, task: URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:9/")!))
    }
    XCTAssertEqual(outcome.error, "响应不完整")
    XCTAssertFalse(outcome.ok)
    XCTAssertTrue(outcome.data.isEmpty)
  }

  func testContentRangeParsing() {
    XCTAssertEqual(CDNURLSessionFetcher.contentRange("bytes 10-19/100").start, 10)
    XCTAssertEqual(CDNURLSessionFetcher.contentRange("bytes 10-19/100").end, 19)
    XCTAssertEqual(CDNURLSessionFetcher.contentRange("bytes */100").total, 100)
    XCTAssertNil(CDNURLSessionFetcher.contentRange("bytes */100").start)
    XCTAssertNil(CDNURLSessionFetcher.contentRange("items 1-2/3").total)
  }

  func testRelayAnswers416PastTheEnd() async throws {
    let total = 600_000
    let fetcher = FakeFetcher(total: total) { _ in 0 }
    let relay = MediaRelay(fetcher: fetcher, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    relay.setHosts([CDNHost("upos-sz-mirrorhw.bilivideo.com")!])
    // Unknown length: the upstream 416 is passed on, not turned into 502.
    let fresh = try XCTUnwrap(relay.register(sample))
    var request = URLRequest(url: fresh)
    request.setValue("bytes=900000-", forHTTPHeaderField: "Range")
    let (_, first) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((first as? HTTPURLResponse)?.statusCode, 416)
    XCTAssertEqual((first as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes */\(total)")
    // Known length: answered locally without asking a node.
    let before = fetcher.totalRequests
    let (_, second) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((second as? HTTPURLResponse)?.statusCode, 416)
    XCTAssertEqual(fetcher.totalRequests, before)
  }

  func testRelayRetriesAShortLastChunkElsewhere() async throws {
    let total = 3 * 256 * 1024 + 1000
    let fetcher = FakeFetcher(total: total) { _ in 0.005 }
    fetcher.short = ["upos-sz-mirrorcos.bilivideo.com"]
    let relay = MediaRelay(fetcher: fetcher, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    relay.setHosts(["upos-sz-mirrorcos.bilivideo.com", "upos-sz-mirrorhw.bilivideo.com"].compactMap(CDNHost.init),
      seedMbps: ["upos-sz-mirrorcos.bilivideo.com": 100, "upos-sz-mirrorhw.bilivideo.com": 10])
    let local = try XCTUnwrap(relay.register(sample))
    let (data, _) = try await URLSession.shared.data(from: local)
    XCTAssertEqual(data.count, total)
    XCTAssertTrue(data == FakeFetcher.bytes(0..<total), "short windows are never passed to mpv")
  }

  func testRelaySkipsDisabledIssuedNodes() async throws {
    let fetcher = FakeFetcher(total: 600_000) { _ in 0 }
    let relay = MediaRelay(fetcher: fetcher, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    let akamai = URL(string: "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/x.m4s")!
    relay.setHosts([])
    relay.setDisabled([sample.host!])
    let local = try XCTUnwrap(relay.register(sample, backups: [akamai]))
    let (data, _) = try await URLSession.shared.data(from: local)
    XCTAssertEqual(data.count, 600_000)
    XCTAssertEqual(fetcher.requests(sample.host!), 0, "the disabled primary is not used while a backup works")
    XCTAssertGreaterThan(fetcher.requests("upos-hz-mirrorakam.akamaized.net"), 0)
  }

  // MARK: Proxied routes

  func testProxiedRoutesTakeOverWhenEveryDirectNodeIsRefused() async throws {
    let total = 3 * 256 * 1024 + 4321
    let direct = FakeFetcher(total: total) { _ in 0.002 }
    direct.failing = ["upos-sz-mirrorhw.bilivideo.com", "upos-sz-mirrorali.bilivideo.com", sample.host!]
    let proxied = FakeFetcher(total: total) { _ in 0.004 }
    let relay = MediaRelay(fetcher: direct, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    let hosts = ["upos-sz-mirrorhw.bilivideo.com", "upos-sz-mirrorali.bilivideo.com"].compactMap(CDNHost.init)
    relay.setHosts(hosts)
    relay.setProxyFetcher(proxied)
    relay.setProxiedHosts(hosts)
    let local = try XCTUnwrap(relay.register(sample))
    let (data, _) = try await URLSession.shared.data(from: local)
    XCTAssertEqual(data.count, total)
    XCTAssertTrue(data == FakeFetcher.bytes(0..<total), "region-refused direct nodes, proxied routes deliver intact bytes")
    let served = relay.snapshot().hosts.filter { $0.totalBytes > 0 }.map(\.host)
    XCTAssertTrue(served.allSatisfy(MediaRelay.isProxyKey), "\(served)")
    XCTAssertGreaterThan(proxied.totalRequests, 0)
  }

  func testDirectAndProxiedRoutesShareTheLoad() async throws {
    let total = 24 * 256 * 1024
    let direct = FakeFetcher(total: total) { _ in 0.03 }
    let proxied = FakeFetcher(total: total) { _ in 0.03 }
    let relay = MediaRelay(fetcher: direct, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    let hosts = [CDNHost("upos-sz-mirrorhw.bilivideo.com")!]
    relay.setHosts(hosts, seedMbps: ["upos-sz-mirrorhw.bilivideo.com": 40])
    relay.setProxyFetcher(proxied)
    relay.setProxiedHosts(hosts, seedMbps: [MediaRelay.proxyKey("upos-sz-mirrorhw.bilivideo.com"): 40])
    let local = try XCTUnwrap(relay.register(sample))
    let (data, _) = try await URLSession.shared.data(from: local)
    XCTAssertTrue(data == FakeFetcher.bytes(0..<total))
    let stats = Dictionary(uniqueKeysWithValues: relay.snapshot().hosts.map { ($0.host, $0.totalBytes) })
    XCTAssertGreaterThan(stats["upos-sz-mirrorhw.bilivideo.com"] ?? 0, 0)
    XCTAssertGreaterThan(stats[MediaRelay.proxyKey("upos-sz-mirrorhw.bilivideo.com")] ?? 0, 0, "equal routes split the chunks")
    XCTAssertTrue(relay.snapshot().hosts.allSatisfy { $0.inflight == 0 })
  }

  func testRemovingTheProxyStopsProxiedRoutes() async throws {
    let total = 4 * 256 * 1024
    let direct = FakeFetcher(total: total) { _ in 0.002 }
    let proxied = FakeFetcher(total: total) { _ in 0 }
    let relay = MediaRelay(fetcher: direct, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    let hosts = [CDNHost("upos-sz-mirrorhw.bilivideo.com")!]
    relay.setHosts(hosts)
    relay.setProxyFetcher(proxied)
    relay.setProxiedHosts(hosts)
    relay.setProxyFetcher(nil)
    XCTAssertTrue(relay.proxiedPool.isEmpty)
    let local = try XCTUnwrap(relay.register(sample))
    let (data, _) = try await URLSession.shared.data(from: local)
    XCTAssertEqual(data.count, total)
    XCTAssertEqual(proxied.totalRequests, 0, "no request uses a removed proxy")
  }

  func testRouteKeys() {
    XCTAssertEqual(MediaRelay.proxyKey("a.bilivideo.com"), "a.bilivideo.com@proxy")
    XCTAssertTrue(MediaRelay.isProxyKey("a.bilivideo.com@proxy"))
    XCTAssertEqual(MediaRelay.hostName(ofKey: "a.bilivideo.com@proxy"), "a.bilivideo.com")
    XCTAssertEqual(MediaRelay.hostName(ofKey: "a.bilivideo.com"), "a.bilivideo.com")
    XCTAssertNil(CDNHost("a.bilivideo.com@proxy"), "a route key is never mistaken for a host")
  }

  func testRelayStartsNothingAfterUnregister() async throws {
    let total = 64 * 256 * 1024
    let fetcher = FakeFetcher(total: total) { _ in 0.2 }
    let relay = MediaRelay(fetcher: fetcher, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    relay.setHosts(["upos-sz-mirrorhw.bilivideo.com", "upos-sz-mirrorali.bilivideo.com"].compactMap(CDNHost.init))
    let local = try XCTUnwrap(relay.register(sample))
    let reader = Task { try? await URLSession.shared.data(from: local) }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertLessThanOrEqual(fetcher.totalRequests, 12, "prefetch stays within the per-stream window")
    relay.unregisterAll()
    reader.cancel()
    try await Task.sleep(nanoseconds: 300_000_000)
    let settled = fetcher.totalRequests
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(fetcher.totalRequests, settled, "no new chunk downloads after the stream is dropped")
    XCTAssertTrue(relay.snapshot().hosts.allSatisfy { $0.inflight == 0 }, "in-flight slots are released")
  }

  // MARK: Review fixes (proxied media routing)

  func testIssuedOnlyProxiedRouteServesAnUnswappableURL() async throws {
    // F2: an overseas Akamai URL has no CDNHost, so the proxied pool has no nodes; the issued
    // primary still goes through the proxy once it measured fine there.
    let total = 3 * 256 * 1024 + 99
    let akamai = URL(string: "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/x.m4s")!
    let direct = FakeFetcher(total: total) { _ in 0.002 }
    direct.failing = [akamai.host!]
    let proxied = FakeFetcher(total: total) { _ in 0.002 }
    let relay = MediaRelay(fetcher: direct, chunkSize: 256 * 1024)
    try await relay.start()
    defer { relay.stop() }
    relay.setHosts([])
    relay.setProxyFetcher(proxied)
    relay.setProxiedHosts([], issued: true)
    XCTAssertTrue(relay.proxiesIssuedPrimary)
    let local = try XCTUnwrap(relay.register(akamai))
    let (data, response) = try await URLSession.shared.data(from: local)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertTrue(data == FakeFetcher.bytes(0..<total), "the proxied issued route delivers intact bytes")
    XCTAssertGreaterThan(proxied.requests(akamai.host!), 0)
    XCTAssertTrue(relay.snapshot().hosts.filter { $0.totalBytes > 0 }.allSatisfy { MediaRelay.isProxyKey($0.host) })
    relay.setProxyFetcher(nil)
    XCTAssertFalse(relay.proxiesIssuedPrimary, "removing the proxy turns the issued route off too")
  }

  func testProxiedRoutesKeepIssuedHostsThatAreNotCatalogNodes() {
    func result(_ host: String, ok: Bool, mbps: Double) -> CDNBenchmarkResult {
      // mbps = bytes * 8 / durationMs / 1000, so 100 ms carries mbps * 12_500 bytes.
      CDNBenchmarkResult(host: host, ok: ok, stage: .quick, status: ok ? 206 : 0, bytes: Int(mbps * 12_500), ttfbMs: 50,
        durationMs: 100, error: ok ? nil : "超时")
    }
    let akamai = MediaRelay.proxyKey("upos-hz-mirrorakam.akamaized.net")
    let node = CDNHost("upos-sz-mirrorhw.bilivideo.com")!
    let provisional = [node]
    // F2: only the Akamai route answered through the proxy.
    let issuedOnly = MediaProxyPolicy.routes([result(akamai, ok: true, mbps: 6)], provisional: provisional, disabled: [])
    XCTAssertEqual(issuedOnly.hosts, [])
    XCTAssertEqual(issuedOnly.issuedKeys, [akamai])
    XCTAssertEqual(issuedOnly.routeKeys, [akamai])
    let both = MediaProxyPolicy.routes([result(MediaRelay.proxyKey(node.name), ok: true, mbps: 9), result(akamai, ok: true, mbps: 6),
      result("upos-sz-mirrorali.bilivideo.com", ok: true, mbps: 50)], provisional: [], disabled: [])
    XCTAssertEqual(both.hosts, [node])
    XCTAssertEqual(both.routeKeys, [MediaRelay.proxyKey(node.name), akamai])
    // F5: a round that failed entirely leaves no routes; once those failures are dropped (the
    // proxy recovered) the direct pool's best serve until the new round answers.
    let failed = [result(MediaRelay.proxyKey(node.name), ok: false, mbps: 0), result(akamai, ok: false, mbps: 0)]
    XCTAssertEqual(MediaProxyPolicy.routes(failed, provisional: provisional, disabled: []), .none)
    XCTAssertEqual(MediaProxyPolicy.routes(failed.filter(\.ok), provisional: provisional, disabled: []).hosts, provisional)
    XCTAssertEqual(MediaProxyPolicy.routes([result(MediaRelay.proxyKey(node.name), ok: true, mbps: 9)], provisional: [],
      disabled: [node]).hosts, [], "disabled nodes stay out of the proxied pool")
  }

  func testProxyHealthChangesReactInEveryMediaMode() {
    // F5: a proxy that was down when playback started joins `.concurrent` once it recovers.
    XCTAssertEqual(MediaProxyPolicy.healthChanged(route: .concurrent, active: false, usable: true), .activate)
    XCTAssertEqual(MediaProxyPolicy.healthChanged(route: .concurrent, active: true, usable: true), .reprobe)
    XCTAssertEqual(MediaProxyPolicy.healthChanged(route: .onStall, active: true, usable: true), .reprobe)
    XCTAssertEqual(MediaProxyPolicy.healthChanged(route: .onStall, active: false, usable: true), .none, "a stall turns it on")
    XCTAssertEqual(MediaProxyPolicy.healthChanged(route: .off, active: false, usable: true), .none)
    XCTAssertEqual(MediaProxyPolicy.healthChanged(route: .concurrent, active: true, usable: false), .deactivate)
    XCTAssertEqual(MediaProxyPolicy.healthChanged(route: .concurrent, active: false, usable: false), .none)
  }
}

/// Deterministic upstream: byte i is `i % 251`; per-host latency in seconds; failing hosts get 403.
private final class FakeFetcher: CDNRangeFetching, @unchecked Sendable {
  let total: Int
  let latency: @Sendable (String) -> Double
  var failing: Set<String> = []
  /// Host → number of successful responses before it starts answering 403.
  var failAfter: [String: Int] = [:]
  /// Hosts that end a 206 early, returning only half of the window.
  var short: Set<String> = []
  private var served: [String: Int] = [:]
  private var calls: [String: Int] = [:]
  func requests(_ host: String) -> Int { lock.withLock { calls[host] ?? 0 } }
  var totalRequests: Int { lock.withLock { calls.values.reduce(0, +) } }
  private let lock = NSLock()
  init(total: Int, latency: @escaping @Sendable (String) -> Double) { self.total = total; self.latency = latency }

  static func bytes(_ range: Range<Int>) -> Data { Data(range.map { UInt8($0 % 251) }) }

  func fetch(_ url: URL, range: ClosedRange<Int>, timeout: TimeInterval) async -> CDNFetchOutcome {
    let host = url.host ?? ""
    lock.withLock { calls[host, default: 0] += 1 }
    let delay = latency(host)
    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    if Task.isCancelled {
      return CDNFetchOutcome(status: 0, data: Data(), ttfbMs: 0, durationMs: 0, totalLength: nil, contentType: nil, error: "已取消")
    }
    let dead = lock.withLock { () -> Bool in
      if let limit = failAfter[host] { served[host, default: 0] += 1; return served[host]! > limit }
      return false
    }
    if failing.contains(host) || dead {
      return CDNFetchOutcome(status: 403, data: Data(), ttfbMs: 5, durationMs: 5, totalLength: nil, contentType: nil, error: "HTTP 403")
    }
    if range.lowerBound >= total {
      return CDNFetchOutcome(status: 416, data: Data(), ttfbMs: 5, durationMs: 5, totalLength: total, contentType: nil, error: "HTTP 416")
    }
    var end = min(range.upperBound, total - 1)
    if short.contains(host) { end = range.lowerBound + (end - range.lowerBound) / 2 }
    let data = Self.bytes(range.lowerBound..<(end + 1))
    return CDNFetchOutcome(status: 206, data: data, ttfbMs: max(1, delay * 1000), durationMs: max(1, delay * 1000 + 1),
      totalLength: total, contentType: "video/mp4", error: nil)
  }
}
