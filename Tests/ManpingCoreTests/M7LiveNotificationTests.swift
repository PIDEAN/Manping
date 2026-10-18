import XCTest
@testable import ManpingCore

final class M7LiveNotificationTests: XCTestCase {
  private func room(_ id: Int64) -> M7MomentNotification {
    M7MomentNotification(id: "live-\(id)", title: "房间 \(id)", publisher: "主播 \(id) 开播了", page: "live", mediaID: String(id))
  }

  func testFirstCheckIsASilentBaseline() {
    let plan = M7LiveNotificationPolicy.plan([room(1), room(2)], previousIDs: nil)
    XCTAssertTrue(plan.notifications.isEmpty)
    XCTAssertEqual(plan.rememberedIDs, ["live-1", "live-2"])
  }

  func testOnlyNewlyLiveRoomsNotifyAndAtMostThree() {
    let previous = ["live-1", "live-2"]
    let plan = M7LiveNotificationPolicy.plan([room(1), room(3), room(4), room(5), room(6), room(3)], previousIDs: previous)
    XCTAssertEqual(plan.notifications.map(\.id), ["live-3", "live-4", "live-5"])
    // Room 2 went offline: forgotten, so its next broadcast notifies again.
    XCTAssertEqual(plan.rememberedIDs, ["live-1", "live-3", "live-4", "live-5", "live-6"])
    let again = M7LiveNotificationPolicy.plan([room(1), room(2)], previousIDs: plan.rememberedIDs)
    XCTAssertEqual(again.notifications.map(\.id), ["live-2"])
  }

  func testLiveOnlyConfigurationHasAScopeAndLiveDeliveriesOpen() {
    let configuration = M7NotificationConfiguration(enabled: true, moments: false, live: true, identityID: "fixture-account", fixture: false)
    let scope = try! XCTUnwrap(configuration.scope)
    let delivery = M7NotificationDelivery(identifier: M7NotificationIdentityPolicy.prefix(scope: scope) + "live-7.fixture",
      scope: scope, moment: room(7))
    XCTAssertTrue(M7NotificationIdentityPolicy.canOpen(delivery, configuration: configuration))
    // Neither feature on: no scope, nothing opens.
    let off = M7NotificationConfiguration(enabled: true, moments: false, live: false, identityID: "fixture-account", fixture: false)
    XCTAssertNil(off.scope)
    XCTAssertFalse(M7NotificationIdentityPolicy.canOpen(delivery, configuration: off))
    // Fixtures never get a scope.
    XCTAssertNil(M7NotificationConfiguration(enabled: true, moments: false, live: true, identityID: "a", fixture: true).scope)
  }

  func testEachKindOpensAndSurvivesOnlyWithItsOwnSwitch() {
    let liveOnly = M7NotificationConfiguration(enabled: true, moments: false, live: true, identityID: "a", fixture: false)
    let momentsOnly = M7NotificationConfiguration(enabled: true, moments: true, live: false, identityID: "a", fixture: false)
    let scope = liveOnly.scope!
    XCTAssertEqual(scope, momentsOnly.scope)
    let video = M7MomentNotification(id: "900", title: "t", publisher: "p", page: "video", mediaID: "BV1fK4y1t7hj")
    let videoDelivery = M7NotificationDelivery(identifier: M7NotificationIdentityPolicy.prefix(scope: scope) + "900.x", scope: scope, moment: video)
    let liveDelivery = M7NotificationDelivery(identifier: M7NotificationIdentityPolicy.prefix(scope: scope) + "live-7.x", scope: scope, moment: room(7))
    XCTAssertFalse(M7NotificationIdentityPolicy.canOpen(videoDelivery, configuration: liveOnly))
    XCTAssertTrue(M7NotificationIdentityPolicy.canOpen(liveDelivery, configuration: liveOnly))
    XCTAssertTrue(M7NotificationIdentityPolicy.canOpen(videoDelivery, configuration: momentsOnly))
    XCTAssertFalse(M7NotificationIdentityPolicy.canOpen(liveDelivery, configuration: momentsOnly))
    let ids = [videoDelivery.identifier, liveDelivery.identifier]
    XCTAssertEqual(M7NotificationIdentityPolicy.removalIDs(ids, configuration: liveOnly), [videoDelivery.identifier])
    XCTAssertEqual(M7NotificationIdentityPolicy.removalIDs(ids, configuration: momentsOnly), [liveDelivery.identifier])
  }
}
