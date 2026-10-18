import XCTest
@testable import ManpingCore

final class M2QueueTests: XCTestCase {
  private var videos: [Video] { (1...3).map { Video(bvid: "", title: "Video \($0)", aid: Int64($0)) } }
  func testQueueDeduplicatesAndStopsAtBothEnds() throws {
    var queue = VideoPlaybackQueue()
    XCTAssertNil(queue.current); XCTAssertEqual(queue.position, 0)
    try queue.replace([videos[0], videos[0], videos[1], videos[2]])
    XCTAssertEqual(queue.count, 3)
    XCTAssertNil(queue.previous())
    XCTAssertEqual(queue.next()?.aid, 2)
    XCTAssertEqual(queue.next()?.aid, 3)
    XCTAssertNil(queue.next()); XCTAssertEqual(queue.position, 3)
    XCTAssertEqual(queue.previous()?.aid, 2)
    XCTAssertEqual(queue.select(id: "av1")?.aid, 1)
    XCTAssertNil(queue.select(id: "av999")); XCTAssertEqual(queue.position, 1)
  }
  func testInvalidReplacementPreservesCurrentQueueAndEOFGeneration() throws {
    var queue = VideoPlaybackQueue()
    try queue.replace(videos)
    let original = queue
    XCTAssertThrowsError(try queue.replace([]))
    XCTAssertEqual(queue, original)
    XCTAssertThrowsError(try queue.replace([Video(bvid: "invalid", title: "A")]))
    XCTAssertEqual(queue, original)
    XCTAssertThrowsError(try queue.replace([Video(bvid: "BV1fixture01", title: "A", aid: -1)]))
    XCTAssertEqual(queue, original)
    let eof = queue.generation
    XCTAssertEqual(queue.next(afterEOF: eof)?.aid, 2)
    XCTAssertNil(queue.next(afterEOF: eof), "Duplicate EOF must not skip another item")
    try queue.replace(videos)
    XCTAssertNil(queue.next(afterEOF: eof), "Previous playlist callbacks are stale")
    XCTAssertEqual(queue.position, 1)
  }
  func testBoundQueueClearsOnlyOnIdentityChangeAndRejectsLateEOF() throws {
    var queue = VideoPlaybackQueue()
    let snapshot = AuthSnapshot(epoch: 1, identityRevision: 2, state: .needsLogin, token: nil)
    try queue.replace(videos, identity: PlaybackQueueIdentity(snapshot))
    let eof = queue.generation
    XCTAssertFalse(queue.invalidate(epoch: 1, revision: 2), "Initial current-identity event preserves queue")
    XCTAssertTrue(queue.invalidate(epoch: 1, revision: 3))
    XCTAssertEqual(queue.count, 0)
    XCTAssertNil(queue.next(afterEOF: eof))
    XCTAssertNil(queue.identity)
    XCTAssertFalse(queue.invalidate(epoch: 2, revision: 4))
  }
}
