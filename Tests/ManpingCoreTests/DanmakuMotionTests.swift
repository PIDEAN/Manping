import XCTest
@testable import ManpingCore

final class DanmakuMotionTests: XCTestCase {
  func testLowRefreshStageTravelIsCappedWithoutChangingWindowsOr120Hz() {
    for width in [640.0, 960, 1280] {
      XCTAssertEqual(DanmakuMotion.scrollingDurationScale(stageWidth: width, maximumFPS: 60), 1)
    }
    for hz in [24, 30, 60] {
      for width in [1920.0, 2560, 3840] {
        let scale = DanmakuMotion.scrollingDurationScale(stageWidth: width, maximumFPS: hz)
        XCTAssertEqual(width / (8 * scale), 160, accuracy: 1e-9)
        for speed in [0.5, 1, 2] {
          XCTAssertEqual(width / (8 * scale / speed) / 60, 160 * speed / 60, accuracy: 1e-9)
        }
      }
    }
    XCTAssertEqual(DanmakuMotion.scrollingDurationScale(stageWidth: 3840, maximumFPS: 120), 1)
    XCTAssertEqual(DanmakuMotion.scrollingDurationScale(stageWidth: .nan, maximumFPS: 60), 1)
    XCTAssertEqual(DanmakuMotion.scrollingDurationScale(stageWidth: -1, maximumFPS: 60), 1)
  }
  func testLongerScrollingDwellRelayoutsLanesButNotFixedComments() {
    let comments = [DanmakuComment(time: 0, text: "滚动"), DanmakuComment(time: 0, mode: 4, text: "底部")]
    var timeline = DanmakuTimeline(comments: comments)
    timeline.setScrollingDurationScale(1.5)
    XCTAssertTrue(timeline.hasVisible(at: 10))
    XCTAssertEqual(timeline.visible(at: 10).map(\.comment.text), ["滚动"])
    XCTAssertEqual(timeline.visible(at: 6).first!.progress, 0.5, accuracy: 1e-9)
    timeline.setSpeed(0.5)
    XCTAssertEqual(timeline.visible(at: 6, speed: 0.5).first!.progress, 0.25, accuracy: 1e-9)
    XCTAssertFalse(timeline.hasVisible(at: 24, speed: 0.5))
    timeline.setScrollingDurationScale(1)
    XCTAssertFalse(timeline.hasVisible(at: 17, speed: 0.5))
  }
  func testAutomaticGlyphStylePreservesHighRefreshAppearance() {
    XCTAssertEqual(DanmakuGlyphStyle.automatic.resolved(maximumFPS: 60), .outline)
    XCTAssertEqual(DanmakuGlyphStyle.automatic.resolved(maximumFPS: 120), .shadow)
    XCTAssertEqual(DanmakuGlyphStyle.shadow.resolved(maximumFPS: 60), .shadow)
    XCTAssertEqual(DanmakuGlyphStyle.outline.resolved(maximumFPS: 120), .outline)
  }
}
