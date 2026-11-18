import XCTest
@testable import ManpingApp
@testable import ManpingCore

@MainActor private final class WatchTestClock: WatchProgressSource {
  var time = 37.9
  var paused = false
  var eofReached = false
  var hasPlaybackSample = true
}

final class WatchProgressReporterTests: XCTestCase {
  private let video = WatchProgressReporter.Item(aid: 1, cid: 2)
  private func account(_ id: UInt64) -> AuthSnapshot {
    AuthSnapshot(epoch: id, identityRevision: id, state: .appAuthorized, token: nil)
  }

  @MainActor func testFailedTickRetriesOnSameSecondCloseAndSuccessfulTickDeduplicates() async {
    var attempts: [Int] = [], errors: [String] = []
    let reporter = WatchProgressReporter(enabled: { true }, checkpoint: { _, _, _ in }, feedback: {
      if let error = $0 { errors.append(error) }
    }, submit: { _, seconds, _ in
      attempts.append(seconds)
      if attempts.count == 1 { throw BiliError.api(-1, "fixture") }
    })
    let clock = WatchTestClock()
    reporter.begin(video, player: clock, identity: account(1))
    reporter.sample(final: false)
    await reporter.waitForReports()
    reporter.flush()
    await reporter.waitForReports()
    reporter.begin(video, player: clock, identity: account(1))
    reporter.flush()
    await reporter.waitForReports()
    XCTAssertEqual(attempts, [37, 37])
    XCTAssertEqual(errors.count, 1)
    reporter.identityChanged(to: account(2))
    reporter.begin(video, player: clock, identity: account(2))
    reporter.flush()
    await reporter.waitForReports()
    XCTAssertEqual(attempts, [37, 37, 37])
  }

  @MainActor func testInFlightTickPreservesLatestRewindIncludingFinalFlush() async {
    var attempts: [Int] = []
    let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
    let (release, releaseSignal) = AsyncStream<Void>.makeStream()
    let reporter = WatchProgressReporter(enabled: { true }, checkpoint: { _, _, _ in }, feedback: { _ in },
      submit: { _, seconds, _ in
        attempts.append(seconds)
        if attempts.count == 1 {
          enteredSignal.yield()
          for await _ in release { break }
        }
      })
    let clock = WatchTestClock()
    reporter.begin(video, player: clock, identity: account(1))
    reporter.sample(final: false)
    for await _ in entered { break }
    clock.time = 99; reporter.sample(final: false)
    clock.time = 18; clock.paused = true; reporter.flush()
    releaseSignal.yield()
    await reporter.waitForReports()
    XCTAssertEqual(attempts, [37, 18])
  }

  @MainActor func testPendingOldAccountDiscardedAndLateSuccessCannotConfirmNewAccount() async {
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, resume) = AsyncStream<Void>.makeStream()
    var attempts: [UInt64] = [], confirmed: [UInt64] = []
    let reporter = WatchProgressReporter(enabled: { true }, checkpoint: { _, _, _ in }, feedback: { _ in },
      submit: { _, _, identity in
        attempts.append(identity.epoch)
        if attempts.count == 1 {
          signal.yield()
          for await _ in release { break }
        }
      })
    reporter.onConfirmed = { _, _, identity in confirmed.append(identity.epoch) }
    let clock = WatchTestClock()
    reporter.begin(video, player: clock, identity: account(1))
    reporter.sample(final: false)
    for await _ in entered { break }
    clock.time = 65; reporter.flush()
    reporter.identityChanged(to: account(2))
    clock.time = 37
    reporter.begin(video, player: clock, identity: account(2)); reporter.flush()
    resume.yield()
    await reporter.waitForReports()
    XCTAssertEqual(attempts, [1, 2])
    XCTAssertEqual(confirmed, [2])
  }

  @MainActor func testFinalTransportFailureGetsOneRetryAndAuthFailureNeedsNewCredentials() async {
    for transportFailure in [true, false] {
      var attempts = 0, errors: [String] = []
      let reporter = WatchProgressReporter(enabled: { true }, checkpoint: { _, _, _ in },
        feedback: { if let error = $0 { errors.append(error) } },
        submit: { _, _, _ in
          attempts += 1
          if transportFailure { throw URLError(.timedOut) }
          throw AuthFailure.needsLogin
        })
      let clock = WatchTestClock()
      reporter.begin(video, player: clock, identity: account(1)); reporter.flush()
      await reporter.waitForReports()
      XCTAssertEqual(attempts, transportFailure ? 2 : 1)
      if !transportFailure { XCTAssertTrue(errors.first?.contains("重新扫码") == true) }
    }
  }
  @MainActor func testLocalCheckpointWithoutRemoteAndPausedClose() async {
    var enabled = false, checkpoints: [Int] = [], attempts: [Int] = []
    let reporter = WatchProgressReporter(enabled: { enabled }, checkpoint: { _, _, seconds in checkpoints.append(seconds) },
      feedback: { _ in }, submit: { _, seconds, _ in attempts.append(seconds) })
    let clock = WatchTestClock()
    reporter.begin(video, player: clock, identity: account(1))
    clock.hasPlaybackSample = false; reporter.sample(final: false)
    clock.hasPlaybackSample = true; clock.paused = true; reporter.sample(final: false)
    reporter.flush()
    await reporter.waitForReports()
    XCTAssertEqual(checkpoints, [37]); XCTAssertTrue(attempts.isEmpty)
    enabled = true
    reporter.begin(video, player: clock, identity: account(1)); reporter.flush()
    await reporter.waitForReports()
    XCTAssertEqual(attempts, [37])
  }
}
