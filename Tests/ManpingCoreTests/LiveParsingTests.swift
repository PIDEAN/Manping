import BiliProtocol
import Foundation
import SwiftProtobuf
import XCTest

@testable import ManpingCore

final class LiveParsingTests: XCTestCase {
  private func packet(_ command: [String: Any]) throws -> Data {
    LiveChatPacket.encode(.message, body: try JSONSerialization.data(withJSONObject: command))
  }
  private func gift(tid: String = "tx", count: Int64 = 1, uid: Int64 = 9, giftID: Int64 = 100)
    -> LiveGiftMessage
  {
    LiveGiftMessage(
      uid: uid, user: "fixture", giftID: giftID, name: "gift", count: count, coinType: "gold",
      tid: tid)
  }
  func testDanmakuMedalEmotesReplyAndTimestamp() throws {
    let extra: [String: Any] = [
      "id_str": "9007199254740993", "dm_type": 1, "emoticon_unique": "fixture-emote",
      "emots": ["[哈]": ["url": "https://fixture.invalid/emote.png"]], "reply_mid": 99,
      "reply_uname": "回复者", "reply_dmid": "parent", "reply_attr": 1,
    ]
    var meta: [Any] = [
      0, 4, 25, 0xabcdef, 100, 0, 0, 0, 0, 0, 0, 0, 0, ["url": "https://fixture.invalid/room.png"],
      0,
      ["extra": String(decoding: try JSONSerialization.data(withJSONObject: extra), as: UTF8.self)],
    ]
    meta[15] = [
      "extra": String(decoding: try JSONSerialization.data(withJSONObject: extra), as: UTF8.self),
      "user": ["guard": ["level": 2]],
    ]
    let info: [Any] = [
      meta, "[哈]", [42, "观众"], [12, "勋章", "主播", 0, 100, 0, 0, 101, 102, 103, 3, 1, 77], [], [], [],
      3, [], ["ts": 12345],
    ]
    let events = LiveChatPacket.decode(try packet(["cmd": "DANMU_MSG:4:0", "info": info])).events
    guard case .danmaku(let message) = try XCTUnwrap(events.first) else { return XCTFail() }
    XCTAssertEqual(message.uid, 42)
    XCTAssertEqual(message.mode, 4)
    XCTAssertEqual(message.guardLevel, 2)
    XCTAssertEqual(message.medal?.level, 12)
    XCTAssertEqual(message.medal?.startColor, 102)
    XCTAssertEqual(message.medal?.anchorID, 77)
    XCTAssertEqual(message.id, "9007199254740993")
    XCTAssertEqual(message.dmType, 1)
    XCTAssertEqual(message.timestamp, 12345)
    XCTAssertEqual(message.reply["reply_mid"].int64, 99)
    XCTAssertEqual(message.reply["reply_dmid"].string, "parent")
    XCTAssertEqual(message.emotes["[哈]"]["url"].string, "https://fixture.invalid/emote.png")
    XCTAssertEqual(message.roomEmote["url"].string, "https://fixture.invalid/room.png")
    XCTAssertTrue(message.isOwn(accountMid: 42))
    XCTAssertFalse(message.isOwn(accountMid: nil))
  }
  func testV2RepeatedGiftsAndExactFieldNumbers() throws {
    // Raw bytes avoid testing generated encoding against itself: outer gift_list tag=82;
    // total_coin field7 tag=56; rnd field12 tag=98. V1 and V2 share the same transaction ID.
    let item = Data([
      8, 100, 18, 1, 71, 24, 2, 40, 100, 56, 200, 1, 66, 4, 103, 111, 108, 100, 74, 2, 116, 120, 80,
      123, 98, 1, 98,
    ])
    var bytes = Data([8, 9, 18, 1, 85, 82, UInt8(item.count)])
    bytes += item
    bytes += Data([82, UInt8(item.count)])
    bytes += item
    let events = LiveChatPacket.decode(
      try packet(["cmd": "SEND_GIFT_V2", "data": ["pb": bytes.base64EncodedString()]])
    ).events
    XCTAssertEqual(events.count, 2)
    guard case .gift(let parsed) = events[0] else { return XCTFail() }
    XCTAssertEqual(parsed.uid, 9)
    XCTAssertEqual(parsed.giftID, 100)
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed.totalCoin, 200)
    XCTAssertEqual(parsed.batchID, "b")
    XCTAssertEqual(parsed.timestamp, 123)
    var reducer = LiveChatReducer()
    XCTAssertNotNil(reducer.ingest(events[0], now: 1))
    XCTAssertNil(reducer.ingest(events[1], now: 2))
  }
  func testMalformedAndOversizedProtobufReturnEmpty() throws {
    for pb in [
      "!not base64!", Data([82, 255]).base64EncodedString(),
      String(repeating: "A", count: 1_400_004),
    ] {
      XCTAssertTrue(LiveChatPacket.event(["cmd": "SEND_GIFT_V2", "data": ["pb": pb]]).isEmpty)
    }
    var many = Bilibili_Live_Gift_V1_SendGiftBroadcast()
    many.giftList = Array(repeating: Bilibili_Live_Gift_V1_GiftItem(), count: 1025)
    XCTAssertTrue(
      LiveChatPacket.event([
        "cmd": "SEND_GIFT_V2", "data": ["pb": try many.serializedData().base64EncodedString()],
      ]).isEmpty)
    XCTAssertTrue(LiveChatPacket.event(["cmd": "DANMU_MSG", "info": []]).isEmpty)
  }
  func testV1V2DedupBeforeAggregation() throws {
    let v1 = LiveChatPacket.event([
      "cmd": "SEND_GIFT",
      "data": [
        "uid": 9, "uname": "u", "giftId": 100, "giftName": "g", "num": 2, "coin_type": "gold",
        "tid": "tx",
      ],
    ])
    var message = Bilibili_Live_Gift_V1_SendGiftBroadcast()
    message.uid = 9
    message.uname = "u"
    var item = Bilibili_Live_Gift_V1_GiftItem()
    item.giftID = 100
    item.num = 2
    item.coinType = "gold"
    item.tid = "tx"
    message.giftList = [item]
    let v2 = LiveChatPacket.event([
      "cmd": "SEND_GIFT_V2", "data": ["pb": try message.serializedData().base64EncodedString()],
    ])
    var reducer = LiveChatReducer()
    XCTAssertNotNil(reducer.ingest(v1[0], now: 1))
    XCTAssertNil(reducer.ingest(v2[0], now: 2))
    guard case .gift(let merged) = reducer.ingest(.gift(gift(tid: "tx2", count: 3)), now: 3) else {
      return XCTFail()
    }
    XCTAssertEqual(merged.count, 5)
  }
  func testGiftWindowIdentityAndOverflowBounds() {
    var aggregator = LiveGiftAggregator(window: 5, capacity: 2)
    let first = aggregator.ingest(gift(), now: 1)
    let second = aggregator.ingest(gift(tid: "tx2", count: 3), now: 2)
    XCTAssertEqual(second?.count, 4)
    XCTAssertEqual(first?.aggregationID, second?.aggregationID)
    XCTAssertEqual(aggregator.ingest(gift(tid: "tx3", uid: 10), now: 3)?.count, 1)
    XCTAssertEqual(aggregator.ingest(gift(tid: "tx4"), now: 20)?.count, 1)
    var overflow = LiveGiftAggregator()
    XCTAssertNotNil(overflow.ingest(gift(count: .max), now: 1))
    XCTAssertNil(overflow.ingest(gift(tid: "next"), now: 2))
    XCTAssertNil(overflow.ingest(gift(tid: "bad", count: -1), now: 2))
  }
  func testNoServerIDDoesNotInventDeduplication() {
    var aggregator = LiveGiftAggregator()
    XCTAssertEqual(aggregator.ingest(gift(tid: ""), now: 1)?.count, 1)
    XCTAssertEqual(aggregator.ingest(gift(tid: ""), now: 2)?.count, 2)
  }
  func testSuperChatServerIdentityTimesAndDeletion() throws {
    let event =
      [
        "cmd": "SUPER_CHAT_MESSAGE",
        "data": [
          "id": 9_007_199_254_740_993, "uid": 9, "price": 30, "message": "fixture",
          "start_time": 100, "end_time": 160, "user_info": ["uname": "u"],
        ],
      ] as [String: Any]
    let events = LiveChatPacket.decode(
      try packet(event)
        + packet(["cmd": "SUPER_CHAT_MESSAGE_DELETE", "data": ["ids": ["9007199254740993"]]])
    ).events
    guard case .superChat(let message) = events[0] else { return XCTFail() }
    XCTAssertEqual(message.id, "9007199254740993")
    XCTAssertEqual(message.startTime, 100)
    XCTAssertEqual(message.endTime, 160)
    XCTAssertEqual(events[1], .superChatDeleted(["9007199254740993"]))
  }
  func testGuardLikeModerationLotteryAndRedPocketCommands() {
    let groups: [[String]] = [
      ["GUARD_BUY", "USER_TOAST_MSG_V2"], ["LIKE_INFO_V3_UPDATE", "LIKE_INFO_V3_CLICK"],
      ["ROOM_SILENT_ON", "ROOM_SILENT_OFF", "ROOM_BLOCK_MSG"],
      ["ANCHOR_LOT_START", "ANCHOR_LOT_END", "ANCHOR_LOT_AWARD"],
      [
        "POPULARITY_RED_POCKET_START", "POPULARITY_RED_POCKET_NEW",
        "POPULARITY_RED_POCKET_WINNER_LIST",
      ],
    ]
    for (index, commands) in groups.enumerated() {
      for command in commands {
        let events = LiveChatPacket.event([
          "cmd": command,
          "data": ["uid": 9, "username": "u", "guard_level": 3, "num": 1, "unknown": "preserved"],
        ])
        XCTAssertEqual(events.count, 1)
        switch (index, events[0]) {
        case (0, .guardPurchase(let x)): XCTAssertEqual(x.raw["unknown"].string, "preserved")
        case (1, .like), (2, .moderation), (3, .lottery), (4, .redPocket): break
        default: XCTFail(command)
        }
      }
    }
    XCTAssertTrue(LiveChatPacket.event(["cmd": "COMBO_SEND"]).isEmpty)
  }
  func testSyntheticBinaryFixtureUsesProductionDecodeChain() throws {
    let events = LiveChatPacket.decode(try LiveChatFixture.frame()).events
    XCTAssertEqual(events.count, 5)
    XCTAssertEqual(events.filter { if case .gift = $0 { true } else { false } }.count, 2)
  }
}
