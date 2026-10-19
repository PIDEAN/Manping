import XCTest
@testable import ManpingCore

final class LiveReconnectBudgetTests: XCTestCase {
  func testEightRetriesThenTerminalCallbacksCannotRearmUntilReset() {
    var budget = LiveReconnectBudget()
    XCTAssertEqual((0..<8).compactMap { _ in budget.nextDelay() }, [1, 2, 4, 8, 16, 16, 16, 16])
    XCTAssertNil(budget.nextDelay())
    XCTAssertTrue(budget.terminal)
    for _ in 0..<100 { XCTAssertNil(budget.nextDelay()) }
    XCTAssertEqual(budget.attempts, 8)
    budget.reset()
    XCTAssertFalse(budget.terminal)
    XCTAssertEqual(budget.nextDelay(), 1)
  }
  func testOnlyContinuousProgressResetsTheRecoveryBurst() {
    var budget = LiveReconnectBudget()
    _ = budget.nextDelay()
    // Old load age or one frame every 21 seconds cannot forgive the retry burst.
    for time in [100.0, 121, 142, 163] {
      budget.recordProgress(at: time, advancing: true, paused: false)
    }
    XCTAssertEqual(budget.attempts, 1)
    for time in 200...219 { budget.recordProgress(at: Double(time), advancing: true, paused: false) }
    XCTAssertEqual(budget.attempts, 1)
    budget.recordProgress(at: 220, advancing: true, paused: false)
    XCTAssertEqual(budget.attempts, 0)
  }

  func testPauseAndFrozenClockBreakTheHealthyWindow() {
    var budget = LiveReconnectBudget()
    _ = budget.nextDelay()
    for time in 0...15 { budget.recordProgress(at: Double(time), advancing: true, paused: false) }
    budget.recordProgress(at: 16, advancing: true, paused: true)
    for time in 17...35 { budget.recordProgress(at: Double(time), advancing: true, paused: false) }
    XCTAssertEqual(budget.attempts, 1)
    budget.recordProgress(at: 36, advancing: false, paused: false)
    for time in 37...56 { budget.recordProgress(at: Double(time), advancing: true, paused: false) }
    XCTAssertEqual(budget.attempts, 1)
    budget.recordProgress(at: 57, advancing: true, paused: false)
    XCTAssertEqual(budget.attempts, 0)
  }

  func testRoomEndedThenStartedCannotBypassTerminalRecovery() {
    var budget = LiveReconnectBudget()
    for _ in 0..<8 { XCTAssertNotNil(budget.nextDelay()) }
    XCTAssertNil(budget.nextDelay())
    // PREPARING may mark the room ended while the recovery burst is terminal. The next
    // LIVE must not enter LivePlaybackModel.refresh(), which explicitly resets that burst.
    XCTAssertFalse(budget.shouldRestartRoom(after: .liveEnded, roomEnded: true))
    XCTAssertFalse(budget.shouldRestartRoom(after: .liveStarted, roomEnded: true))
    for time in 0...30 { budget.recordProgress(at: Double(time), advancing: true, paused: false) }
    XCTAssertTrue(budget.terminal)
    XCTAssertFalse(budget.shouldRestartRoom(after: .liveStarted, roomEnded: true))
    // Both explicit refresh and quality change use this reset; they remain able to reopen.
    budget.reset()
    XCTAssertTrue(budget.shouldRestartRoom(after: .liveStarted, roomEnded: true))
    XCTAssertEqual(budget.nextDelay(), 1)
  }

  func testNormallyEndedRoomCanRestartWithoutDuplicateLiveEvents() {
    var budget = LiveReconnectBudget()
    _ = budget.nextDelay()
    XCTAssertFalse(budget.shouldRestartRoom(after: .liveEnded, roomEnded: true))
    XCTAssertTrue(budget.shouldRestartRoom(after: .liveStarted, roomEnded: true))
    XCTAssertFalse(budget.shouldRestartRoom(after: .liveStarted, roomEnded: false))
    XCTAssertFalse(budget.shouldRestartRoom(after: .connected, roomEnded: true))
  }

}
