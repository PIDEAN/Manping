import XCTest
@testable import ManpingCore

final class DanmakuTimelineViewportCacheTests: XCTestCase {
  private func assertVisible(_ actual: DanmakuTimeline, equals expected: DanmakuTimeline, at time: Double,
    speed: Double = 1, file: StaticString = #filePath, line: UInt = #line) {
    let actual = actual.visible(at: time, speed: speed), expected = expected.visible(at: time, speed: speed)
    XCTAssertEqual(actual.map(\.comment), expected.map(\.comment), file: file, line: line)
    XCTAssertEqual(actual.map(\.lane), expected.map(\.lane), file: file, line: line)
    XCTAssertEqual(actual.map(\.progress), expected.map(\.progress), file: file, line: line)
  }

  func testRepeatedDurationScaleAndUnchangedWidePublicationsKeepTheLayout() {
    var source = DanmakuTimeline(comments: (0..<8_000).map { DanmakuComment(time: Double($0) / 5, text: "Line \($0)") })
    var cache = DanmakuTimeline.ViewportCache()
    let scale = DanmakuMotion.scrollingDurationScale(stageWidth: 1920, maximumFPS: 60)
    cache.update(source: source, scrollingDurationScale: scale)
    let layout = cache.timeline.layoutRevision
    for _ in 0..<100 {
      cache.update(source: source, scrollingDurationScale: scale)
      XCTAssertEqual(cache.timeline.layoutRevision, layout, "unchanged publication must not place the source again")
    }
    XCTAssertEqual(source.scrollingDurationScale, 1)
    source.setScrollingDurationScale(scale)
    let sourceLayout = source.layoutRevision
    source.setScrollingDurationScale(scale)
    XCTAssertEqual(source.layoutRevision, sourceLayout)
    assertVisible(cache.timeline, equals: source, at: 100)

    cache.update(source: source, scrollingDurationScale: 2)
    XCTAssertNotEqual(cache.timeline.layoutRevision, layout)
    let resized = cache.timeline.layoutRevision
    cache.update(source: source, scrollingDurationScale: 2)
    XCTAssertEqual(cache.timeline.layoutRevision, resized)
  }

  func testWideLiveAppendsPlaceOnlyTheNewSuffixIncludingCoalescedPublications() {
    var source = DanmakuTimeline(comments: [])
    var cache = DanmakuTimeline.ViewportCache()
    cache.update(source: source, scrollingDurationScale: 1.5)
    let layout = cache.timeline.layoutRevision
    for batch in 0..<100 {
      for index in (batch * 3)..<(batch * 3 + 3) {
        source.append(DanmakuComment(time: Double(index) / 5, mode: index % 11 == 0 ? 4 : 1, text: "Live \(index)"))
      }
      cache.update(source: source, scrollingDurationScale: 1.5)
      XCTAssertEqual(cache.timeline.layoutRevision, layout, "even multiple appends between frames must preserve existing placement")
      var expected = source
      expected.setScrollingDurationScale(1.5)
      assertVisible(cache.timeline, equals: expected, at: Double(batch * 3 + 2) / 5)
    }
  }

  func testLivePruningKeepsTheAppendCheckpointAndBoundedViewport() {
    var source = DanmakuTimeline(comments: [])
    var cache = DanmakuTimeline.ViewportCache()
    cache.update(source: source, scrollingDurationScale: 1.5)
    let layout = cache.timeline.layoutRevision
    for index in 0..<3_100 {
      source.append(DanmakuComment(time: Double(index) / 2, text: "Live \(index)"))
      cache.update(source: source, scrollingDurationScale: 1.5)
      XCTAssertEqual(cache.timeline.layoutRevision, layout)
      XCTAssertLessThanOrEqual(cache.timeline.count, 1_500)
    }
    XCTAssertTrue(cache.timeline.hasVisible(at: 1550))
    XCTAssertTrue(cache.timeline.visible(at: 1550).allSatisfy { $0.comment.time > 1500 })
  }

  func testAnEvictedAppendCheckpointRebuildsFromTheCurrentBoundedSource() {
    var source = DanmakuTimeline(comments: [DanmakuComment(time: 0, text: "Old")])
    var cache = DanmakuTimeline.ViewportCache()
    cache.update(source: source, scrollingDurationScale: 1.5)
    let oldLayout = cache.timeline.layoutRevision
    for index in 1...2_000 { source.append(DanmakuComment(time: Double(index), text: "Live \(index)")) }
    cache.update(source: source, scrollingDurationScale: 1.5)
    XCTAssertNotEqual(cache.timeline.layoutRevision, oldLayout, "a renderer that missed the retained suffix must rebuild, not combine unrelated offsets")
    var expected = source
    expected.setScrollingDurationScale(1.5)
    assertVisible(cache.timeline, equals: expected, at: 2_000)
    XCTAssertLessThanOrEqual(cache.timeline.count, 1_500)
  }

  func testSourceReplacementSpeedFilterAndDivergentAppendInvalidateTheCache() {
    let original = DanmakuTimeline(comments: [DanmakuComment(time: 0, text: "Original")])
    var source = original, cache = DanmakuTimeline.ViewportCache()
    source.append(DanmakuComment(time: 1, text: "First branch"))
    cache.update(source: source, scrollingDurationScale: 1.5)
    let first = cache.timeline.layoutRevision
    source = original
    source.append(DanmakuComment(time: 1, text: "Other branch"))
    source.append(DanmakuComment(time: 2, text: "New suffix"))
    cache.update(source: source, scrollingDurationScale: 1.5)
    XCTAssertNotEqual(cache.timeline.layoutRevision, first)
    XCTAssertEqual(cache.timeline.visible(at: 2).map(\.comment.text), ["Original", "Other branch", "New suffix"])

    let beforeSpeed = cache.timeline.layoutRevision
    source.setSpeed(0.5)
    cache.update(source: source, scrollingDurationScale: 1.5)
    XCTAssertNotEqual(cache.timeline.layoutRevision, beforeSpeed)
    var filter = DanmakuFilter()
    filter.rules = ["Other"]
    source.setFilter(filter)
    cache.update(source: source, scrollingDurationScale: 1.5)
    XCTAssertEqual(cache.timeline.visible(at: 2, speed: 0.5).map(\.comment.text), ["Original", "New suffix"])
    source.append(DanmakuComment(time: 3, text: "Other hidden"))
    let filtered = cache.timeline.layoutRevision
    cache.update(source: source, scrollingDurationScale: 1.5)
    XCTAssertEqual(cache.timeline.layoutRevision, filtered)
    XCTAssertEqual(cache.timeline.visible(at: 3, speed: 0.5).map(\.comment.text), ["Original", "New suffix"])

    source = DanmakuTimeline(comments: [DanmakuComment(time: 0, text: "Replacement")])
    cache.update(source: source, scrollingDurationScale: 1.5)
    XCTAssertEqual(cache.timeline.visible(at: 1).map(\.comment.text), ["Replacement"])
  }

  func test120HzKeepsTheOriginalSourceLayoutAcrossWidthsAndAppends() {
    var source = DanmakuTimeline(comments: [DanmakuComment(time: 0, text: "Native")])
    var cache = DanmakuTimeline.ViewportCache()
    for width in [1920.0, 3840, 2560] {
      source.append(DanmakuComment(time: 1, text: "Live"))
      cache.update(source: source, scrollingDurationScale: DanmakuMotion.scrollingDurationScale(stageWidth: width, maximumFPS: 120))
      XCTAssertEqual(cache.timeline.layoutRevision, source.layoutRevision)
      XCTAssertEqual(cache.timeline.scrollingDurationScale, 1)
      assertVisible(cache.timeline, equals: source, at: 2)
    }
  }
}
