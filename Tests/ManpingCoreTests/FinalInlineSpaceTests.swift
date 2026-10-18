import BiliProtocol
import Foundation
import XCTest
@testable import ManpingCore

final class FinalInlineSpaceTests: XCTestCase {
  func testEmotesPreserveOrderRepetitionAndUnmappedTokens() throws {
    let smile = try XCTUnwrap(URL(string: "http://i.example/smile.png"))
    let heart = try XCTUnwrap(URL(string: "https://i.example/heart.png"))
    let mappings = [RPCEmote(text: "[微笑]", image: smile), RPCEmote(text: "[爱心]", image: heart),
      RPCEmote(text: "[无图]", image: nil), RPCEmote(text: "unused", image: smile)]
    XCTAssertEqual(RPCEmoteTextSegment.parse("前[微笑]中[爱心][微笑]尾[未知][无图]", emotes: mappings), [
      .text("前"), .emote(token: "[微笑]", image: smile), .text("中"), .emote(token: "[爱心]", image: heart),
      .emote(token: "[微笑]", image: smile), .text("尾[未知][无图]")])
    XCTAssertEqual(RPCEmoteTextSegment.parse("😀👩🏽‍💻\n[断开的", emotes: mappings), [.text("😀👩🏽‍💻\n[断开的")])
    XCTAssertEqual(RPCEmoteTextSegment.parse("普通文本", emotes: mappings), [.text("普通文本")])
    XCTAssertEqual(RPCEmoteTextSegment.parse("[外层[微笑]]", emotes: mappings), [.text("[外层[微笑]]")])
  }
  func testProfileFieldsAreIndependentOfArchiveCount() throws {
    let user = try BiliService.libraryUser(["mid": "123", "name": "Fixture", "fans": 1000,
      "follow": 23, "attention": 999, "like_num": 45678, "archive_count": 8,
      "level_info": ["current_level": 6], "vip": ["status": 2, "sign": "年度大会员"]])
    XCTAssertEqual(user.followers, 1000); XCTAssertEqual(user.following, 23)
    XCTAssertEqual(user.likes, 45678); XCTAssertEqual(user.videos, 8)
    XCTAssertEqual(user.level, 6); XCTAssertTrue(user.isVIP); XCTAssertEqual(user.vipLabel, "年度大会员")
    let sparse = try BiliService.libraryUser(["mid": 123, "name": "Sparse"])
    XCTAssertEqual(sparse.likes, 0); XCTAssertEqual(sparse.level, 0); XCTAssertFalse(sparse.isVIP)
  }
  func testDynamicEmoteMapAndSegmentFallbackText() throws {
    var item = Bilibili_App_Dynamic_V2_DynamicItem()
    item.cardType = .word; item.extend.dynIDStr = "fixture"
    var module = Bilibili_App_Dynamic_V2_Module(); module.moduleType = .moduleDesc
    var before = Bilibili_App_Dynamic_V2_Description(); before.type = .text; before.text = "前"
    var emote = Bilibili_App_Dynamic_V2_Description(); emote.type = .emoji; emote.text = "[微笑]"
    emote.uri = "https://fixture.invalid/emote/smile"
    module.moduleDesc.desc = [before, emote]; item.modules = [module]
    let dynamic = try BiliRPCAdapter.dynamic(item)
    XCTAssertEqual(dynamic.text, "前[微笑]")
    XCTAssertEqual(dynamic.emotes.map(\.text), ["[微笑]"])
    XCTAssertEqual(RPCEmoteTextSegment.parse(dynamic.text, emotes: dynamic.emotes).count, 2)
  }
}
