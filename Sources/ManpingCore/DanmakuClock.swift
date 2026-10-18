import Foundation
import os

/// A smooth media clock for scrolling danmaku.
///
/// mpv's `time-pos` is the PTS of the frame on screen, so it advances in steps of one video
/// frame (42 ms at 24 fps, 67 ms at 15 fps) and is only sampled every 100 ms. Writing those
/// samples straight into the position made every correction a visible jump, sometimes
/// backwards. This clock is instead a straight line `media(t) = anchor + (t − anchorHost) × rate`
/// evaluated at the display's presentation time. Samples (taken with their own host time on
/// the sampling thread) only nudge `rate`, by at most ±4 % of the playback speed, so the error
/// bleeds off over about 1.5 s with no visible change in speed. Seeks and large drifts reset the
/// line; pause and buffering freeze it. While playing it never runs backwards.
public final class DanmakuClock: Sendable {
  public struct Sample: Sendable, Equatable {
    public var host: Double
    public var media: Double
    public var playing: Bool
    public var speed: Double
    public init(host: Double, media: Double, playing: Bool, speed: Double) {
      self.host = host; self.media = media; self.playing = playing; self.speed = speed
    }
  }
  struct State {
    var anchorHost = 0.0
    var anchorMedia = 0.0
    var rate = 0.0
    var speed = 1.0
    var running = false
    var known = false
    /// After a user seek: samples far from the target are pre-seek leftovers until this host time.
    var seekTarget: Double?
    var seekOrigin: Double?
    var seekDeadline = 0.0
    // Diagnostics since the last drain.
    var samples = 0
    var resets = 0
    var maxError = 0.0
  }
  /// Seconds over which a small error is absorbed.
  static let convergence = 1.5
  /// Largest speed change used to absorb it, relative to playback speed.
  static let maximumSlew = 0.04
  /// Errors above this are seeks, stalls or reloads: jump instead of slewing.
  static let resetThreshold = 0.35
  /// Media behind the line by less than this (a stutter) is waited for; more is a seek back.
  static let holdLimit = 3.0

  private let state = OSAllocatedUnfairLock(initialState: State())
  public init() {}

  /// Feeds one measurement. Call from any thread.
  public func update(_ sample: Sample) {
    guard sample.host.isFinite, sample.media.isFinite else { return }
    state.withLock { s in
      if let target = s.seekTarget {
        // A sample belongs to the new position once it is near the target, or clearly moved
        // from where the seek started toward it (keyframe seeks land off-target).
        let arrived = abs(sample.media - target) <= 0.3
          || s.seekOrigin.map { abs(sample.media - target) < abs($0 - target) - 0.3 } ?? (abs(sample.media - target) <= 1.5)
        if !arrived, sample.host < s.seekDeadline { return }
        s.seekTarget = nil; s.seekOrigin = nil
      }
      let speed = sample.speed.isFinite && sample.speed > 0 ? sample.speed : 1
      guard sample.playing else {
        // Freeze where the line is now. Media ahead of it (or far behind: a seek) moves it;
        // media slightly behind (a buffering stall) does not pull lines backwards.
        if s.running { s.anchorMedia = Self.position(s, at: sample.host) }
        if !s.known || sample.media > s.anchorMedia || s.anchorMedia - sample.media > Self.holdLimit {
          s.anchorMedia = sample.media
        }
        s.anchorHost = sample.host; s.running = false; s.known = true; s.speed = speed
        return
      }
      s.samples += 1
      if s.running, s.known, speed != s.speed {
        // Speed change: bend the line where it is now; position never steps back.
        s.anchorMedia = Self.position(s, at: sample.host); s.anchorHost = sample.host
        s.rate = speed; s.speed = speed
        return
      }
      if !s.running || !s.known || speed != s.speed {
        let behind = s.known ? s.anchorMedia - sample.media : 0
        s.anchorHost = sample.host; s.speed = speed; s.running = true
        if s.known, behind > 0, behind < Self.holdLimit {
          // Resuming slightly behind the frozen line: wait for media to catch up.
          s.rate = 0
        } else {
          s.anchorMedia = sample.media; s.rate = speed
        }
        s.known = true
        return
      }
      let predicted = Self.position(s, at: sample.host)
      let error = sample.media - predicted
      s.maxError = max(s.maxError, abs(error))
      if error < -Self.resetThreshold * max(1, speed), error > -Self.holdLimit {
        // Media fell behind (the source stuttered): hold still until it catches up rather
        // than jumping lines backwards. Small residue is slewed away as usual afterwards.
        s.anchorHost = sample.host; s.anchorMedia = predicted; s.rate = 0
        return
      }
      if abs(error) > Self.resetThreshold * max(1, speed) {
        s.resets += 1
        s.anchorHost = sample.host; s.anchorMedia = sample.media; s.rate = speed
        return
      }
      // Re-anchor on the line itself (no jump) and steer its slope toward the samples.
      let limit = speed * Self.maximumSlew
      s.anchorHost = sample.host; s.anchorMedia = predicted
      s.rate = speed + min(limit, max(-limit, error / Self.convergence))
    }
  }

  /// Forgets everything (a new file or a user seek); the next sample starts a fresh line,
  /// which may lie behind the old one.
  public func reset() { state.withLock { s in s.running = false; s.known = false; s.seekTarget = nil; s.seekOrigin = nil } }
  /// A user seek to `media`: ignore stale samples from before it (for up to 1.5 s), then follow.
  public func seek(to media: Double, now host: Double) {
    state.withLock { s in
      // A second seek before the first landed keeps the first origin: samples from before
      // either seek still sit there.
      s.seekOrigin = s.known ? Self.position(s, at: host) : (s.seekTarget != nil ? s.seekOrigin : nil)
      s.running = false; s.known = false
      s.seekTarget = media.isFinite ? media : nil; s.seekDeadline = host + 1.5
    }
  }

  /// Media time at host time `host` (seconds on the CACurrentMediaTime timeline).
  public func media(at host: Double) -> Double? {
    state.withLock { s in s.known ? Self.position(s, at: host) : nil }
  }

  public var isRunning: Bool { state.withLock { $0.running } }

  /// Samples, resets and the largest absorbed error since the previous call.
  public func drainDiagnostics() -> (samples: Int, resets: Int, maxError: Double) {
    state.withLock { s in
      defer { s.samples = 0; s.resets = 0; s.maxError = 0 }
      return (s.samples, s.resets, s.maxError)
    }
  }

  private static func position(_ s: State, at host: Double) -> Double {
    guard s.running else { return s.anchorMedia }
    // Never extrapolate far past the last sample: a stalled poll must not run away.
    let elapsed = min(max(0, host - s.anchorHost), 0.5)
    return s.anchorMedia + elapsed * s.rate
  }
}
