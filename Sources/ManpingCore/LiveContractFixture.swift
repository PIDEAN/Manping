import Foundation

/// Fully synthetic contract transport. Used by unit tests and DebugUIFixtures only.
/// Validation deliberately precedes all simulated effects, including lost responses.
public actor LiveContractFixture: AuthTransport {
  public enum Outcome: String, Sendable {
    case success, rejected, timeout, late, executedResponseLost, risk
  }
  public enum Identity: Sendable { case anonymous, webOnly, appAuthorized }
  public static let csrf = "fixture-live-csrf"
  public static let imageKey = "00000000000000000000000000000000"
  public static let subKey = "11111111111111111111111111111111"
  public static func cookies(identity: Identity = .webOnly) -> [HTTPCookie] {
    var values = ["buvid3": "fixture-live-device"]
    if identity != .anonymous {
      values.merge(
        ["SESSDATA": "fixture-live-session", "bili_jct": csrf, "DedeUserID": String(900001)],
        uniquingKeysWith: { _, new in new })
    }
    return values.map {
      HTTPCookie(properties: [
        .name: $0.key, .value: $0.value, .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
      ])!
    }
  }
  public static func token(identity: Identity) -> AppToken? {
    identity == .appAuthorized
      ? AppToken(
        mid: 900001, accessToken: "fixture-live-access", refreshToken: "fixture-live-refresh",
        expiresAt: 9_999_999_999) : nil
  }
  public static func route(for request: URLRequest) -> LiveRoute? {
    LiveRoute.allCases.first { $0.url.host == request.url?.host && $0.path == request.url?.path }
  }
  public private(set) var requests: [URLRequest] = []
  public private(set) var executions = 0
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
  private let scene: String?
  private let outcome: Outcome
  private let delay: @Sendable () async throws -> Void
  public init(
    outcome: Outcome = .success, scene: String? = nil,
    delay: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(200))
    }
  ) {
    self.scene = scene
    self.outcome = outcome
    self.delay = delay
  }
  public func waitForMutation() async {
    if requests.contains(where: { $0.httpMethod == "POST" }) { return }
    await withCheckedContinuation { mutationWaiters.append($0) }
  }
  public func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    guard let url = request.url else { throw BiliError.invalidResponse("Fixture URL missing") }
    if url.path == "/x/web-interface/nav" {
      return response(
        url,
        try JSONSerialization.data(withJSONObject: [
          "code": -101,
          "data": [
            "wbi_img": [
              "img_url": "https://fixture.invalid/\(Self.imageKey).png",
              "sub_url": "https://fixture.invalid/\(Self.subKey).png",
            ]
          ],
        ]))
    }
    if let sample = M5LiveFixture.response(path: url.path), Self.route(for: request) == nil {
      return response(url, sample)
    }
    guard let route = Self.route(for: request) else {
      throw BiliError.invalidResponse("Unknown live fixture route")
    }
    try Self.validate(request, route: route)
    requests.append(request)
    if route.isMutation {
      for waiter in mutationWaiters { waiter.resume() }
      mutationWaiters = []
      if scene == "send-failed", route == .sendDanmaku {
        return response(url, Data(#"{"code":0,"message":"k","data":{}}"#.utf8))
      }
      switch outcome {
      case .risk:
        return response(url, Data(#"{"code":-352,"message":"fixture risk","data":null}"#.utf8))
      case .rejected:
        return response(url, Data(#"{"code":-101,"message":"fixture rejection","data":null}"#.utf8))
      case .timeout: throw URLError(.timedOut)
      case .late: try await delay()
      case .executedResponseLost:
        executions += 1
        throw URLError(.networkConnectionLost)
      case .success: break
      }
      executions += 1
    }
    if route.isMutation {
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self).replacingOccurrences(
        of: "+", with: "%20")
      let body = URLComponents(string: "https://fixture.invalid/?" + form)?.queryItems ?? []
      let fields = Dictionary(
        (query + body).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
      let receipt: [String: Any] = [
        "fixture_receipt": "synthetic-only", "route": route.rawValue, "fields": fields,
      ]
      return response(
        url,
        try JSONSerialization.data(withJSONObject: ["code": 0, "message": "", "data": receipt]))
    }
    return response(url, try Self.sample(route, scene: scene))
  }
  public static let receiptPolicy = LiveReceiptPolicy(
    verify: { route, envelope, quote in
      guard let quote, envelope.data["fixture_receipt"].string == "synthetic-only",
        envelope.data["route"].string == route.rawValue
      else { return false }
      let fields = envelope.data["fields"]
      return fields["gift_id"].int64 == quote.giftID && fields["gift_num"].int64 == quote.quantity
        && fields["uid"].int64 == quote.context.accountMid
        && fields["ruid"].int64 == quote.context.anchorID
        && fields["biz_id"].int64 == quote.context.roomID
        && (quote.bagID.map { fields["bag_id"].int64 == $0 }
          ?? (fields["price"].int64 == quote.unitPrice && fields["coin_type"].string == quote.coin))
    },
    verifyActivity: { route, envelope, ticket in
      guard envelope.data["fixture_receipt"].string == "synthetic-only",
        envelope.data["route"].string == route.rawValue
      else { return false }
      let fields = envelope.data["fields"]
      return fields[route == .joinLottery ? "id" : "lot_id"].int64 == ticket.activity.id
        && fields["room_id"].int64 == ticket.context.roomID
        && (route == .joinLottery
          || (fields["uid"].int64 == ticket.context.accountMid
            && fields["ruid"].int64 == ticket.context.anchorID))
    })

  public static func validate(_ request: URLRequest, route: LiveRoute) throws {
    guard request.url?.host == route.url.host, request.url?.path == route.path,
      (request.httpMethod ?? "GET") == route.method,
      request.value(forHTTPHeaderField: "Origin") == "https://live.bilibili.com",
      request.value(forHTTPHeaderField: "Referer") == "https://live.bilibili.com/"
    else { throw BiliError.invalidResponse("Live fixture headers/method mismatch") }
    func fields(_ items: [URLQueryItem]) throws -> [String: String] {
      guard Set(items.map(\.name)).count == items.count else {
        throw BiliError.invalidResponse("Duplicate live fixture fields")
      }
      return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
    let query = try fields(
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    let formString = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      .replacingOccurrences(of: "+", with: "%20")
    let form = try fields(
      URLComponents(string: "https://fixture.invalid/?" + formString)?.queryItems ?? [])
    var allowedQuery = route.queryFields
    var allowedForm = route.bodyFields
    if route.signedQuery { allowedQuery.formUnion(["wts", "w_rid"]) }
    switch route.csrf {
    case .none: break
    case .query:
      allowedQuery.insert("csrf")
      guard query["csrf"] == csrf else { throw AuthFailure.missingCSRF }
    case .form:
      allowedForm.insert("csrf")
      guard form["csrf"] == csrf else { throw AuthFailure.missingCSRF }
    case .formBoth:
      allowedForm.formUnion(["csrf", "csrf_token"])
      guard form["csrf"] == csrf && form["csrf_token"] == csrf else {
        throw AuthFailure.missingCSRF
      }
    }
    guard Set(query.keys).isSubset(of: allowedQuery), Set(form.keys).isSubset(of: allowedForm),
      route.requiredFields.allSatisfy({ !(query[$0] ?? form[$0] ?? "").isEmpty })
    else { throw LiveRouteError.invalidFields(route) }
    if !form.isEmpty,
      request.value(forHTTPHeaderField: "Content-Type") != "application/x-www-form-urlencoded"
    {
      throw BiliError.invalidResponse("Live fixture content type mismatch")
    }
    if route.isMutation {
      guard
        request.value(forHTTPHeaderField: "Cookie")?.contains("SESSDATA=fixture-live-session")
          == true
      else { throw LiveRouteError.missingWebIdentity }
    }
    if route.signedQuery {
      guard let timestamp = query["wts"].flatMap(Int.init) else {
        throw BiliError.invalidResponse("Missing fixture WBI timestamp")
      }
      var unsigned = query
      unsigned["wts"] = nil
      unsigned["w_rid"] = nil
      let expected = try WBI.sign(
        unsigned, imageKey: imageKey, subKey: subKey, timestamp: timestamp)
      let signed = URLComponents(string: "https://fixture.invalid/?" + expected)?.queryItems?.first
      { $0.name == "w_rid" }?.value
      guard signed == query["w_rid"] else {
        throw BiliError.invalidResponse("Invalid fixture WBI signature")
      }
    }
  }
  public static func sample(_ route: LiveRoute, scene: String? = nil) throws -> Data {
    if let scene { return try richSample(route, scene: scene) }
    let payload: [String: Any]
    switch route {
    case .infoByUser:
      payload = ["property": ["danmu": ["length": 20]], "wallet": ["gold": 12345, "silver": 0]]
    case .dmConfig:
      payload = [
        "group": [
          ["name": "普通", "color": [["color": 16_777_215, "color_hex": "#FFFFFF", "status": 1]]]
        ], "mode": [["mode": 1, "status": 1]],
      ]
    case .emoticons:
      payload = [
        "data": [
          [
            "pkg_name": "示例表情",
            "emoticons": [["emoticon_unique": "fixture-emote", "perm": 1, "identity": 0]],
          ]
        ]
      ]
    case .giftConfig:
      payload = ["list": [["id": 100, "name": "示例礼物", "price": 100, "coin_type": "gold"]]]
    case .roomGiftList:
      payload = [
        "gift_data": ["room_gift_list": ["gold_list": [["id": 100]], "silver_list": []]],
        "gift_config": [:], "global_config": [:],
      ]
    case .bagList:
      payload = [
        "list": [["bag_id": 200, "gift_id": 100, "gift_num": 2, "expire_at": 2_000_000_000]]
      ]
    case .superChatList:
      payload = [
        "list": [
          [
            "id": "300", "uid": 900002, "price": 30, "message": "示例留言", "start_time": 100,
            "end_time": 160, "user_info": ["uname": "示例观众"],
          ]
        ]
      ]
    case .lotteryInfo:
      payload = [
        "anchor": ["id": 400, "require_type": 0, "require_text": "条件待核实"],
        "popularity_red_pocket": [:],
      ]
    case .danmuInfo:
      payload = [
        "token": "fixture-live-chat-token",
        "host_list": [["host": "fixture.invalid", "wss_port": 443]],
      ]
    case .sendGold: payload = ["total_coin": 100, "gift_list": [["gift_id": 100, "num": 1]]]
    default: payload = [:]
    }
    return try JSONSerialization.data(withJSONObject: ["code": 0, "message": "", "data": payload])
  }
  private static func richSample(_ route: LiveRoute, scene: String) throws -> Data {
    let payload: [String: Any]
    switch route {
    case .infoByUser:
      payload = [
        "property": ["danmu": ["length": 20]],
        "wallet": scene == "balance-unknown" ? [:] : ["gold": 123450, "silver": 0],
        "shield_info": ["is_block": scene == "user-muted", "block_expired": 4_000_000_000],
        "room_silent": ["type": scene == "all-muted" ? "all" : "off"],
      ]
    case .dmConfig:
      payload = [
        "group": [
          [
            "name": "普通",
            "color": [
              ["color": 16_777_215, "color_hex": "#FFFFFF", "status": 1],
              ["color": 14_893_055, "status": 0], ["color": 53_247, "status": 0],
            ],
          ],
          [
            "name": "舰长",
            "color": [["color": 4_091_864, "status": 0], ["color": 9_264_344, "status": 0]],
          ],
          ["name": "粉丝勋章", "color": [["color": 16_751_538, "status": 0]]],
        ],
        "mode": [["mode": 1, "status": 1], ["mode": 4, "status": 0], ["mode": 5, "status": 0]],
      ]
    case .emoticons:
      payload = [
        "data": [
          [
            "pkg_name": "示例表情",
            "emoticons": (0..<18).map { index in
              [
                "emoticon_unique": "fixture-emote-\(index)", "perm": index < 15 ? 1 : 0,
                "identity": index < 15 ? 0 : 3, "emoji": "表情 \(index + 1)",
                "url": "https://fixture.invalid/emote/\(index)",
              ] as [String: Any]
            },
          ]
        ]
      ]
    case .giftConfig:
      let names = ["小花花", "打call", "牛哇", "这个好诶", "情书", "星河入梦", "花式夸夸", "摩天大楼"]
      let prices = [100, 500, 100, 1000, 5200, 19900, 3300, 45000]
      payload = [
        "list": names.enumerated().map { index, name in
          [
            "id": 100 + index, "name": name, "price": prices[index], "coin_type": "gold",
            "count_map": [1, 10, 66, 520, 1314],
          ] as [String: Any]
        }
      ]
    case .roomGiftList:
      payload = [
        "gift_data": [
          "room_gift_list": ["gold_list": (100..<108).map { ["id": $0] }, "silver_list": []]
        ],
        "gift_config": [:], "global_config": [:],
      ]
    case .bagList:
      payload = [
        "list": [
          ["bag_id": 200, "gift_id": 100, "gift_num": 24, "expire_at": 2_000_000_000],
          ["bag_id": 201, "gift_id": 101, "gift_num": 1],
          ["bag_id": 202, "gift_id": 102, "gift_num": 30, "expire_at": 2_000_000_000],
          ["bag_id": 203, "gift_id": 103, "gift_num": 2, "expire_at": 2_000_000_000],
        ]
      ]
    case .medalPanel:
      payload = [
        "list": [
          [
            "medal_info": [
              "medal_id": 500, "medal_name": "山野电台", "level": 9, "medal_color": 4_091_864,
              "is_lighted": 1,
            ], "anchor_info": ["uname": "山野记录"], "wearing_status": 1,
          ],
          [
            "medal_info": [
              "medal_id": 501, "medal_name": "夜航", "level": 21, "medal_color": 9_264_344,
              "is_lighted": 1,
            ], "anchor_info": ["uname": "北岸电台"],
          ],
          [
            "medal_info": ["medal_id": 502, "medal_name": "慢旅行", "level": 4, "is_lighted": 0],
            "anchor_info": ["uname": "云杉"],
          ],
        ]
      ]
    case .superChatList:
      let now = Int64(Date().timeIntervalSince1970)
      var messages: [[String: Any]] = []
      for (index, price) in [30, 50, 100].enumerated() {
        let name = ["阿青", "北岸", "云杉"][index]
        let end = now + 120 + Int64(index * 180)
        let message: [String: Any] = [
          "id": String(300 + index), "uid": 900002 + index, "price": price,
          "message": "谢谢主播分享这段旅程，希望大家都能找到属于自己的山野与远方。今天的风景真的太美了。",
          "start_time": now - 60, "end_time": end, "user_info": ["uname": name],
        ]
        messages.append(message)
      }
      payload = ["list": messages]
    case .lotteryInfo:
      let red = scene.hasPrefix("redpocket")
      let known = scene.hasPrefix("lottery-") && scene != "lottery-unknown" || red
      let required = scene == "lottery-gift-required" || scene == "redpocket-required"
      let entry: [String: Any] = [
        "id": 400, "award_name": red ? "人气红包 · 100 电池" : "山野电台周边 T 恤 ×3",
        "deadline": Int64(Date().timeIntervalSince1970) + 252, "require_type": required ? 1 : 0,
        "require_text": required ? "需送「情书」才能参加" : "条件：无",
        "fixture_conditions_known": known, "fixture_is_free": !required,
        "fixture_automatic_danmaku": "参加了参加了", "fixture_automatically_follows": true,
      ]
      payload = red ? ["popularity_red_pocket": entry] : ["anchor": entry]
    case .danmuInfo:
      payload = [
        "token": "fixture-live-chat-token",
        "host_list": [["host": "fixture.invalid", "wss_port": 443]],
      ]
    case .sendGold: payload = ["total_coin": 100, "gift_list": [["gift_id": 100, "num": 1]]]
    default: payload = [:]
    }
    return try JSONSerialization.data(withJSONObject: ["code": 0, "message": "", "data": payload])
  }
  private func response(_ url: URL, _ body: Data) -> AuthHTTPResponse {
    AuthHTTPResponse(
      body: body,
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
