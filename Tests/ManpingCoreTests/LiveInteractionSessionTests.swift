import Foundation
import Synchronization
import XCTest

@testable import ManpingCore

private final class InteractionClock: Sendable {
  private let value = Mutex<TimeInterval>(100)
  var now: TimeInterval { value.withLock { $0 } }
  func advance(_ delta: TimeInterval) { value.withLock { $0 += delta } }
}
private actor InteractionTransport {
  enum Mode {
    case success, hold, timeout
    case rejected(Int)
    case malformed
  }
  var mode: Mode = .success
  var requests: [(LiveRoute, [String: String])] = []
  var continuation: CheckedContinuation<LiveEnvelope, Error>?
  var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  func set(_ value: Mode) { mode = value }
  func send(_ route: LiveRoute, _ fields: [String: String]) async throws -> LiveEnvelope {
    requests.append((route, fields))
    let ready = waiters.filter { requests.count >= $0.0 }
    waiters.removeAll { requests.count >= $0.0 }
    for waiter in ready { waiter.1.resume() }
    switch mode {
    case .hold: return try await withCheckedThrowingContinuation { continuation = $0 }
    case .timeout: throw URLError(.timedOut)
    case .malformed: throw BiliError.invalidResponse("fixture")
    case .rejected(let code):
      return try LiveEnvelope.parse(
        Data("{\"code\":\(code),\"message\":\"fixture\",\"data\":{}}".utf8))
    case .success: return try response()
    }
  }
  func response() throws -> LiveEnvelope {
    try LiveEnvelope.parse(Data(#"{"code":0,"message":"","data":{"receipt":"synthetic"}}"#.utf8))
  }
  func release() throws {
    continuation?.resume(returning: try response())
    continuation = nil
  }
  func release(_ response: LiveEnvelope) {
    continuation?.resume(returning: response)
    continuation = nil
  }
  func fail(_ error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
  func waitFor(_ count: Int) async {
    if requests.count >= count { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }
}
private actor InteractionSleeper {
  var waits: [CheckedContinuation<Void, Error>] = []
  var observers: [(Int, CheckedContinuation<Void, Never>)] = []
  var count = 0
  func sleep(_ duration: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      waits.append(continuation)
      count += 1
      let ready = observers.filter { count >= $0.0 }
      observers.removeAll { count >= $0.0 }
      for waiter in ready { waiter.1.resume() }
    }
  }
  func waitFor(_ count: Int) async {
    if self.count >= count { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }
  func releaseAll() {
    let current = waits
    waits = []
    for waiter in current { waiter.resume() }
  }
}
private struct InteractionHarness: Sendable {
  let clock = InteractionClock()
  let transport = InteractionTransport()
  let pending = LivePendingGiftStore()
  let session: LiveInteractionSession
  init(
    allowPaid: Bool = true, receipt: Bool = true,
    limiter: LiveAccountLimiter = LiveAccountLimiter(), sleeper: InteractionSleeper? = nil
  ) {
    let clock = clock
    let transport = transport
    session = LiveInteractionSession(
      prepare: { route, fields, _ in { try await transport.send(route, fields) } },
      policy: LiveGiftPolicy(allowPaid: allowPaid, fixedGoldPrices: [100: 100]),
      receipts: LiveReceiptPolicy(
        verify: { _, envelope, _ in receipt && envelope.data["receipt"].string == "synthetic" },
        verifyActivity: { _, envelope, ticket in
          receipt && ticket.activity.id == 400 && envelope.data["receipt"].string == "synthetic"
        }),
      limiter: limiter, pending: pending, now: { clock.now },
      sleep: { duration in
        if let sleeper {
          try await sleeper.sleep(duration)
        } else {
          try await Task.sleep(for: duration)
        }
      })
  }
  func context(
    epoch: UInt64 = 1, room: Int64 = 5000, generation: UInt64 = 1,
    state: AuthorizationState = .webOnly
  ) -> LiveInteractionContext {
    LiveInteractionContext(
      identity: AuthSnapshot(epoch: epoch, identityRevision: epoch, state: state, token: nil),
      accountMid: state == .needsLogin ? nil : 900001, roomID: room, anchorID: 900002,
      generation: generation)
  }
  func gift(price: Int64 = 100, coin: String = "gold", extra: [String: LiveJSON] = [:]) -> LiveGift
  {
    var raw: [String: LiveJSON] = [
      "id": .integer(100), "name": .string("fixture"), "price": .integer(price),
      "coin_type": .string(coin),
    ]
    raw.merge(extra) { _, new in new }
    return LiveGift(.object(raw))!
  }
  func ticket(quantity: Int64 = 1, extra: Bool = false) async throws -> LiveGiftConfirmation {
    let context = context()
    await session.bind(context)
    let quote = try await session.makeQuote(gift: gift(), quantity: quantity, expected: context)
    return try await session.confirmGift(quote, extraConfirmed: extra, expected: context)
  }
}
final class LiveInteractionSessionTests: XCTestCase, @unchecked Sendable {
  func testCharacterAndUTF16Length() {
    XCTAssertEqual(LiveLengthAlgorithm.character.count("中文👨‍👩‍👧‍👦"), 3)
    XCTAssertEqual(LiveLengthAlgorithm.utf16.count("中文👨‍👩‍👧‍👦"), 13)
  }
  func testDanmakuFailureClassification() {
    for code in [1_003_212, 10030, 10031, 1003, -101] {
      XCTAssertFalse(LiveDanmakuFailure.message(code: code, message: "").contains("B 站返回"))
    }
    for value in ["f", "k", "msg in 1s", "msg repeat"] {
      XCTAssertFalse(LiveDanmakuFailure.message(code: 0, message: value).contains("B 站返回"))
    }
    XCTAssertEqual(LiveDanmakuFailure.message(code: 7, message: "unknown"), "B 站返回：unknown（7）")
  }
  func testPaidDisabledAtQuoteAndSend() async throws {
    let h = InteractionHarness(allowPaid: false)
    let context = h.context()
    await h.session.bind(context)
    do {
      _ = try await h.session.makeQuote(gift: h.gift(), quantity: 1, expected: context)
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .paidGiftsDisabled) }
    await h.session.updatePolicy(LiveGiftPolicy(allowPaid: true, fixedGoldPrices: [100: 100]))
    let ticket = try await h.ticket()
    await h.session.updatePolicy(LiveGiftPolicy())
    do {
      try await h.session.sendGift(ticket, expected: context)
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .paidGiftsDisabled) }
    let count = await h.transport.requests.count
    XCTAssertEqual(count, 0)
  }
  func testThresholdStrictlyGreaterAndRepeatedConfirmation() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket(quantity: 100)
    XCTAssertEqual(ticket.quote.total, 10_000)
    do {
      _ = try await h.session.confirmGift(ticket.quote, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .invalidConfirmation) }
    let quote = try await h.session.makeQuote(gift: h.gift(), quantity: 101, expected: h.context())
    do {
      _ = try await h.session.confirmGift(quote, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .extraConfirmationRequired) }
    let confirmed = try await h.session.confirmGift(
      quote, extraConfirmed: true, expected: h.context())
    XCTAssertTrue(confirmed.extraConfirmed)
  }
  func testExpiredQuoteAndChangedQuantityInvalidateConfirmation() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket()
    h.clock.advance(61)
    do {
      try await h.session.sendGift(ticket, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .expiredQuote) }
    let new = try await h.ticket()
    _ = try await h.session.makeQuote(gift: h.gift(), quantity: 2, expected: h.context())
    do {
      try await h.session.sendGift(new, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .invalidConfirmation) }
  }
  func testOverflowAndUnsupportedGiftRejected() async throws {
    let h = InteractionHarness()
    await h.session.bind(h.context())
    do {
      _ = try await h.session.makeQuote(gift: h.gift(), quantity: .max, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .overflow) }
    for gift in [
      h.gift(coin: "unknown"), h.gift(extra: ["blind_gift": .object([:])]),
      h.gift(extra: ["discount_price": .integer(50)]), h.gift(extra: ["gift_type": .integer(1)]),
    ] {
      do {
        _ = try await h.session.makeQuote(gift: gift, quantity: 1, expected: h.context())
        XCTFail()
      } catch { XCTAssertEqual(error as? LiveInteractionError, .unsupportedGift) }
    }
  }
  func testBagCannotTopUpWithGold() async throws {
    let h = InteractionHarness(allowPaid: false)
    await h.session.bind(h.context())
    let bag = LiveBagItem(
      .object(["bag_id": .integer(200), "gift_id": .integer(100), "gift_num": .integer(2)]))!
    do {
      _ = try await h.session.makeQuote(
        gift: h.gift(), quantity: 3, bag: bag, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .insufficientBag) }
    let q = try await h.session.makeQuote(
      gift: h.gift(), quantity: 2, bag: bag, expected: h.context())
    XCTAssertEqual(q.total, 0)
    XCTAssertEqual(q.coin, "bag")
  }
  func testGiftConfirmationConsumedExactlyOnce() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket()
    try await h.session.sendGift(ticket, expected: h.context())
    let state = await h.session.giftState
    XCTAssertEqual(state, .succeeded(ticket.nonce))
    do {
      try await h.session.sendGift(ticket, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .invalidConfirmation) }
    let count = await h.transport.requests.count
    XCTAssertEqual(count, 1)
  }
  func testConcurrentGiftCallsCannotClearFirstSlot() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket()
    await h.transport.set(.hold)
    let first = Task { try await h.session.sendGift(ticket, expected: h.context()) }
    await h.transport.waitFor(1)
    do {
      try await h.session.sendGift(ticket, expected: h.context())
      XCTFail()
    } catch {}
    let busy = await h.session.isBusy(.gift)
    XCTAssertTrue(busy)
    try await h.transport.release()
    try await first.value
    let count = await h.transport.requests.count
    XCTAssertEqual(count, 1)
  }
  func testTimeoutAndMalformedBecomeUnknownWithoutReplay() async throws {
    for mode in [InteractionTransport.Mode.timeout, .malformed] {
      let h = InteractionHarness()
      let ticket = try await h.ticket()
      await h.transport.set(mode)
      do {
        try await h.session.sendGift(ticket, expected: h.context())
        XCTFail()
      } catch {}
      let state = await h.session.giftState
      XCTAssertEqual(state, .unknown(ticket.nonce))
      XCTAssertEqual(h.pending.pending.count, 1)
      do {
        try await h.session.sendGift(ticket, expected: h.context())
        XCTFail()
      } catch {}
      let count = await h.transport.requests.count
      XCTAssertEqual(count, 1)
    }
  }
  func testCodeZeroWithoutVerifiedReceiptIsUnknown() async throws {
    let h = InteractionHarness(receipt: false)
    let ticket = try await h.ticket()
    do {
      try await h.session.sendGift(ticket, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .unverifiedReceipt) }
    let state = await h.session.giftState
    XCTAssertEqual(state, .unknown(ticket.nonce))
  }
  func testExplicitRejectionResolvesPending() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket()
    await h.transport.set(.rejected(-101))
    do {
      try await h.session.sendGift(ticket, expected: h.context())
      XCTFail()
    } catch {}
    let state = await h.session.giftState
    guard case .rejected(ticket.nonce, _) = state else { return XCTFail() }
    XCTAssertTrue(h.pending.pending.isEmpty)
  }
  func testRoomSwitchKeepsUnknownAndDiscardsLateSuccess() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket()
    await h.transport.set(.hold)
    let task = Task { try await h.session.sendGift(ticket, expected: h.context()) }
    await h.transport.waitFor(1)
    await h.session.bind(h.context(room: 6000, generation: 2))
    XCTAssertEqual(h.pending.pending.count, 1)
    try await h.transport.release()
    do {
      try await task.value
      XCTFail()
    } catch {}
    let state = await h.session.giftState
    XCTAssertEqual(state, .idle)
    await h.session.acknowledgeGiftChecked(ticket.nonce)
    XCTAssertTrue(h.pending.pending.isEmpty)
  }
  func testIdentityChangeInvalidatesUnsentTicket() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket()
    await h.session.bind(h.context(epoch: 2))
    do {
      try await h.session.sendGift(ticket, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .staleContext) }
    XCTAssertTrue(h.pending.pending.isEmpty)
  }
  func testCallerCancellationNeverAcceptsLateSuccess() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket()
    await h.transport.set(.hold)
    let task = Task { try await h.session.sendGift(ticket, expected: h.context()) }
    await h.transport.waitFor(1)
    task.cancel()
    try await h.transport.release()
    do {
      try await task.value
      XCTFail()
    } catch {}
    let state = await h.session.giftState
    XCTAssertEqual(state, .unknown(ticket.nonce))
    XCTAssertEqual(h.pending.pending.count, 1)
  }
  func testRiskPauseOnlyAllowsNewManualActionAfterDeadline() async throws {
    let h = InteractionHarness()
    await h.session.bind(h.context())
    await h.transport.set(.rejected(-352))
    do {
      try await h.session.setStyle(color: 1, expected: h.context())
      XCTFail()
    } catch {}
    do {
      try await h.session.wearMedal(1, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .paused(until: 160)) }
    h.clock.advance(61)
    await h.transport.set(.success)
    let count = await h.transport.requests.count
    XCTAssertEqual(count, 1)
    try await h.session.wearMedal(1, expected: h.context())
  }
  func testSharedAccountRateLimitAndDuplicateContent() async throws {
    let limiter = LiveAccountLimiter()
    let a = InteractionHarness(limiter: limiter)
    let b = InteractionHarness(limiter: limiter)
    for h in [a, b] {
      await h.session.bind(h.context())
      try await h.session.updateDraft(LiveDanmakuDraft(text: "中文"), expected: h.context())
    }
    try await a.session.sendDanmaku(expected: a.context())
    do {
      try await b.session.sendDanmaku(expected: b.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .rateLimited) }
    b.clock.advance(2)
    do {
      try await b.session.sendDanmaku(expected: b.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .duplicateContent) }
    b.clock.advance(3)
    try await b.session.sendDanmaku(expected: b.context())
  }
  func testReplyAndEmoticonDraftFieldsAndLength() async throws {
    let h = InteractionHarness()
    await h.session.bind(h.context())
    try await h.session.updateDraft(
      LiveDanmakuDraft(text: "中😀", reply: LiveDanmakuReply(mid: 8, name: "示例", messageID: "9")),
      expected: h.context())
    do {
      try await h.session.sendDanmaku(expected: h.context(), limit: 2, algorithm: .utf16)
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .tooLong) }
    try await h.session.sendDanmaku(expected: h.context(), limit: 2)
    h.clock.advance(2)
    try await h.session.updateDraft(
      LiveDanmakuDraft(text: "", emoticon: "fixture-emote"), expected: h.context())
    try await h.session.sendDanmaku(expected: h.context(), limit: 1)
    let requests = await h.transport.requests
    XCTAssertEqual(requests[0].1["reply_mid"], "8")
    XCTAssertEqual(requests[1].1["dm_type"], "1")
    XCTAssertNil(requests[1].1["reply_mid"])
  }
  func testIndependentActionsAndDuplicateStyleSingleFlight() async throws {
    let h = InteractionHarness()
    await h.session.bind(h.context())
    await h.transport.set(.hold)
    let task = Task { try await h.session.setStyle(color: 1, expected: h.context()) }
    await h.transport.waitFor(1)
    do {
      try await h.session.setStyle(color: 2, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .busy) }
    let busy = await h.session.isBusy(.style)
    XCTAssertTrue(busy)
    await h.transport.set(.success)
    try await h.session.wearMedal(1, expected: h.context())
    try await h.transport.release()
    try await task.value
  }
  func testLikesDebounceCountAndIdentityCancellation() async throws {
    let sleeper = InteractionSleeper()
    let h = InteractionHarness(sleeper: sleeper)
    await h.session.bind(h.context())
    try await h.session.like(expected: h.context())
    await sleeper.waitFor(1)
    try await h.session.like(expected: h.context())
    await sleeper.waitFor(2)
    await sleeper.releaseAll()
    await h.transport.waitFor(1)
    let requests = await h.transport.requests
    XCTAssertEqual(requests[0].1["click_time"], "2")
    // Wait for the active action to finish using its state, without wall-clock sleeps.
    while await h.session.isBusy(.like) { await Task.yield() }
    try await h.session.like(expected: h.context())
    await sleeper.waitFor(3)
    await h.session.bind(h.context(epoch: 2))
    await sleeper.releaseAll()
    for _ in 0..<20 { await Task.yield() }
    let count = await h.transport.requests.count
    XCTAssertEqual(count, 1)
  }
  func testSuperChatDeletionWinsOverLateHTTPAndExpiryUsesEndTime() throws {
    var store = LiveSuperChatStore()
    let message = LiveSuperChat(.object(["id": .string("1"), "end_time": .integer(120)]))!
    store.merge([message])
    XCTAssertEqual(store.active(now: 119).count, 1)
    XCTAssertTrue(store.active(now: 120).isEmpty)
    store.delete(["1"])
    store.merge([message])
    XCTAssertTrue(store.active(now: 100).isEmpty)
  }
  func testUnknownLotteryConditionsAndSideEffectsAreRejectedOrDisclosed() async throws {
    let h = InteractionHarness()
    await h.session.bind(h.context())
    let unknown = LiveActivity(
      id: 400, kind: .lottery, deadline: 160, isFree: true, conditionsKnown: true,
      automaticDanmaku: "", automaticallyFollows: nil)
    do {
      _ = try await h.session.confirmActivity(unknown, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .unknownConditions) }
    let activity = LiveActivity(
      id: 400, kind: .lottery, deadline: 160, isFree: true, conditionsKnown: true,
      automaticDanmaku: "示例参与", automaticallyFollows: true)
    let ticket = try await h.session.confirmActivity(activity, expected: h.context())
    XCTAssertEqual(ticket.activity.automaticDanmaku, "示例参与")
    XCTAssertEqual(ticket.activity.automaticallyFollows, true)
    try await h.session.joinActivity(ticket, expected: h.context())
    let routes = await h.transport.requests.map(\.0)
    XCTAssertEqual(routes, [.joinLottery])
    do {
      try await h.session.joinActivity(ticket, expected: h.context())
      XCTFail()
    } catch {}
  }
  func testLotteryDeadlineAndReceiptEvidence() async throws {
    let h = InteractionHarness(receipt: false)
    await h.session.bind(h.context())
    let activity = LiveActivity(
      id: 400, kind: .redPocket, deadline: 160, isFree: true, conditionsKnown: true,
      automaticDanmaku: "", automaticallyFollows: false)
    let ticket = try await h.session.confirmActivity(activity, expected: h.context())
    do {
      try await h.session.joinActivity(ticket, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .unverifiedReceipt) }
    let second = try await h.session.confirmActivity(activity, expected: h.context())
    h.clock.advance(60)
    do {
      try await h.session.joinActivity(second, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .invalidActivity) }
  }
  func testPreflightCancellationRevokesTicketWithoutPendingTransaction() async throws {
    let sleeper = InteractionSleeper()
    let transport = InteractionTransport()
    let context = InteractionHarness().context()
    let pending = LivePendingGiftStore()
    let session = LiveInteractionSession(
      prepare: { route, fields, _ in
        try await sleeper.sleep(.seconds(1))
        return { try await transport.send(route, fields) }
      }, policy: LiveGiftPolicy(allowPaid: true, fixedGoldPrices: [100: 100]), pending: pending)
    await session.bind(context)
    let quote = try await session.makeQuote(
      gift: InteractionHarness().gift(), quantity: 1, expected: context)
    let ticket = try await session.confirmGift(quote, expected: context)
    let task = Task { try await session.sendGift(ticket, expected: context) }
    await sleeper.waitFor(1)
    task.cancel()
    await sleeper.releaseAll()
    do {
      try await task.value
      XCTFail()
    } catch {}
    do {
      try await session.sendGift(ticket, expected: context)
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .invalidConfirmation) }
    XCTAssertTrue(pending.pending.isEmpty)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testHTTPRiskAndStyleHexContract() async throws {
    for code in [412, 429] {
      let clock = InteractionClock()
      let context = InteractionHarness().context()
      let session = LiveInteractionSession(
        prepare: { _, _, _ in { throw BiliError.http(code) } }, now: { clock.now })
      await session.bind(context)
      do {
        try await session.setStyle(color: 0xffffff, expected: context)
        XCTFail()
      } catch {}
      let until = await session.pausedUntil
      XCTAssertEqual(until, 160)
    }
    let h = InteractionHarness()
    await h.session.bind(h.context())
    try await h.session.setStyle(color: 0x12abef, expected: h.context())
    let fields = await h.transport.requests.first?.1
    XCTAssertEqual(fields?["color"], "0x12ABEF")
  }
  func testLotteryExpiresDuringPreparationWithoutSending() async throws {
    let sleeper = InteractionSleeper()
    let clock = InteractionClock()
    let transport = InteractionTransport()
    let context = InteractionHarness().context()
    let session = LiveInteractionSession(
      prepare: { route, fields, _ in
        try await sleeper.sleep(.seconds(1))
        return { try await transport.send(route, fields) }
      }, now: { clock.now })
    await session.bind(context)
    let activity = LiveActivity(
      id: 400, kind: .lottery, deadline: 101, isFree: true, conditionsKnown: true,
      automaticDanmaku: "", automaticallyFollows: false)
    let ticket = try await session.confirmActivity(activity, expected: context)
    let task = Task { try await session.joinActivity(ticket, expected: context) }
    await sleeper.waitFor(1)
    clock.advance(2)
    await sleeper.releaseAll()
    do {
      try await task.value
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .invalidActivity) }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testSharedPolicySourceDisablesConfirmationSynchronously() async throws {
    let h = InteractionHarness()
    let source = LiveGiftPolicySource(LiveGiftPolicy(allowPaid: true, fixedGoldPrices: [100: 100]))
    let session = LiveInteractionSession(
      prepare: { _, _, _ in { try await h.transport.response() } }, policySource: source)
    await session.bind(h.context())
    let quote = try await session.makeQuote(gift: h.gift(), quantity: 1, expected: h.context())
    source.update(LiveGiftPolicy())
    do {
      _ = try await session.confirmGift(quote, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .paidGiftsDisabled) }
    source.update(LiveGiftPolicy(allowPaid: true, fixedGoldPrices: [100: 100]))
    do {
      _ = try await session.confirmGift(quote, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .invalidConfirmation) }
  }
  func testPolicyChangesDuringPreparationPreventHandoff() async throws {
    let h = InteractionHarness()
    let sleeper = InteractionSleeper()
    let source = LiveGiftPolicySource(LiveGiftPolicy(allowPaid: true, fixedGoldPrices: [100: 100]))
    let session = LiveInteractionSession(
      prepare: { route, fields, _ in
        try await sleeper.sleep(.seconds(1))
        return { try await h.transport.send(route, fields) }
      }, policySource: source, pending: h.pending)
    await session.bind(h.context())
    let quote = try await session.makeQuote(gift: h.gift(), quantity: 1, expected: h.context())
    let ticket = try await session.confirmGift(quote, expected: h.context())
    let task = Task { try await session.sendGift(ticket, expected: h.context()) }
    await sleeper.waitFor(1)
    source.update(LiveGiftPolicy())
    await sleeper.releaseAll()
    do {
      try await task.value
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .paidGiftsDisabled) }
    let requests = await h.transport.requests
    XCTAssertTrue(requests.isEmpty)
    XCTAssertTrue(h.pending.pending.isEmpty)
  }
  func testSynchronousLifetimeRetirementPreventsHandoffAndStaleBind() async throws {
    let h = InteractionHarness()
    let sleeper = InteractionSleeper()
    let session = LiveInteractionSession(prepare: { route, fields, _ in
      try await sleeper.sleep(.seconds(1))
      return { try await h.transport.send(route, fields) }
    })
    let revision = session.lifetime.revision
    await session.bind(h.context(), lifetimeRevision: revision)
    let task = Task { try await session.setStyle(color: 1, expected: h.context()) }
    await sleeper.waitFor(1)
    session.lifetime.retire()
    await session.bind(h.context(), lifetimeRevision: revision)
    XCTAssertFalse(session.lifetime.matches(h.context()))
    await sleeper.releaseAll()
    do {
      try await task.value
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .staleContext) }
    let requests = await h.transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testAuthorizedFollowingUsesBoundAnchorAndRiskPause() async throws {
    let h = InteractionHarness()
    let context = InteractionHarness().context(state: .appAuthorized)
    let observed = Mutex<Int64?>(nil)
    let session = LiveInteractionSession(
      prepare: { _, _, _ in { try await h.transport.response() } },
      follow: { context, value in
        observed.withLock { $0 = value ? context.anchorID : nil }
        throw BiliError.http(429)
      }, now: { h.clock.now })
    await session.bind(context)
    do {
      try await session.setFollowing(true, expected: context)
      XCTFail()
    } catch {}
    XCTAssertEqual(observed.withLock { $0 }, context.anchorID)
    let until = await session.pausedUntil
    XCTAssertEqual(until, 160)
  }
  func testRetiredShutdownCannotClearNewerBinding() async throws {
    let h = InteractionHarness()
    await h.session.bind(h.context())
    let retired = h.session.lifetime.retire()
    let newer = h.context(room: 6000, generation: 2)
    await h.session.bind(newer, lifetimeRevision: retired)
    await h.session.shutdown(lifetimeRevision: retired)
    let current = await h.session.context
    XCTAssertEqual(current, newer)
    XCTAssertTrue(h.session.lifetime.matches(newer))
    try await h.session.setStyle(color: 1, expected: newer)
  }
  func testOtherSessionCannotAcknowledgeInFlightGiftBeforeTimeout() async throws {
    let h = InteractionHarness()
    let ticket = try await h.ticket()
    await h.transport.set(.hold)
    let send = Task { try await h.session.sendGift(ticket, expected: h.context()) }
    await h.transport.waitFor(1)
    let other = LiveInteractionSession(
      prepare: { _, _, _ in { try await h.transport.response() } }, pending: h.pending)
    XCTAssertTrue(h.pending.pending.isEmpty)
    await other.acknowledgeGiftChecked(ticket.nonce)
    h.pending.acknowledgeChecked(ticket.nonce)
    await h.transport.fail(URLError(.timedOut))
    do {
      try await send.value
      XCTFail()
    } catch {}
    let state = await h.session.giftState
    XCTAssertEqual(state, .unknown(ticket.nonce))
    XCTAssertEqual(h.pending.pending.map(\.nonce), [ticket.nonce])
    do {
      try await h.session.sendGift(ticket, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .invalidConfirmation) }
    let count = await h.transport.requests.count
    XCTAssertEqual(count, 1)
    await other.acknowledgeGiftChecked(ticket.nonce)
    XCTAssertTrue(h.pending.pending.isEmpty)
  }
  func testWebOnlyFollowingNeedsAppLogin() async throws {
    let h = InteractionHarness()
    await h.session.bind(h.context())
    do {
      try await h.session.setFollowing(true, expected: h.context())
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .needsAppLogin) }
  }
}

extension LiveInteractionSessionTests {
  func testNewExpiredGiftConfirmationCannotInheritAcknowledgedUnknownPresentation() async throws {
    let h = InteractionHarness()
    let context = h.context()
    let previous = try await h.ticket()
    await h.transport.set(.timeout)
    do {
      try await h.session.sendGift(previous, expected: context)
      XCTFail()
    } catch {}
    await h.session.acknowledgeGiftChecked(previous.nonce)
    XCTAssertTrue(h.pending.pending.isEmpty)
    let quote = try await h.session.makeQuote(
      gift: h.gift(), quantity: 1, expected: context, lifetime: 1)
    h.clock.advance(2)
    var issuedNonce: UUID?
    do {
      issuedNonce = try await h.session.confirmGift(quote, expected: context).nonce
      XCTFail("expired quote must not issue a ticket")
    } catch { XCTAssertEqual(error as? LiveInteractionError, .expiredQuote) }
    let state = await h.session.giftState
    XCTAssertEqual(state, .unknown(previous.nonce))
    XCTAssertEqual(
      LiveGiftPresentationPolicy.failure(
        ticketNonce: issuedNonce, state: state, message: "expired", closed: false),
      .rejected("expired"))
    XCTAssertEqual(
      LiveGiftPresentationPolicy.failure(
        ticketNonce: UUID(), state: state, message: "preflight", closed: true), .closed)
    XCTAssertEqual(
      LiveGiftPresentationPolicy.failure(
        ticketNonce: previous.nonce, state: state, message: "transport", closed: false), .unknown)
    XCTAssertNil(LiveGiftPresentationPolicy.result(state, matching: UUID()))
    XCTAssertTrue(h.pending.pending.isEmpty)
    let requests = await h.transport.requests
    XCTAssertEqual(requests.count, 1)
  }

  func testLateUserInfoCannotOverwriteNewModerationNotices() async throws {
    let all = LiveNoticeEvent(command: "ROOM_SILENT_ON", data: .object(["type": .string("all")]))
    let off = LiveNoticeEvent(command: "ROOM_SILENT_OFF", data: .null)
    let block = LiveNoticeEvent(command: "ROOM_BLOCK_MSG", data: .object(["uid": .integer(900001)]))
    for notice in [block, all, off] {
      let h = InteractionHarness()
      let context = h.context()
      await h.session.bind(context)
      if notice == off { try await h.session.receive([.moderation(all)], expected: context) }
      await h.transport.set(.hold)
      let read = Task {
        try await h.session.read(.infoByUser, fields: ["room_id": "5000"], expected: context)
      }
      await h.transport.waitFor(1)
      try await h.session.receive([.moderation(notice)], expected: context)
      let data =
        notice == off
        ? #"{"code":0,"data":{"shield_info":{"is_block":false},"room_silent":{"type":"all"}}}"#
        : #"{"code":0,"data":{"shield_info":{"is_block":false},"room_silent":{"type":"off"}}}"#
      await h.transport.release(try LiveEnvelope.parse(Data(data.utf8)))
      _ = try await read.value
      let state = await h.session.moderation
      XCTAssertEqual(state.message(now: h.clock.now) != nil, notice != off)
    }
  }

  private func moderationAfterHeldUserInfo(
    notice: LiveNoticeEvent, initialRoomMute: Bool = false, responseUserMuted: Bool
  ) async throws -> LiveModerationState {
    let h = InteractionHarness()
    let context = h.context()
    await h.session.bind(context)
    if initialRoomMute {
      try await h.session.receive(
        [
          .moderation(
            LiveNoticeEvent(command: "ROOM_SILENT_ON", data: .object(["type": .string("all")])))
        ],
        expected: context)
    }
    await h.transport.set(.hold)
    let read = Task {
      try await h.session.read(.infoByUser, fields: ["room_id": "5000"], expected: context)
    }
    await h.transport.waitFor(1)
    try await h.session.receive([.moderation(notice)], expected: context)
    let payload: [String: Any] = [
      "code": 0,
      "data": [
        "shield_info": ["is_block": responseUserMuted], "room_silent": ["type": "all"],
      ],
    ]
    await h.transport.release(
      try LiveEnvelope.parse(JSONSerialization.data(withJSONObject: payload)))
    _ = try await read.value
    return await h.session.moderation
  }

  func testOtherUsersBlockDoesNotDiscardPersonalMuteHTTP() async throws {
    let state = try await moderationAfterHeldUserInfo(
      notice: LiveNoticeEvent(command: "ROOM_BLOCK_MSG", data: .object(["uid": .integer(900002)])),
      responseUserMuted: true)
    XCTAssertTrue(state.userMuted)
    XCTAssertTrue(state.allMuted)
  }

  func testRoomUnmuteDoesNotDiscardPersonalMuteHTTP() async throws {
    let state = try await moderationAfterHeldUserInfo(
      notice: LiveNoticeEvent(command: "ROOM_SILENT_OFF", data: .null), initialRoomMute: true,
      responseUserMuted: true)
    XCTAssertTrue(state.userMuted)
    XCTAssertFalse(state.allMuted)
  }

  func testPersonalBlockDoesNotDiscardRoomMuteHTTP() async throws {
    let state = try await moderationAfterHeldUserInfo(
      notice: LiveNoticeEvent(command: "ROOM_BLOCK_MSG", data: .object(["uid": .integer(900001)])),
      responseUserMuted: false)
    XCTAssertTrue(state.userMuted)
    XCTAssertTrue(state.allMuted)
  }

  func testMuteDuringPreparationStopsHandoffWithoutReservingLimiter() async throws {
    let h = InteractionHarness()
    let gate = InteractionSleeper()
    let session = LiveInteractionSession(
      prepare: { route, fields, _ in
        try await gate.sleep(.zero)
        return { try await h.transport.send(route, fields) }
      }, limiter: LiveAccountLimiter(), now: { h.clock.now })
    let context = h.context()
    await session.bind(context)
    try await session.updateDraft(LiveDanmakuDraft(text: "same manual draft"), expected: context)
    let first = Task { try await session.sendDanmaku(expected: context) }
    await gate.waitFor(1)
    try await session.receive(
      [
        .moderation(
          LiveNoticeEvent(command: "ROOM_SILENT_ON", data: .object(["type": .string("all")])))
      ], expected: context)
    await gate.releaseAll()
    do {
      try await first.value
      XCTFail("mute must win before handoff")
    } catch { XCTAssertEqual(error as? LiveInteractionError, .muted) }
    let blocked = await h.transport.requests
    XCTAssertTrue(blocked.isEmpty)
    try await session.receive(
      [.moderation(LiveNoticeEvent(command: "ROOM_SILENT_OFF", data: .null))], expected: context)
    let second = Task { try await session.sendDanmaku(expected: context) }
    await gate.waitFor(2)
    await gate.releaseAll()
    try await second.value
    let sent = await h.transport.requests
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(sent.first?.1["msg"], "same manual draft")
  }

  func testObsoleteQuoteDismissalCannotRevokeReplacement() async throws {
    let h = InteractionHarness()
    let context = h.context()
    await h.session.bind(context)
    let old = try await h.session.makeQuote(gift: h.gift(), quantity: 1, expected: context)
    let next = try await h.session.makeQuote(gift: h.gift(), quantity: 2, expected: context)
    await h.session.invalidateGiftQuote(old.id, expected: context)
    let ticket = try await h.session.confirmGift(next, expected: context)
    try await h.session.sendGift(ticket, expected: context)
    let state = await h.session.giftState
    XCTAssertEqual(state, .succeeded(ticket.nonce))
  }
  func testSuccessfulStyleAppliesToNextSendWithoutReplacingEditedDraft() async throws {
    let h = InteractionHarness()
    let context = h.context()
    await h.session.bind(context)
    try await h.session.updateDraft(LiveDanmakuDraft(text: "before"), expected: context)
    try await h.session.setStyle(color: 0x00cfff, expected: context)
    try await h.session.setStyle(mode: 4, expected: context)
    try await h.session.updateDraft(LiveDanmakuDraft(text: "after"), expected: context)
    try await h.session.sendDanmaku(expected: context)
    let requests = await h.transport.requests
    XCTAssertEqual(requests.last?.0, .sendDanmaku)
    XCTAssertEqual(requests.last?.1["color"], String(0x00cfff))
    XCTAssertEqual(requests.last?.1["mode"], "4")
    XCTAssertEqual(requests.last?.1["msg"], "after")
  }
  func testModerationBlocksBeforeTransportAndRoomUnmuteAllowsManualSend() async throws {
    let h = InteractionHarness()
    let context = h.context()
    await h.session.bind(context)
    try await h.session.updateDraft(LiveDanmakuDraft(text: "manual"), expected: context)
    try await h.session.receive(
      [
        .moderation(
          LiveNoticeEvent(command: "ROOM_SILENT_ON", data: .object(["type": .string("all")])))
      ], expected: context)
    do {
      try await h.session.sendDanmaku(expected: context)
      XCTFail("mute must block")
    } catch { XCTAssertEqual(error as? LiveInteractionError, .muted) }
    let blocked = await h.transport.requests
    XCTAssertTrue(blocked.isEmpty)
    try await h.session.receive(
      [.moderation(LiveNoticeEvent(command: "ROOM_SILENT_OFF", data: .null))], expected: context)
    try await h.session.sendDanmaku(expected: context)
    let sent = await h.transport.requests
    XCTAssertEqual(sent.count, 1)
  }
  func testUIScenesNeverFallThroughToImplicitGiftAndUnknownNameFails() async throws {
    let h = InteractionHarness()
    let context = h.context()
    for scene in LiveSessionFixture.uiScenes
    where !["unknown-cross-room", "fullscreen-unknown", "sidebar-unknown"].contains(scene) {
      _ = try await LiveSessionFixture.run(scene: scene, session: h.session, context: context)
    }
    let requests = await h.transport.requests
    XCTAssertTrue(requests.isEmpty)
    do {
      _ = try await LiveSessionFixture.run(
        scene: "invalid-scene", session: h.session, context: context)
      XCTFail("unknown scene")
    } catch {}
  }
}
