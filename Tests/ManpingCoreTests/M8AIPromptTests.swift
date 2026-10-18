import Foundation
import XCTest
@testable import ManpingCore

private final class AIPromptCredentials: AuthCredentialStore, @unchecked Sendable {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ token: AppToken?) {}
  func clear() {}
}
private actor AIPromptTransport: AuthTransport {
  private(set) var paths: [String] = []
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    paths.append(request.url!.path)
    let object: [String: Any]
    if request.url?.path == "/x/player/wbi/v2" {
      object = ["code": 0, "data": ["subtitle": ["subtitles": [
        ["id": 1, "id_str": "1", "lan": "ai-zh", "lan_doc": "AI 中文", "ai_type": 1,
          "subtitle_url": "https://aisubtitle.hdslb.com/bfs/ai_subtitle/fixture.json"],
        ["id": 2, "id_str": "2", "lan": "zh-CN", "lan_doc": "中文", "ai_type": 0,
          "subtitle_url": "https://i0.hdslb.com/bfs/subtitle/fixture.json"]
      ]]]]
    } else {
      object = ["body": [["from": 0.0, "to": 12.5, "content": "字幕含 {question} 字样。"]]]
    }
    return AuthHTTPResponse(body: try JSONSerialization.data(withJSONObject: object),
      response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private actor AIPromptRPC: BiliRPCService {
  private(set) var requestedType: Int32?
  private(set) var requestedSort: RPCCommentSort?
  let afterRead: (@Sendable () async throws -> Void)?
  init(afterRead: (@Sendable () async throws -> Void)? = nil) { self.afterRead = afterRead }
  func comments(oid: Int64, targetType: Int32, sort: RPCCommentSort, next: Int64) async throws -> RPCCommentPage {
    requestedType = targetType; requestedSort = sort
    try await afterRead?()
    let user = RPCUser(mid: 1, name: "fixture", avatar: nil)
    let comment = RPCComment(id: 1, root: 1, author: user, text: "内容清晰。", emotes: [], createdAt: 0,
      likes: 1, replyCount: 0, liked: false, pinned: false, replies: [])
    return RPCCommentPage(oid: oid, targetType: targetType, comments: [comment], pinned: nil, next: 0, isEnd: true)
  }
  func commentDetails(oid: Int64, targetType: Int32, root: Int64, sort: RPCCommentSort, next: Int64) async throws -> RPCCommentPage { throw BiliRPCError.invalidArgument }
  func dynamics(_ query: RPCDynamicQuery) async throws -> RPCDynamicPage { throw BiliRPCError.invalidArgument }
  func history(business: String, max: Int64) async throws -> RPCHistoryPage { throw BiliRPCError.invalidArgument }
  func popular(index: Int64, version: String) async throws -> RPCPopularPage { throw BiliRPCError.invalidArgument }
  func ranking(region: Int32) async throws -> [RPCVideoCard] { throw BiliRPCError.invalidArgument }
  func shutdown() async {}
}
final class M8AIPromptTests: XCTestCase, @unchecked Sendable {
  func testAllSourceTemplatesRenderOnePromptAndPreserveContextBraces() throws {
    for task in AIPromptTask.allCases {
      let values = Dictionary(uniqueKeysWithValues: task.placeholders.map { ($0, "fixture-" + $0) })
      let rendered = try AIPromptRenderer.render(template: task.defaultTemplate, values: values)
      for token in task.placeholders {
        XCTAssertTrue(rendered.contains("fixture-" + token), "Missing \(token) in \(task)")
        XCTAssertFalse(rendered.contains("{" + token + "}"))
      }
      XCTAssertTrue(rendered.contains("以下是"))
    }
    XCTAssertEqual(try AIPromptRenderer.render(template: "{title} | {question}", values: ["title": "literal {question}", "question": "actual"]),
      "literal {question} | actual")
    XCTAssertThrowsError(try AIPromptRenderer.render(template: "  ", values: [:]))
    XCTAssertThrowsError(try AIPromptRenderer.render(template: String(repeating: "x", count: 128 * 1024 + 1), values: [:]))
  }
  func testSubtitleTimingAndWholeCommentUTF16BudgetMatchSource() {
    let cues = [DownloadSubtitleCue(start: 62.8, end: 3605.9, text: "fixture")]
    XCTAssertEqual(AIPromptContext.subtitleText(cues), "01:02 - 01:00:05: fixture")
    let first = String(repeating: "😀", count: 390)
    XCTAssertEqual(AIPromptContext.hotCommentText([first, "this does not fit", "last"]), first + "\n------")
    XCTAssertEqual(AIPromptContext.hotCommentText([String(repeating: "x", count: 801)]), "无评论")
    XCTAssertEqual(AIContextSource.normalizedArticle("  first\n\nsecond\tthird "), "first second third")
  }
  func testVideoContextPrefersHumanSubtitleAndReadsOnlyOneHotPage() async throws {
    let transport = AIPromptTransport()
    let service = BiliService(transport: transport, credentials: AIPromptCredentials())
    let identity = await service.authSnapshot()
    let rpc = AIPromptRPC()
    let context = try await service.aiPromptContext(source: .video(aid: 100, cid: 200, title: "fixture", description: "intro"),
      task: .videoEvaluation, rpc: rpc, expectedIdentity: identity)
    XCTAssertEqual(context.values["subtitle"], "00:00 - 00:12: 字幕含 {question} 字样。")
    XCTAssertEqual(context.values["comments"], "内容清晰。\n------")
    let paths = await transport.paths
    XCTAssertEqual(paths, ["/x/player/wbi/v2", "/bfs/subtitle/fixture.json"])
    let type = await rpc.requestedType
    XCTAssertEqual(type, 1)
    let sort = await rpc.requestedSort
    if case .hot? = sort {} else { XCTFail("Expected hot comments") }
  }
  func testArticleEvaluationUsesArticleTargetAndDoesNotLoadSubtitle() async throws {
    let transport = AIPromptTransport()
    let service = BiliService(transport: transport, credentials: AIPromptCredentials())
    let rpc = AIPromptRPC()
    let context = try await service.aiPromptContext(source: .article(id: 100, title: "fixture", content: "正文\n内容"),
      task: .articleEvaluation, rpc: rpc, expectedIdentity: await service.authSnapshot())
    XCTAssertEqual(context.values["content"], "正文 内容")
    let paths = await transport.paths
    XCTAssertTrue(paths.isEmpty)
    let type = await rpc.requestedType
    XCTAssertEqual(type, 12)
  }
  func testIdentityChangeDuringContextReadCancelsBeforePromptUse() async throws {
    let service = BiliService(transport: AIPromptTransport(), credentials: AIPromptCredentials())
    let rpc = AIPromptRPC(afterRead: { try await service.logout() })
    let snapshot = await service.authSnapshot()
    do {
      _ = try await service.aiPromptContext(source: .article(id: 1, title: "fixture", content: "正文"),
        task: .articleEvaluation, rpc: rpc, expectedIdentity: snapshot)
      XCTFail("Expected identity cancellation")
    } catch is CancellationError {}
  }
  @MainActor func testPromptPersistenceAndFixtureIsolation() throws {
    let suite = "fixture.ai.prompts." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let persisted = AIPromptStore(defaults: defaults)
    try persisted.save("custom {title}", for: .videoSummary); persisted.streaming = false
    let restored = AIPromptStore(defaults: defaults)
    XCTAssertEqual(restored.template(for: .videoSummary), "custom {title}")
    XCTAssertFalse(restored.streaming)
    let fixture = AIPromptStore(fixtures: true, defaults: defaults)
    XCTAssertEqual(fixture.template(for: .videoSummary), AIPromptTask.videoSummary.defaultTemplate)
    XCTAssertTrue(fixture.streaming)
    try fixture.save("fixture {title}", for: .videoSummary)
    XCTAssertEqual(restored.template(for: .videoSummary), "custom {title}")
    XCTAssertEqual(defaults.string(forKey: "Manping.AI.prompt.videoSummary"), "custom {title}")
    restored.reset(.videoSummary)
    XCTAssertEqual(AIPromptStore(defaults: defaults).template(for: .videoSummary), AIPromptTask.videoSummary.defaultTemplate)
  }
}
