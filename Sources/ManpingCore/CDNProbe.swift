import Foundation

/// Result of one ranged GET against a CDN host.
public struct CDNFetchOutcome: Sendable {
  public let status: Int
  public let data: Data
  public let ttfbMs: Double
  public let durationMs: Double
  /// Total resource length parsed from `Content-Range: bytes a-b/total`.
  public let totalLength: Int?
  public let contentType: String?
  public let error: String?
  public var ok: Bool { error == nil && (status == 206 || status == 200) && !data.isEmpty }
  public init(status: Int, data: Data, ttfbMs: Double, durationMs: Double, totalLength: Int?, contentType: String?, error: String?) {
    self.status = status; self.data = data; self.ttfbMs = ttfbMs; self.durationMs = durationMs
    self.totalLength = totalLength; self.contentType = contentType; self.error = error
  }
}

/// Upstream byte-range transport, injectable for tests.
public protocol CDNRangeFetching: Sendable {
  func fetch(_ url: URL, range: ClosedRange<Int>, timeout: TimeInterval) async -> CDNFetchOutcome
}

/// URLSession transport: no credentials, no cookies, no cache, Bilibili referer and a desktop user agent.
public final class CDNURLSessionFetcher: CDNRangeFetching {
  private let session: URLSession
  /// `configuration` carries a proxy (`ProxyRuntime.configuration`) for the proxied path.
  public init(maximumConnectionsPerHost: Int = 6, configuration base: URLSessionConfiguration = .ephemeral) {
    let configuration = base.copy() as! URLSessionConfiguration
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
    configuration.timeoutIntervalForRequest = 15
    configuration.httpAdditionalHeaders = [
      "User-Agent": BiliService.browserUserAgent,
      "Referer": "https://www.bilibili.com/",
      "Origin": "https://www.bilibili.com",
    ]
    session = URLSession(configuration: configuration)
  }
  deinit { session.invalidateAndCancel() }

  public func fetch(_ url: URL, range: ClosedRange<Int>, timeout: TimeInterval) async -> CDNFetchOutcome {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
    // A delegate-driven task validates status and range from the response head and stops at
    // `range.count` bytes, so a node that ignores Range never streams a whole video into memory.
    let loader = RangeLoader(range: range)
    let task = session.dataTask(with: request)
    task.delegate = loader
    let deadline = Task {
      try await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
      loader.finish(error: "超时", cancel: task)
    }
    defer { deadline.cancel() }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        loader.begin(continuation, task: task)
      }
    } onCancel: {
      loader.finish(error: "已取消", cancel: task)
    }
  }

  /// `bytes a-b/total` or `bytes */total`.
  static func contentRange(_ header: String) -> (start: Int?, end: Int?, total: Int?) {
    let value = header.trimmingCharacters(in: .whitespaces)
    guard value.lowercased().hasPrefix("bytes") else { return (nil, nil, nil) }
    let spec = value.dropFirst(5).trimmingCharacters(in: .whitespaces)
    let halves = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    let total = halves.count == 2 ? Int(halves[1].trimmingCharacters(in: .whitespaces)) : nil
    let bounds = halves.first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
    guard bounds.count == 2 else { return (nil, nil, total) }
    return (Int(bounds[0].trimmingCharacters(in: .whitespaces)), Int(bounds[1].trimmingCharacters(in: .whitespaces)), total)
  }

}

/// Collects one ranged response. The response head decides whether the body is wanted at all;
/// the body is cut off at the expected length; a short body is reported as incomplete.
final class RangeLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let range: ClosedRange<Int>
  private let started = ContinuousClock.now
  private var continuation: CheckedContinuation<CDNFetchOutcome, Never>?
  private var finished: CDNFetchOutcome?
  private var data = Data()
  private var status = 0
  private var contentType: String?
  private var total: Int?
  private var expected: Int?
  private var ttfb: Double?

  init(range: ClosedRange<Int>) { self.range = range }

  private func elapsed() -> Double {
    let duration = ContinuousClock.now - started
    return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  func begin(_ continuation: CheckedContinuation<CDNFetchOutcome, Never>, task: URLSessionTask) {
    let done = lock.withLock { () -> CDNFetchOutcome? in
      if let finished { return finished }
      self.continuation = continuation
      return nil
    }
    if let done { continuation.resume(returning: done); return }
    task.resume()
  }

  /// Completes once; later calls are ignored. Errors drop the partial body.
  func finish(error: String?, cancel task: URLSessionTask? = nil) {
    let resolved = lock.withLock { () -> (CheckedContinuation<CDNFetchOutcome, Never>?, CDNFetchOutcome)? in
      guard finished == nil else { return nil }
      let duration = elapsed()
      let outcome = CDNFetchOutcome(status: status, data: error == nil ? data : Data(), ttfbMs: ttfb ?? duration,
        durationMs: duration, totalLength: total, contentType: contentType, error: error)
      finished = outcome
      let pending = continuation; continuation = nil
      return (pending, outcome)
    }
    task?.cancel()
    if let (pending, outcome) = resolved { pending?.resume(returning: outcome) }
  }

  /// Decides from the response head whether the body is usable. Returns the error, if any.
  func accept(status code: Int, contentType type: String?, contentRange: String?, contentLength: Int?) -> String? {
    let parsed = contentRange.map(CDNURLSessionFetcher.contentRange)
    return lock.withLock { () -> String? in
      status = code; contentType = type; ttfb = elapsed()
      total = parsed?.total ?? (code == 200 ? contentLength : nil)
      switch code {
      case 206:
        // The returned window must start where asked and end at the requested end (or EOF).
        guard let start = parsed?.start, let end = parsed?.end, start == range.lowerBound else { return "分段范围不符" }
        let wantedEnd = parsed?.total.map { min(range.upperBound, $0 - 1) } ?? range.upperBound
        guard end == wantedEnd, end >= start else { return "分段范围不符" }
        expected = end - start + 1
      case 200:
        // A 200 means the range was ignored: only acceptable when the window starts at zero.
        if range.lowerBound > 0 { return "节点不支持分段请求" }
        expected = contentLength.map { min($0, range.count) } ?? range.count
      default:
        return "HTTP \(code)"
      }
      if let type, type.contains("text/html") || type.contains("application/json") { return "返回内容不是媒体" }
      if let expected { data.reserveCapacity(expected) }
      return nil
    }
  }

  /// Appends body bytes up to the expected length. Returns true once the window is complete.
  func append(_ chunk: Data) -> Bool {
    lock.withLock { () -> Bool in
      guard finished == nil, let expected else { return false }
      let room = expected - data.count
      if room > 0 { data.append(chunk.prefix(room)) }
      return data.count >= expected
    }
  }

  /// End of body without a transport error: complete only when every expected byte arrived.
  func complete(error: Error?) {
    if let error {
      let code = (error as? URLError)?.code
      finish(error: code == .timedOut ? "超时" : code == .cancelled ? "已取消" : "网络错误")
      return
    }
    let short = lock.withLock { expected.map { data.count < $0 } ?? data.isEmpty }
    finish(error: short ? "响应不完整" : nil)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    let http = response as? HTTPURLResponse
    let problem = accept(status: http?.statusCode ?? 0, contentType: http?.value(forHTTPHeaderField: "Content-Type"),
      contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
      contentLength: response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil)
    if let problem {
      completionHandler(.cancel)
      finish(error: problem)
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    if append(chunk) { finish(error: nil, cancel: dataTask) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    complete(error: error)
  }
}

/// Two-stage benchmark: a quick 128 KB read on up to eight hosts, then a sustained 1 MB read
/// (after the quick window) on the three fastest. About 4 MB of extra traffic per round.
public struct CDNProber: Sendable {
  public var quickBytes = 128 * 1024
  public var sustainedBytes = 1024 * 1024
  public var quickTimeout: TimeInterval = 5
  public var sustainedTimeout: TimeInterval = 9
  public var finalists = 3
  public var concurrency = 4
  public let fetcher: CDNRangeFetching
  public init(fetcher: CDNRangeFetching) { self.fetcher = fetcher }

  /// One benchmark target: a node reached by host swap, or an issued URL used as-is.
  public struct Target: Sendable, Hashable {
    public let key: String
    public let url: URL
    public init(key: String, url: URL) { self.key = key; self.url = url }
  }

  /// Swapped-host targets for `hosts` plus the issued URLs whose host is not already covered.
  public static func targets(sample: URL, hosts: [CDNHost], issued: [URL] = []) -> [Target] {
    var result: [Target] = []
    var seen = Set<String>()
    for host in hosts {
      guard let url = CDNCatalog.replacingHost(sample, with: host), seen.insert(host.name).inserted else { continue }
      result.append(Target(key: host.name, url: url))
    }
    for url in issued {
      guard let key = url.host?.lowercased(), seen.insert(key).inserted else { continue }
      result.append(Target(key: key, url: url))
    }
    return result
  }

  /// `onResult` sees each host's result as soon as it finishes, fastest first.
  public func quick(_ targets: [Target], onResult: (@Sendable (CDNBenchmarkResult) async -> Void)? = nil) async -> [CDNBenchmarkResult] {
    await run(targets, stage: .quick, range: 0...(quickBytes - 1), timeout: quickTimeout, onResult: onResult)
  }

  public func sustained(_ targets: [Target]) async -> [CDNBenchmarkResult] {
    await run(targets, stage: .sustained, range: quickBytes...(quickBytes + sustainedBytes - 1), timeout: sustainedTimeout)
  }

  /// Full two-stage round. Quick results stay in the output for hosts that did not reach the final.
  public func benchmark(_ targets: [Target]) async -> [CDNBenchmarkResult] {
    let quickResults = await quick(targets)
    let ranked = Set(quickResults.filter { $0.ok }.sorted { $0.mbps > $1.mbps }.prefix(finalists).map(\.host))
    let finals = targets.filter { ranked.contains($0.key) }
    guard !Task.isCancelled, !finals.isEmpty else { return quickResults }
    let sustainedResults = await sustained(finals)
    let replaced = Set(sustainedResults.map(\.host))
    return sustainedResults + quickResults.filter { !replaced.contains($0.host) }
  }

  private func run(_ targets: [Target], stage: CDNBenchmarkStage, range: ClosedRange<Int>,
    timeout: TimeInterval, onResult: (@Sendable (CDNBenchmarkResult) async -> Void)? = nil) async -> [CDNBenchmarkResult] {
    let fetcher = self.fetcher
    let limit = max(1, concurrency)
    return await withTaskGroup(of: CDNBenchmarkResult.self) { group in
      var iterator = targets.makeIterator()
      var running = 0
      func launch() -> Bool {
        guard !Task.isCancelled, let target = iterator.next() else { return false }
        group.addTask {
          guard !Task.isCancelled else {
            return CDNBenchmarkResult(host: target.key, ok: false, stage: stage, status: 0,
              bytes: 0, ttfbMs: 0, durationMs: 0, error: "已取消")
          }
          let outcome = await fetcher.fetch(target.url, range: range, timeout: timeout)
          return CDNBenchmarkResult(host: target.key, ok: outcome.ok, stage: stage, status: outcome.status,
            bytes: outcome.data.count, ttfbMs: outcome.ttfbMs, durationMs: outcome.durationMs, error: outcome.error)
        }
        return true
      }
      while running < limit, launch() { running += 1 }
      var results: [CDNBenchmarkResult] = []
      while let result = await group.next() {
        results.append(result)
        await onResult?(result)
        if !launch() { running -= 1 }
      }
      return results
    }
  }
}
