import AppKit
import ManpingCore
import Foundation
import SwiftUI
#if DEBUG
import BiliProtocol
import GRPCCore
import SwiftProtobuf
#endif

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
  static var liveScene: String? {
    #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      guard enabled, let index = args.firstIndex(of: "--ui-live-scene"),
        args.indices.contains(index + 1)
      else { return nil }
      return args[index + 1]
    #else
      return nil
    #endif
  }
  static var usesLiveSceneMemory: Bool {
    #if DEBUG
      LiveFixturePresentation.requiresMemory(arguments: ProcessInfo.processInfo.arguments)
    #else
      false
    #endif
  }
  static var livePresentation: LiveFixturePresentation? {
    liveScene.flatMap { LiveFixturePresentation(scene: $0) }
  }
  static var liveIdentity: LiveContractFixture.Identity? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--ui-live-scene"), args.indices.contains(index + 1) else { return nil }
    switch args[index + 1] {
    case "anonymous": return .anonymous
    case "web-only": return .webOnly
    default: return .appAuthorized
    }
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
}

struct DebugUICredentialStore: AuthCredentialStore {
  func save(_ cookies: [HTTPCookie]) {}
  func load() -> [HTTPCookie] {
    if let identity = DebugUIFixtures.liveIdentity { return LiveContractFixture.cookies(identity: identity) }
    return [("SESSDATA", "fixture-live-session"), ("bili_jct", "fixture-live-csrf"), ("DedeUserID", String(M3Fixture.owner)), ("buvid3", "fixture-live-device")].compactMap { name, value in
      HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: name, .value: value])
    }
  }
  func saveToken(_ token: AppToken?) {}
  func loadToken() -> AppToken? {
    if let identity = DebugUIFixtures.liveIdentity { return LiveContractFixture.token(identity: identity) }
    return AppToken(mid: M3Fixture.owner, accessToken: "debug-fixture-access", refreshToken: "debug-fixture-refresh", expiresAt: 9_999_999_999)
  }
  func clear() {}
}

actor DebugUITransport: AuthTransport {
  private static let live = LiveContractFixture(outcome: {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--ui-live-scene"), args.indices.contains(index + 1) else { return .success }
      if args[index + 1] == "gift-sending" { return .late }
      if ["unknown-cross-room", "fullscreen-unknown", "sidebar-unknown"].contains(args[index + 1]) {
        return .executedResponseLost
      }
      return LiveContractFixture.Outcome(rawValue: args[index + 1]) ?? .success
    }(), scene: DebugUIFixtures.liveScene,
    delay: {
      try await Task.sleep(for: .seconds(DebugUIFixtures.liveScene == "gift-sending" ? 30 : 0.2))
    })
  static func waitForLiveMutation() async { await live.waitForMutation() }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    if LiveContractFixture.route(for: request) != nil { return try await Self.live.send(request) }
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
      data = ["wbi_img": ["img_url": "https://fixture.invalid/00000000000000000000000000000000.png",
        "sub_url": "https://fixture.invalid/11111111111111111111111111111111.png"]]
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
      #if DEBUG
      if let demo = DemoConfig.danmakuXML() { return response(url, body: demo) }
      #endif
      return response(url, body: Data("<i></i>".utf8))
    case "/x/dm/filter/user":
      data = ["rule": [["id": 1, "type": 0, "filter": "剧透"], ["id": 2, "type": 0, "filter": "前方高能"],
        ["id": 3, "type": 1, "filter": "^哈{3,}$"], ["id": 4, "type": 2, "filter": "abcdef12"]], "limit": 5000]
    default:
      if url.path == "/x/space/wbi/arc/search", ProcessInfo.processInfo.arguments.contains("--ui-space-fallback") {
        return response(url, body: Data(#"{"code":-352,"data":{}}"#.utf8))
      }
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

#if DEBUG
private actor SpaceLibraryCheckGate {
  private var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  func pause() async {
    entered = true
    observers.forEach { $0.resume() }; observers = []
    // Finish late even if the caller was cancelled, like an uncancellable response.
    await withCheckedContinuation { continuation = $0 }
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() { continuation?.resume(); continuation = nil }
}

private actor SpaceLibraryIdentityReader {
  let gate = SpaceLibraryCheckGate()
  private var armed = false
  func arm() { armed = true }
  func read(_ service: BiliService) async -> AuthSnapshot {
    if armed { armed = false; await gate.pause() }
    return await service.authSnapshot()
  }
}

private actor SpaceLibraryCheckTransport: AuthTransport {
  enum Hold { case secondWBI, collectWBI }
  let gate = SpaceLibraryCheckGate()
  private let fixture = DebugUITransport()
  private var hold: Hold?
  private var failCollectionTail = false
  private(set) var wbiSecondRequests = 0
  private(set) var appRequests = 0
  private(set) var collectionRequests = 0
  func arm(_ hold: Hold) { self.hold = hold }
  func failTail() { failCollectionTail = true }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    let url = request.url!
    let fields = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
      .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    if url.path == "/x/space/wbi/arc/search" {
      if fields["pn"] == "2" { wbiSecondRequests += 1 }
      if let hold, hold == .collectWBI || fields["pn"] == "2" {
        self.hold = nil
        await gate.pause()
        if hold == .collectWBI {
          return AuthHTTPResponse(body: Data(#"{"code":-352,"data":{}}"#.utf8),
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
      }
    }
    if url.path == "/x/v2/space/archive/cursor" { appRequests += 1 }
    if ["/x/polymer/web-space/seasons_archives_list", "/x/series/archives"].contains(url.path) {
      collectionRequests += 1
      if failCollectionTail, fields["page_num"] == "2" || fields["pn"] == "2" {
        throw URLError(.networkConnectionLost)
      }
    }
    return try await fixture.send(request)
  }
}

private actor SpaceSearchCheckRPCTransport: BiliRPCTransport {
  struct RequestRecord: Sendable { let mid: Int64; let keyword: String; let page: Int }
  private let fixture = M3FixtureRPCTransport(richUI: true)
  private(set) var requests: [RequestRecord] = []
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    let result = try await fixture.unary(request, response: response, descriptor: descriptor, metadata: metadata)
    guard let query = request as? Bilibili_App_Interfaces_V1_SearchArchiveReq,
      var reply = result as? Bilibili_App_Interfaces_V1_SearchArchiveReply else { return result }
    requests.append(RequestRecord(mid: query.mid, keyword: query.keyword, page: Int(query.pn)))
    // Distinct IDs make accidental collection/search mixing observable.
    reply.archives = reply.archives.map { original in
      var item = original
      item.archive.aid += 10_000; item.archive.title = "关键词搜索 · \(item.archive.aid)"
      return item
    }
    guard let typed = reply as? Response else { throw BiliRPCError.invalidArgument }
    return typed
  }
  func shutdown(grace: Duration) async { await fixture.shutdown(grace: grace) }
}

/// Runs actual LibraryModel entry points against delayed synthetic responses, without
/// windows or playback. Invoked only by the explicit DEBUG diagnostic launch parameter.
@MainActor enum SpaceLibraryModelChecks {
  private enum Failure: Error { case assertion(String) }
  private static func require(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure.assertion(message) }
  }
  static func run() async -> Bool {
    do {
      try await pagingOwnsList()
      print("PASS space model paging blocks playAll")
      try await collectingOwnsList()
      print("PASS space model playAll blocks paging across provider switch")
      try await staleTailCannotPublish()
      print("PASS space model query change during final identity await drops partial results")
      try await partialPlaybackHasOneOwner()
      print("PASS space model partial playback has one owned task and original context")
      try await collectionSearchResetsContext()
      return true
    } catch { print("FAIL space model check: \(error)"); return false }
  }
  private static func makeService(_ transport: SpaceLibraryCheckTransport) -> BiliService {
    BiliService(transport: transport, credentials: DebugUICredentialStore())
  }
  private static func pagingOwnsList() async throws {
    let transport = SpaceLibraryCheckTransport(), service: BiliService
    service = makeService(transport)
    let library = LibraryModel(service: service, observeIdentity: false)
    await library.load(.space(SpaceArchiveQuery(mid: 10001)))
    await transport.arm(.secondWBI)
    let paging = Task { await library.loadNext() }
    await transport.gate.waitUntilEntered()
    try require(library.isLoading, "delayed WBI page must own the list")
    var handoffs = 0
    library.playAll { _ in handoffs += 1 }
    try require(!library.playAllProgress && library.playbackTaskForChecks == nil,
      "playAll must not start beside an in-flight page")
    await transport.gate.release(); await paging.value
    let appRequests = await transport.appRequests
    try require(handoffs == 0 && appRequests == 0 && library.entries.count == 40,
      "rejected playAll cannot switch provider before delayed paging completes")
    library.cancel()
  }
  private static func collectingOwnsList() async throws {
    let transport = SpaceLibraryCheckTransport(), service: BiliService
    service = makeService(transport)
    let library = LibraryModel(service: service, observeIdentity: false)
    await library.load(.space(SpaceArchiveQuery(mid: 10001)))
    await transport.arm(.collectWBI)
    var handedOff: [Video] = []
    library.playAll { handedOff = $0.videos }
    let task = library.playbackTaskForChecks
    await transport.gate.waitUntilEntered()
    await library.loadNext()
    let wbiPages = await transport.wbiSecondRequests
    try require(library.playAllProgress && !library.isLoading && wbiPages == 0,
      "loadNext must not enqueue WBI paging while playAll owns the list")
    await transport.gate.release(); await task?.value
    try require(library.spacePage?.provider == .appCursor && handedOff.count == 40,
      "collection must hand off the restarted app list")
    try require(library.entries.allSatisfy { $0.title.hasPrefix("本地投稿") },
      "no WBI entries may mix back into the app list")
    await library.loadNext()
    try require(library.entries.count == 40 && !library.playAllProgress,
      "paging resumes using the app cursor after collection releases ownership")
    library.cancel()
  }
  private static func staleTailCannotPublish() async throws {
    let transport = SpaceLibraryCheckTransport(), reader = SpaceLibraryIdentityReader()
    let service = makeService(transport)
    let library = LibraryModel(service: service, observeIdentity: false, readIdentity: { await reader.read(service) })
    let collection = try await service.spaceCollections(mid: 10001).items[0]
    await library.load(.collection(collection, false))
    await transport.failTail(); await reader.arm()
    var handoffs = 0
    library.playAll { _ in handoffs += 1 }
    let oldTask = library.playbackTaskForChecks
    await reader.gate.waitUntilEntered()
    await library.load(.space(SpaceArchiveQuery(mid: 10002, order: .click)))
    await reader.gate.release(); await oldTask?.value
    library.playLoaded { _ in handoffs += 1 }
    try require(library.partialVideos.isEmpty && library.playAllNotice == nil && handoffs == 0,
      "old partial results must not publish after the final identity await")
    try require(library.spacePage?.order == .click && library.playbackTaskForChecks == nil,
      "playLoaded cannot rebind an old result to the new query generation")
    library.cancel()
  }
  private static func partialPlaybackHasOneOwner() async throws {
    let transport = SpaceLibraryCheckTransport(), service: BiliService
    service = makeService(transport)
    let library = LibraryModel(service: service, observeIdentity: false)
    let collection = try await service.spaceCollections(mid: 10001).items[0]
    await library.load(.collection(collection, false)); await transport.failTail()
    library.playAll { _ in }
    await library.playbackTaskForChecks?.value
    try require(library.partialVideos.count == 30, "second-page failure keeps the original partial list")
    let gate = SpaceLibraryCheckGate()
    var calls = 0, confirmed = false
    library.playLoaded { handoff in
      calls += 1
      await gate.pause()
      let identity = await service.authSnapshot()
      confirmed = (try? handoff.confirm(current: identity)) != nil
    }
    let originalTask = library.playbackTaskForChecks
    await gate.waitUntilEntered()
    library.playLoaded { _ in calls += 1 }
    await library.loadNext()
    try require(calls == 1 && library.playAllProgress && !library.isLoading,
      "a second playLoaded and paging cannot replace the owned handoff task")
    await library.load(.space(SpaceArchiveQuery(mid: 10002, order: .click)))
    await gate.release(); await originalTask?.value
    try require(calls == 1 && !confirmed && library.partialVideos.isEmpty,
      "original partial handoff must reject a changed query after its last await")
    library.cancel()
  }
  private static func collectionSearchResetsContext() async throws {
    for kind in [SpaceCollectionKind.season, .series] {
      let transport = SpaceLibraryCheckTransport(), rpcTransport = SpaceSearchCheckRPCTransport()
      let service = makeService(transport)
      let rpc = LibraryRPCService(auth: service, transport: rpcTransport, installationID: "space-search-check")
      let library = LibraryModel(service: service, libraryRPC: rpc, observeIdentity: false)
      guard let collection = try await service.spaceCollections(mid: 10001).items.first(where: { $0.kind == kind }) else {
        throw Failure.assertion("missing collection fixture")
      }
      var selection = SpacePageSelection(tab: "合集和系列", selectedCollection: collection)
      func currentMode() -> LibraryModel.Mode {
        selection.contentMode(mid: 10001, order: .click, tid: 0, descending: true)
      }
      await library.load(currentMode()); await library.loadNext()
      let oldIDs = Set(library.entries.map(\.id))
      try require(oldIDs.count == 40 && !library.hasMore, "collection must start beyond its first page")
      await transport.failTail()
      library.playAll { _ in }
      await library.playbackTaskForChecks?.value
      try require(library.partialVideos.count == 40, "failed collection tail must leave partial playback to invalidate")
      var oldHandoff: PlaylistHandoff?
      library.playLoaded { oldHandoff = $0 }
      await library.playbackTaskForChecks?.value
      try require(oldHandoff != nil, "partial handoff must exist before changing query")
      let collectionRequests = await transport.collectionRequests
      let oldRevision = selection.searchRevision
      selection.submit("  动画 \n", library: library)
      try require(selection.tab == "投稿" && selection.selectedCollection == nil && selection.submitted == "动画" &&
        selection.searchRevision != oldRevision, "search submission exits collection and trims the keyword")
      try require(library.partialVideos.isEmpty && library.playAllNotice == nil && library.playbackTaskForChecks == nil,
        "submission synchronously invalidates partial playback and its owned task")
      var stalePlays = 0
      library.playAll { _ in stalePlays += 1 }; library.playLoaded { _ in stalePlays += 1 }
      await library.loadNext()
      try require(stalePlays == 0 && library.playbackTaskForChecks == nil,
        "cancelled old mode cannot play or page before the replacement task starts")
      let identity = await service.authSnapshot()
      var rejectedOldHandoff = false
      do { _ = try oldHandoff?.confirm(current: identity) } catch is CancellationError { rejectedOldHandoff = true }
      try require(rejectedOldHandoff, "old partial handoff must reject the new search generation")
      await library.load(currentMode())
      let firstRequests = await rpcTransport.requests
      try require(firstRequests.count == 1 && firstRequests[0].page == 1 && firstRequests[0].mid == 10001 &&
        firstRequests[0].keyword == "动画" && library.spacePage?.provider == .grpc && library.entries.count == 20,
        "production content mode must restart keyword gRPC at page one")
      try require(oldIDs.isDisjoint(with: library.entries.map(\.id)), "old collection entries must be replaced")
      await library.loadNext()
      try require(library.entries.count == 40 && !library.hasMore, "search pagination must advance its own cursor")
      var videos: [Video] = []
      library.playAll { videos = $0.videos }
      await library.playbackTaskForChecks?.value
      let requests = await rpcTransport.requests
      let afterCollectionRequests = await transport.collectionRequests
      try require(requests.map(\.page) == [1, 2, 1, 2] && videos.count == 40 &&
        videos.allSatisfy { $0.title.hasPrefix("关键词搜索") && ($0.aid ?? 0) >= 10_000 } &&
        afterCollectionRequests == collectionRequests, "paging and playAll must use only the new keyword gRPC source")
      let repeatedRevision = selection.searchRevision
      selection.submit("动画", library: library)
      try require(selection.searchRevision != repeatedRevision, "same-keyword submission must change the task ID")
      await library.load(currentMode())
      let repeatedRequests = await rpcTransport.requests
      try require(repeatedRequests.map(\.page) == [1, 2, 1, 2, 1] && library.entries.count == 20 && library.hasMore,
        "repeating a search must restart instead of leaving the cancelled mode empty")
      library.cancel()
      print("PASS space model collection search kind=\(kind.rawValue) exited_detail=yes keyword=动画 provider=grpc pages=1,2 playAll=40 search_only=yes stale_handoff=rejected repeated_page=1")
    }
  }
}
#endif
