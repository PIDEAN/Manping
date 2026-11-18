import XCTest
@testable import ManpingCore

final class PlaybackBookmarkTests: XCTestCase {
  @MainActor func testReopenUsesLatestMatchingAccountAndPartAfterRestart() async {
    let preferences = MemoryPreferences()
    let store = PlaybackBookmarks(defaults: preferences)
    store.save(.init(owner: 7, aid: 1, cid: 12, seconds: 91, updated: 1))
    store.save(.init(owner: 7, aid: 1, cid: 12, seconds: 37, updated: 3))
    let reopened = PlaybackBookmarks(defaults: preferences)
    let history = PlaybackBookmark(owner: 7, aid: 1, cid: 12, seconds: 48, updated: 2)
    XCTAssertEqual(reopened.latestPart(owner: 7, aid: 1), 12)
    XCTAssertEqual(reopened.start(owner: 7, aid: 1, cid: 12, duration: 120, history: history), 37)
    XCTAssertEqual(reopened.start(owner: 0, aid: 1, cid: 12, duration: 120, history: history), 0)
    XCTAssertEqual(reopened.start(owner: 8, aid: 1, cid: 12, duration: 120, history: history), 0)
    XCTAssertEqual(reopened.start(owner: 7, aid: 1, cid: 11, duration: 120, history: history), 0)
    XCTAssertEqual(reopened.start(owner: 7, aid: 2, cid: 12, duration: 120, history: history), 0)
    XCTAssertEqual(reopened.start(owner: nil, aid: 1, cid: 12, duration: 120, history: history), 0)
  }
  @MainActor func testNewerHistoryCompletionAndInvalidOffsets() async {
    let store = PlaybackBookmarks(defaults: MemoryPreferences())
    store.save(.init(owner: 7, aid: 1, cid: 12, seconds: 37, updated: 3))
    for (seconds, expected) in [(91, 91.0), (-1, 0), (0, 0), (120, 0), (121, 0)] {
      let row = PlaybackBookmark(owner: 7, aid: 1, cid: 12, seconds: seconds, updated: 4)
      XCTAssertEqual(store.start(owner: 7, aid: 1, cid: 12, duration: 120, history: row), expected)
    }
    let stale = PlaybackBookmark(owner: 7, aid: 1, cid: 12, seconds: 37, updated: 1)
    store.save(.init(owner: 7, aid: 1, cid: 12, seconds: 0, updated: 5))
    XCTAssertNil(store.latestPart(owner: 7, aid: 1))
    XCTAssertEqual(store.start(owner: 7, aid: 1, cid: 12, duration: 120, history: stale), 0)
  }
}
