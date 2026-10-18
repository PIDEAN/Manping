import Foundation
import XCTest

@testable import ManpingCore

/// Real-network check of the benchmark and relay. Skipped unless `MANPING_LIVE_SAMPLE_URL`
/// holds a fresh signed `*.bilivideo.com` media URL (from a public playurl response).
final class CDNLiveTests: XCTestCase {
  func testRealBenchmarkAndRelayThroughput() async throws {
    guard let text = ProcessInfo.processInfo.environment["MANPING_LIVE_SAMPLE_URL"], let sample = URL(string: text) else {
      throw XCTSkip("set MANPING_LIVE_SAMPLE_URL to run")
    }
    let fetcher = CDNURLSessionFetcher()
    let prober = CDNProber(fetcher: fetcher)
    let hosts = CDNCatalog.builtin.compactMap { CDNHost($0.0) }
    let issued = (ProcessInfo.processInfo.environment["MANPING_LIVE_BACKUPS"] ?? "").split(separator: " ").compactMap { URL(string: String($0)) }
    let results = await prober.benchmark(CDNProber.targets(sample: sample, hosts: hosts, issued: [sample] + issued))
    for result in results.sorted(by: { $0.mbps > $1.mbps }) {
      print(String(format: "BENCH %@ %@ %@ %.2f Mbps ttfb %.0f ms %@", result.host, result.stage.rawValue,
        result.ok ? "ok" : "fail", result.mbps, result.ttfbMs, result.error ?? ""))
    }
    let ok = results.filter(\.ok).sorted { $0.mbps > $1.mbps }
    XCTAssertFalse(ok.isEmpty, "at least one node must be reachable")
    let bytes = 12 << 20

    // Single best node, sequential 1 MB ranges (what a plain player connection achieves).
    let best = try XCTUnwrap(ok.first.flatMap { CDNHost($0.host) }.flatMap { CDNCatalog.replacingHost(sample, with: $0) } ?? sample)
    let singleStart = Date()
    var single = 0
    while single < bytes {
      let outcome = await fetcher.fetch(best, range: single...(single + (1 << 20) - 1), timeout: 20)
      guard outcome.ok else { break }
      single += outcome.data.count
      if outcome.data.count < 1 << 20 { break }
    }
    let singleSeconds = Date().timeIntervalSince(singleStart)

    // Relay over the four fastest nodes.
    let relay = MediaRelay(fetcher: fetcher)
    try await relay.start()
    defer { relay.stop() }
    relay.setHosts(ok.prefix(4).compactMap { CDNHost($0.host) }, seedMbps: Dictionary(ok.map { ($0.host, $0.mbps) }, uniquingKeysWith: max))
    relay.markUnreachable(results.filter { !$0.ok }.map(\.host))
    let local = try XCTUnwrap(relay.register(sample, backups: issued))
    var request = URLRequest(url: local)
    request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
    let relayStart = Date()
    let (data, response) = try await URLSession.shared.data(for: request)
    let relaySeconds = Date().timeIntervalSince(relayStart)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
    let snapshot = relay.snapshot()
    print(String(format: "SINGLE %d bytes in %.2f s = %.2f Mbps", single, singleSeconds, Double(single) * 8 / singleSeconds / 1e6))
    print(String(format: "RELAY  %d bytes in %.2f s = %.2f Mbps hedges=%d retries=%d", data.count, relaySeconds,
      Double(data.count) * 8 / relaySeconds / 1e6, snapshot.hedgedRequests, snapshot.retries))
    for host in snapshot.hosts where host.totalBytes > 0 {
      print(String(format: "RELAY-HOST %@ %d KB failures=%d", host.host, host.totalBytes / 1024, host.failures))
    }
    // Byte-for-byte identical to a direct read of the same range from the best node.
    let check = await fetcher.fetch(best, range: (bytes - 65_536)...(bytes - 1), timeout: 20)
    if check.ok, data.count == bytes { XCTAssertEqual(data.suffix(65_536), check.data) }
  }
}
