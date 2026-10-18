import XCTest
@testable import ManpingCore

final class PlaybackSkipTests: XCTestCase {
  func testParsesOpeningAndEndingAndIgnoresJunk() {
    let skips = PlaybackSkip.parse([
      ["materialNo": 0, "start": 1130, "end": 1239, "toastText": "即将跳过片尾", "clipType": "CLIP_TYPE_ED"],
      ["start": 16, "end": 162, "clipType": "CLIP_TYPE_OP"],
      ["start": 10, "end": 12, "clipType": "CLIP_TYPE_OP"],
      ["start": 0, "end": 2_000, "clipType": "CLIP_TYPE_OP"],
      ["start": 30, "end": 60, "clipType": "CLIP_TYPE_UNKNOWN"],
      ["clipType": "CLIP_TYPE_OP"],
    ] as [[String: Any]])
    XCTAssertEqual(skips, [PlaybackSkip(kind: .opening, start: 16, end: 162), PlaybackSkip(kind: .ending, start: 1130, end: 1239)])
    XCTAssertEqual(PlaybackSkip.parse(nil), [])
  }

  func testActiveRangeStopsOfferingNearItsEnd() {
    let skips = [PlaybackSkip(kind: .opening, start: 16, end: 162)]
    XCTAssertNil(PlaybackSkip.active(skips, at: 15.9))
    XCTAssertEqual(PlaybackSkip.active(skips, at: 20)?.kind, .opening)
    XCTAssertNil(PlaybackSkip.active(skips, at: 160))
  }
}
