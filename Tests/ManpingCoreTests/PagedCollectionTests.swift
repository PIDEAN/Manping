import XCTest

@testable import ManpingCore

private actor PageRequests {
  var pages: [Int] = []
  var failures = 0
  func load(_ page: Int) throws -> PageBatch<Video> {
    pages.append(page)
    if failures > 0 {
      failures -= 1
      throw URLError(.notConnectedToInternet)
    }
    return PageBatch(
      items: [Video(bvid: "shared", title: "shared"), Video(bvid: "page-\(page)", title: "page")],
      hasMore: page < 2)
  }
  func failOnce() { failures = 1 }
  func recorded() -> [Int] { pages }
}
private actor SuspendedPage {
  var reply: CheckedContinuation<PageBatch<Video>, Never>?
  var started: CheckedContinuation<Void, Never>?
  func load() async -> PageBatch<Video> {
    await withCheckedContinuation { continuation in
      reply = continuation
      started?.resume()
      started = nil
    }
  }
  func waitForStart() async {
    if reply != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func finish() {
    reply?.resume(returning: PageBatch(items: [Video(bvid: "late", title: "late")], hasMore: false))
    reply = nil
  }
}
final class PagedCollectionTests: XCTestCase {
  @MainActor func testDeduplicatesPagesAndStopsAtEnd() async {
    let requests = PageRequests()
    let collection = PagedCollection<Video>()
    await collection.reset { try await requests.load($0) }
    await collection.loadNext()
    await collection.loadNext()
    XCTAssertEqual(collection.items.map(\.id), ["shared", "page-1", "page-2"])
    XCTAssertFalse(collection.hasMore)
    let pages = await requests.recorded()
    XCTAssertEqual(pages, [1, 2])
  }
  @MainActor func testFailureRetriesTheSamePage() async {
    let requests = PageRequests()
    await requests.failOnce()
    let collection = PagedCollection<Video>()
    await collection.reset { try await requests.load($0) }
    XCTAssertNotNil(collection.error)
    XCTAssertFalse(collection.isLoading)
    await collection.loadNext()
    XCTAssertNil(collection.error)
    XCTAssertEqual(collection.items.count, 2)
    let pages = await requests.recorded()
    XCTAssertEqual(pages, [1, 1])
  }
  @MainActor func testResetRejectsUncooperativeLateResponseAndConcurrentLoad() async {
    let suspended = SuspendedPage()
    let collection = PagedCollection<Video>()
    let old = Task { await collection.reset { _ in await suspended.load() } }
    await suspended.waitForStart()
    // This must not issue a second request while the first is pending.
    await collection.loadNext()
    await collection.reset { _ in
      PageBatch(items: [Video(bvid: "new", title: "new")], hasMore: false)
    }
    await suspended.finish()
    await old.value
    XCTAssertEqual(collection.items.map(\.id), ["new"])
    XCTAssertFalse(collection.isLoading)
    XCTAssertNil(collection.error)
  }
}
