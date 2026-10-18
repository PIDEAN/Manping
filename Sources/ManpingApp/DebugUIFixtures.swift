import AppKit
import ManpingCore
import Foundation
import SwiftUI

/// Explicit local samples for layout inspection, never a fallback for live requests.
enum DebugUIFixtures {
  static var enabled: Bool {
    if PerformanceOptions.requested { return true }
    #if DEBUG
    return ProcessInfo.processInfo.arguments.contains("--ui-fixture")
    #else
    return false
    #endif
  }
  static let episodic = enabled && ProcessInfo.processInfo.arguments.contains("--ui-episodic")
  static let bvid = "BV1fixture01"
  static let titles = [
    "走进山野：记录一段慢下来的旅程", "从零搭建桌面工作空间｜整理与收纳",
    "城市的声音：雨后的街道与夜色", "用镜头发现日常里的光影",
    "聊聊经典游戏背后的设计", "一周读书分享：故事与想象力",
    "在家做一碗热气腾腾的面", "小小实验室：看见科学的乐趣",
  ]
  static func archive(_ index: Int) -> [String: Any] {
    ["aid": index == 0 ? 100 : 100 + index, "bvid": index == 0 ? bvid : "BV1sample\(String(format: "%03d", index))",
      "cid": 1000 + index, "title": titles[index % titles.count],
      "pic": "https://fixture.invalid/cover/\(index % titles.count)", "duration": 180 + index * 21,
      "pubdate": 1_760_000_000 - index * 3000,
      "subtitle": ["昨天 18:00", "8小时前", "7小时前", "8小时前", "14小时前", "23小时前"][index % 6],
      "rcmd_reason": ["content": index % 4 == 0 ? "很多人点赞" : index % 4 == 2 ? "6万点赞" : ""],
      "desc": "这是显式 Debug fixture 的本地样本，用于检查页面布局、分P、分页和浅深主题。\n不会发送真实账号写操作，也不会加载在线媒体。",
      "owner": ["mid": 10001 + index, "name": ["山野记录", "桌面计划", "城市观察", "日常放映"][index % 4],
        "face": "https://fixture.invalid/avatar/\(index % 4)"],
      "stat": ["view": 120_000 + index * 1249, "danmaku": 860, "reply": 36,
        "like": 6800, "coin": 1280, "favorite": 2400, "share": 318]]
  }
  static func comment(_ index: Int, root: Int64 = 0) -> RPCComment {
    let messages = ["这段画面让人一下就放松了[微笑]，感谢分享[爱心]。", "从开头一直看到最后，细节很用心！",
      "收藏起来周末再看，期待下一期。", "音乐和镜头的节奏搭配得很舒服。", "这个想法很有意思，可以再展开聊聊吗？"]
    let object: [String: Any] = [
      "id": (root > 0 ? Int(root) * 100 : 2000) + index, "root": root,
      "author": ["mid": 3000 + index, "name": "样本观众 \(index + 1)", "avatar": "https://fixture.invalid/avatar/\(index % 4)"],
      "text": messages[index % messages.count], "emotes": index % messages.count == 0 ? [
        ["text": "[微笑]", "image": "https://fixture.invalid/emote/smile"],
        ["text": "[爱心]", "image": "https://fixture.invalid/emote/heart"]] : [], "createdAt": 1_760_000_000 - index * 300,
      "likes": 120 - index, "replyCount": root > 0 ? 0 : 8, "liked": false,
      "pinned": index == 0 && root == 0, "replies": []]
    return try! JSONDecoder().decode(RPCComment.self, from: JSONSerialization.data(withJSONObject: object))
  }
}

struct DebugUICredentialStore: AuthCredentialStore {
  func save(_ cookies: [HTTPCookie]) {}
  func load() -> [HTTPCookie] {
    [("SESSDATA", "debug-fixture-session"), ("bili_jct", "debug-fixture-csrf")].compactMap { name, value in
      HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: name, .value: value])
    }
  }
  func saveToken(_ token: AppToken?) {}
  func loadToken() -> AppToken? {
    AppToken(mid: M3Fixture.owner, accessToken: "debug-fixture-access", refreshToken: "debug-fixture-refresh", expiresAt: 9_999_999_999)
  }
  func clear() {}
}

actor DebugUITransport: AuthTransport {
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    if let url = request.url, request.httpMethod == "POST" {
      let fields = Dictionary((URLComponents(string: "https://fixture.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!.replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
      if let data = M5PGCFixture.response(path: url.path, parameters: fields) { return response(url, body: data) }
      if let data = M6MessageFixture.response(path: url.path, parameters: fields) { return response(url, body: data) }
      if let data = M6ArticleFixture.response(path: url.path, parameters: fields) { return response(url, body: data) }
    }
    if request.httpMethod == "POST", let url = request.url,
      ["/x/v2/history/toview/del", "/x/v2/history/toview/clear", "/x/v3/fav/resource/batch-del", "/pgc/app/follow/del", "/x/relation/modify", "/x/v2/reply/action", "/x/v2/reply/add"].contains(url.path) {
      return response(url, body: Data(#"{"code":0,"data":{}}"#.utf8))
    }
    guard request.httpMethod == nil || request.httpMethod == "GET", let url = request.url else {
      throw BiliError.invalidResponse("Debug fixture rejects mutations")
    }
    let fields = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
      .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    if let data = M6MessageFixture.response(path: url.path, parameters: fields) { return response(url, body: data) }
    if let data = M6ArticleFixture.response(path: url.path, parameters: fields) { return response(url, body: data) }
    if let data = M5LiveFixture.response(path: url.path, parameters: fields) { return response(url, body: data) }
    if let data = M5PGCFixture.response(path: url.path, parameters: fields) { return response(url, body: data) }
    let page = Int(fields["pn"] ?? "1") ?? 1
    var data: Any
    switch url.path {
    case "/x/player/wbi/v2":
      data = ["subtitle": ["subtitles": [
        ["id": 300, "id_str": "300", "lan": "zh-CN", "lan_doc": "中文", "subtitle_url": "https://i0.hdslb.com/bfs/subtitle/fixture-cn.json", "ai_type": 0],
        ["id": 301, "id_str": "301", "lan": "ai-zh", "lan_doc": "AI 中文", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/ai_subtitle/fixture-ai.json", "ai_type": 1]
      ]]]
    case "/bfs/subtitle/fixture-cn.json", "/bfs/ai_subtitle/fixture-ai.json":
      return response(url, body: try JSONSerialization.data(withJSONObject: ["body": [["from": 0.0, "to": 2.5, "content": "这是本地字幕样本"], ["from": 2.5, "to": 5.0, "content": "字幕导出与账号写操作无关"]]]))
    case "/x/web-interface/nav":
      data = ["wbi_img": ["img_url": "https://fixture.invalid/7cd084941338484aae1ad9425b84077c.png",
        "sub_url": "https://fixture.invalid/4932caff0ff746eab6f01bf08b70ac45.png"]]
    case "/x/web-interface/popular", "/x/web-interface/ranking/v2":
      let start = (page - 1) * 24
      data = ["list": (start..<min(start + 24, 48)).map(DebugUIFixtures.archive), "no_more": page >= 2]
    case "/x/web-interface/index/top/feed/rcmd":
      data = ["item": (0..<10).map { index in
        var archive = DebugUIFixtures.archive(index)
        archive["id"] = archive["aid"]
        return archive
      }]
    case "/x/v2/feed/index":
      let cursor = Int(fields["idx"] ?? "0") ?? 0
      // First page is filtered out, but the raw cursor advances to a real video page.
      if cursor == 0 { data = ["items": [["card_goto": "ad", "idx": 24]]] }
      else { data = ["items": cursor >= 72 ? [] : (cursor..<cursor + 24).map { index in
        var card = appCard(index)
        card["play"] = nil; card["pubdate"] = nil; card["subtitle"] = nil
        card["cover_left_text_1"] = index % 2 == 0 ? "14.2万" : "3.6万"
        card["cover_left_text_2"] = "860"
        return card
      }] }
    case "/x/v2/region/index":
      data = [(1, "动画"), (3, "音乐"), (129, "舞蹈"), (4, "游戏"), (36, "知识"),
        (188, "科技"), (223, "汽车"), (234, "运动"), (160, "生活"), (211, "美食"),
        (217, "动物圈"), (119, "鬼畜"), (155, "时尚"), (5, "娱乐"), (181, "影视")].map { id, name in
        ["tid": id, "name": name, "uri": "bilibili://region/\(id)", "children": [
          ["tid": id * 100 + 1, "name": "综合"], ["tid": id * 100 + 2, "name": "精选"]]] as [String: Any]
      }
    case "/x/v2/region/dynamic", "/x/v2/region/dynamic/child",
      "/x/v2/region/dynamic/list", "/x/v2/region/dynamic/child/list":
      let offset = Int(fields["ctime"] ?? "0") ?? 0
      data = ["new": offset >= 48 ? [] : (offset..<offset + 24).map { appCard($0) },
        "recommend": [], "cbottom": offset >= 48 ? 0 : offset + 24]
    case "/x/v2/region/show/child/list":
      let start = page * 30
      data = start >= 60 ? [] : (start..<start + 30).map { appCard($0) }
    case "/x/web-interface/archive/relation":
      data = ["like": true, "favorite": true, "attention": true, "coin": 1]
    case "/x/web-interface/view", "/x/web-interface/wbi/view": data = detailArchive(fields)
    case "/x/web-interface/view/detail", "/x/web-interface/wbi/view/detail":
      let view = detailArchive(fields)
      data = ["View": view, "Card": ["card": view["owner"]!, "follower": 124_000],
        "Tags": ["生活", "旅行", "原创"].map { ["tag_name": $0] },
        "Related": (1..<9).map(DebugUIFixtures.archive)]
      if DebugUIFixtures.episodic {
        data = ["View": view, "Card": ["card": view["owner"]!, "follower": 124_000], "Tags": []]
      }
    case "/x/player/wbi/playurl", "/x/player/playurl":
      data = ["accept_quality": [80, 64, 32], "accept_description": ["1080P", "720P", "480P"],
        "dash": ["duration": 180, "video": [80, 64, 32].flatMap { quality in
          ["avc1.640028", "hev1.1.6.L120.90"].map { codec in
            ["id": quality, "codecs": codec, "base_url": "https://fixture.invalid/\(quality)/\(codec)",
              "bandwidth": quality * 10000, "width": 1920, "height": 1080] as [String: Any]
          }
        }, "audio": [["id": 30280, "codecs": "mp4a.40.2", "base_url": "https://fixture.invalid/audio", "bandwidth": 128000]]]]
    case "/x/v1/dm/list.so":
      return response(url, body: Data("<i></i>".utf8))
    case "/x/dm/filter/user":
      data = ["rule": [["id": 1, "type": 0, "filter": "剧透"], ["id": 2, "type": 0, "filter": "前方高能"],
        ["id": 3, "type": 1, "filter": "^哈{3,}$"], ["id": 4, "type": 2, "filter": "abcdef12"]], "limit": 5000]
    default:
      if let body = M3Fixture.uiResponse(path: url.path, parameters: fields) {
        return response(url, body: body)
      }
      throw BiliError.invalidResponse("No Debug fixture for requested endpoint")
    }
    return response(url, body: try JSONSerialization.data(withJSONObject: ["code": 0, "data": data]))
  }
  private func appCard(_ index: Int) -> [String: Any] {
    let archive = DebugUIFixtures.archive(index)
    return ["card_goto": "av", "goto": "av", "idx": index + 1, "aid": archive["aid"]!,
      "title": archive["title"]!, "cover": archive["pic"]!, "play": 120_000,
      "pubdate": archive["pubdate"]!, "subtitle": archive["subtitle"]!, "rcmd_reason": archive["rcmd_reason"]!,
      "args": ["aid": archive["aid"]!, "up_name": "本地样本", "up_id": 10001],
      "player_args": ["cid": archive["cid"]!, "duration": archive["duration"]!]]
  }
  private func detailArchive(_ fields: [String: String]) -> [String: Any] {
    var view = DebugUIFixtures.archive(0)
    view["aid"] = Int(fields["aid"] ?? "100") ?? 100
    view["bvid"] = fields["bvid"] ?? DebugUIFixtures.bvid
    view["pages"] = (1...3).map { part in
      ["cid": 999 + part, "page": part, "part": "第 \(part) 集 · \(["出发", "山间", "归途"][part - 1])", "duration": 180] as [String: Any]
    }
    view["ugc_season"] = ["sections": [["id": 1, "title": "慢生活记录", "episodes": (0..<6).map { ["arc": DebugUIFixtures.archive($0)] }]]]
    if DebugUIFixtures.episodic {
      view["title"] = "凡人修仙传"
      view["cid"] = 1007
      view["duration"] = 1244
      view["pages"] = (0..<8).map { index -> [String: Any] in
        let stats: [String: Int] = ["like": 278_000 + index * 9_000, "coin": 15_000 + index * 4_000]
        var episode: [String: Any] = ["cid": 1000 + index, "page": index + 1, "duration": 1244]
        episode["part"] = "星海飞驰\(37 + index)"
        episode["first_frame"] = "https://fixture.invalid/cover/\(index)"
        episode["badge"] = index == 0 ? "" : "会员"
        episode["stat"] = stats
        return episode
      }
      view.removeValue(forKey: "ugc_season")
    }
    return view
  }
  private func response(_ url: URL, body: Data) -> AuthHTTPResponse {
    AuthHTTPResponse(body: body, response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

struct DebugFixtureImage: View {
  let index: Int
  var avatar = false
  private var color: Color { [Color.teal, .indigo, .orange, .purple, .mint, .blue, .pink, .brown][abs(index) % 8] }
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        LinearGradient(colors: [color, color.opacity(0.55), .black.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
        if avatar {
          Image(systemName: "person.fill").font(.system(size: geometry.size.height * 0.5)).foregroundStyle(.white.opacity(0.85))
        } else {
          Circle().fill(.white.opacity(0.12)).frame(width: geometry.size.width * 0.8)
            .offset(x: geometry.size.width * 0.3, y: geometry.size.height * 0.4)
          VStack(alignment: .leading, spacing: 8) {
            Image(systemName: ["mountain.2.fill", "desktopcomputer", "building.2.fill", "camera.fill", "gamecontroller.fill", "book.fill", "fork.knife", "atom"][abs(index) % 8])
              .font(.system(size: min(48, geometry.size.width * 0.2)))
            Text(["山野之间", "桌面计划", "城市漫游", "日常光影", "游戏设计", "故事时间", "一餐一饭", "科学现场"][abs(index) % 8])
              .font(.system(size: min(22, geometry.size.width * 0.08), weight: .semibold))
          }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(20)
        }
      }
    }.clipped()
  }
}
