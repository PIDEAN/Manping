import Foundation

/// 只看 3 分钟 依次播放: plays a validated clip list on one media, one clip after another.
///
/// The machine is pure; the app feeds it playback clock samples and performs the actions it
/// returns. It is bound to one media identity: any sample from another media ends it. A clip is
/// only "playing" after the player has reported a position at the seek target, so stale samples
/// from before the seek never count. Every seek the player is asked for is reported through
/// `seekRequested(to:)`: any seek but the one the machine just issued (the user dragged the
/// progress bar, pressed ←/→, chose a chapter), however small, ends the mode. Jumps between clock
/// samples are a second line of defence for seeks that bypass the report.
public struct AIClipPlaybackMachine: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case idle
    /// A seek to clip `index` was issued; waiting for the player to land there.
    case seeking(index: Int)
    case playing(index: Int)
  }
  public enum Action: Sendable, Equatable {
    case seek(Double)
    case play
    case pause
  }
  public enum Exit: Sendable, Equatable {
    /// The last clip ended; playback was paused.
    case finished
    /// The user moved the playhead.
    case userSeek
    /// Another video, part or episode is playing now.
    case mediaChanged
    /// Stopped from the UI (or the mode was replaced).
    case stopped
    /// The player never reached a clip's start.
    case seekFailed
  }

  /// Seconds the player may land before a seek target (keyframe seeks) or after it.
  public static let landingBefore = 5.0
  public static let landingAfter = 3.0
  /// A clip ends this close to its end time (the clock ticks about ten times a second).
  public static let endSlack = 0.25
  /// Backward or forward movement between two samples larger than this is a jump.
  public static let backwardJump = 1.5
  public static let forwardJump = 5.0
  /// A seek that has not landed after this many seconds gives up.
  public static let seekTimeout = 8.0
  /// Clips this close together play through without a seek.
  public static let contiguousGap = 0.5

  public private(set) var phase: Phase = .idle
  public private(set) var media: String?
  public private(set) var clips: [AITimeRange] = []
  public private(set) var lastExit: Exit?
  private var lastTime: Double?
  private var seekIssuedAt = 0.0
  private var seekFrom: Double?
  /// The seek the machine issued and has not yet seen reported.
  private var ownSeek: Double?

  public init() {}

  public var isActive: Bool { phase != .idle }
  /// Index of the clip being sought or played.
  public var index: Int? {
    switch phase {
    case .idle: nil
    case .seeking(let index), .playing(let index): index
    }
  }

  /// Starts on `media` with clips sorted by start. `position` is the playhead before the first
  /// seek, `now` a monotonic clock in seconds.
  public mutating func start(clips: [AITimeRange], media: String, position: Double?, now: Double) -> [Action] {
    let usable = clips.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.start >= 0 }
      .sorted { $0.start < $1.start }
    guard !usable.isEmpty, !media.isEmpty else { return [] }
    self.clips = usable; self.media = media; lastExit = nil; lastTime = nil
    return beginSeek(0, from: position, now: now) + [.play]
  }

  /// One clock sample of the current media.
  public mutating func tick(time: Double, media current: String?, now: Double) -> [Action] {
    guard isActive else { return [] }
    guard current == media else { finish(.mediaChanged); return [] }
    guard time.isFinite else { return [] }
    switch phase {
    case .idle: return []
    case .seeking(let index):
      let target = clips[index].start
      let landed = time >= target - Self.landingBefore && time <= target + Self.landingAfter
      // A sample taken before the seek may already sit near the target; only a moved
      // playhead (or enough time for the seek to have happened) counts as the landing.
      let moved = seekFrom.map { abs(time - $0) > 0.5 } ?? true
      if landed && (moved || now - seekIssuedAt >= 1) {
        phase = .playing(index: index); lastTime = time
        return []
      }
      if now - seekIssuedAt > Self.seekTimeout { finish(.seekFailed) }
      return []
    case .playing(let index):
      let clip = clips[index]
      if let last = lastTime {
        let delta = time - last
        if delta < -Self.backwardJump || delta > Self.forwardJump { finish(.userSeek); return [] }
      }
      if time < clip.start - Self.landingBefore || time > clip.end + Self.forwardJump { finish(.userSeek); return [] }
      lastTime = time
      guard time >= clip.end - Self.endSlack else { return [] }
      let next = index + 1
      guard next < clips.count else { finish(.finished); return [.pause] }
      if clips[next].start - clip.end <= Self.contiguousGap, clips[next].start >= clip.end - Self.endSlack {
        phase = .playing(index: next)
        return []
      }
      return beginSeek(next, from: time, now: now)
    }
  }

  /// A periodic check while waiting for a seek (no samples arrive while the clock stands still).
  public mutating func check(now: Double) {
    if case .seeking = phase, now - seekIssuedAt > Self.seekTimeout { finish(.seekFailed) }
  }

  /// A seek was requested on the player. The machine's own seek is recognised once; any other
  /// seek is the user's and ends the mode. Returns true when the mode ended.
  @discardableResult
  public mutating func seekRequested(to target: Double) -> Bool {
    guard isActive else { return false }
    if let own = ownSeek, abs(own - target) < 0.001 { ownSeek = nil; return false }
    finish(.userSeek)
    return true
  }

  public mutating func stop(_ reason: Exit = .stopped) {
    guard isActive else { return }
    finish(reason)
  }

  private mutating func beginSeek(_ index: Int, from position: Double?, now: Double) -> [Action] {
    phase = .seeking(index: index); seekIssuedAt = now; seekFrom = position; lastTime = nil; ownSeek = clips[index].start
    return [.seek(clips[index].start)]
  }
  private mutating func finish(_ reason: Exit) {
    phase = .idle; lastExit = reason; lastTime = nil; seekFrom = nil; ownSeek = nil
  }
}
