import XCTest

@testable import ManpingCore

final class LivePresentationTests: XCTestCase {
  func testGiftArtworkSurvivesRoomIntersectionAndFallsBackToWebP() {
    let panel: LiveJSON = .object(["gold_list": .array([.object(["id": .integer(1)])])])
    let raw: LiveJSON = .object([
      "id": .integer(1), "name": .string("Artwork"), "img_basic": .string(""),
      "webp": .string("//example.invalid/gift.webp"),
    ])
    let gifts = LiveGift.roomAvailable(panel: panel, config: .object(["list": .array([raw])]))
    XCTAssertEqual(gifts.first?.raw, raw)
    XCTAssertEqual(gifts.first?.imageURL?.absoluteString, "https://example.invalid/gift.webp")
    XCTAssertEqual(
      LiveGift.imageURL(
        in: .object([
          "img_basic": .string("https://example.invalid/basic.png"),
          "webp": .string("https://example.invalid/gift.webp"),
        ]))?.lastPathComponent, "basic.png")
    XCTAssertEqual(
      LiveGift.imageURL(
        in: .object([
          "img_basic": .string("file:///tmp/gift.png"),
          "webp": .string("https://example.invalid/gift.webp"),
        ]))?.lastPathComponent, "gift.webp")
    for raw in ["", "relative/avatar.png", "file:///tmp/avatar.png"] {
      let effect = LiveEffect(
        kind: .guardPurchase, title: "", detail: "", avatarURL: URL(string: raw))
      XCTAssertNil(effect.avatarURL, raw)
    }
    let effect = LiveEffect(
      kind: .superChat, title: "", detail: "",
      avatarURL: URL(string: "//example.invalid/avatar.png"))
    XCTAssertEqual(effect.avatarURL?.absoluteString, "https://example.invalid/avatar.png")
    XCTAssertNil(LiveGift.imageURL(in: .null))
    XCTAssertNil(LiveGift.imageURL(in: .object(["img_basic": .string("relative.png")])))
  }

  func testPresentationCountersTraverseProductionPacketDecode() throws {
    let events = LiveChatPacket.decode(try LiveChatFixture.presentationFrame()).events
    XCTAssertTrue(events.contains(.online(23_000)))
    XCTAssertTrue(events.contains(.watched(186_000)))
    let likes = events.compactMap { event -> Int64? in
      guard case .like(let notice) = event, notice.command == "LIKE_INFO_V3_UPDATE" else {
        return nil
      }
      return notice.data["click_count"].int64
    }
    XCTAssertEqual(likes, [42_000])
    XCTAssertFalse(events.contains(.popularity(23_000)))
  }

  func testActivitySnapshotsRejectOutOfOrderRefreshAwardAndRetirement() {
    var snapshot = LiveActivitySnapshot()
    let initial = snapshot.begin()
    let start = snapshot.begin()
    let end = snapshot.begin()
    let ended: LiveJSON = .object(["anchor": .null])
    XCTAssertTrue(snapshot.apply(ended, request: end))
    XCTAssertFalse(
      snapshot.apply(.object(["anchor": .object(["id": .integer(1)])]), request: start))
    XCTAssertFalse(
      snapshot.apply(.object(["anchor": .object(["id": .integer(2)])]), request: initial))
    XCTAssertEqual(snapshot.value, ended)
    let oldStart = snapshot.begin()
    let newStart = snapshot.begin()
    let current: LiveJSON = .object(["anchor": .object(["id": .integer(3)])])
    XCTAssertTrue(snapshot.apply(current, request: newStart))
    XCTAssertFalse(snapshot.apply(ended, request: oldStart))
    let pendingAtAward = snapshot.begin()
    snapshot.invalidate()
    XCTAssertFalse(snapshot.apply(ended, request: pendingAtAward))
    XCTAssertEqual(snapshot.value, current)
    let pendingAtRetirement = snapshot.begin()
    snapshot.invalidate()
    XCTAssertFalse(snapshot.apply(ended, request: pendingAtRetirement))
    let nextRoom = snapshot.begin()
    XCTAssertTrue(snapshot.apply(ended, request: nextRoom))
  }
  func testGiftClickGateRequiresTwoSecondsIncludingClockRollback() {
    var gate = LiveGiftClickGate()
    XCTAssertTrue(gate.reserve(now: 100))
    XCTAssertFalse(gate.reserve(now: 101.999))
    XCTAssertFalse(gate.reserve(now: 99))
    XCTAssertTrue(gate.reserve(now: 102))
    XCTAssertFalse(gate.reserve(now: .infinity))
  }
  func testIntegerMoneyAndUnknownBalance() {
    XCTAssertEqual(LiveMoney.batteries(101), "1.01")
    XCTAssertEqual(LiveMoney.yuan(101), "0.101")
    XCTAssertEqual(LiveMoney.batteries(.max), "92233720368547758.07")
    XCTAssertEqual(LiveMoney.batteries(.min), "-92233720368547758.08")
    XCTAssertNil(LiveMoney.total(price: .max, quantity: 2))
    XCTAssertNil(LiveMoney.total(price: -1, quantity: 1))
    XCTAssertNil(LiveMoney.remaining(balance: nil, total: 100))
    XCTAssertEqual(LiveMoney.remaining(balance: 100, total: 101), -1)
  }
  func testQueueBoundsAdmissionAndImmediatePurge() {
    var queue = LiveEffectQueue(capacity: 3)
    var settings = MacSettings()
    for index in 0..<10 {
      queue.enqueue(
        LiveEffect(kind: .gift, title: "\(index)", detail: ""), flags: settings.liveEffective)
    }
    XCTAssertEqual(queue.active?.title, "0")
    XCTAssertEqual(queue.pending.map(\.title), ["8", "9"])
    settings.set(.liveHideGifting, .bool(true), capabilities: Set(MacSettingKey.allCases))
    queue.update(settings.liveEffective)
    XCTAssertNil(queue.active)
    XCTAssertTrue(queue.pending.isEmpty)
    queue.enqueue(
      LiveEffect(kind: .guardPurchase, title: "guard", detail: ""), flags: settings.liveEffective)
    XCTAssertNotNil(queue.active)
    settings.set(.livePureMode, .bool(true), capabilities: Set(MacSettingKey.allCases))
    queue.update(settings.liveEffective)
    for kind: LiveEffect.Kind in [.gift, .guardPurchase, .superChat] {
      queue.enqueue(
        LiveEffect(kind: kind, title: "discard", detail: ""), flags: settings.liveEffective)
    }
    XCTAssertNil(queue.active)
    XCTAssertTrue(queue.pending.isEmpty)
  }
  func testDeletedSuperChatLeavesTheScreenAndQueueAndStaysOut() {
    var queue = LiveEffectQueue(capacity: 4)
    let flags = MacSettings().liveEffective
    queue.enqueue(LiveEffect(kind: .superChat, title: "shown", detail: "", sourceID: "sc-1"), flags: flags)
    queue.enqueue(LiveEffect(kind: .gift, title: "gift", detail: ""), flags: flags)
    queue.enqueue(LiveEffect(kind: .superChat, title: "queued", detail: "", sourceID: "sc-2"), flags: flags)
    queue.withdraw(["sc-1", "sc-2"])
    XCTAssertEqual(queue.active?.title, "gift", "the shown super chat was replaced by the next effect")
    XCTAssertTrue(queue.pending.isEmpty, "the queued super chat is gone")
    queue.enqueue(LiveEffect(kind: .superChat, title: "late", detail: "", sourceID: "sc-2"), flags: flags)
    XCTAssertTrue(queue.pending.isEmpty, "a broadcast arriving after its deletion is refused")
    queue.enqueue(LiveEffect(kind: .superChat, title: "other", detail: "", sourceID: "sc-3"), flags: flags)
    XCTAssertEqual(queue.pending.map(\.title), ["other"])
  }
  func testConfirmationSuppressesBothEnterKeysOnlyInItsWindow() {
    for key: UInt16 in [36, 76] {
      XCTAssertTrue(
        LiveConfirmationKeyboardPolicy.suppress(keyCode: key, inConfirmationWindow: true))
      XCTAssertFalse(
        LiveConfirmationKeyboardPolicy.suppress(keyCode: key, inConfirmationWindow: false))
    }
    XCTAssertFalse(LiveConfirmationKeyboardPolicy.suppress(keyCode: 53, inConfirmationWindow: true))
  }
  func testReplyUsesServerDanmakuIDAndKeepsSuperChatDeletionSeparate() {
    var history = LiveChatHistory()
    history.add(LiveDanmaku(uid: 1, user: "fixture", text: "hello", id: "server-dm"), accountMid: 1)
    XCTAssertEqual(history.lines.first?.replyTarget?.messageID, "server-dm")
    history.removeSuperChats(["server-dm"])
    XCTAssertEqual(history.lines.count, 1)
    history.add(LiveDanmaku(uid: 1, user: "fixture", text: "no-id"), accountMid: nil)
    XCTAssertNil(history.lines.last?.replyTarget)
  }
  func testMotionPolicyHonorsAccessibilityAndPower() {
    XCTAssertTrue(LiveEffectMotion.animates(reduceMotion: false, saving: .normal))
    XCTAssertFalse(LiveEffectMotion.animates(reduceMotion: true, saving: .normal))
    XCTAssertFalse(LiveEffectMotion.animates(reduceMotion: false, saving: .light))
  }

  func testModerationBooleanMissingExpiryAndAccountBinding() {
    var state = LiveModerationState()
    state.mergeUser(
      .object(["shield_info": .object(["is_block": .bool(true), "block_expired": .integer(200)])]))
    XCTAssertNotNil(state.message(now: 100))
    XCTAssertNil(state.message(now: 201))
    state.mergeUser(.object(["shield_info": .object(["is_block": .bool(false)])]))
    state.receive(
      LiveNoticeEvent(command: "ROOM_BLOCK_MSG", data: .object(["uid": .integer(2)])), accountMid: 1
    )
    XCTAssertNil(state.message(now: 100))
    state.receive(
      LiveNoticeEvent(command: "ROOM_SILENT_ON", data: .object(["type": .string("all")])),
      accountMid: 1)
    XCTAssertEqual(state.message(now: 100), "主播开启了全员禁言")
    state.receive(LiveNoticeEvent(command: "ROOM_SILENT_OFF", data: .null), accountMid: 1)
    XCTAssertNil(state.message(now: 100))
    state.mergeUser(.null)
    XCTAssertNil(state.message(now: 100))
  }

  func testGiftAggregationKeepsActualValueAndUnknownValue() {
    var aggregator = LiveGiftAggregator()
    let first = LiveGiftMessage(
      uid: 1, user: "fixture", giftID: 100, name: "discount", count: 2, price: 100, totalCoin: 50,
      coinType: "gold", tid: "a")
    let second = LiveGiftMessage(
      uid: 1, user: "fixture", giftID: 100, name: "discount", count: 3, price: 100, totalCoin: 75,
      coinType: "gold", tid: "b")
    _ = aggregator.ingest(first, now: 100)
    let result = aggregator.ingest(second, now: 101)
    XCTAssertEqual(result?.count, 5)
    XCTAssertEqual(result?.totalCoin, 125)
    XCTAssertEqual(result?.hasKnownTotal, true)
    let missing = LiveGiftMessage(
      uid: 1, user: "fixture", giftID: 100, name: "discount", coinType: "gold", tid: "c")
    XCTAssertEqual(aggregator.ingest(missing, now: 102)?.hasKnownTotal, false)
  }

  func testRichSceneFixturesUseServerTargetsAndExplicitAvailability() throws {
    let frame = try LiveChatFixture.presentationFrame()
    var history = LiveChatHistory()
    for event in LiveChatPacket.decode(frame).events {
      if case .danmaku(let message) = event { history.add(message, accountMid: 900001) }
    }
    XCTAssertTrue(
      history.lines.contains { $0.isOwn && $0.replyTarget?.messageID == "fixture-dm-0" })
    XCTAssertTrue(history.lines.contains { $0.medal?.lighted == false })
    XCTAssertTrue(history.lines.contains { !$0.inlineEmotes.isEmpty })
    XCTAssertTrue(history.lines.contains { $0.roomEmote != .null })
    let user = LiveUserInfo(
      try LiveEnvelope.parse(LiveContractFixture.sample(.infoByUser, scene: "balance-unknown")).data
    )
    XCTAssertNil(user.raw["wallet"]["gold"].int64)
    let gifts =
      try LiveEnvelope.parse(LiveContractFixture.sample(.giftConfig, scene: "main")).data["list"]
      .array ?? []
    XCTAssertEqual(gifts.count, 8)
    XCTAssertEqual(gifts.first?["count_map"].array?.count, 5)
    XCTAssertEqual(Set(LiveSessionFixture.scenes).count, LiveSessionFixture.scenes.count)
    XCTAssertEqual(LiveSessionFixture.legacyScenes.count, 14)
  }

  func testEntranceNoticeTraversesBinaryDecodeWithoutInventingGiftEffects() throws {
    let json: [String: Any] = [
      "cmd": "INTERACT_WORD", "data": ["uid": 900002, "uname": "示例观众", "msg_type": 1],
    ]
    let frame = LiveChatPacket.encode(
      .message, body: try JSONSerialization.data(withJSONObject: json))
    let events = LiveChatPacket.decode(frame).events
    guard case .entrance(let notice) = events.first else { return XCTFail("missing entrance") }
    XCTAssertEqual(notice.data["uname"].string, "示例观众")
    XCTAssertEqual(events.count, 1)
    XCTAssertTrue(LiveChatPacket.event(["cmd": "INTERACT_WORD", "data": ["msg_type": 2]]).isEmpty)
  }
}
