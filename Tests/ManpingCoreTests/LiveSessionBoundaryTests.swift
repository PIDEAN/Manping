import Foundation
import XCTest

@testable import ManpingCore

private struct BoundaryCredentials: AuthCredentialStore {
  func load() -> [HTTPCookie] { LiveContractFixture.cookies(identity: .appAuthorized) }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { LiveContractFixture.token(identity: .appAuthorized) }
  func saveToken(_ token: AppToken?) {}
  func clear() {}
}
private actor BoundaryTransport: AuthTransport {
  private let fixture = LiveContractFixture()
  private(set) var businessRequests: [URLRequest] = []
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    if request.httpMethod == "POST" { businessRequests.append(request) }
    if request.url?.path == "/x/relation/modify" {
      return AuthHTTPResponse(
        body: Data(#"{"code":0,"data":{}}"#.utf8),
        response: HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    return try await fixture.send(request)
  }
}
private actor DispatchGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  func pause() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      for observer in observers { observer.resume() }
      observers = []
    }
  }
  func waitReady() async {
    if continuation != nil { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

/// A public-delivery identity callback that reports early completion instead of hanging if
/// the outer check is accidentally removed. Its suspension ignores cancellation deliberately.
private actor DeliveryIdentityProbe {
  private let target: Int
  private var count = 0
  private var entered = false
  private var finished = false
  private var continuation: CheckedContinuation<Bool, Never>?
  private var observers: [CheckedContinuation<Bool, Never>] = []
  init(target: Int) { self.target = target }
  func check() async -> Bool {
    count += 1
    guard count == target else { return true }
    entered = true
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      for observer in observers { observer.resume(returning: true) }
      observers = []
    }
  }
  func waitForBoundaryOrFinish() async -> Bool {
    if entered { return true }
    if finished { return false }
    return await withCheckedContinuation { observers.append($0) }
  }
  func finish() {
    finished = true
    for observer in observers { observer.resume(returning: entered) }
    observers = []
  }
  func release(identityMatches: Bool = true) {
    continuation?.resume(returning: identityMatches)
    continuation = nil
  }
}

final class LiveSessionBoundaryTests: XCTestCase, @unchecked Sendable {
  private func context(state: AuthorizationState = .appAuthorized, generation: UInt64 = 1)
    -> LiveInteractionContext
  {
    LiveInteractionContext(
      identity: AuthSnapshot(epoch: 1, identityRevision: 1, state: state, token: nil),
      accountMid: state == .needsLogin ? nil : 900001, roomID: 5000, anchorID: 900010,
      generation: generation)
  }
  func testLiveTransportTaskRechecksPaidLifetimeIdentityAndCancellationAfterDispatchBarrier()
    async throws
  {
    for change in ["paid-off", "retire", "epoch", "revision", "cancel"] {
      let transport = BoundaryTransport()
      let dispatch = DispatchGate()
      let service = BiliService(transport: transport, credentials: BoundaryCredentials())
      try await service.restoreCookies()
      let source = LiveGiftPolicySource(
        LiveGiftPolicy(allowPaid: true, fixedGoldPrices: [100: 100]))
      let session = LiveInteractionSession(
        service: service, gate: LiveMutationGate(enabled: [.sendGold]),
        policySource: source, receipts: LiveContractFixture.receiptPolicy)
      let context = LiveInteractionContext(
        identity: await service.authSnapshot(), accountMid: await service.accountMid(),
        roomID: 5000, anchorID: 900010, generation: 1)
      await session.bind(context)
      let gift = LiveGift(
        .object(["id": .integer(100), "price": .integer(100), "coin_type": .string("gold")]))!
      let quote = try await session.makeQuote(gift: gift, quantity: 1, expected: context)
      let confirmation = try await session.confirmGift(quote, expected: context)
      await service.setTransportDispatchBarrierForTesting { request in
        if request.httpMethod == "POST" { await dispatch.pause() }
      }
      let task = Task { try await session.sendGift(confirmation, expected: context) }
      await dispatch.waitReady()
      switch change {
      case "paid-off": source.update(LiveGiftPolicy())
      case "retire": session.lifetime.retire()
      case "epoch": _ = await service.beginLogin()
      case "revision": try await service.restoreCookies()
      default: task.cancel()
      }
      await dispatch.release()
      do {
        try await task.value
        XCTFail("Old gift escaped dispatch boundary: \(change)")
      } catch {}
      let requests = await transport.businessRequests
      XCTAssertTrue(requests.isEmpty, change)
      for record in await session.pendingGifts() {
        await session.acknowledgeGiftChecked(record.nonce)
      }
    }
  }
  func testFollowingTransportTaskRechecksLifetimeIdentityAndCancellationAfterDispatchBarrier()
    async throws
  {
    for change in ["retire", "epoch", "revision", "cancel"] {
      let transport = BoundaryTransport()
      let dispatch = DispatchGate()
      let service = BiliService(transport: transport, credentials: BoundaryCredentials())
      try await service.restoreCookies()
      let session = LiveInteractionSession(service: service)
      let context = LiveInteractionContext(
        identity: await service.authSnapshot(), accountMid: await service.accountMid(),
        roomID: 5000, anchorID: 900010, generation: 1)
      await session.bind(context)
      await service.setTransportDispatchBarrierForTesting { request in
        if request.httpMethod == "POST" { await dispatch.pause() }
      }
      let task = Task { try await session.setFollowing(true, expected: context) }
      await dispatch.waitReady()
      switch change {
      case "retire": session.lifetime.retire()
      case "epoch": _ = await service.beginLogin()
      case "revision": try await service.restoreCookies()
      default: task.cancel()
      }
      await dispatch.release()
      do {
        try await task.value
        XCTFail("Old follow escaped dispatch boundary: \(change)")
      } catch {}
      let requests = await transport.businessRequests
      XCTAssertTrue(requests.isEmpty, change)
    }
  }
  func testReadPublicDeliveryRechecksAnonymousBindingIdentityAndCancellation() async throws {
    try await assertDeliveryBoundary(following: false)
  }
  func testFollowingPublicDeliveryRechecksBindingIdentitySlotAndCancellation() async throws {
    try await assertDeliveryBoundary(following: true)
  }
  private func assertDeliveryBoundary(following: Bool) async throws {
    for change in ["bind", "shutdown", "shutdown-rebind", "cancel", "identity"] {
      let probe = DeliveryIdentityProbe(target: following ? 3 : 4)
      let response = try LiveEnvelope.parse(Data(#"{"code":0,"message":"","data":{}}"#.utf8))
      let session = LiveInteractionSession(
        prepare: { _, _, _ in { response } },
        identityCurrent: { _ in await probe.check() }, follow: { _, _ in })
      let expected = context(state: following ? .appAuthorized : .needsLogin)
      await session.bind(expected)
      let task = Task { () -> Result<Void, Error> in
        let result: Result<Void, Error>
        do {
          if following {
            try await session.setFollowing(true, expected: expected)
          } else {
            _ = try await session.read(.dmConfig, fields: ["room_id": "5000"], expected: expected)
          }
          result = .success(())
        } catch { result = .failure(error) }
        await probe.finish()
        return result
      }
      guard await probe.waitForBoundaryOrFinish() else {
        _ = await task.value
        XCTFail("Public delivery omitted outer identity check")
        continue
      }
      switch change {
      case "bind": await session.bind(context(state: expected.identity.state, generation: 2))
      case "shutdown": await session.shutdown()
      case "shutdown-rebind":
        await session.shutdown()
        await session.bind(expected)
      case "cancel": task.cancel()
      default: break
      }
      await probe.release(identityMatches: change != "identity")
      let result = await task.value
      if case .success = result { XCTFail("Old result escaped public delivery: \(change)") }
    }
  }
  func testAnonymousReadStillSucceedsWithPublicDeliveryChecks() async throws {
    let response = try LiveEnvelope.parse(Data(#"{"code":0,"message":"","data":{"value":1}}"#.utf8))
    let session = LiveInteractionSession(prepare: { _, _, _ in { response } })
    let expected = context(state: .needsLogin)
    await session.bind(expected)
    let result = try await session.read(.dmConfig, fields: ["room_id": "5000"], expected: expected)
    XCTAssertEqual(result, response)
  }
}
