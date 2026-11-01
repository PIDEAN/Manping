import XCTest
import ManpingCore
@testable import ManpingApp

final class DanmakuRendererTests: XCTestCase {
  func testOneXBackingSupersamplesWithoutChangingPointGeometry() {
    let one = GlyphRaster(fontSize: 24, scale: 1, atlasSize: 1024, style: .outline)
    let two = GlyphRaster(fontSize: 24, scale: 2, atlasSize: 1024, style: .outline)
    XCTAssertEqual(one, two)
    XCTAssertEqual(Double(one.pixelFontSize) / one.scale, 24)
    XCTAssertEqual(one.pixelFontSize, 48)
    let shadow = GlyphRaster(fontSize: 24, scale: 2, atlasSize: 1024, style: .shadow)
    XCTAssertGreaterThan(shadow.pad, one.pad)
  }
  func testMotionProbeOnlyCountsPresentedFramesAndExposesSkippedSlots() {
    DanmakuMotionProbe.enable()
    DanmakuMotionProbe.record(host: 1, clock: 1, speed: 1, playing: true, presentedHost: 1.001)
    DanmakuMotionProbe.skipped(.inFlight)
    DanmakuMotionProbe.skipped(.render)
    DanmakuMotionProbe.skipped(.unconfirmedPresent)
    DanmakuMotionProbe.record(host: 1 + 2.0 / 60, clock: 1 + 2.0 / 60, speed: 1, playing: true,
      presentedHost: 1.001 + 2.0 / 60)
    let result = DanmakuMotionProbe.drain()
    XCTAssertEqual(result["frames"], 1)
    XCTAssertEqual(result["fps"], 30)
    XCTAssertEqual(result["maxInterval"], 33.3)
    XCTAssertEqual(result["skippedInFlight"], 1)
    XCTAssertEqual(result["skippedRender"], 1)
    XCTAssertEqual(result["unconfirmedPresents"], 1)
    XCTAssertEqual(DanmakuMotionProbe.drain()["skippedInFlight"], 0)
  }
  func testFullscreenBlackDoesNotAffectWindowedAmbientChoice() {
    XCTAssertTrue(PlayerStageBackdrop.usesBlack(immersive: true, selection: "black"))
    XCTAssertFalse(PlayerStageBackdrop.usesBlack(immersive: true, selection: "ambient"))
    XCTAssertFalse(PlayerStageBackdrop.usesBlack(immersive: false, selection: "black"))
    XCTAssertFalse(PlayerStageBackdrop.usesBlack(immersive: false, selection: "ambient"))
  }
}
