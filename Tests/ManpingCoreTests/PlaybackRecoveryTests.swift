import XCTest
@testable import ManpingCore

final class PlaybackRecoveryTests: XCTestCase {
  func testStartupRetryCannotRenewDeadline() {
    var policy = PlaybackRecovery(now: 0)
    XCTAssertEqual(policy.sample(now: 15, progressing: false, paused: false), .none)
    XCTAssertEqual(policy.sample(now: 16, progressing: false, paused: false), .retry)
    XCTAssertEqual(policy.sample(now: 27, progressing: false, paused: false), .none)
    XCTAssertEqual(policy.sample(now: 28, progressing: false, paused: false), .fail)
    XCTAssertEqual(policy.terminalAt, 28)
    XCTAssertEqual(policy.sample(now: 29, progressing: true, paused: false), .none)
    XCTAssertTrue(policy.terminal)
    policy.cancel()
    XCTAssertEqual(policy.terminalAt, 28, "teardown must preserve the actual failure time")
  }

  func testExpiredAddressRetriesOnceAndStillTerminates() {
    for status in [403, 410] {
      var policy = PlaybackRecovery(now: 0)
      XCTAssertEqual(policy.sample(now: 2, progressing: false, paused: false, expired: status != 0), .retry)
      XCTAssertEqual(policy.sample(now: 4, progressing: false, paused: false, expired: true), .none)
      XCTAssertEqual(policy.sample(now: 28, progressing: false, paused: false, expired: true), .fail)
    }
  }

  func testExpiredAudioDuringVideoProgressRetriesOnceAndTerminatesStartup() {
    for status in [403, 410] {
      var policy = PlaybackRecovery(now: 0)
      for second in 1...28 {
        let action = policy.sample(now: Double(second), progressing: true, paused: false, expired: status != 0)
        XCTAssertEqual(action, second == 2 ? .retry : second == 28 ? .fail : .none)
      }
      XCTAssertFalse(policy.hasProgress, "video alone cannot establish a healthy playback session")
      XCTAssertTrue(policy.terminal)
      XCTAssertEqual(policy.sample(now: 29, progressing: true, paused: false), .none)
      XCTAssertTrue(policy.terminal, "clearing expiration cannot revive a terminal attempt")
    }
  }

  func testExpiredAudioDuringPreviouslyHealthyVideoProgressUsesMidstreamDeadline() {
    var policy = PlaybackRecovery(now: 0)
    XCTAssertEqual(policy.sample(now: 1, progressing: true, paused: false), .none)
    for second in 1...40 {
      let action = policy.sample(now: Double(second + 1), progressing: true, paused: false, expired: true)
      XCTAssertEqual(action, second == 2 ? .retry : second == 40 ? .fail : .none)
    }
    XCTAssertTrue(policy.hasProgress)
    XCTAssertTrue(policy.terminal)
  }

  func testClearingExpiredAudioWithProgressResetsWaitAndRetry() {
    var policy = PlaybackRecovery(now: 0)
    XCTAssertEqual(policy.sample(now: 2, progressing: true, paused: false, expired: true), .retry)
    XCTAssertEqual(policy.sample(now: 20, progressing: true, paused: false, expired: true), .none)
    XCTAssertEqual(policy.waitingSeconds, 20)
    XCTAssertEqual(policy.sample(now: 21, progressing: true, paused: false), .none)
    XCTAssertEqual(policy.waitingSeconds, 0)
    XCTAssertTrue(policy.hasProgress)
    for second in 22...100 {
      XCTAssertEqual(policy.sample(now: Double(second), progressing: true, paused: false), .none)
    }
    XCTAssertFalse(policy.terminal)
    XCTAssertEqual(policy.sample(now: 102, progressing: true, paused: false, expired: true), .retry,
      "a recovered session has a fresh retry for a later expiration")
  }

  func testPauseFreezesStartupDeadlineAndSeekStartsANewWait() {
    var policy = PlaybackRecovery(now: 0)
    _ = policy.sample(now: 10, progressing: false, paused: false)
    XCTAssertEqual(policy.sample(now: 100, progressing: false, paused: true), .none)
    XCTAssertEqual(policy.sample(now: 106, progressing: false, paused: false), .retry)
    policy.seek(now: 106)
    XCTAssertEqual(policy.sample(now: 121, progressing: false, paused: false), .none)
    XCTAssertEqual(policy.sample(now: 122, progressing: false, paused: false), .retry)
    policy.cancel()
    XCTAssertNil(policy.terminalAt, "cancellation is not a timed recovery failure")
    XCTAssertEqual(policy.sample(now: 1000, progressing: false, paused: false), .none)
  }

  func testTwentySecondMidstreamOutageRecoversButPersistentOutageTerminates() {
    var policy = PlaybackRecovery(now: 0)
    XCTAssertEqual(policy.sample(now: 1, progressing: true, paused: false), .none)
    XCTAssertEqual(policy.sample(now: 7, progressing: false, paused: false), .retry)
    XCTAssertEqual(policy.sample(now: 21, progressing: false, paused: false), .none)
    XCTAssertEqual(policy.sample(now: 22, progressing: true, paused: false), .none)
    XCTAssertEqual(policy.sample(now: 28, progressing: false, paused: false), .retry)
    XCTAssertEqual(policy.sample(now: 62, progressing: false, paused: false), .fail)
  }

  func testEOFFreezesWatchdogButSeekCanResumeMonitoring() {
    var policy = PlaybackRecovery(now: 0)
    XCTAssertEqual(policy.sample(now: 1, progressing: false, paused: false, ended: true), .none)
    XCTAssertEqual(policy.sample(now: 40, progressing: false, paused: false, ended: true), .none)
    policy.seek(now: 40)
    XCTAssertEqual(policy.sample(now: 56, progressing: false, paused: false), .retry)
    XCTAssertEqual(policy.sample(now: 68, progressing: false, paused: false), .fail)
    policy.seek(now: 69)
    XCTAssertTrue(policy.terminal, "seek cannot revive a failed or cancelled playback")
  }

  func testDirectCandidatesVisitThirdURLAndDoNotRecycleKnownFailures() {
    let first = PlaybackURLCandidates.Candidate(video: URL(string: "http://127.0.0.1:12001/primary/media.mp4")!)
    let second = PlaybackURLCandidates.Candidate(video: URL(string: "http://127.0.0.1:12002/primary/media.mp4")!)
    let third = PlaybackURLCandidates.Candidate(video: URL(string: "http://[::1]:12003/backup/media.mp4")!)
    var candidates = PlaybackURLCandidates()
    candidates.markLoaded(first)
    candidates.append([first, second, third, second])
    XCTAssertEqual(candidates.remaining, 2)
    XCTAssertEqual(candidates.next(), second)
    candidates.append([first, second, third])
    XCTAssertEqual(candidates.next(), third)
    XCTAssertNil(candidates.next())
    candidates.append([first, second, third])
    XCTAssertNil(candidates.next(), "background probes must not recycle failed candidates")
  }

  func testRefreshedPrimaryDoesNotHideAnUntriedBackup() {
    let primary = PlaybackURLCandidates.Candidate(video: URL(string: "https://example.invalid/video?signature=old")!)
    let backup = PlaybackURLCandidates.Candidate(video: URL(string: "https://example.invalid/video?signature=new")!)
    var candidates = PlaybackURLCandidates()
    candidates.markLoaded(primary)
    candidates.append([primary, backup])
    XCTAssertEqual(candidates.next(), backup, "full signed URLs, not hostname alone, distinguish candidates")
    XCTAssertNil(candidates.next())
  }

  func testCandidateChangesDoNotExtendTheOverallPlaybackDeadline() {
    var policy = PlaybackRecovery(now: 0)
    for time in [6.0, 12, 18, 24] {
      _ = policy.sample(now: time, progressing: false, paused: false)
      XCTAssertEqual(policy.remainingSeconds, 28 - time)
    }
    XCTAssertEqual(policy.sample(now: 28, progressing: false, paused: false), .fail)
  }

  func testRelayBudgetMergesConcurrentFailuresAndDoesNotChargeHealthyPlaybackAge() {
    let budget = RelayRetryBudget(seconds: 10)
    budget.recordFailure(from: 100, to: 104)
    budget.recordFailure(from: 102, to: 106)
    XCTAssertEqual(budget.remaining, 4)
    budget.recordFailure(from: 300, to: 303)
    XCTAssertEqual(budget.remaining, 1)
    budget.recordFailure(from: 302, to: 305)
    XCTAssertTrue(budget.exhausted)
    XCTAssertEqual(budget.remaining, 0)
  }
}
