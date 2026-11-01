#if DEBUG
import ManpingCore
import XCTest

@testable import ManpingApp

private struct BrowseNoCredentials: AuthCredentialStore {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private struct BrowseOffline: AuthTransport {
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse { throw URLError(.notConnectedToInternet) }
}

private actor BrowseResponseGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var released = false
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuations.append($0) }
  }
  func release() {
    released = true
    for continuation in continuations { continuation.resume() }
    continuations = []
  }
}

@MainActor final class BrowseFeedModelTests: XCTestCase {
  private func service() -> BiliService {
    BiliService(transport: BrowseOffline(), credentials: BrowseNoCredentials())
  }

  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for the feed task")
  }

  func testSameActivationKeepsLoadedRowsAndCursorWithoutAnotherRequest() async throws {
    let feed = BrowseFeedModel(service: service())
    await settle()
    var calls = 0
    let loader: BrowseFeedModel.Loader = { _ in
      calls += 1
      return BrowseVideoPage(items: [Video(bvid: "BV-retained", title: "Retained")], nextCursor: "next")
    }
    feed.activate(key: "recommended", refreshToken: 0, loader: loader)
    try await eventually { !feed.state.isLoading && feed.state.items.count == 1 }
    for _ in 0..<20 { feed.activate(key: "recommended", refreshToken: 0, loader: loader) }
    await settle()
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(feed.state.nextCursor, "next")
    XCTAssertEqual(feed.state.items.first?.bvid, "BV-retained")
    feed.deactivate()
  }

  func testIdentityRefreshClearsEveryCachedSectionAndRejectsLateOldRows() async throws {
    let service = service(), gate = BrowseResponseGate()
    let feed = BrowseFeedModel(service: service)
    await settle()
    let initial = await service.authSnapshot()
    var calls = 0
    let oldLoader: BrowseFeedModel.Loader = { _ in
      let identity = await service.authSnapshot()
      calls += 1
      await gate.wait()
      return BrowseVideoPage(items: [Video(bvid: "account-\(identity.epoch)", title: "Account scoped")], nextCursor: nil)
    }
    feed.activate(key: "recommended", refreshToken: 0) { _ in
      BrowseVideoPage(items: [Video(bvid: "cached-old-account", title: "Old cached section")], nextCursor: nil)
    }
    try await eventually { !feed.state.isLoading && !feed.state.items.isEmpty }
    feed.activate(key: "popular", refreshToken: 0, loader: oldLoader)
    try await eventually { calls == 1 }
    _ = await service.beginLogin()
    // The replacement loader is still suspended. No old account rows may remain visible.
    try await eventually { calls == 2 && feed.state.items.isEmpty && feed.state.isLoading }
    await gate.release()
    try await eventually { !feed.state.isLoading && feed.state.items.count == 1 }
    XCTAssertNotEqual(feed.state.items.first?.bvid, "account-\(initial.epoch)")
    feed.activate(key: "recommended", refreshToken: 0) { _ in
      BrowseVideoPage(items: [Video(bvid: "new-account", title: "New account")], nextCursor: nil)
    }
    try await eventually { !feed.state.isLoading && feed.state.items.first?.bvid == "new-account" }
    XCTAssertEqual(feed.state.items.map(\.bvid), ["new-account"], "a cached tab cannot resurrect old identity rows")
    feed.deactivate()
  }

  func testIdentityRefreshUpdatesARetainedFeedWithoutChangingTheNavigationToken() async throws {
    let service = service(), gate = BrowseResponseGate()
    let feed = BrowseFeedModel(service: service)
    await settle()
    let initial = await service.authSnapshot()
    var calls = 0
    feed.activate(key: "recommended", refreshToken: 7) { _ in
      let identity = await service.authSnapshot()
      calls += 1
      if identity.epoch != initial.epoch { await gate.wait() }
      return BrowseVideoPage(items: [Video(bvid: "account-\(identity.epoch)", title: "Account scoped")], nextCursor: nil)
    }
    try await eventually { !feed.state.isLoading && feed.state.items.count == 1 }
    _ = await service.beginLogin()
    try await eventually { calls == 2 && feed.state.items.isEmpty }
    await gate.release()
    try await eventually { !feed.state.isLoading && feed.state.items.count == 1 }
    XCTAssertNotEqual(feed.state.items.first?.bvid, "account-\(initial.epoch)")
    XCTAssertEqual(calls, 2)
    feed.deactivate()
  }

  func testReleasedBrowsingFeedsDoNotAccumulateIdentityObservers() async throws {
    let service = service()
    for _ in 0..<20 {
      var feed: BrowseFeedModel? = BrowseFeedModel(service: service)
      weak let released = feed
      await settle()
      feed?.activate(key: "recommended", refreshToken: 0) { _ in
        BrowseVideoPage(items: [Video(bvid: "fixture", title: "Fixture")], nextCursor: nil)
      }
      try await eventually { feed?.state.isLoading == false }
      feed?.deactivate()
      feed = nil
      try await eventually { released == nil }
    }
  }
}
#endif
