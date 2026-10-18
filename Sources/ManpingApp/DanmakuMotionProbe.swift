import Foundation
import os

/// Measures how evenly scrolling danmaku move: for every drawn frame while playing, the media
/// clock's advance divided by the time between the frames' presentation timestamps should be
/// exactly 1, and frames should arrive at the display's rate. Deviations are what the eye reads
/// as stutter. Called from the render thread; enabled only by the debug playback report.
enum DanmakuMotionProbe {
  private struct State {
    var enabled = false
    var lastHost: Double?
    var lastClock = 0.0
    var ratios: [Double] = []
    var intervals: [Double] = []
    var stalls = 0
    var backwards = 0
  }
  private static let state = OSAllocatedUnfairLock(initialState: State())

  static func enable() { state.withLock { $0.enabled = true } }

  /// `host` is the presentation time the frame is for, `clock` the media time used to place it.
  static func record(host: Double, clock: Double, speed: Double, playing: Bool) {
    state.withLock { s in
      guard s.enabled else { return }
      defer { s.lastHost = playing ? host : nil; s.lastClock = clock }
      guard playing, let lastHost = s.lastHost, host > lastHost, speed > 0, clock.isFinite else { return }
      let dt = host - lastHost
      // Long gaps are seeks, pauses or hidden windows, not motion.
      guard dt < 0.25, abs(clock - s.lastClock) < 1 else { return }
      s.ratios.append((clock - s.lastClock) / (dt * speed)); s.intervals.append(dt)
      if clock == s.lastClock { s.stalls += 1 }
      if clock < s.lastClock { s.backwards += 1 }
    }
  }

  /// Statistics since the previous call, then reset.
  static func drain() -> [String: Double] {
    state.withLock { s in
      defer { s.ratios = []; s.intervals = []; s.stalls = 0; s.backwards = 0 }
      guard !s.ratios.isEmpty else { return ["frames": 0] }
      let ratios = s.ratios, intervals = s.intervals
      let mean = ratios.reduce(0, +) / Double(ratios.count)
      let deviation = (ratios.map { ($0 - 1) * ($0 - 1) }.reduce(0, +) / Double(ratios.count)).squareRoot()
      let interval = intervals.reduce(0, +) / Double(intervals.count)
      let sorted = ratios.map { abs($0 - 1) }.sorted()
      // Interval jitter: how far frame spacing strays from its mean (dropped / late frames).
      let jitter = (intervals.map { ($0 - interval) * ($0 - interval) }.reduce(0, +) / Double(intervals.count)).squareRoot()
      return [
        "frames": Double(ratios.count),
        "fps": (1 / interval * 10).rounded() / 10,
        "maxInterval": ((intervals.max() ?? 0) * 10_000).rounded() / 10,
        "intervalJitterMs": (jitter * 10_000).rounded() / 10,
        "ratioMean": (mean * 1000).rounded() / 1000,
        "ratioRMS": (deviation * 1000).rounded() / 1000,
        "ratioP95": (sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000).rounded() / 1000,
        "stalls": Double(s.stalls),
        "backwards": Double(s.backwards),
      ]
    }
  }
}
