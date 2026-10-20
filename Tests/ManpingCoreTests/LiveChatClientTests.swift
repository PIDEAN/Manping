import Foundation
import XCTest

@testable import ManpingCore

private final class ScriptLiveSocket: LiveChatSocket, @unchecked Sendable {
  private let lock = NSLock()
  private var frames: [Result<Data, Error>]
  private var pending: CheckedContinuation<Data, Error>?
  private var cancelled = false
  private var sent: [Data] = []
  let receiving: XCTestExpectation?
  let onSend: (@Sendable () async -> Void)?
  init(
    _ frames: [Result<Data, Error>], receiving: XCTestExpectation? = nil,
    onSend: (@Sendable () async -> Void)? = nil
  ) {
    self.frames = frames
    self.receiving = receiving
    self.onSend = onSend
  }
  func send(_ data: Data) async throws {
    try lock.withLock {
      if cancelled { throw CancellationError() }
      sent.append(data)
    }
    await onSend?()
  }
  func receive() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let result: Result<Data, Error>? = lock.withLock {
        if cancelled { return .failure(CancellationError()) }
        if !frames.isEmpty { return frames.removeFirst() }
        pending = continuation
        return nil
      }
      if let result { continuation.resume(with: result) } else { receiving?.fulfill() }
    }
  }
  func cancel() {
    let waiter = lock.withLock { () -> CheckedContinuation<Data, Error>? in
      cancelled = true
      defer { pending = nil }
      return pending
    }
    waiter?.resume(throwing: CancellationError())
  }
  var isCancelled: Bool { lock.withLock { cancelled } }
  var sentCount: Int { lock.withLock { sent.count } }
}
private final class ScriptLiveFactory: LiveChatSocketFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [ScriptLiveSocket]
  private var recorded: [URLRequest] = []
  init(_ sockets: [ScriptLiveSocket]) { self.sockets = sockets }
  func make(_ request: URLRequest) throws -> any LiveChatSocket {
    try lock.withLock {
      recorded.append(request)
      guard !sockets.isEmpty else { throw URLError(.cannotConnectToHost) }
      return sockets.removeFirst()
    }
  }
  var requests: [URLRequest] { lock.withLock { recorded } }
}
private actor CurrentLiveIdentity {
  var current = true
  func invalidate() { current = false }
}

final class LiveChatClientTests: XCTestCase, @unchecked Sendable {
  private let endpoint = LiveChatEndpoint(
    urls: [
      URL(string: "wss://first.fixture.invalid/sub")!,
      URL(string: "wss://second.fixture.invalid/sub")!,
    ], token: "fixture", roomID: 5000, uid: 900001, buvid: "fixture-device")
  private var accepted: Data { LiveChatPacket.encode(.authReply, body: Data(#"{"code":0}"#.utf8)) }
  private func client(_ factory: ScriptLiveFactory, timeoutImmediately: Bool = false)
    -> LiveChatClient
  {
    LiveChatClient(
      factory: factory, handshakeTimeout: .seconds(10), reconnectDelay: .zero,
      heartbeatInterval: .seconds(30),
      sleep: { duration in
        if duration == .zero || (timeoutImmediately && duration == .seconds(10)) { return }
        try await Task.sleep(for: .seconds(3600))
      })
  }
  private func drain(_ stream: AsyncThrowingStream<LiveChatEvent, Error>) async -> (
    [LiveChatEvent], LiveChatFailure?
  ) {
    var events: [LiveChatEvent] = []
    do {
      for try await event in stream { events.append(event) }
      return (events, nil)
    } catch { return (events, LiveChatFailure.classify(error)) }
  }
  func testFallbackAndReconnectShareOneFiniteBudget() async {
    let factory = ScriptLiveFactory([
      ScriptLiveSocket([.failure(URLError(.cannotConnectToHost))]),
      ScriptLiveSocket([.success(accepted), .failure(URLError(.networkConnectionLost))]),
      ScriptLiveSocket([.success(accepted), .failure(URLError(.networkConnectionLost))]),
    ])
    let client = client(factory)
    let budget = LiveChatBudget(limit: 3)
    let result = await drain(client.connect(endpoint, budget: budget, isIdentityCurrent: { true }))
    XCTAssertEqual(result.1, .budgetExhausted)
    XCTAssertEqual(result.0, [.connected, .connected])
    XCTAssertEqual(
      factory.requests.map { $0.url?.host },
      ["first.fixture.invalid", "second.fixture.invalid", "first.fixture.invalid"])
    let attempts = await budget.attempts
    XCTAssertEqual(attempts, 3)
  }
  func testEndpointFailuresAndHostsUseSameBudget() async {
    let factory = ScriptLiveFactory([
      ScriptLiveSocket([.failure(URLError(.notConnectedToInternet))])
    ])
    let client = client(factory)
    let budget = LiveChatBudget(limit: 2)
    let preparationAllowed = await budget.consume()
    XCTAssertTrue(preparationAllowed)
    let result = await drain(client.connect(endpoint, budget: budget, isIdentityCurrent: { true }))
    XCTAssertEqual(result.1, .budgetExhausted)
    XCTAssertEqual(factory.requests.count, 1)
    let remaining = await budget.remaining
    XCTAssertEqual(remaining, 0)
  }
  func testAuthenticationRefusalAndMalformedAuthNeverFallback() async {
    for body in [#"{"code":-101}"#, "broken"] {
      let factory = ScriptLiveFactory([
        ScriptLiveSocket([.success(LiveChatPacket.encode(.authReply, body: Data(body.utf8)))])
      ])
      let client = client(factory)
      let result = await drain(
        client.connect(endpoint, budget: LiveChatBudget(limit: 6), isIdentityCurrent: { true }))
      XCTAssertEqual(result.1, .authentication(body == "broken" ? nil : -101))
      XCTAssertTrue(result.0.isEmpty)
      XCTAssertEqual(factory.requests.count, 1)
    }
  }
  func testRiskControlNeverFallback() async {
    for result: Result<Data, Error> in [
      .success(LiveChatPacket.encode(.authReply, body: Data(#"{"code":-352}"#.utf8))),
      .failure(BiliError.http(412)), .failure(BiliError.http(429)),
    ] {
      let factory = ScriptLiveFactory([ScriptLiveSocket([result])])
      let client = client(factory)
      let outcome = await drain(
        client.connect(endpoint, budget: LiveChatBudget(limit: 6), isIdentityCurrent: { true }))
      if case .riskControl = outcome.1 {} else { XCTFail("\(String(describing: outcome.1))") }
      XCTAssertEqual(factory.requests.count, 1)
    }
  }
  func testHandshakeDeadlineCancelsUncooperativeReceiver() async {
    let socket = ScriptLiveSocket([])
    let factory = ScriptLiveFactory([socket])
    let client = client(factory, timeoutImmediately: true)
    let result = await drain(
      client.connect(endpoint, budget: LiveChatBudget(limit: 1), isIdentityCurrent: { true }))
    XCTAssertEqual(result.1, .budgetExhausted)
    XCTAssertTrue(socket.isCancelled)
  }
  func testAuthAndMessageInSameFrameAreBothDelivered() async {
    let frame = accepted + LiveChatPacket.encode(.message, body: Data(#"{"cmd":"LIVE"}"#.utf8))
    let socket = ScriptLiveSocket([.success(frame), .failure(URLError(.networkConnectionLost))])
    let factory = ScriptLiveFactory([socket])
    let client = client(factory)
    let result = await drain(
      client.connect(endpoint, budget: LiveChatBudget(limit: 1), isIdentityCurrent: { true }))
    XCTAssertEqual(result.0, [.connected, .liveStarted])
  }
  func testOldTerminationCannotCancelNewGeneration() async {
    let firstWaiting = expectation(description: "first receiving")
    let secondWaiting = expectation(description: "second receiving")
    firstWaiting.assertForOverFulfill = false
    secondWaiting.assertForOverFulfill = false
    let first = ScriptLiveSocket([.success(accepted)], receiving: firstWaiting)
    let second = ScriptLiveSocket([.success(accepted)], receiving: secondWaiting)
    let factory = ScriptLiveFactory([first, second])
    let client = client(factory)
    let old = client.connect(
      endpoint, budget: LiveChatBudget(limit: 1), isIdentityCurrent: { true })
    let oldTask = Task { await drain(old) }
    await fulfillment(of: [firstWaiting], timeout: 2)
    let fresh = client.connect(
      endpoint, budget: LiveChatBudget(limit: 1), isIdentityCurrent: { true })
    let newTask = Task { await drain(fresh) }
    await fulfillment(of: [secondWaiting], timeout: 2)
    oldTask.cancel()
    _ = await oldTask.value
    XCTAssertTrue(first.isCancelled)
    XCTAssertFalse(second.isCancelled)
    client.disconnect()
    _ = await newTask.value
    XCTAssertTrue(second.isCancelled)
  }
  func testIdentityChangeBeforeConnectionDoesNotCreateSocket() async {
    let factory = ScriptLiveFactory([])
    let client = client(factory)
    let result = await drain(
      client.connect(endpoint, budget: LiveChatBudget(limit: 2), isIdentityCurrent: { false }))
    XCTAssertEqual(result.1, .identityChanged)
    XCTAssertTrue(factory.requests.isEmpty)
  }
  func testIdentityChangeDuringAuthorizationRejectsLateAuthReply() async {
    let identity = CurrentLiveIdentity()
    let socket = ScriptLiveSocket([.success(accepted)], onSend: { await identity.invalidate() })
    let factory = ScriptLiveFactory([socket])
    let client = client(factory)
    let result = await drain(
      client.connect(
        endpoint, budget: LiveChatBudget(limit: 6), isIdentityCurrent: { await identity.current }))
    XCTAssertEqual(result.1, .identityChanged)
    XCTAssertTrue(result.0.isEmpty)
    XCTAssertEqual(factory.requests.count, 1)
    XCTAssertEqual(socket.sentCount, 1)
    XCTAssertTrue(socket.isCancelled)
  }
  func testReconnectDuplicateBroadcastsAreReducedOnce() async throws {
    let gift = try XCTUnwrap(LiveChatPacket.packets(LiveChatFixture.frame()).dropFirst().first).body
    let frame = LiveChatPacket.encode(.message, body: gift)
    let factory = ScriptLiveFactory(
      (0..<2).map { _ in
        ScriptLiveSocket([
          .success(accepted), .success(frame), .failure(URLError(.networkConnectionLost)),
        ])
      })
    let client = client(factory)
    let result = await drain(
      client.connect(endpoint, budget: LiveChatBudget(limit: 2), isIdentityCurrent: { true }))
    var reducer = LiveChatReducer()
    let reduced = result.0.compactMap { reducer.ingest($0, now: 1) }
    XCTAssertEqual(reduced.filter { if case .gift = $0 { true } else { false } }.count, 2)
    XCTAssertEqual(result.0.filter { if case .gift = $0 { true } else { false } }.count, 4)
  }
  func testBudgetZeroAndEmptyHostsDoNotCrash() async {
    let factory = ScriptLiveFactory([])
    let client = client(factory)
    let zero = await drain(
      client.connect(endpoint, budget: LiveChatBudget(limit: 0), isIdentityCurrent: { true }))
    XCTAssertEqual(zero.1, .budgetExhausted)
    let empty = LiveChatEndpoint(urls: [], token: "", roomID: 1, uid: 0, buvid: "")
    let outcome = await drain(
      client.connect(empty, budget: LiveChatBudget(limit: 1), isIdentityCurrent: { true }))
    XCTAssertEqual(outcome.1, .network("No chat hosts"))
    XCTAssertTrue(factory.requests.isEmpty)
  }
}

private actor SessionEndpointFixture {
  let endpoint: LiveChatEndpoint
  let failures: Int
  let error: any Error
  private(set) var calls = 0
  init(
    endpoint: LiveChatEndpoint, failures: Int, error: any Error = URLError(.notConnectedToInternet)
  ) {
    self.endpoint = endpoint
    self.failures = failures
    self.error = error
  }
  func load() throws -> LiveChatEndpoint {
    calls += 1
    if calls <= failures { throw error }
    return endpoint
  }
}

@MainActor private final class SessionPreparationFixture {
  private let old = AuthSnapshot(epoch: 1, identityRevision: 1, state: .webOnly, token: nil)
  let latest = AuthSnapshot(epoch: 2, identityRevision: 2, state: .webOnly, token: nil)
  var published: AuthSnapshot?
  var generationCurrent = true
  var calls = 0
  var consumedWhileUnbound = 0
  func snapshot() -> AuthSnapshot {
    calls += 1
    if calls == 1 {
      // The observer consumed this change while chatIdentity was nil, and will not replay it.
      if published == nil { consumedWhileUnbound += 1 }
      return old
    }
    return latest
  }
  func matches(_ identity: AuthSnapshot) -> Bool {
    identity.epoch == latest.epoch && identity.identityRevision == latest.identityRevision
  }
}

extension LiveChatClientTests {
  @MainActor func testInitialIdentityCaptureRecoversWithoutAnotherIdentityEvent() async throws {
    let fixture = SessionPreparationFixture()
    let identity = try await LiveChatSession.captureIdentity(
      snapshot: { await fixture.snapshot() }, publish: { fixture.published = $0 },
      isIdentityCurrent: { await fixture.matches($0) },
      isGenerationCurrent: { fixture.generationCurrent })
    XCTAssertEqual(fixture.consumedWhileUnbound, 1)
    XCTAssertEqual(fixture.calls, 2)
    XCTAssertEqual(identity.epoch, fixture.latest.epoch)
    XCTAssertEqual(fixture.published?.identityRevision, fixture.latest.identityRevision)
  }
  @MainActor func testInitialIdentityCaptureCannotRestartRetiredGeneration() async {
    let fixture = SessionPreparationFixture()
    do {
      _ = try await LiveChatSession.captureIdentity(
        snapshot: { await fixture.snapshot() },
        publish: {
          fixture.published = $0
          fixture.generationCurrent = false
        },
        isIdentityCurrent: { await fixture.matches($0) },
        isGenerationCurrent: { fixture.generationCurrent })
      XCTFail("A retired generation must stop")
    } catch is CancellationError {} catch { XCTFail("\(error)") }
    XCTAssertEqual(fixture.calls, 1)
  }
  func testEndpointOrchestrationStopsAfterExactlySixFailures() async {
    for limit in [0, 1, 6] {
      let fixture = SessionEndpointFixture(endpoint: endpoint, failures: .max)
      let budget = LiveChatBudget(limit: limit)
      do {
        _ = try await LiveChatSession.endpoint(
          budget: budget, load: { try await fixture.load() }, isIdentityCurrent: { true },
          sleep: { _ in })
        XCTFail("Endpoint failure must exhaust the budget")
      } catch { XCTAssertEqual(LiveChatFailure.classify(error), .budgetExhausted) }
      let calls = await fixture.calls
      XCTAssertEqual(calls, limit)
      let remaining = await budget.remaining
      XCTAssertEqual(remaining, 0)
    }
  }
  func testEndpointAndSocketOrchestrationShareActualAttemptLimit() async throws {
    let fixture = SessionEndpointFixture(endpoint: endpoint, failures: 2)
    let budget = LiveChatBudget(limit: 6)
    let prepared = try await LiveChatSession.endpoint(
      budget: budget, load: { try await fixture.load() }, isIdentityCurrent: { true },
      sleep: { _ in })
    let factory = ScriptLiveFactory(
      (0..<4).map { _ in ScriptLiveSocket([.failure(URLError(.cannotConnectToHost))]) })
    let client = client(factory)
    let outcome = await drain(client.connect(prepared, budget: budget, isIdentityCurrent: { true }))
    XCTAssertEqual(outcome.1, .budgetExhausted)
    let calls = await fixture.calls
    XCTAssertEqual(calls, 3, "Two failed preparations and one successful preparation")
    XCTAssertEqual(factory.requests.count, 4)
    let attempts = await budget.attempts
    XCTAssertEqual(
      attempts, 6, "Failed endpoint preparation and actual socket attempts share one limit")
  }
  func testHTTPAuthenticationStopsEndpointOrchestrationAfterOneCall() async {
    for status in [401, 403] {
      let fixture = SessionEndpointFixture(
        endpoint: endpoint, failures: .max, error: BiliError.http(status))
      let classified = LiveChatFailure.classify(BiliError.http(status))
      XCTAssertEqual(classified, .authentication(status))
      XCTAssertTrue(classified.terminal)
      do {
        _ = try await LiveChatSession.endpoint(
          budget: LiveChatBudget(limit: 6), load: { try await fixture.load() },
          isIdentityCurrent: { true }, sleep: { _ in XCTFail("Authentication must not back off") })
        XCTFail("Authentication must terminate")
      } catch { XCTAssertEqual(LiveChatFailure.classify(error), .authentication(status)) }
      let calls = await fixture.calls
      XCTAssertEqual(calls, 1)
    }
  }
}
