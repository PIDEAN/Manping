import Foundation
import XCTest

@testable import ManpingCore

private struct LiveSessionCredentials: AuthCredentialStore {
  let identity: LiveContractFixture.Identity
  func load() -> [HTTPCookie] { LiveContractFixture.cookies(identity: identity) }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { LiveContractFixture.token(identity: identity) }
  func saveToken(_ token: AppToken?) {}
  func clear() {}
}
private actor LiveLateGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var ready: [CheckedContinuation<Void, Never>] = []
  func hold() async {
    await withCheckedContinuation {
      continuation = $0
      for waiter in ready { waiter.resume() }
      ready = []
    }
  }
  func waitReady() async {
    if continuation != nil { return }
    await withCheckedContinuation { ready.append($0) }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
final class LiveSessionIntegrationTests: XCTestCase, @unchecked Sendable {
  private func setup(
    identity: LiveContractFixture.Identity = .appAuthorized,
    outcome: LiveContractFixture.Outcome = .success
  ) async throws -> (
    LiveContractFixture, BiliService, LiveInteractionSession, LiveInteractionContext
  ) {
    let transport = LiveContractFixture(outcome: outcome)
    let service = BiliService(
      transport: transport, credentials: LiveSessionCredentials(identity: identity))
    try await service.restoreCookies()
    let snapshot = await service.authSnapshot()
    let mid = await service.accountMid()
    let room = try await service.liveRoom(5)
    let context = LiveInteractionContext(
      identity: snapshot, accountMid: mid, roomID: room.roomID, anchorID: room.anchorID,
      generation: 1)
    let session = LiveInteractionSession(
      service: service, gate: LiveMutationGate(enabled: Set(LiveRoute.allCases)),
      receipts: LiveContractFixture.receiptPolicy)
    await session.bind(context)
    return (transport, service, session, context)
  }
  func testLiveDefaultsAndEffectiveSettingsAreIndependent() {
    var settings = MacSettings()
    XCTAssertFalse(settings.bool(.liveAllowPaidGifts))
    XCTAssertEqual(settings.number(.livePaidConfirmThreshold), 10000)
    XCTAssertTrue(settings.liveEffective.giftMessages)
    XCTAssertTrue(settings.liveEffective.giftEffects)
    let all = Set(MacSettingKey.allCases)
    settings.set(.livePureMode, .bool(true), capabilities: all)
    let pure = settings.liveEffective
    XCTAssertTrue(pure.giftMessages)
    XCTAssertFalse(pure.giftEffects)
    XCTAssertFalse(pure.guardEffects)
    XCTAssertFalse(pure.superChatEffects)
    XCTAssertFalse(pure.lotteryBanner)
    XCTAssertFalse(pure.interactNotices)
    settings.set(.livePureMode, .bool(false), capabilities: all)
    settings.set(.liveHideGifting, .bool(true), capabilities: all)
    XCTAssertFalse(settings.liveEffective.giftMessages)
    XCTAssertFalse(settings.liveEffective.giftEffects)
    XCTAssertTrue(settings.liveEffective.guardEffects)
    XCTAssertTrue(settings.liveEffective.superChatEffects)
    settings.set(.liveGuardEffects, .bool(false), capabilities: all)
    XCTAssertFalse(settings.liveEffective.guardEffects)
    XCTAssertTrue(settings.liveEffective.interactNotices)
  }
  func testLiveSettingsPersistOnlyInInjectedSuite() throws {
    let name = "Manping.tests.live.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let all = Set(MacSettingKey.allCases)
    _ = MacSettings.committing(.liveAllowPaidGifts, .bool(true), capabilities: all, to: defaults)
    _ = MacSettings.committing(
      .livePaidConfirmThreshold, .number(12300), capabilities: all, to: defaults)
    let loaded = MacSettings.load(from: defaults)
    XCTAssertTrue(loaded.liveGiftPolicy().allowPaid)
    XCTAssertEqual(loaded.liveGiftPolicy().extraConfirmationThreshold, 12300)
    XCTAssertEqual(
      MacSettingGroup.allCases.firstIndex(of: .live),
      MacSettingGroup.allCases.firstIndex(of: .danmaku)! + 1)
    XCTAssertEqual(MacSettingsCatalog.descriptors.filter { $0.group == .live }.count, 9)
  }
  func testRichChatOwnIdentityAndTwoHundredLineLimit() {
    var history = LiveChatHistory()
    let message = LiveDanmaku(
      uid: 900001, user: "示例", text: "弹幕", guardLevel: 3,
      emotes: .object(["x": .string("fixture")]), roomEmote: .string("large"),
      reply: .object(["mid": .integer(7)]))
    history.add(message, accountMid: 900001)
    XCTAssertTrue(history.lines[0].isOwn)
    XCTAssertEqual(history.lines[0].uid, 900001)
    XCTAssertEqual(history.lines[0].guardLevel, 3)
    XCTAssertEqual(history.lines[0].emotes, message.emotes)
    XCTAssertEqual(history.lines[0].roomEmote, message.roomEmote)
    XCTAssertEqual(history.lines[0].reply, message.reply)
    history.add(message, accountMid: 9)
    XCTAssertFalse(history.lines[1].isOwn)
    for i in 0..<201 { history.add(user: "", text: "\(i)", kind: .notice) }
    XCTAssertEqual(history.lines.count, 200)
    XCTAssertEqual(history.lines.first?.text, "1")
  }
  func testRichGiftAggregationAndDeletedSuperChatNeverReappears() {
    var history = LiveChatHistory()
    let group = UUID()
    let gift = LiveGiftMessage(user: "示例", name: "示例礼物", count: 2, aggregationID: group)
    history.add(user: "", text: "1", kind: .gift, group: group)
    history.add(user: "", text: "2", kind: .gift, group: group, gift: gift)
    XCTAssertEqual(history.lines.count, 1)
    XCTAssertEqual(history.lines.first?.gift?.count, 2)
    history.add(user: "", text: "sc", kind: .superChat(30), serverID: "1")
    history.removeSuperChats(["1"])
    history.add(user: "", text: "late", kind: .superChat(30), serverID: "1")
    XCTAssertEqual(history.lines.count, 1)
    history.removeGifts()
    XCTAssertTrue(history.lines.isEmpty)
  }
  func testRoomAndAllReadFixturesTraverseServiceDecoders() async throws {
    let (_, service, session, context) = try await setup()
    XCTAssertEqual(context.roomID, 5000)
    XCTAssertEqual(context.anchorID, 900010)
    let room = try await service.liveRoom(5)
    XCTAssertEqual(room.anchorName, "示例主播")
    let user = try await service.liveUserInfo(roomID: 5000, expectedIdentity: context.identity)
    XCTAssertEqual(user.danmakuLength, 20)
    let gifts = try await service.liveRoomGifts(roomID: 5000, expectedIdentity: context.identity)
    XCTAssertEqual(gifts.map(\.id), [100])
    let bag = try await service.liveBag(roomID: 5000, expectedIdentity: context.identity)
    XCTAssertEqual(bag.first?.count, 2)
    let emotes = try await service.liveEmoticons(roomID: 5000, expectedIdentity: context.identity)
    XCTAssertEqual(emotes.count, 1)
    let sc = try await service.liveSuperChats(roomID: 5000, expectedIdentity: context.identity)
    XCTAssertEqual(sc.first?.id, "300")
    let lottery = try await service.liveLotteryInfo(
      roomID: 5000, expectedIdentity: context.identity)
    XCTAssertEqual(lottery.anchor["id"].int64, 400)
    let read = try await session.read(.dmConfig, fields: ["room_id": "5000"], expected: context)
    XCTAssertEqual(LiveDMConfig(read.data).groups.count, 1)
    for route in LiveRoute.allCases where !route.isMutation {
      XCTAssertNotNil(M5LiveFixture.response(path: route.path), route.rawValue)
    }
  }
  func testFixtureThreeIdentityScenes() async throws {
    for (identity, scene, state) in [
      (LiveContractFixture.Identity.anonymous, "anonymous", AuthorizationState.needsLogin),
      (.webOnly, "web-only", .webOnly), (.appAuthorized, "app-authorized", .appAuthorized),
    ] {
      let (transport, _, session, context) = try await setup(identity: identity)
      XCTAssertEqual(context.identity.state, state)
      let result = try await LiveSessionFixture.run(
        scene: scene, session: session, context: context)
      XCTAssertFalse(result.isEmpty)
      let mutations = await transport.requests.filter { ($0.httpMethod ?? "GET") == "POST" }
      XCTAssertTrue(mutations.isEmpty)
    }
  }
  func testFixtureGiftSuccessRejectedTimeoutLostAndRiskUseContracts() async throws {
    for (outcome, scene) in [
      (LiveContractFixture.Outcome.success, "gift-success"), (.rejected, "rejected"),
      (.timeout, "timeout"), (.executedResponseLost, "executedResponseLost"), (.risk, "risk"),
    ] {
      let (transport, _, session, context) = try await setup(outcome: outcome)
      let result = try await LiveSessionFixture.run(
        scene: scene, session: session, context: context)
      XCTAssertFalse(result.isEmpty)
      let state = await session.giftState
      switch outcome {
      case .success:
        guard case .succeeded = state else {
          XCTFail()
          continue
        }
      case .rejected, .risk:
        guard case .rejected = state else {
          XCTFail()
          continue
        }
      default:
        guard case .unknown = state else {
          XCTFail()
          continue
        }
      }
      let requests = await transport.requests.filter { ($0.httpMethod ?? "GET") == "POST" }
      XCTAssertEqual(requests.count, 1)
      try LiveContractFixture.validate(XCTUnwrap(requests.first), route: .sendGold)
      for record in await session.pendingGifts() {
        await session.acknowledgeGiftChecked(record.nonce)
      }
    }
  }
  func testFixtureDisabledThresholdAndUnknownLotteryDoNotSend() async throws {
    for scene in [
      "paid-disabled", "confirmation-required", "lottery-unknown", "sc-deleted", "parsing",
    ] {
      let (transport, _, session, context) = try await setup()
      let result = try await LiveSessionFixture.run(
        scene: scene, session: session, context: context)
      XCTAssertFalse(result.isEmpty)
      let requests = await transport.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }
  func testBinaryFixtureFeedsSessionSuperChatTombstones() async throws {
    let (_, _, session, context) = try await setup()
    let events = LiveChatPacket.decode(try LiveChatFixture.frame(includeDeletion: true)).events
    XCTAssertGreaterThan(events.count, 5)
    try await session.receive(events, expected: context)
    let deleted = events.flatMap { event -> [String] in
      if case .superChatDeleted(let ids) = event { return ids }
      return []
    }
    for id in deleted {
      try await session.mergeSuperChats(
        [LiveSuperChat(.object(["id": .string(id), "end_time": .integer(.max)]))!],
        expected: context)
    }
    let store = await session.superChats
    for id in deleted { XCTAssertFalse(store.contains(id)) }
  }
  func testLateFixtureActuallyExecutesButCannotResolveRetiredSession() async throws {
    let gate = LiveLateGate()
    let transport = LiveContractFixture(outcome: .late, delay: { await gate.hold() })
    let service = BiliService(
      transport: transport, credentials: LiveSessionCredentials(identity: .appAuthorized))
    try await service.restoreCookies()
    let context = LiveInteractionContext(
      identity: await service.authSnapshot(), accountMid: await service.accountMid(),
      roomID: 5000, anchorID: 900010, generation: 1)
    let session = LiveInteractionSession(
      service: service, gate: LiveMutationGate(enabled: Set(LiveRoute.allCases)),
      receipts: LiveContractFixture.receiptPolicy)
    let task = Task {
      try await LiveSessionFixture.run(
        scene: "late", session: session, context: context,
        waitForLateHandoff: { await transport.waitForMutation() })
    }
    await gate.waitReady()
    while await session.context?.generation != 2 { await Task.yield() }
    await gate.release()
    let messages = try await task.value
    XCTAssertTrue(messages[0].contains("迟到结果已丢弃"))
    let executions = await transport.executions
    XCTAssertEqual(executions, 1)
    let state = await session.giftState
    XCTAssertEqual(state, .idle)
    let pending = await session.pendingGifts()
    XCTAssertFalse(pending.isEmpty)
    for record in pending { await session.acknowledgeGiftChecked(record.nonce) }
  }
  func testPreparedLiveRequestRechecksRetiredLifetimeBeforeTransport() async throws {
    let (transport, service, _, context) = try await setup()
    let prepared = try await service.prepareLiveRequest(
      .like,
      fields: ["uid": "900001", "room_id": "5000", "anchor_id": "900010", "click_time": "1"],
      expectedIdentity: context.identity, gate: LiveMutationGate(enabled: [.like]))
    let lifetime = LiveInteractionLifetime()
    XCTAssertTrue(lifetime.activate(context, revision: lifetime.revision))
    lifetime.retire()
    do {
      _ = try await service.executeLiveRequest(
        prepared,
        beforeSend: {
          guard lifetime.matches(context) else { throw LiveInteractionError.staleContext }
        })
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveInteractionError, .staleContext) }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testLiveReadRejectsOtherRoomFields() async throws {
    let (transport, _, session, context) = try await setup()
    do {
      _ = try await session.read(.infoByUser, fields: ["room_id": "6000"], expected: context)
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveRouteError, .invalidFields(.infoByUser)) }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testProductionGateStaysClosedEvenWithPaidPreference() async throws {
    let (_, service, _, context) = try await setup()
    let session = LiveInteractionSession(
      service: service, policy: LiveGiftPolicy(allowPaid: true, fixedGoldPrices: [100: 100]))
    await session.bind(context)
    let gift = LiveGift(
      .object(["id": .integer(100), "price": .integer(100), "coin_type": .string("gold")]))!
    let q = try await session.makeQuote(gift: gift, quantity: 1, expected: context)
    let ticket = try await session.confirmGift(q, expected: context)
    do {
      try await session.sendGift(ticket, expected: context)
      XCTFail()
    } catch { XCTAssertEqual(error as? LiveRouteError, .mutationClosed(.sendGold)) }
    let state = await session.giftState
    XCTAssertEqual(state, .idle)
  }
}
