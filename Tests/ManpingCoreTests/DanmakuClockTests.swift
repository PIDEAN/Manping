import XCTest
@testable import ManpingCore

final class DanmakuClockTests: XCTestCase {
  private func feed(_ clock: DanmakuClock, host: Double, media: Double, playing: Bool = true, speed: Double = 1) {
    clock.update(.init(host: host, media: media, playing: playing, speed: speed))
  }

  func testFrameQuantisedSamplesGiveAUniformLine() {
    // 24 fps time-pos: each 100 ms sample is floored to the last frame, with sampling jitter.
    let clock = DanmakuClock()
    var host = 10.0
    for step in 0..<100 {
      host += 0.1 + (step % 3 == 0 ? 0.004 : -0.002)
      let truth = host - 10
      feed(clock, host: host, media: (truth * 24).rounded(.down) / 24)
    }
    // Evaluate at 120 Hz over the next 100 ms: per-frame advance stays within 5 % of 1/120 s.
    var previous = clock.media(at: host)!
    for frame in 1...12 {
      let value = clock.media(at: host + Double(frame) / 120)!
      XCTAssertEqual((value - previous) * 120, 1, accuracy: 0.05)
      previous = value
    }
    // And it tracks the truth (minus half a frame of flooring) within a few milliseconds.
    XCTAssertEqual(clock.media(at: host)!, host - 10 - 1.0 / 48, accuracy: 0.03)
  }

  func testNeverRunsBackwardsAndFreezesWhilePaused() {
    let clock = DanmakuClock()
    feed(clock, host: 0, media: 5)
    feed(clock, host: 0.1, media: 5.1)
    var last = clock.media(at: 0.1)!
    // A stutter: media falls 0.6 s behind. The line holds instead of jumping back.
    feed(clock, host: 1.0, media: 5.4)
    for host in stride(from: 1.0, through: 1.6, by: 0.05) {
      let value = clock.media(at: host)!
      XCTAssertGreaterThanOrEqual(value, last - 1e-9)
      last = value
    }
    feed(clock, host: 2, media: 6, playing: false)
    XCTAssertEqual(clock.media(at: 5), clock.media(at: 9))
    XCTAssertFalse(clock.isRunning)
  }

  func testSeeksJumpAndNewFilesReset() {
    let clock = DanmakuClock()
    feed(clock, host: 0, media: 10)
    feed(clock, host: 0.1, media: 10.1)
    feed(clock, host: 0.2, media: 120)
    XCTAssertEqual(clock.media(at: 0.2)!, 120, accuracy: 0.001)
    feed(clock, host: 0.3, media: 20)   // seek back beyond the hold limit
    XCTAssertEqual(clock.media(at: 0.3)!, 20, accuracy: 0.001)
    clock.reset()
    XCTAssertNil(clock.media(at: 1))
  }

  func testUserSeekIgnoresStaleSamplesThenFollowsBackwards() {
    let clock = DanmakuClock()
    feed(clock, host: 0, media: 60)
    feed(clock, host: 0.1, media: 60.1)
    clock.seek(to: 58, now: 0.15)
    feed(clock, host: 0.2, media: 60.2)   // still the old position: ignored
    XCTAssertNil(clock.media(at: 0.2))
    feed(clock, host: 0.3, media: 58.0)
    feed(clock, host: 0.4, media: 58.1)
    XCTAssertEqual(clock.media(at: 0.4)!, 58.1, accuracy: 0.01)
  }

  func testResumingSlightlyBehindHoldsInsteadOfJumpingBack() {
    let clock = DanmakuClock()
    feed(clock, host: 0, media: 10)
    feed(clock, host: 1, media: 11)
    let frozen = clock.media(at: 1.05)!
    feed(clock, host: 1.1, media: 10.8, playing: false)   // buffering, media a bit behind
    XCTAssertEqual(clock.media(at: 1.2)!, frozen, accuracy: 0.11)
    feed(clock, host: 1.5, media: 10.8)                     // resumes behind the line
    XCTAssertGreaterThanOrEqual(clock.media(at: 1.6)!, frozen - 0.11)
  }

  func testShortSeekBackIsNotMistakenForAStaleSample() {
    let clock = DanmakuClock()
    feed(clock, host: 0, media: 60)
    feed(clock, host: 0.1, media: 60.1)
    clock.seek(to: 59.5, now: 0.12)
    feed(clock, host: 0.2, media: 60.2)    // stale: not closer to the target than the origin
    XCTAssertNil(clock.media(at: 0.2))
    feed(clock, host: 0.3, media: 59.5)
    feed(clock, host: 0.4, media: 59.6)
    XCTAssertEqual(clock.media(at: 0.4)!, 59.6, accuracy: 0.01)
  }

  func testSpeedChangeBendsTheLineWithoutSteppingBack() {
    let clock = DanmakuClock()
    feed(clock, host: 0, media: 10)
    feed(clock, host: 0.1, media: 10.08)
    let before = clock.media(at: 0.2)!
    feed(clock, host: 0.2, media: 10.16, speed: 2)
    XCTAssertGreaterThanOrEqual(clock.media(at: 0.2)!, before - 1e-9)
    XCTAssertEqual(clock.media(at: 0.3)! - clock.media(at: 0.2)!, 0.2, accuracy: 0.001)
  }

  func testBackToBackSeeksKeepRejectingStaleSamples() {
    let clock = DanmakuClock()
    feed(clock, host: 0, media: 60)
    feed(clock, host: 0.1, media: 60.1)
    clock.seek(to: 58, now: 0.12)
    clock.seek(to: 59.5, now: 0.14)
    feed(clock, host: 0.2, media: 60.2)
    XCTAssertNil(clock.media(at: 0.2))
    feed(clock, host: 0.3, media: 59.5)
    feed(clock, host: 0.4, media: 59.6)
    XCTAssertEqual(clock.media(at: 0.4)!, 59.6, accuracy: 0.01)
  }
}
