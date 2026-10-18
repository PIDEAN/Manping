import Foundation
import XCTest
@testable import ManpingCore

final class M7MpvRuntimeTests: XCTestCase {
  func testIPCEncodesURLAsDataAndRejectsInvalidCommands() throws {
    let url = "https://example.invalid/video?text=\"a\"&x=1\nsecond"
    let data = try MpvRuntimePlan.ipcData(command: ["loadfile", url], requestID: 9)
    XCTAssertEqual(data.last, 10)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["command"] as? [String], ["loadfile", url])
    XCTAssertEqual(object["request_id"] as? Int, 9)
    XCTAssertThrowsError(try MpvRuntimePlan.ipcData(command: [], requestID: 1))
    XCTAssertThrowsError(try MpvRuntimePlan.ipcData(command: ["bad\0"], requestID: 1))
  }
  func testSeekModesRejectNonfinitePositions() {
    XCTAssertNil(MpvRuntimePlan.seek(.infinity, precise: true))
    XCTAssertEqual(MpvRuntimePlan.seek(-1, precise: false), ["seek", "0.0", "absolute+keyframes"])
    XCTAssertEqual(MpvRuntimePlan.seek(12, precise: true), ["seek", "12.0", "absolute+exact"])
  }
  func testDanmakuSpeedChangesTravelTimeWithoutMovingPublicationTime() {
    let timeline = DanmakuTimeline(comments: [DanmakuComment(time: 10, text: "fixture")])
    XCTAssertTrue(timeline.visible(at: 9, speed: 2).isEmpty)
    XCTAssertEqual(timeline.visible(at: 12, speed: 1).first?.progress, 0.25)
    XCTAssertEqual(timeline.visible(at: 12, speed: 2).first?.progress, 0.5)
    XCTAssertTrue(timeline.visible(at: 15, speed: 2).isEmpty)
    XCTAssertEqual(timeline.visible(at: 15, speed: 0.5).count, 1)
  }
  func testCacheAndCoreAudioOptionsUseIndependentSettings() {
    var settings = MacSettings()
    let capabilities = Set(MacSettingKey.allCases)
    settings.set(.diskCache, .bool(true), capabilities: capabilities)
    settings.set(.diskCacheDirectory, .text("/tmp/mpv-cache-fixture"), capabilities: capabilities)
    settings.set(.audioExclusive, .bool(true), capabilities: capabilities)
    let properties = Dictionary(uniqueKeysWithValues: MpvRuntimePlan.properties(settings))
    XCTAssertEqual(properties["cache-on-disk"], "yes")
    XCTAssertEqual(properties["demuxer-cache-dir"], "/tmp/mpv-cache-fixture")
    XCTAssertEqual(properties["audio-exclusive"], "yes")
  }
}
