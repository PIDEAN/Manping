import Foundation

/// Presentation follows the owning surface, independently of application activation.
public enum PlaybackPresentation {
  public static func expected(hasWindow: Bool, hidden: Bool, miniaturized: Bool,
    occlusionVisible: Bool, renderingActive: Bool) -> Bool {
    hasWindow && !hidden && !miniaturized && occlusionVisible && renderingActive
  }
}

/// Hidden surfaces still need real media progress. Returning to presentation needs a fresh frame.
public struct PlaybackProgress: Sendable {
  private var previousPosition: Double?
  private var expected: Bool
  private var frameBaseline: Int
  private var previousPresentedFrames: Int
  public init(position: Double, presentedFrames: Int, presentationExpected: Bool) {
    previousPosition = position.isFinite ? position : nil
    expected = presentationExpected
    frameBaseline = presentedFrames
    previousPresentedFrames = presentedFrames
  }
  public mutating func sample(position: Double, presentedFrames: Int,
    presentationExpected: Bool, requiresFrames: Bool = true) -> Bool {
    // A frame presented between visibility restoration and this sample is already evidence.
    if presentationExpected && !expected { frameBaseline = previousPresentedFrames }
    expected = presentationExpected
    previousPresentedFrames = presentedFrames
    let previous = previousPosition
    previousPosition = position.isFinite ? position : nil
    guard position.isFinite, let previous, position > previous + 0.02 else { return false }
    return !requiresFrames || !presentationExpected || presentedFrames > frameBaseline
  }
}

/// One playback attempt, driven by a monotonic clock. Reloading a URL must not recreate it.
public struct PlaybackRecovery: Sendable {
  public enum Action: Equatable, Sendable { case none, retry, fail }
  public private(set) var terminal = false
  /// Monotonic failure time. Cancelling a session is terminal but is not a recovery failure.
  public private(set) var terminalAt: Double?
  public private(set) var hasProgress = false
  private var previous: Double
  private var waiting = 0.0
  private var retried = false
  public var waitingSeconds: Double { waiting }
  public var remainingSeconds: Double { max(0, (hasProgress ? 40 : 28) - waiting) }

  public init(now: Double) { previous = now }

  /// User seeks start a new wait; automatic URL reloads deliberately do not call this.
  public mutating func seek(now: Double) { previous = now; waiting = 0; retried = false }
  public mutating func cancel() { terminal = true }

  public mutating func sample(now: Double, progressing: Bool, paused: Bool, ended: Bool = false,
    expired: Bool = false) -> Action {
    guard !terminal else { return .none }
    let delta = max(0, now - previous)
    previous = now
    if ended { waiting = 0; retried = false; return .none }
    // Explicit user pause freezes the deadline; paused-for-cache is not a user pause.
    guard !paused else { return .none }
    // Video can keep advancing while an external audio stream has an expired URL.
    if progressing && !expired { hasProgress = true; waiting = 0; retried = false; return .none }
    waiting += delta
    if waiting >= (hasProgress ? 40 : 28) { terminal = true; terminalAt = now; return .fail }
    if !retried, waiting >= (expired ? 2 : hasProgress ? 6 : 16) {
      retried = true
      return .retry
    }
    return .none
  }
}

/// Ordered, finite direct-mode alternatives. Different signed URLs on one host remain distinct.
public struct PlaybackURLCandidates: Sendable {
  public struct Candidate: Hashable, Sendable {
    public let video: URL
    public let audio: URL?
    public init(video: URL, audio: URL? = nil) { self.video = video; self.audio = audio }
  }
  private var tried: Set<Candidate> = []
  private var pending: [Candidate] = []
  public init() {}
  public var remaining: Int { pending.count }
  public mutating func markLoaded(_ candidate: Candidate) {
    tried.insert(candidate); pending.removeAll { $0 == candidate }
  }
  public mutating func claim(_ candidate: Candidate) -> Bool {
    guard !tried.contains(candidate) else { return false }
    markLoaded(candidate)
    return true
  }
  public mutating func append(_ candidates: [Candidate]) {
    for candidate in candidates where !tried.contains(candidate) && !pending.contains(candidate) {
      pending.append(candidate)
    }
  }
  public mutating func next() -> Candidate? {
    guard !pending.isEmpty else { return nil }
    let candidate = pending.removeFirst()
    tried.insert(candidate)
    return candidate
  }
}

/// Signed URL refreshes may stay on each stream's current node without enabling failover.
public enum PlaybackNodePolicy {
  public static func sameAuthority(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let lhsHost = lhs.host?.lowercased(), let rhsHost = rhs.host?.lowercased(),
      ["http", "https"].contains(lhs.scheme?.lowercased() ?? ""),
      ["http", "https"].contains(rhs.scheme?.lowercased() ?? "") else { return false }
    func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
    return lhsHost == rhsHost && port(lhs) == port(rhs)
  }

  public static func restrictedURLs(_ issued: [URL], current: URL?, manualHost: String?) -> [URL] {
    if let manualHost {
      let matching = issued.filter { $0.host?.lowercased() == manualHost.lowercased() }
      let choices: [URL]
      if !matching.isEmpty { choices = matching }
      else if let host = CDNHost(manualHost) { choices = issued.compactMap { CDNCatalog.replacingHost($0, with: host) } }
      else { return [] }
      if let current, current.host?.lowercased() == manualHost.lowercased() {
        return choices.filter { sameAuthority($0, current) }
      }
      return choices
    }
    guard let current else { return [] }
    return issued.filter { sameAuthority($0, current) }
  }

  public static func refreshed(video: [URL], audio: [URL], current: PlaybackURLCandidates.Candidate,
    manualHost: String?) -> PlaybackURLCandidates.Candidate? {
    guard let nextVideo = restrictedURLs(video, current: current.video, manualHost: manualHost).first else { return nil }
    let nextAudio = restrictedURLs(audio, current: current.audio ?? current.video, manualHost: manualHost).first
    guard audio.isEmpty || nextAudio != nil else { return nil }
    return .init(video: nextVideo, audio: nextAudio)
  }
}

/// Shared by the video/audio streams and replacement URLs of one playback session.
/// Only failed transfer/backoff intervals consume this budget; ordinary playback age does not.
/// Overlapping prefetch failures count once, and exhaustion survives new HTTP range reads.
public final class RelayRetryBudget: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Double
  private var intervals: [ClosedRange<Double>] = []
  public init(seconds: Double = 45) { limit = max(0, seconds) }
  public var exhausted: Bool {
    lock.withLock { !intervals.isEmpty && intervals.reduce(0) { $0 + $1.upperBound - $1.lowerBound } >= limit }
  }
  public var remaining: Double {
    lock.withLock { max(0, limit - intervals.reduce(0) { $0 + $1.upperBound - $1.lowerBound }) }
  }
  public func recordFailure(from start: Double, to end: Double) {
    guard end > start else { return }
    lock.withLock {
      let sorted = (intervals + [start...end]).sorted { $0.lowerBound < $1.lowerBound }
      intervals = []
      for interval in sorted {
        if let last = intervals.last, interval.lowerBound <= last.upperBound {
          intervals[intervals.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
        } else { intervals.append(interval) }
      }
    }
  }
}
