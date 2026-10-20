#if DEBUG
import ManpingCore
import XCTest

@testable import ManpingApp

private final class NoCredentials: AuthCredentialStore, @unchecked Sendable {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private struct Offline: AuthTransport {
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse { throw URLError(.notConnectedToInternet) }
}

/// Navigation stack behaviour of AppModel, without playback or windows.
@MainActor final class NavigationTests: XCTestCase {
  private func model() -> AppModel {
    AppModel(probeService: BiliService(transport: Offline(), credentials: NoCredentials()))
  }

  func testBackAndForwardWalkTheOverlayStack() {
    let app = model()
    app.openOverlay(.userSpace(1))
    app.openOverlay(.search("山野"))
    XCTAssertEqual(app.overlays, [.userSpace(1), .search("山野")])
    app.goBack()
    XCTAssertEqual(app.currentOverlay, .userSpace(1))
    XCTAssertTrue(app.canGoForward)
    app.goForward()
    XCTAssertEqual(app.currentOverlay, .search("山野"))
    XCTAssertFalse(app.canGoForward)
  }

  func testOpeningSomethingNewDropsTheForwardHistory() {
    let app = model()
    app.openOverlay(.userSpace(1))
    app.openOverlay(.userSpace(2))
    app.goBack()
    XCTAssertTrue(app.canGoForward)
    app.openOverlay(.history)
    XCTAssertFalse(app.canGoForward, "a new destination ends the forward history")
    XCTAssertEqual(app.overlays, [.userSpace(1), .history])
  }

  func testSpaceFromPlaybackWithoutPlaybackIsAPlainOpen() {
    let app = model()
    app.openSpaceKeepingPlayback(42)
    XCTAssertEqual(app.currentOverlay, .userSpace(42))
    XCTAssertFalse(app.compactPlayer, "nothing was playing, so no mini window")
    app.openSpaceKeepingPlayback(0)
    XCTAssertEqual(app.overlays.count, 1, "an unknown user opens nothing")
  }
}
#endif
