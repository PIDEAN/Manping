import Foundation
import XCTest

@testable import ManpingCore

private struct LiveTestCredentials: AuthCredentialStore {
  var missingCSRF = false
  var wrongDomain = false
  var missingDevice = false
  var targetDeviceOnly = false
  func load() -> [HTTPCookie] {
    LiveContractFixture.cookies().filter {
      (!missingCSRF || $0.name != "bili_jct") && (!missingDevice || $0.name != "buvid3")
    }.map {
      if targetDeviceOnly && $0.name == "buvid3" {
        return HTTPCookie(properties: [
          .name: $0.name, .value: $0.value, .domain: "api.live.bilibili.com", .path: "/",
        ])!
      }
      guard wrongDomain else { return $0 }
      return HTTPCookie(properties: [
        .name: $0.name, .value: $0.value, .domain: "api.bilibili.com", .path: "/",
      ])!
    }
  }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ token: AppToken?) {}
  func clear() {}
}
final class LiveRouteTests: XCTestCase, @unchecked Sendable {
  private func fields(_ route: LiveRoute) -> [String: String] {
    switch route {
    case .medalPanel, .takeOffMedal: return [:]
    case .lotteryInfo: return ["roomid": "5000"]
    case .danmuInfo: return ["id": "5000"]
    case .sendDanmaku: return ["msg": "fixture & 表情", "roomid": "5000", "rnd": "123"]
    case .setDMConfig: return ["room_id": "5000", "color": "0xFFFFFF"]
    case .sendBag:
      return [
        "uid": "900001", "gift_id": "100", "ruid": "900002", "gift_num": "1", "bag_id": "200",
        "biz_id": "5000",
      ]
    case .sendGold:
      return [
        "uid": "900001", "gift_id": "100", "ruid": "900002", "gift_num": "1", "biz_id": "5000",
        "price": "100", "coin_type": "gold",
      ]
    case .like:
      return ["uid": "900001", "anchor_id": "900002", "click_time": "2", "room_id": "5000"]
    case .wearMedal: return ["medal_id": "123"]
    case .joinLottery: return ["room_id": "5000", "id": "400"]
    case .drawRedPocket:
      return ["uid": "900001", "ruid": "900002", "room_id": "5000", "lot_id": "400", "ts": "123"]
    default: return ["room_id": "5000"]
    }
  }
  func testEveryRouteContractAndCSRFPlacement() async throws {
    let transport = LiveContractFixture()
    let service = BiliService(transport: transport, credentials: LiveTestCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let gate = LiveMutationGate(enabled: Set(LiveRoute.allCases))
    for route in LiveRoute.allCases {
      let envelope = try await service.liveRequest(
        route, fields: fields(route), expectedIdentity: identity, gate: gate)
      XCTAssertEqual(envelope.code, 0, route.rawValue)
    }
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 19)
    let expectedPaths = [
      "/xlive/web-room/v1/index/getInfoByUser", "/xlive/web-room/v1/dM/GetDMConfigByGroup",
      "/xlive/web-ucenter/v2/emoticon/GetEmoticons", "/xlive/web-room/v1/giftPanel/roomGiftList",
      "/xlive/web-room/v1/giftPanel/giftConfig", "/xlive/web-room/v1/gift/bag_list",
      "/av/v1/SuperChat/getMessageList", "/xlive/lottery-interface/v1/lottery/getLotteryInfoWeb",
      "/xlive/app-ucenter/v1/fansMedal/panel", "/xlive/web-room/v1/index/getDanmuInfo", "/msg/send",
      "/xlive/web-room/v1/dM/AjaxSetConfig", "/xlive/revenue/v2/gift/sendBagMultiUser",
      "/xlive/revenue/v1/gift/sendGold", "/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3",
      "/xlive/app-ucenter/v1/fansMedal/wear", "/xlive/web-room/v1/fansMedal/take_off",
      "/xlive/lottery-interface/v1/Anchor/Join",
      "/xlive/lottery-interface/v1/popularityRedPocket/RedPocketDraw",
    ]
    XCTAssertEqual(requests.compactMap { $0.url?.path }, expectedPaths)
    let expectedQuery: [Set<String>] = [
      ["room_id"], ["room_id"], ["platform", "room_id"],
      ["platform", "room_id", "area_parent_id", "area_id"], ["platform", "room_id"],
      ["t", "room_id", "mobi_app", "receive_users", "web_location", "wts", "w_rid"],
      ["room_id"], ["roomid"], ["page", "page_size"],
      ["id", "type", "web_location", "wts", "w_rid"],
      ["web_location", "wts", "w_rid"], [],
      [
        "uid", "gift_id", "ruid", "send_ruid", "gift_num", "bag_id", "platform", "biz_code",
        "biz_id", "storm_beat_id", "metadata", "price", "receive_users", "live_statistics",
        "statistics", "web_location", "csrf", "wts", "w_rid",
      ],
      ["web_location", "wts", "w_rid"],
      ["click_time", "room_id", "uid", "anchor_id", "web_location", "csrf", "wts", "w_rid"], [], [],
      [], ["csrf"],
    ]
    let expectedBody: [LiveRoute: Set<String>] = [
      .sendDanmaku: [
        "bubble", "msg", "color", "mode", "room_type", "jumpfrom", "statistics", "fontsize", "rnd",
        "roomid", "csrf", "csrf_token", "data_extend", "reply_mid", "reply_attr", "replay_dmid",
        "reply_type", "reply_uname",
      ],
      .setDMConfig: ["room_id", "color", "csrf", "csrf_token", "visit_id"],
      .sendGold: [
        "uid", "gift_id", "ruid", "send_ruid", "gift_num", "coin_type", "bag_id", "platform",
        "biz_code", "biz_id", "storm_beat_id", "metadata", "price", "receive_users",
        "live_statistics", "statistics", "csrf", "csrf_token",
      ],
      .wearMedal: ["medal_id", "csrf", "csrf_token", "visit_id"], .takeOffMedal: ["csrf", "csrf_token"],
      .joinLottery: ["room_id", "id", "platform", "csrf"],
      .drawRedPocket: ["uid", "room_id", "ruid", "lot_id", "ts"],
    ]
    for (index, request) in requests.enumerated() {
      XCTAssertEqual(request.url?.host, "api.live.bilibili.com")
      let route = try XCTUnwrap(LiveContractFixture.route(for: request))
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      let form =
        URLComponents(
          string: "https://fixture.invalid/?" + body.replacingOccurrences(of: "+", with: "%20"))?
        .queryItems ?? []
      XCTAssertEqual(Set(query.map(\.name)), expectedQuery[index], route.rawValue)
      XCTAssertEqual(Set(form.map(\.name)), expectedBody[route] ?? [], route.rawValue)
      XCTAssertEqual(request.httpMethod, index < 10 ? "GET" : "POST")
      if route == .sendBag || route == .like {
        XCTAssertNil(request.httpBody)
        XCTAssertTrue(query.contains { $0.name == "csrf" })
      }
      if route == .drawRedPocket {
        XCTAssertTrue(query.contains { $0.name == "csrf" })
        XCTAssertFalse(body.contains("csrf"))
      }
      if route == .sendDanmaku {
        XCTAssertTrue(body.contains("csrf_token="))
        XCTAssertFalse(query.contains { $0.name == "msg" })
        XCTAssertTrue(body.contains("fixture"))
      }
      if route.signedQuery { XCTAssertTrue(query.contains { $0.name == "w_rid" }) }
    }
  }
  func testAllMutationGatesAreClosedBeforeTransport() async throws {
    let transport = LiveContractFixture()
    let service = BiliService(transport: transport, credentials: LiveTestCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    for route in LiveRoute.allCases where route.isMutation {
      do {
        _ = try await service.liveRequest(route, fields: fields(route), expectedIdentity: identity)
        XCTFail(route.rawValue)
      } catch LiveRouteError.mutationClosed(let denied) { XCTAssertEqual(denied, route) }
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testMissingCSRFAndWrongDomainNeverSend() async throws {
    for credentials in [
      LiveTestCredentials(missingCSRF: true), LiveTestCredentials(wrongDomain: true),
    ] {
      let transport = LiveContractFixture()
      let service = BiliService(transport: transport, credentials: credentials)
      try await service.restoreCookies()
      let identity = await service.authSnapshot()
      do {
        _ = try await service.liveRequest(
          .sendDanmaku, fields: fields(.sendDanmaku), expectedIdentity: identity,
          gate: LiveMutationGate(enabled: [.sendDanmaku]))
        XCTFail()
      } catch AuthFailure.missingCSRF {} catch LiveRouteError.missingWebIdentity {}
      let requests = await transport.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }
  func testStaleIdentityAndForeignUIDNeverSend() async throws {
    let transport = LiveContractFixture()
    let service = BiliService(transport: transport, credentials: LiveTestCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    var draft = fields(.like)
    draft["uid"] = "99"
    do {
      _ = try await service.liveRequest(
        .like, fields: draft, expectedIdentity: identity, gate: LiveMutationGate(enabled: [.like]))
      XCTFail()
    } catch is CancellationError {}
    try await service.logout()
    do {
      _ = try await service.liveRequest(
        .infoByUser, fields: fields(.infoByUser), expectedIdentity: identity)
      XCTFail()
    } catch is CancellationError {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testRawEnvelopeAndLargeIdentifiersRemainExact() throws {
    let raw = Data(
      #"{"code":0,"message":"msg repeat","data":{"id":9007199254740993,"extra":[null,true]}}"#.utf8)
    let envelope = try LiveEnvelope.parse(raw)
    XCTAssertEqual(envelope.raw, raw)
    XCTAssertEqual(envelope.message, "msg repeat")
    XCTAssertEqual(envelope.data["id"].int64, 9_007_199_254_740_993)
    XCTAssertFalse(LiveRoute.sendDanmaku.accepts(envelope))
    XCTAssertThrowsError(try envelope.checkedData(for: .sendDanmaku))
    XCTAssertFalse(
      LiveRoute.joinLottery.accepts(try LiveEnvelope.parse(Data(#"{"code":0,"data":{}}"#.utf8))))
  }
  func testReadModelsAndRoomGiftIntersection() async throws {
    let service = BiliService(transport: LiveContractFixture(), credentials: LiveTestCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let user = try await service.liveUserInfo(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(user.danmakuLength, 20)
    XCTAssertEqual(user.gold, 12345)
    XCTAssertNil(LiveUserInfo(.object([:])).danmakuLength)
    XCTAssertEqual(LiveUserInfo(.null).gold, 0)
    let gifts = try await service.liveRoomGifts(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(gifts.count, 1)
    XCTAssertEqual(gifts.first?.price, 100)
    XCTAssertEqual(gifts.first?.coinType, "gold")
    let config = try await service.liveDMConfig(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(config.modes.count, 1)
    let emotes = try await service.liveEmoticons(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(emotes.count, 1)
    let bag = try await service.liveBag(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(bag.first?.count, 2)
    let chats = try await service.liveSuperChats(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(chats.first?.endTime, 160)
    let lottery = try await service.liveLotteryInfo(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(lottery.anchor["id"].int64, 400)
    let endpoint = try await service.liveChatEndpoint(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(endpoint.uid, 900001)
    XCTAssertEqual(endpoint.buvid, "fixture-live-device")
  }
  func testFixtureRejectionTimeoutLateAndExecutedResponseLost() async throws {
    for outcome in [LiveContractFixture.Outcome.rejected, .timeout, .late, .executedResponseLost] {
      let transport = LiveContractFixture(outcome: outcome, delay: {})
      let service = BiliService(transport: transport, credentials: LiveTestCredentials())
      try await service.restoreCookies()
      let identity = await service.authSnapshot()
      do {
        let response = try await service.liveRequest(
          .sendDanmaku, fields: fields(.sendDanmaku), expectedIdentity: identity,
          gate: LiveMutationGate(enabled: [.sendDanmaku]))
        XCTAssertTrue(outcome == .late || outcome == .rejected)
        if outcome == .rejected {
          XCTAssertEqual(response.code, -101)
          XCTAssertEqual(response.message, "fixture rejection")
        }
      } catch let error as URLError {
        XCTAssertTrue([.timedOut, .networkConnectionLost].contains(error.code))
      }
      let executions = await transport.executions
      XCTAssertEqual(executions, outcome == .late || outcome == .executedResponseLost ? 1 : 0)
    }
  }
  func testUnknownFieldsAndAmbiguousStyleAreRejected() throws {
    XCTAssertThrowsError(
      try LiveRoute.sendDanmaku.fields(
        [
          "msg": "emote", "roomid": "1", "rnd": "2", "dm_type": "1",
          "emoticonOptions": "[object Object]", "reply_mid": "5",
        ], timestamp: 1))
    XCTAssertThrowsError(
      try LiveRoute.sendDanmaku.fields(
        ["msg": "x", "roomid": "1", "rnd": "2", "access_key": "bad"], timestamp: 1))
    XCTAssertThrowsError(
      try LiveRoute.setDMConfig.fields(["room_id": "1", "color": "x", "mode": "1"], timestamp: 1))
  }
}

private actor PausingLiveTransport: AuthTransport {
  let path: String
  let reached: XCTestExpectation
  private var pending: CheckedContinuation<Void, Never>?
  private let fixture = LiveContractFixture()
  private(set) var requests: [URLRequest] = []
  init(path: String, reached: XCTestExpectation) {
    self.path = path
    self.reached = reached
  }
  func release() {
    pending?.resume()
    pending = nil
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    if request.url?.path == path {
      await withCheckedContinuation { continuation in
        pending = continuation
        reached.fulfill()
      }
    }
    if request.url?.path == "/x/frontend/finger/spi" {
      return AuthHTTPResponse(
        body: Data(
          #"{"code":0,"data":{"b_3":"fixture-prepared-device","b_4":"fixture-other-device"}}"#.utf8),
        response: HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    return try await fixture.send(request)
  }
}
extension LiveRouteTests {
  func testIdentityChangeDuringDeviceAndWBIPreparationNeverSendsBusinessRequest() async throws {
    for path in ["/x/frontend/finger/spi", "/x/web-interface/nav"] {
      let reached = expectation(description: path)
      let transport = PausingLiveTransport(path: path, reached: reached)
      let service = BiliService(
        transport: transport,
        credentials: LiveTestCredentials(missingDevice: path.contains("finger")),
        webDeviceCookies: true)
      try await service.restoreCookies()
      let identity = await service.authSnapshot()
      let task = Task {
        try await service.liveRequest(
          .sendDanmaku, fields: fields(.sendDanmaku), expectedIdentity: identity,
          gate: LiveMutationGate(enabled: [.sendDanmaku]))
      }
      await fulfillment(of: [reached], timeout: 2)
      try await service.logout()
      await transport.release()
      do {
        _ = try await task.value
        XCTFail("Stale preparation must be cancelled")
      } catch is CancellationError {}
      let requests = await transport.requests
      XCTAssertFalse(requests.contains { $0.url?.path == LiveRoute.sendDanmaku.path })
    }
  }
  func testIdentityChangeDiscardsInFlightEndpointAndMutationResults() async throws {
    for route in [LiveRoute.danmuInfo, .sendDanmaku] {
      let reached = expectation(description: route.rawValue)
      let transport = PausingLiveTransport(path: route.path, reached: reached)
      let service = BiliService(transport: transport, credentials: LiveTestCredentials())
      try await service.restoreCookies()
      let identity = await service.authSnapshot()
      let task = Task {
        if route == .danmuInfo {
          _ = try await service.liveChatEndpoint(roomID: 5000, expectedIdentity: identity)
        } else {
          _ = try await service.liveRequest(
            route, fields: fields(route), expectedIdentity: identity,
            gate: LiveMutationGate(enabled: [route]))
        }
      }
      await fulfillment(of: [reached], timeout: 2)
      try await service.logout()
      await transport.release()
      do {
        try await task.value
        XCTFail("Late response must not cross identity")
      } catch is CancellationError {}
    }
  }
  func testEndpointUsesTargetScopedDeviceCookie() async throws {
    let service = BiliService(
      transport: LiveContractFixture(), credentials: LiveTestCredentials(targetDeviceOnly: true))
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let endpoint = try await service.liveChatEndpoint(roomID: 5000, expectedIdentity: identity)
    XCTAssertEqual(endpoint.buvid, "fixture-live-device")
  }
  func testEmoteAndReplyContractsKeepBodyOutOfWBIScope() async throws {
    let transport = LiveContractFixture()
    let service = BiliService(transport: transport, credentials: LiveTestCredentials())
    try await service.restoreCookies()
    let identity = await service.authSnapshot()
    let gate = LiveMutationGate(enabled: [.sendDanmaku])
    var reply = fields(.sendDanmaku)
    reply.merge(
      ["reply_mid": "900002", "reply_attr": "0", "replay_dmid": "fixture-parent"],
      uniquingKeysWith: { _, new in new })
    _ = try await service.liveRequest(
      .sendDanmaku, fields: reply, expectedIdentity: identity, gate: gate)
    var emote = fields(.sendDanmaku)
    emote["msg"] = "fixture-emote"
    emote["dm_type"] = "1"
    emote["emoticonOptions"] = "[object Object]"
    _ = try await service.liveRequest(
      .sendDanmaku, fields: emote, expectedIdentity: identity, gate: gate)
    let requests = await transport.requests
    let body = requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
    XCTAssertTrue(body[0].contains("replay_dmid=fixture-parent"))
    XCTAssertTrue(body[1].contains("dm_type=1"))
    XCTAssertFalse(body[1].contains("reply_mid"))
    XCTAssertEqual(requests[0].url, requests[1].url, "Body variants must not enter WBI query scope")
  }
}

/// The production switches follow docs/LiveContracts.md: only routes captured from the web page
/// with a successful response are open, and only a backpack gift has a verified receipt.
final class LiveProductionContractTests: XCTestCase {
  func testProductionGateOpensOnlyCapturedWrites() {
    let open = Set(LiveRoute.allCases.filter { $0.isMutation && LiveMutationGate.production.allows($0) })
    XCTAssertEqual(open, [.sendDanmaku, .setDMConfig, .like, .wearMedal, .sendBag])
    XCTAssertTrue(LiveRoute.allCases.filter { !$0.isMutation }.allSatisfy(LiveMutationGate.production.allows))
  }

  func testProductionReceiptsAcceptOnlyASuccessfulBackpackGift() throws {
    let ok = try LiveEnvelope.parse(Data(#"{"code":0,"message":"OK","data":{}}"#.utf8))
    let refused = try LiveEnvelope.parse(Data(#"{"code":200013,"message":"余额不足","data":{}}"#.utf8))
    XCTAssertTrue(LiveReceiptPolicy.production.accepts(.sendBag, ok))
    XCTAssertFalse(LiveReceiptPolicy.production.accepts(.sendBag, refused))
    XCTAssertFalse(LiveReceiptPolicy.production.accepts(.sendGold, ok))
  }

  func testDanmakuFieldsMatchTheCapturedWebRequests() throws {
    let plain = try LiveRoute.sendDanmaku.fields(["msg": "hi", "roomid": "1", "rnd": "1"], timestamp: 1).body
    XCTAssertEqual(plain["data_extend"], #"{"trackid":"-99998"}"#)
    XCTAssertEqual(plain["reply_mid"], "0")
    XCTAssertEqual(plain["replay_dmid"], "")
    let reply = try LiveRoute.sendDanmaku.fields(
      ["msg": "hi", "roomid": "1", "rnd": "1", "reply_mid": "42", "reply_uname": "someone"], timestamp: 1
    ).body
    XCTAssertEqual(reply["reply_mid"], "42", "a reply keeps its own target")
    XCTAssertEqual(reply["reply_uname"], "someone")
    let emoticon = try LiveRoute.sendDanmaku.fields(
      ["msg": "official_1", "roomid": "1", "rnd": "1", "dm_type": "1", "emoticonOptions": "[object Object]"],
      timestamp: 1
    ).body
    XCTAssertNil(emoticon["reply_mid"], "an emoticon carries no reply fields")
    XCTAssertEqual(emoticon["data_extend"], #"{"trackid":"-99998"}"#)
  }

  func testMedalWearAndBackpackGiftMatchTheCapturedWebRequests() throws {
    XCTAssertEqual(LiveRoute.wearMedal.path, "/xlive/app-ucenter/v1/fansMedal/wear")
    let wear = try LiveRoute.wearMedal.fields(["medal_id": "7", "target_id": "9"], timestamp: 1).body
    XCTAssertEqual(wear["target_id"], "9")
    XCTAssertEqual(wear["visit_id"], "")
    let style = try LiveRoute.setDMConfig.fields(["room_id": "1", "color": "0xffffff"], timestamp: 1).body
    XCTAssertEqual(style["visit_id"], "")
  }
}
