import Foundation
import XCTest
@testable import ManpingCore

final class M7NotificationIdentityTests: XCTestCase {
  private let moment = M7MomentNotification(id: "fixture-moment", title: "Fixture", publisher: "Sample", page: "video", mediaID: "100")
  private func configuration(_ identity: String?, enabled: Bool = true, fixture: Bool = false) -> M7NotificationConfiguration {
    M7NotificationConfiguration(enabled: enabled, moments: true, identityID: identity, fixture: fixture)
  }
  private func delivery(_ identity: String) -> M7NotificationDelivery {
    let scope = configuration(identity).scope!
    return M7NotificationDelivery(identifier: M7NotificationIdentityPolicy.prefix(scope: scope) + moment.id + ".fixture-instance", scope: scope, moment: moment)
  }
  func testRestartWithAnotherAccountRemovesPreviousProcessNotificationsAndRejectsOldClick() async {
    let old = delivery("fixture-account-A")
    let current = delivery("fixture-account-B")
    let foreign = "AnotherFeature.Notification.fixture"
    let adapter = FixtureNotificationDelivery(pending: [old.identifier, foreign], delivered: [old.identifier, current.identifier, foreign])
    let controller = M7NotificationIdentityController(adapter: adapter)
    await controller.configure(configuration("fixture-account-B"))
    let pending = await adapter.pendingIDs()
    let delivered = await adapter.deliveredIDs()
    XCTAssertEqual(pending, [foreign])
    XCTAssertEqual(delivered, [current.identifier, foreign])
    let oldAllowed = await controller.canOpen(old)
    let currentAllowed = await controller.canOpen(current)
    XCTAssertFalse(oldAllowed); XCTAssertTrue(currentAllowed)
    let authorizationCount = await adapter.authorizationCount
    XCTAssertEqual(authorizationCount, 0)
  }
  func testDisabledAtStartupRemovesEveryOwnedNotificationButLeavesForeignRequests() async {
    let old = delivery("fixture-account-A")
    let current = delivery("fixture-account-B")
    let foreign = "AnotherFeature.Notification.fixture"
    let adapter = FixtureNotificationDelivery(pending: [old.identifier, foreign], delivered: [current.identifier, foreign])
    let controller = M7NotificationIdentityController(adapter: adapter)
    await controller.configure(configuration("fixture-account-B", enabled: false))
    let pending = await adapter.pendingIDs()
    let delivered = await adapter.deliveredIDs()
    XCTAssertEqual(pending, [foreign]); XCTAssertEqual(delivered, [foreign])
    let allowed = await controller.canOpen(current)
    XCTAssertFalse(allowed)
  }
  func testClickRequiresBothIdentifierScopeAndPayloadBindingAndActiveSettings() async {
    let adapter = FixtureNotificationDelivery()
    let controller = M7NotificationIdentityController(adapter: adapter)
    let a = delivery("fixture-account-A")
    let b = delivery("fixture-account-B")
    await controller.configure(configuration("fixture-account-B"))
    let mixed = M7NotificationDelivery(identifier: a.identifier, scope: b.scope, moment: moment)
    let wrongPayload = M7NotificationDelivery(identifier: b.identifier, scope: a.scope, moment: moment)
    let emptyID = M7NotificationDelivery(identifier: b.identifier, scope: b.scope,
      moment: M7MomentNotification(id: "", title: "", publisher: "", page: "video", mediaID: "100"))
    for value in [mixed, wrongPayload, emptyID] {
      let allowed = await controller.canOpen(value); XCTAssertFalse(allowed)
    }
    await controller.configure(configuration("fixture-account-B", fixture: true))
    let allowed = await controller.canOpen(b)
    XCTAssertFalse(allowed)
    let authorized = try? await controller.authorize(expectedScope: b.scope)
    XCTAssertEqual(authorized, false)
    let authorizationCount = await adapter.authorizationCount
    XCTAssertEqual(authorizationCount, 0)
  }
  func testLateDeliveryAfterIdentitySwitchRemovesItself() async throws {
    let adapter = FixtureNotificationDelivery(holdAdd: true)
    let controller = M7NotificationIdentityController(adapter: adapter)
    let a = configuration("fixture-account-A")
    await controller.configure(a)
    let moment = self.moment
    let sending = Task { try await controller.deliver(moment, expectedScope: a.scope!) }
    await adapter.waitForAdd()
    await controller.configure(configuration("fixture-account-B"))
    // Simulate a system add callback completing after the new account's enumeration and cleanup.
    await adapter.finishAdd()
    let accepted = try await sending.value
    XCTAssertFalse(accepted)
    let pending = await adapter.pendingIDs()
    let delivered = await adapter.deliveredIDs()
    XCTAssertTrue(pending.isEmpty); XCTAssertTrue(delivered.isEmpty)
  }
}

private actor FixtureNotificationDelivery: M7NotificationDeliveryAdapter {
  private var pending: [String]
  private var delivered: [String]
  private let holdAdd: Bool
  private var enteredAdd = false
  private var addWaiters: [CheckedContinuation<Void, Never>] = []
  private var addContinuation: CheckedContinuation<Void, Never>?
  private var staged: M7NotificationDelivery?
  private(set) var authorizationCount = 0
  init(pending: [String] = [], delivered: [String] = [], holdAdd: Bool = false) {
    self.pending = pending; self.delivered = delivered; self.holdAdd = holdAdd
  }
  func pendingIDs() -> [String] { pending }
  func deliveredIDs() -> [String] { delivered }
  func removeIDs(_ ids: [String]) { pending.removeAll { ids.contains($0) }; delivered.removeAll { ids.contains($0) } }
  func authorize() -> Bool { authorizationCount += 1; return true }
  func add(_ delivery: M7NotificationDelivery) async {
    enteredAdd = true; staged = delivery
    for waiter in addWaiters { waiter.resume() }; addWaiters.removeAll()
    if holdAdd { await withCheckedContinuation { addContinuation = $0 } }
    pending.append(delivery.identifier); delivered.append(delivery.identifier)
  }
  func waitForAdd() async {
    guard !enteredAdd else { return }
    await withCheckedContinuation { addWaiters.append($0) }
  }
  func finishAdd() { addContinuation?.resume(); addContinuation = nil }
}
