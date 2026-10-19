import Foundation
import XCTest
@testable import ManpingCore

final class M8AIBudgetTests: XCTestCase {
  private let source = AISource.video(AIVideoInfo(aid: 1, cid: 2, title: "视频", duration: 3600))
  private func transcript(minutes: Int, perMinute: Int = 6, text: String = "这是一句比较长的字幕内容，用来占用预算") -> AITranscript {
    var cues: [DownloadSubtitleCue] = []
    for index in 0..<(minutes * perMinute) {
      let start = Double(index) * 60 / Double(perMinute)
      cues.append(DownloadSubtitleCue(start: start, end: start + 3, text: text + "\(index)"))
    }
    return AITranscript.clean(cues, language: "zh-CN", isAI: false)
  }
  private func comments(_ count: Int) -> AICommentDigest? {
    AICommentDigest.make(pages: [RPCCommentPage(oid: 1, targetType: 1, comments: (0..<count).map {
      RPCComment(id: Int64($0 + 1), root: 0, author: RPCUser(mid: 1, name: "u", avatar: nil), text: String(repeating: "评", count: 150),
        emotes: [], createdAt: 0, likes: Int64(100 - $0), replyCount: 0, liked: false, pinned: false, replies: [])
    }, pinned: nil, next: 0, isEnd: true)], uploaderMid: nil)
  }

  func testBudgetAndModelCapacity() {
    let known = AIModel(id: "claude-sonnet-5-5", name: "x").withKnownCapacity.requestBudget(desiredOutput: 6_000)
    XCTAssertTrue(known.known); XCTAssertEqual(known.contextTokens, 200_000); XCTAssertEqual(known.maxOutputTokens, 6_000)
    XCTAssertEqual(AIModel(id: "my-local-model", name: "x").requestBudget(desiredOutput: 6_000).contextTokens, 32_768)
    XCTAssertFalse(AIModel(id: "my-local-model", name: "x").requestBudget(desiredOutput: 6_000).known)
    XCTAssertEqual(AIModel(id: "moonshot-v1-8k", name: "x").requestBudget(desiredOutput: 6_000).contextTokens, 8_192)
    XCTAssertEqual(AIModel(id: "custom", name: "x", contextTokens: 64_000, maxOutputTokens: 2_000).requestBudget(desiredOutput: 6_000).maxOutputTokens, 2_000)
    let unknown = AIRequestBudget(contextTokens: 32_768, maxOutputTokens: 4_096, known: false)
    XCTAssertEqual(unknown.reduced()?.contextTokens, 16_384)
    XCTAssertEqual(unknown.reduced()?.reduced()?.contextTokens, 8_192)
    XCTAssertNil(AIRequestBudget(contextTokens: 4_096, maxOutputTokens: 1_024, known: false).reduced())
    XCTAssertLessThan(unknown.inputLimit, unknown.contextTokens - unknown.maxOutputTokens)
    XCTAssertEqual(AIProvider.anthropic.predefinedModels.first?.contextTokens, 200_000)
    // Capacity survives the public configuration round trip and is validated.
    let model = AIModel(id: "m", name: "m", contextTokens: 50_000, maxOutputTokens: 4_000)
    let decoded = try? JSONDecoder().decode(AIModel.self, from: JSONEncoder().encode(model))
    XCTAssertEqual(decoded, model)
  }

  func testAssemblerDropsL2ThenHistoryThenAsksForSegmentation() throws {
    let bundle = AIMaterialBundle(source: source, transcript: transcript(minutes: 10), comments: comments(10))
    let pack = AIContextPack.build(bundle, preset: AIBuiltInPresets.question, settings: AIMaterialSettings())
    let history = (0..<5).map { AIHistoryTurn(question: "问题\($0)", answer: String(repeating: "答", count: 400), materials: [.subtitles]) }
    func assemble(_ context: Int) -> AIAssemblyOutcome {
      AIPromptAssembler.assemble(.init(system: AISystemPrompt.defaultText, preset: AIBuiltInPresets.question, pack: pack, question: "这里在讲什么",
        history: history, settings: AIMaterialSettings(), budget: AIRequestBudget(contextTokens: context, maxOutputTokens: 1_000, known: true)))
    }
    guard case .ready(let full) = assemble(200_000) else { return XCTFail() }
    XCTAssertEqual(full.recentTurns, 3); XCTAssertEqual(full.compressedTurns, 2)
    XCTAssertTrue(full.droppedTags.isEmpty)
    XCTAssertTrue(full.materials.contains(.history))
    XCTAssertEqual(full.request.messages.map(\.role), [.user, .assistant, .user, .assistant, .user, .assistant, .user])
    XCTAssertTrue(full.request.messages[0].text.contains("<history_summary>"))
    XCTAssertEqual(full.request.messages.last?.text, "问题：这里在讲什么")
    // Tighter: comments go first, then history; L0 and the question stay.
    let base = AITokenEstimator.estimate(pack.without([.comments]).rendered()) + AITokenEstimator.estimate(AISystemPrompt.defaultText) + 1_000
    guard case .ready(let tight) = assemble(base + 1_500) else { return XCTFail("Expected a fitted request") }
    XCTAssertEqual(tight.droppedTags, [.comments])
    XCTAssertLessThan(tight.recentTurns + tight.compressedTurns, 5)
    XCTAssertFalse(tight.notes.isEmpty)
    XCTAssertTrue(tight.request.messages[0].text.contains("<metadata>"))
    XCTAssertTrue(tight.request.messages.last?.text.contains("这里在讲什么") == true)
    XCTAssertLessThanOrEqual(tight.request.estimatedInputTokens, AIRequestBudget(contextTokens: base + 1_500, maxOutputTokens: 1_000, known: true).inputLimit)
    // The transcript alone is too long: segmentation.
    XCTAssertEqual(assemble(3_000), .needsSegmentation)
  }

  func testHistoryWithSwitchedOffMaterialIsNotResent() {
    let history = [AIHistoryTurn(question: "弹幕说什么", answer: "大家在刷前方高能", materials: [.danmaku]),
      AIHistoryTurn(question: "讲了什么", answer: "讲了翻山", materials: [.subtitles])]
    let allowed = AIPromptAssembler.allowedHistory(history, settings: AIMaterialSettings(disabled: [.danmaku]), oneTime: [])
    XCTAssertEqual(allowed.map(\.question), ["讲了什么"])
    XCTAssertTrue(AIPromptAssembler.allowedHistory(history, settings: AIMaterialSettings(disabled: [.history]), oneTime: []).isEmpty)
    let pack = AIContextPack.build(AIMaterialBundle(source: source), preset: AIBuiltInPresets.question, settings: AIMaterialSettings(disabled: [.danmaku]))
    guard case .ready(let assembly) = AIPromptAssembler.assemble(.init(system: "s", preset: AIBuiltInPresets.question, pack: pack, question: "q",
      history: history, settings: AIMaterialSettings(disabled: [.danmaku]), budget: AIRequestBudget(contextTokens: 100_000, maxOutputTokens: 1_000, known: true))) else { return XCTFail() }
    let sent = assembly.request.messages.map(\.text).joined()
    XCTAssertFalse(sent.contains("前方高能"))
    XCTAssertFalse(assembly.materials.contains(.danmaku))
  }

  func testLegacyTemplateRendersOldVariablesFromAllowedMaterial() {
    let legacy = AIPreset(id: "legacy-videoSummary", name: "视频总结（自定义）", targets: [.video], taskPrompt: "标题 {title}\n字幕 {subtitle}\n评论 {comments}",
      optional: [.subtitles, .comments], legacyTemplate: true)
    let bundle = AIMaterialBundle(source: source, transcript: transcript(minutes: 1), comments: comments(1))
    let pack = AIContextPack.build(bundle, preset: legacy, settings: AIMaterialSettings(disabled: [.comments]))
    guard case .ready(let assembly) = AIPromptAssembler.assemble(.init(system: "s", preset: legacy, pack: pack, settings: AIMaterialSettings(disabled: [.comments]),
      budget: AIRequestBudget(contextTokens: 100_000, maxOutputTokens: 1_000, known: true))) else { return XCTFail() }
    let text = assembly.request.messages[0].text
    XCTAssertTrue(text.hasPrefix("标题 视频\n字幕 [c1 00:00-00:03]"))
    XCTAssertTrue(text.hasSuffix("评论 无评论"))
    XCTAssertFalse(text.contains("<context>"))
  }

  func testSegmentPlannerPrefersChaptersAndSplitsOversizedWindows() {
    let long = transcript(minutes: 30)
    // Chapters are the cut points; windows only merge while a part stays within ten minutes.
    let chunks = AISegmentPlanner.transcriptChunks(long, boundaries: [400, 1000], maxTokens: 100_000, duration: 1800)
    XCTAssertEqual(chunks.map(\.start), [0, 400, 1000])
    let fiveMinute = AISegmentPlanner.transcriptChunks(long, boundaries: [], maxTokens: 100_000, duration: 1800)
    XCTAssertEqual(fiveMinute.map(\.start), [0, 600, 1200])
    let small = AISegmentPlanner.transcriptChunks(long, boundaries: [], maxTokens: 300, duration: 1800)
    XCTAssertGreaterThan(small.count, 6)
    XCTAssertTrue(small.allSatisfy { $0.tokens <= 300 })
    XCTAssertEqual(Set(small.map(\.index)).count, small.count)
    // A single cue larger than the budget is split by characters.
    let giant = AITranscript(language: "zh", isAI: false, cues: [AITranscriptCue(id: "c1", start: 0, end: 10, text: String(repeating: "长", count: 2_000))])
    let pieces = AISegmentPlanner.transcriptChunks(giant, boundaries: [], maxTokens: 300, duration: 10)
    XCTAssertGreaterThan(pieces.count, 5)
    XCTAssertTrue(pieces.allSatisfy { $0.tokens <= 300 })
    let article = AIArticleInfo(id: 1, title: "t", paragraphs: (0..<40).map { AIArticleParagraph(heading: $0 % 10 == 0 ? 2 : nil, text: String(repeating: "文", count: 120)) })
    let parts = AISegmentPlanner.articleChunks(article, maxTokens: 600)
    XCTAssertGreaterThan(parts.count, 4)
    XCTAssertEqual(parts.first?.label?.hasPrefix("p1-"), true)
  }

  func testSegmentRunnerRetriesCachesAndReportsCoverage() async throws {
    let chunks = AISegmentPlanner.transcriptChunks(transcript(minutes: 30), boundaries: [], maxTokens: 100_000, duration: 1800)
    XCTAssertEqual(chunks.count, 3)
    let calls = AICallCounter()
    let cache = AISegmentCache()
    await cache.put("seg-0", "缓存命中")
    let result = try await AISegmentRunner.run(chunks, request: { AIConversationRequest(system: nil, messages: [.user("段 \($0.index)")]) },
      cacheKey: { "seg-\($0.index)" }, cached: { await cache.get($0) }, store: { await cache.put($0, $1) },
      generate: { request in
        _ = calls.increment()
        if request.messages[0].text == "段 2" { throw AIChatFailure.providerError }
        return "摘要"
      }, progress: { _, _ in })
    XCTAssertEqual(result.summaries.map(\.id), ["g1", "g2"])
    XCTAssertEqual(result.summaries.first?.text, "缓存命中")
    XCTAssertEqual(calls.count, 3) // segment 1 once, segment 2 twice (one retry)
    XCTAssertEqual(result.coverageNote, "部分内容未覆盖：20:00-29:53")
    let stored = await cache.get("seg-1")
    XCTAssertEqual(stored, "摘要")
    do {
      _ = try await AISegmentRunner.run(chunks, request: { _ in AIConversationRequest(system: nil, messages: [.user("x")]) }, cacheKey: { "k\($0.index)" },
        cached: { _ in nil }, store: { _, _ in }, generate: { _ in throw AIChatFailure.providerError }, progress: { _, _ in })
      XCTFail("No coverage must fail")
    } catch let failure as AISegmentationFailure { XCTAssertEqual(failure, .tooLittleCoverage(covered: 0, total: 3)) }
    do {
      _ = try await AISegmentRunner.run(chunks, request: { _ in AIConversationRequest(system: nil, messages: [.user("x")]) }, cacheKey: { "k\($0.index)" },
        cached: { _ in nil }, store: { _, _ in }, generate: { _ in throw AIChatFailure.unauthorized }, progress: { _, _ in })
      XCTFail("Account failures stop the run")
    } catch let failure as AIChatFailure { XCTAssertEqual(failure, .unauthorized) }
  }
}

actor AISegmentCache {
  private var values: [String: String] = [:]
  func get(_ key: String) -> String? { values[key] }
  func put(_ key: String, _ value: String) { values[key] = value }
}
