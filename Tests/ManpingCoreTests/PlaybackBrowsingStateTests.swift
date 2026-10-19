import XCTest
@testable import ManpingCore

final class PlaybackBrowsingStateTests: XCTestCase {
  private let player = UUID(), generation = UUID()
  private func binding(media: String = "av100", epoch: UInt64 = 1, revision: UInt64 = 2,
    player: UUID? = nil, generation: UUID? = nil) -> PlaybackBrowsingState.Binding {
    .init(player: player ?? self.player, media: media, generation: generation ?? self.generation,
      epoch: epoch, revision: revision)
  }
  func testOriginallyPausedRemainsPaused() {
    var state = PlaybackBrowsingState()
    state.enter(binding: binding(), depth: 2, playing: false)
    XCTAssertEqual(state.returnToPlayback(binding: binding(), depth: 2, playbackVisible: true), false)
    XCTAssertFalse(state.isBrowsing)
  }
  func testLoadingIntentSurvivesNestedBackAndForward() {
    var state = PlaybackBrowsingState()
    state.enter(binding: binding(), depth: 1, playing: true)
    state.enter(binding: binding(), depth: 2, playing: false)
    XCTAssertEqual(state.suspension?.depth, 1)
    XCTAssertNil(state.returnToPlayback(binding: binding(), depth: 2, playbackVisible: false))
    XCTAssertEqual(state.returnToPlayback(binding: binding(), depth: 1, playbackVisible: true), true)
    state.enter(binding: binding(), depth: 1, playing: true)
    XCTAssertTrue(state.isBrowsing)
    XCTAssertEqual(state.returnToPlayback(binding: binding(), depth: 1, playbackVisible: true), true)
  }
  func testReplacementRejectsEveryStaleBinding() {
    for replacement in [binding(media: "av200"), binding(epoch: 2), binding(revision: 3),
      binding(player: UUID()), binding(generation: UUID())] {
      var state = PlaybackBrowsingState()
      state.enter(binding: binding(), depth: 1, playing: true)
      XCTAssertEqual(state.returnToPlayback(binding: replacement, depth: 1, playbackVisible: true), false)
    }
  }
  func testIdentityAndQueueInvalidationRevokeResume() {
    var state = PlaybackBrowsingState()
    state.enter(binding: binding(), depth: 1, playing: true)
    state.invalidate()
    XCTAssertTrue(state.isBrowsing)
    XCTAssertNil(state.suspension)
    XCTAssertEqual(state.returnToPlayback(binding: binding(), depth: 1, playbackVisible: true), false)
  }
  func testWindowMigrationPreservesOriginalIntentAndResetsSuspension() {
    for playing in [false, true] {
      var state = PlaybackBrowsingState()
      state.enter(binding: binding(), depth: 1, playing: playing)
      XCTAssertEqual(state.finishForPlacement(binding: binding()), playing)
      XCTAssertFalse(state.isBrowsing)
      XCTAssertNil(state.finishForPlacement(binding: binding()))
    }
  }
  func testCountdownVetoAndNativeFullScreenPreserveSuspension() {
    var state = PlaybackBrowsingState()
    XCTAssertTrue(state.allowsAutomaticAdvance)
    let effects = state.enter(binding: binding(), depth: 1, playing: true)
    XCTAssertTrue(effects.cancelNextPlayback)
    XCTAssertTrue(effects.pause)
    XCTAssertFalse(state.allowsAutomaticAdvance)
    let suspension = state.suspension
    XCTAssertNil(state.presentationChanged(.nativeFullScreen, binding: binding()))
    XCTAssertEqual(state.suspension, suspension)
    XCTAssertFalse(state.allowsAutomaticAdvance)
    XCTAssertEqual(state.presentationChanged(.playbackFullScreen, binding: binding()), true)
    XCTAssertTrue(state.allowsAutomaticAdvance)
  }
  func testWrongDepthNeverResumesAndNewMediaClearsRecord() {
    var state = PlaybackBrowsingState()
    state.enter(binding: binding(), depth: 2, playing: true)
    XCTAssertEqual(state.returnToPlayback(binding: binding(), depth: 1, playbackVisible: true), false)
    state.enter(binding: binding(), depth: 1, playing: true)
    state.reset()
    XCTAssertNil(state.suspension)
    XCTAssertFalse(state.isBrowsing)
  }
}
