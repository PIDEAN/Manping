import XCTest
@testable import ManpingCore

final class PlaybackProgressTests: XCTestCase {
  func testOwningSurfacePresentationStates() {
    // These are the current owner's inputs after mini player, standalone or full-screen moves.
    XCTAssertTrue(PlaybackPresentation.expected(hasWindow: true, hidden: false,
      miniaturized: false, occlusionVisible: true, renderingActive: true))
    for state in 0..<5 {
      XCTAssertFalse(PlaybackPresentation.expected(hasWindow: state != 0, hidden: state == 1,
        miniaturized: state == 2, occlusionVisible: state != 3, renderingActive: state != 4))
    }
  }

  func testHiddenStartupAndNewSessionKeepRealMediaProgress() {
    for _ in 0..<2 {
      var progress = PlaybackProgress(position: 0, presentedFrames: 7, presentationExpected: false)
      var recovery = PlaybackRecovery(now: 0)
      for second in 1...35 {
        let healthy = progress.sample(position: Double(second), presentedFrames: 7, presentationExpected: false)
        XCTAssertTrue(healthy)
        XCTAssertEqual(recovery.sample(now: Double(second), progressing: healthy, paused: false), .none)
      }
      XCTAssertFalse(recovery.terminal)
      XCTAssertFalse(progress.sample(position: 36, presentedFrames: 7, presentationExpected: true))
      XCTAssertFalse(progress.sample(position: 37, presentedFrames: 7, presentationExpected: true))
      XCTAssertTrue(progress.sample(position: 38, presentedFrames: 8, presentationExpected: true))
      XCTAssertTrue(progress.sample(position: 39, presentedFrames: 8, presentationExpected: true),
        "the first new frame establishes presentation; static/low-fps media stays valid")
    }
  }

  func testSingleFramePresentedBeforeFirstVisibleSampleStaysHealthy() {
    var progress = PlaybackProgress(position: 0, presentedFrames: 1, presentationExpected: false)
    var recovery = PlaybackRecovery(now: 0)
    for second in 1...45 {
      let healthy = progress.sample(position: Double(second), presentedFrames: 4, presentationExpected: true)
      XCTAssertTrue(healthy, "the first visible sample must retain the frame already presented since attach")
      XCTAssertEqual(recovery.sample(now: Double(second), progressing: healthy, paused: false), .none)
    }
    XCTAssertFalse(recovery.terminal, "continuous audio with one displayed video frame is healthy")
  }

  func testHiddenNetworkStallStillTerminates() {
    var progress = PlaybackProgress(position: 0, presentedFrames: 0, presentationExpected: false)
    var recovery = PlaybackRecovery(now: 0)
    for second in 1...28 {
      let healthy = progress.sample(position: 0, presentedFrames: 0, presentationExpected: false)
      let action = recovery.sample(now: Double(second), progressing: healthy, paused: false)
      XCTAssertEqual(action, second == 16 ? .retry : second == 28 ? .fail : .none)
    }
    XCTAssertTrue(recovery.terminal)
  }

  func testVisibleStartupStillNeedsFrameAndFiniteProgress() {
    var progress = PlaybackProgress(position: 0, presentedFrames: 4, presentationExpected: true)
    XCTAssertFalse(progress.sample(position: 1, presentedFrames: 4, presentationExpected: true))
    XCTAssertFalse(progress.sample(position: .infinity, presentedFrames: 5, presentationExpected: true))
    XCTAssertFalse(progress.sample(position: 2, presentedFrames: 5, presentationExpected: true))
    XCTAssertTrue(progress.sample(position: 3, presentedFrames: 5, presentationExpected: true))
    XCTAssertFalse(progress.sample(position: .nan, presentedFrames: 5, presentationExpected: false))
    XCTAssertFalse(progress.sample(position: 4, presentedFrames: 5, presentationExpected: false))
    XCTAssertFalse(progress.sample(position: 4, presentedFrames: 5, presentationExpected: false))
  }
}
