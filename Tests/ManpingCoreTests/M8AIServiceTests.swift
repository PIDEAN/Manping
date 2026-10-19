import Foundation
import XCTest
@testable import ManpingCore

/// Records every request and answers through a closure; never touches the network.
private final class AIRecordingBackends: AIBackendFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(AIConversationRequest, AIRequestBudget?)] = []
  let model: AIModel
  let answer: @Sendable (AIConversationRequest, Int) async throws -> String
  init(model: AIModel = AIModel(id: "fixture-model", name: "f", contextTokens: 128_000, maxOutputTokens: 8_000),
    answer: @escaping @Sendable (AIConversationRequest, Int) async throws -> String = { request, _ in AIFixtureBackend.cannedAnswer(request) }) {
    self.model = model; self.answer = answer
  }
  var requests: [AIConversationRequest] { lock.withLock { recorded.map(\.0) } }
  func record(_ request: AIConversationRequest) -> Int { lock.withLock { recorded.append((request, request.budget)); return recorded.count } }
  func revision() async -> UInt64 { 0 }
  func backend(provider: AIProvider, modelID: String) async throws -> any AIModelBackend {
    AIRecordingBackend(owner: self, descriptor: AIBackendDescriptor(provider: provider, model: model, endpoint: "https://fixture.invalid",
      apiVersion: nil, revision: 0))
  }
}
private struct AIRecordingBackend: AIModelBackend {
  let owner: AIRecordingBackends
  let descriptor: AIBackendDescriptor
  func budget(desiredOutput: Int) -> AIRequestBudget { descriptor.model.requestBudget(desiredOutput: desiredOutput) }
  func stream(_ request: AIConversationRequest, options: AIResponseOptions, streaming: Bool) -> AsyncThrowingStream<String, Error> {
    let owner = self.owner
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let index = owner.record(request)
          let text = try await owner.answer(request, index)
          for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            continuation.yield(String(piece) + "\n")
            await Task.yield()
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
private final class AIIdentityBox: @unchecked Sendable {
  private let lock = NSLock()
  private var epoch: UInt64 = 1
  func bump() { lock.withLock { epoch += 1 } }
  var gate: AIIdentityGate {
    AIIdentityGate { [self] in lock.withLock { AuthSnapshot(epoch: epoch, identityRevision: 0, state: .needsLogin, token: nil) } }
  }
}
/// The fixture materials with an optional long transcript.
private struct AITestMaterials: AIMaterialProvider {
  let longMinutes: Int?
  func gather(source: AISource, kinds: Set<AIMaterialKind>, settings: AIMaterialSettings, identity: AuthSnapshot?,
    fallbackChapters: [AIViewPoint], loadedDanmaku: [DanmakuComment]?) async throws -> AIMaterialBundle {
    var bundle = try await AIFixtureMaterialProvider().gather(source: source, kinds: kinds, settings: settings, identity: identity,
      fallbackChapters: fallbackChapters, loadedDanmaku: loadedDanmaku)
    if let longMinutes, kinds.contains(.subtitles) {
      let cues = (0..<(longMinutes * 6)).map { DownloadSubtitleCue(start: Double($0) * 10, end: Double($0) * 10 + 3, text: "第 \($0) 句比较长的字幕内容，用来占用预算") }
      bundle.transcript = AITranscript.clean(cues, language: "zh-CN", isAI: false)
    }
    return bundle
  }
}

/// Fails the subtitle download once (a passing failure), then serves the fixture materials.
private final class AIFlakyMaterials: AIMaterialProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var calls: Int { lock.withLock { count } }
  func gather(source: AISource, kinds: Set<AIMaterialKind>, settings: AIMaterialSettings, identity: AuthSnapshot?,
    fallbackChapters: [AIViewPoint], loadedDanmaku: [DanmakuComment]?) async throws -> AIMaterialBundle {
    let call = lock.withLock { count += 1; return count }
    var bundle = try await AIFixtureMaterialProvider().gather(source: source, kinds: kinds, settings: settings, identity: identity,
      fallbackChapters: fallbackChapters, loadedDanmaku: loadedDanmaku)
    if call == 1 { bundle.transcript = nil; bundle.transcriptNote = "字幕下载失败"; bundle.transient = true }
    return bundle
  }
}
/// Article sources carry their body themselves; nothing else is gathered.
private struct AIArticleMaterials: AIMaterialProvider {
  func gather(source: AISource, kinds: Set<AIMaterialKind>, settings: AIMaterialSettings, identity: AuthSnapshot?,
    fallbackChapters: [AIViewPoint], loadedDanmaku: [DanmakuComment]?) async throws -> AIMaterialBundle { AIMaterialBundle(source: source) }
}

final class M8AIServiceTests: XCTestCase, @unchecked Sendable {
  private let source = AISource.video(AIVideoInfo(aid: 1, cid: 2, bvid: "BV1", title: "走进山野", duration: 1104, uploaderMid: 2))
  private func options(_ settings: AIMaterialSettings = AIMaterialSettings(), save: Bool = true, oneTime: Set<AIMaterialKind> = []) -> AIRunOptions {
    AIRunOptions(provider: .openAI, modelID: "fixture-model", settings: settings, oneTime: oneTime, saveConversations: save)
  }
  private func collect(_ run: AIConversationRun) async -> [AIConversationEvent] {
    var events: [AIConversationEvent] = []
    for await event in run.events { events.append(event) }
    return events
  }
  private func completed(_ events: [AIConversationEvent]) -> AITurn? {
    for event in events { if case .completed(let turn) = event { return turn } }
    return nil
  }
  private func failure(_ events: [AIConversationEvent]) -> String? {
    for event in events { if case .failed(let message) = event { return message } }
    return nil
  }

  func testChaptersRunValidatesCachesAndRegenerates() async throws {
    let backends = AIRecordingBackends()
    let store = try AIConversationStore(url: nil)
    let service = AIConversationService(store: store, materials: AIFixtureMaterialProvider(), backends: backends, identity: .unchecked)
    let first = await collect(await service.start(preset: AIBuiltInPresets.chapters, source: source, options: options()))
    let turn = try XCTUnwrap(completed(first), String(describing: first))
    guard case .structured(.chapters(let chapters)) = turn.content else { return XCTFail("\(turn.content)") }
    XCTAssertEqual(chapters.chapters.count, 3)
    XCTAssertTrue(chapters.chapters.allSatisfy(\.start.seekable))
    XCTAssertTrue(first.contains(.status(.organizing)))
    XCTAssertFalse(first.contains { if case .textDelta = $0 { return true }; return false })
    XCTAssertEqual(backends.requests.count, 1)
    let request = try XCTUnwrap(backends.requests.first)
    XCTAssertEqual(request.system, AISystemPrompt.defaultText)
    XCTAssertEqual(request.format, .json)
    XCTAssertTrue(request.messages[0].text.contains("<transcript source=\"cc\""))
    XCTAssertFalse(request.messages[0].text.contains("<comments")) // not a material of 章节总结
    // Same inputs: cached, no second request.
    let second = await collect(await service.start(preset: AIBuiltInPresets.chapters, source: source, options: options()))
    XCTAssertTrue(second.contains(.status(.cached)))
    XCTAssertEqual(completed(second)?.fromCache, true)
    XCTAssertEqual(backends.requests.count, 1)
    // Regenerate bypasses the cache and replaces the turn.
    let saved = await service.thread(for: source)
    let thread = try XCTUnwrap(saved)
    XCTAssertEqual(thread.turns.count, 2)
    let again = await collect(await service.regenerate(turnID: thread.turns[1].id, preset: AIBuiltInPresets.chapters, source: source, options: options()))
    XCTAssertEqual(completed(again)?.fromCache, false)
    XCTAssertEqual(backends.requests.count, 2)
    let replaced = await service.thread(for: source)
    XCTAssertEqual(replaced?.turns.count, 2)
    // A different system prompt is a different answer.
    var edited = options(); edited.systemPrompt = "另一套规则"
    _ = await collect(await service.start(preset: AIBuiltInPresets.chapters, source: source, options: edited))
    XCTAssertEqual(backends.requests.count, 3)
  }

  func testAnswerAndSegmentKeysSeparateEveryDeterminingInput() {
    let pack = AIContextPack.build(AIMaterialBundle(source: source), preset: AIBuiltInPresets.question, settings: AIMaterialSettings())
    let descriptor = AIBackendDescriptor(provider: .openAI, model: AIModel(id: "m", name: "m"), endpoint: "https://a", apiVersion: nil,
      revision: 0)
    let descriptor_ = descriptor
    func key(_ request: AIConversationRequest, source: AISource? = nil, descriptor: AIBackendDescriptor? = nil, preset: AIPreset = AIBuiltInPresets.question) -> String {
      AIConversationService.answerKey(source: source ?? self.source, preset: preset, mode: preset.output, request: request, pack: pack,
        descriptor: descriptor ?? descriptor_, options: options())
    }
    let base = AIConversationRequest(system: "s", messages: [.user("ctx 问题：一")])
    let k = key(base)
    XCTAssertEqual(k, key(base))
    XCTAssertNotEqual(k, key(AIConversationRequest(system: "s", messages: [.user("ctx 问题：二")])))
    XCTAssertNotEqual(k, key(AIConversationRequest(system: "s", messages: [.user("ctx"), .assistant("a"), .user("问题：一")])))
    XCTAssertNotEqual(k, key(AIConversationRequest(system: "t", messages: [.user("ctx 问题：一")])))
    XCTAssertNotEqual(k, key(base, source: .video(AIVideoInfo(aid: 1, cid: 3, title: "t", duration: 1104))))
    XCTAssertNotEqual(k, key(base, source: .pgc(AIPGCInfo(epid: 1, aid: 1, cid: 2, seasonTitle: "s", episodeTitle: "e", duration: 1104))))
    XCTAssertNotEqual(k, key(base, descriptor: AIBackendDescriptor(provider: .openAI, model: AIModel(id: "m", name: "m"), endpoint: "https://b",
      apiVersion: nil, revision: 0)))
    XCTAssertNotEqual(k, key(base, descriptor: AIBackendDescriptor(provider: .deepSeek, model: AIModel(id: "m", name: "m"), endpoint: "https://a",
      apiVersion: nil, revision: 0)))
    XCTAssertNotEqual(k, key(base, descriptor: AIBackendDescriptor(provider: .openAI, model: AIModel(id: "m2", name: "m"), endpoint: "https://a",
      apiVersion: nil, revision: 0)))
    var bumped = AIBuiltInPresets.question; bumped.version += 1
    XCTAssertNotEqual(k, key(base, preset: bumped))
    let chunk = AISegmentChunk(index: 0, start: 0, end: 300, label: nil, body: "[c1 00:00-00:03] 字幕")
    let segment = AIConversationService.segmentKey(chunk, descriptor: descriptor, system: "s")
    XCTAssertEqual(segment, AIConversationService.segmentKey(chunk, descriptor: descriptor, system: "s"))
    XCTAssertNotEqual(segment, AIConversationService.segmentKey(AISegmentChunk(index: 0, start: 0, end: 301, label: nil, body: chunk.body),
      descriptor: descriptor, system: "s"))
    XCTAssertNotEqual(segment, AIConversationService.segmentKey(AISegmentChunk(index: 0, start: 0, end: 300, label: nil, body: "[c1 00:00-00:03] 改"),
      descriptor: descriptor, system: "s"))
  }

  func testSwitchedOffMaterialIsNeverSentAndHistoryIsRebuilt() async throws {
    let backends = AIRecordingBackends()
    let service = AIConversationService(store: try AIConversationStore(url: nil), materials: AIFixtureMaterialProvider(), backends: backends, identity: .unchecked)
    let off = AIMaterialSettings(disabled: [.danmaku])
    let blocked = await collect(await service.start(preset: AIBuiltInPresets.highlights, source: source, options: options(off)))
    XCTAssertTrue(failure(blocked)?.contains("弹幕统计") == true)
    XCTAssertTrue(backends.requests.isEmpty)
    // One-time permission runs it.
    let allowed = await collect(await service.start(preset: AIBuiltInPresets.highlights, source: source, options: options(off, oneTime: [.danmaku])))
    guard case .structured(.highlights(let highlights))? = completed(allowed)?.content else { return XCTFail("\(allowed)") }
    XCTAssertEqual(highlights.moments.first?.quotes.first?.text, "前方高能")
    // A question with danmaku on, then danmaku off: the earlier exchange that carried danmaku is not re-sent.
    _ = await collect(await service.start(preset: AIBuiltInPresets.question, source: source, question: "弹幕在说什么", options: options()))
    let lastWithDanmaku = try XCTUnwrap(backends.requests.last)
    XCTAssertTrue(lastWithDanmaku.messages.map(\.text).joined().contains("danmaku_digest"))
    _ = await collect(await service.start(preset: AIBuiltInPresets.question, source: source, question: "讲了什么", options: options(off)))
    let restricted = try XCTUnwrap(backends.requests.last)
    let sent = restricted.messages.map(\.text).joined()
    XCTAssertFalse(sent.contains("danmaku_digest"))
    XCTAssertFalse(sent.contains("「前方高能」")) // representative danmaku (the subtitle itself mentions the phrase)
    XCTAssertFalse(sent.contains("弹幕在说什么"))
    XCTAssertEqual(restricted.messages.count, 1)
  }

  func testIdentityChangeAndClearStopWrites() async throws {
    let identity = AIIdentityBox()
    let gate = AsyncGate()
    let backends = AIRecordingBackends { _, _ in await gate.wait(); return "## 回答\n内容" }
    let store = try AIConversationStore(url: nil)
    let service = AIConversationService(store: store, materials: AIFixtureMaterialProvider(), backends: backends, identity: identity.gate)
    let run = await service.start(preset: AIBuiltInPresets.evaluation, source: source, options: options())
    let collector = Task { await self.collect(run) }
    while backends.requests.isEmpty { await Task.yield() }
    identity.bump()
    await gate.open()
    let events = await collector.value
    XCTAssertEqual(failure(events), "登录状态已改变，请重新打开当前页面。")
    XCTAssertNil(completed(events))
    let none = await service.thread(for: source)
    XCTAssertNil(none)
    // Clear while answering: the run is cancelled and writes nothing.
    let slow = AsyncGate()
    let second = AIRecordingBackends { _, _ in await slow.wait(); return "迟到的回答" }
    let other = AIConversationService(store: store, materials: AIFixtureMaterialProvider(), backends: second, identity: .unchecked)
    let pending = await other.start(preset: AIBuiltInPresets.evaluation, source: source, options: options())
    let pendingEvents = Task { await self.collect(pending) }
    while second.requests.isEmpty { await Task.yield() }
    try await other.clear()
    await slow.open()
    let cleared = await pendingEvents.value
    XCTAssertTrue(cleared.contains(.cancelled), "\(cleared)")
    let clearedThread = await other.thread(for: source)
    XCTAssertNil(clearedThread)
  }

  func testUnknownWindowShrinksAndRetriesOnOverflow() async throws {
    let backends = AIRecordingBackends(model: AIModel(id: "unknown-model", name: "u")) { request, index in
      if index == 1 { XCTAssertEqual(request.budget?.contextTokens, 32_768); throw AIChatFailure.contextTooLong }
      XCTAssertEqual(request.budget?.contextTokens, 16_384)
      return "回答"
    }
    let service = AIConversationService(store: try AIConversationStore(url: nil), materials: AIFixtureMaterialProvider(), backends: backends, identity: .unchecked)
    let events = await collect(await service.start(preset: AIBuiltInPresets.evaluation, source: source, options: options()))
    XCTAssertNotNil(completed(events), "\(events)")
    XCTAssertTrue(events.contains { if case .status(.degraded(let text)) = $0 { return text.contains("16K") }; return false })
    XCTAssertEqual(backends.requests.count, 2)
    // A known window never retries on overflow.
    let known = AIRecordingBackends { _, _ in throw AIChatFailure.contextTooLong }
    let fixed = AIConversationService(store: try AIConversationStore(url: nil), materials: AIFixtureMaterialProvider(), backends: known, identity: .unchecked)
    let failed = await collect(await fixed.start(preset: AIBuiltInPresets.evaluation, source: source, options: options()))
    XCTAssertNotNil(failure(failed))
    XCTAssertEqual(known.requests.count, 1)
  }

  func testLongTranscriptIsSegmentedAndSegmentsAreReused() async throws {
    let backends = AIRecordingBackends(model: AIModel(id: "small", name: "s", contextTokens: 6_000, maxOutputTokens: 1_500)) { request, _ in
      let text = request.messages.last?.text ?? ""
      if text.contains("视频字幕的第") { return "- [00:10] 要点" }
      return AIFixtureBackend.cannedAnswer(request)
    }
    let service = AIConversationService(store: try AIConversationStore(url: nil), materials: AITestMaterials(longMinutes: 60), backends: backends,
      identity: .unchecked)
    let events = await collect(await service.start(preset: AIBuiltInPresets.evaluation, source: source, options: options()))
    XCTAssertNotNil(completed(events), "\(events)")
    XCTAssertTrue(events.contains { if case .status(.segmenting) = $0 { return true }; return false })
    let final = try XCTUnwrap(backends.requests.last)
    XCTAssertTrue(final.messages[0].text.contains("<segment_summaries"))
    XCTAssertFalse(final.messages[0].text.contains("<transcript"))
    XCTAssertLessThanOrEqual(final.estimatedInputTokens, try XCTUnwrap(final.budget).inputLimit)
    let mapCount = backends.requests.filter { $0.messages.last?.text.contains("视频字幕的第") == true }.count
    XCTAssertGreaterThan(mapCount, 1)
    // Another preset on the same video reuses the segment summaries.
    let before = backends.requests.count
    _ = await collect(await service.start(preset: AIBuiltInPresets.commentViews, source: source, options: options()))
    let mapAfter = backends.requests.dropFirst(before).filter { $0.messages.last?.text.contains("视频字幕的第") == true }.count
    XCTAssertEqual(mapAfter, 0)
  }

  func testInvalidClipsAreShownButNotCachedAndSavingOffKeepsMemoryOnly() async throws {
    let backends = AIRecordingBackends { _, _ in #"{"clips":[{"start":"00:00","end":"09:00","reason":"太长","evidence":["c1"]}]}"# }
    let store = try AIConversationStore(url: nil)
    let service = AIConversationService(store: store, materials: AIFixtureMaterialProvider(), backends: backends, identity: .unchecked)
    let first = await collect(await service.start(preset: AIBuiltInPresets.clips, source: source, options: options()))
    guard case .structured(.clips(let clips))? = completed(first)?.content else { return XCTFail("\(first)") }
    XCTAssertFalse(clips.valid)
    XCTAssertTrue(completed(first)?.notes.contains { $0.contains("不能播放") } == true)
    _ = await collect(await service.start(preset: AIBuiltInPresets.clips, source: source, options: options()))
    XCTAssertEqual(backends.requests.count, 2)
    // Saving off: nothing written, the thread lives in memory.
    let memoryStore = try AIConversationStore(url: nil)
    let memory = AIConversationService(store: memoryStore, materials: AIFixtureMaterialProvider(), backends: AIRecordingBackends(), identity: .unchecked)
    _ = await collect(await memory.start(preset: AIBuiltInPresets.evaluation, source: source, options: options(save: false)))
    let memoryThread = await memory.thread(for: source)
    XCTAssertEqual(memoryThread?.turns.count, 1)
    XCTAssertEqual(try memoryStore.threads(sourceKey: source.identifier, ticket: memoryStore.ticket()), [])
    XCTAssertEqual(try memoryStore.usage().answers, 0)
  }

  func testTurningSavingOffStopsWritesOfARunningRequest() async throws {
    let gate = AsyncGate()
    let backends = AIRecordingBackends(model: AIModel(id: "small", name: "s", contextTokens: 6_000, maxOutputTokens: 1_500)) { request, _ in
      await gate.wait()
      let text = request.messages.last?.text ?? ""
      if text.contains("视频字幕的第") { return "- [00:10] 要点" }
      return AIFixtureBackend.cannedAnswer(request)
    }
    let store = try AIConversationStore(url: nil)
    let service = AIConversationService(store: store, materials: AITestMaterials(longMinutes: 60), backends: backends, identity: .unchecked)
    let run = await service.start(preset: AIBuiltInPresets.evaluation, source: source, options: options())
    let collector = Task { await self.collect(run) }
    while backends.requests.isEmpty { await Task.yield() }
    // Switched off while the segments are being generated.
    service.setSaving(false)
    await gate.open()
    let events = await collector.value
    XCTAssertNotNil(completed(events), "\(events)")
    XCTAssertTrue(events.contains { if case .status(.segmenting) = $0 { return true }; return false })
    // No answer, no thread …
    XCTAssertEqual(try store.usage().answers, 0)
    XCTAssertEqual(try store.usage().sources, 0)
    XCTAssertEqual(try store.threads(sourceKey: source.identifier, ticket: store.ticket()), [])
    let memoryThread = await service.thread(for: source)
    XCTAssertEqual(memoryThread?.turns.count, 1)
    let originalMaps = backends.requests.filter { $0.messages.last?.text.contains("视频字幕的第") == true }.count
    XCTAssertGreaterThan(originalMaps, 1)
    // … and no segment: re-enable the shared store so the next run can actually read its cache.
    service.setSaving(true)
    let again = AIConversationService(store: store, materials: AITestMaterials(longMinutes: 60), backends: backends, identity: .unchecked)
    let before = backends.requests.count
    let retry = await collect(await again.start(preset: AIBuiltInPresets.evaluation, source: source, options: options()))
    let retryTurn = try XCTUnwrap(completed(retry), "\(retry)")
    let maps = backends.requests.dropFirst(before).filter { $0.messages.last?.text.contains("视频字幕的第") == true }.count
    XCTAssertEqual(maps, originalMaps)
    // Control: bypass the answer cache; the retry's segments leave only the final reduce request.
    let cached = AIConversationService(store: store, materials: AITestMaterials(longMinutes: 60), backends: backends, identity: .unchecked)
    let beforeCached = backends.requests.count
    let hit = await collect(await cached.regenerate(turnID: retryTurn.id, preset: AIBuiltInPresets.evaluation, source: source, options: options()))
    XCTAssertNotNil(completed(hit), "\(hit)")
    XCTAssertTrue(hit.contains { if case .status(.segmenting) = $0 { return true }; return false })
    XCTAssertEqual(backends.requests.count - beforeCached, 1)
    XCTAssertEqual(backends.requests.dropFirst(beforeCached).filter { $0.messages.last?.text.contains("视频字幕的第") == true }.count, 0)
  }

  func testPreviewShowsTheHistoryTheRequestWillSend() async throws {
    let backends = AIRecordingBackends { _, _ in "回答：沿 318 国道往西走。" }
    let service = AIConversationService(store: try AIConversationStore(url: nil), materials: AIFixtureMaterialProvider(), backends: backends,
      identity: .unchecked)
    let empty = try await service.preview(preset: AIBuiltInPresets.question, source: source, options: options())
    guard case .unavailable = empty.rows.first(where: { $0.kind == .history })?.state else {
      return XCTFail("\(String(describing: empty.rows.first(where: { $0.kind == .history })))")
    }
    _ = await collect(await service.start(preset: AIBuiltInPresets.question, source: source, question: "第一天去了哪里", options: options()))
    let preview = try await service.preview(preset: AIBuiltInPresets.question, source: source, options: options())
    let row = try XCTUnwrap(preview.rows.first { $0.kind == .history })
    XCTAssertEqual(row.state, .sent)
    XCTAssertGreaterThan(row.tokens, 0)
    XCTAssertEqual(preview.totalTokens - empty.totalTokens, row.tokens)
    // The follow-up really carries that exchange.
    _ = await collect(await service.start(preset: AIBuiltInPresets.question, source: source, question: "然后呢", options: options()))
    let sent = try XCTUnwrap(backends.requests.last).messages.map(\.text).joined()
    XCTAssertTrue(sent.contains("第一天去了哪里"))
    // Switched off: neither previewed nor sent.
    let off = AIMaterialSettings(disabled: [.history])
    let hidden = try await service.preview(preset: AIBuiltInPresets.question, source: source, options: options(off))
    XCTAssertEqual(hidden.rows.first { $0.kind == .history }?.state, .switchedOff)
    XCTAssertEqual(hidden.rows.first { $0.kind == .history }?.tokens, 0)
    _ = await collect(await service.start(preset: AIBuiltInPresets.question, source: source, question: "最后呢", options: options(off)))
    XCTAssertFalse(try XCTUnwrap(backends.requests.last).messages.map(\.text).joined().contains("第一天去了哪里"))
    // An action preset does not use history at all.
    let action = try await service.preview(preset: AIBuiltInPresets.chapters, source: source, options: options())
    XCTAssertEqual(action.rows.first { $0.kind == .history }?.state, .notUsed)
  }

  func testPassingMaterialFailureIsNotCachedSoRetryRecovers() async throws {
    let materials = AIFlakyMaterials()
    let service = AIConversationService(store: try AIConversationStore(url: nil), materials: materials, backends: AIRecordingBackends(),
      identity: .unchecked)
    let first = await collect(await service.start(preset: AIBuiltInPresets.clips, source: source, options: options()))
    XCTAssertTrue(failure(first)?.contains("字幕下载失败") == true, "\(first)")
    let retry = await collect(await service.start(preset: AIBuiltInPresets.clips, source: source, options: options()))
    guard case .structured(.clips(let clips))? = completed(retry)?.content else { return XCTFail("\(retry)") }
    XCTAssertTrue(clips.valid)
    XCTAssertEqual(materials.calls, 2)
    // A complete bundle is cached as before.
    _ = await collect(await service.start(preset: AIBuiltInPresets.clips, source: source, options: options()))
    XCTAssertEqual(materials.calls, 2)
  }

  func testSegmentOverflowShrinksTheUnknownWindowAndResegments() async throws {
    let paragraphs = (0..<400).map { AIArticleParagraph(text: "第 \($0) 段：" + String(repeating: "山路很长风很大我们继续往前走", count: 7)) }
    let article = AISource.article(AIArticleInfo(id: 9, title: "长文", paragraphs: paragraphs))
    let backends = AIRecordingBackends(model: AIModel(id: "unknown-model", name: "u")) { request, _ in
      // The provider's real window is 8K.
      if request.estimatedInputTokens > 8_000 { throw AIChatFailure.contextTooLong }
      return "- [p1] 要点"
    }
    let service = AIConversationService(store: try AIConversationStore(url: nil), materials: AIArticleMaterials(), backends: backends,
      identity: .unchecked)
    let events = await collect(await service.start(preset: AIBuiltInPresets.articleEvaluation, source: article, options: options()))
    XCTAssertNotNil(completed(events), "\(events)")
    XCTAssertTrue(events.contains { if case .status(.degraded(let text)) = $0 { return text.contains("8K") }; return false }, "\(events)")
    let final = try XCTUnwrap(backends.requests.last)
    XCTAssertTrue(final.messages[0].text.contains("<segment_summaries"))
    XCTAssertEqual(final.budget?.contextTokens, 8_192)
    // The chunks were planned again within the reduced window.
    let accepted = backends.requests.filter { $0.estimatedInputTokens <= 8_000 && $0.messages[0].text.contains("<article") }
    XCTAssertGreaterThan(accepted.count, 1)
    XCTAssertTrue(accepted.allSatisfy { $0.budget?.contextTokens == 8_192 })
  }

  func testSavingSwitchedOffBetweenPermissionAndWriteWritesNothing() async throws {
    let store = try AIConversationStore(url: nil)
    // The run passed its own saving check; the switch goes off before the row is written.
    store.beforeSave = { [unowned store] in store.setSaving(false) }
    let service = AIConversationService(store: store, materials: AIFixtureMaterialProvider(), backends: AIRecordingBackends(), identity: .unchecked)
    let events = await collect(await service.start(preset: AIBuiltInPresets.evaluation, source: source, options: options()))
    XCTAssertNotNil(completed(events), "\(events)")
    XCTAssertFalse(store.isSaving)
    XCTAssertEqual(try store.usage().answers, 0)
    XCTAssertEqual(try store.threads(sourceKey: source.identifier, ticket: store.ticket()), [])
    let memoryThread = await service.thread(for: source)
    XCTAssertEqual(memoryThread?.turns.count, 1)
    // Directly: every kind of save is refused while off, deleting still works.
    store.beforeSave = nil
    let ticket = store.ticket()
    let thread = AIThread(sourceKey: source.identifier, title: "t")
    XCTAssertFalse(try store.save(thread, ticket: ticket))
    XCTAssertFalse(try store.save(segment: "s", key: "k", ticket: ticket))
    XCTAssertFalse(try store.save(answer: AIStoredAnswer(content: .markdown("a"), rawText: "a", materials: [], notes: [], createdAt: Date()),
      key: "k", ticket: ticket))
    XCTAssertTrue(try store.deleteThread(id: thread.id, ticket: ticket))
    XCTAssertNil(try store.segment(key: "k", ticket: ticket))
    store.setSaving(true)
    XCTAssertTrue(try store.save(thread, ticket: ticket))
  }

  func testSavingSwitchedOffAtThreadWriteKeepsConversationWithoutIdentityFailure() async throws {
    let store = try AIConversationStore(url: nil)
    let identity = AIIdentityBox()
    let ticket = store.ticket()
    let saves = AICallCounter()
    // Let the answer save succeed; only the subsequent thread save loses permission.
    store.beforeSave = { [unowned store] in if saves.increment() == 2 { store.setSaving(false) } }
    defer { store.beforeSave = nil }
    let service = AIConversationService(store: store, materials: AIFixtureMaterialProvider(), backends: AIRecordingBackends(), identity: identity.gate)
    let events = await collect(await service.start(preset: AIBuiltInPresets.evaluation, source: source, options: options()))
    let turn = try XCTUnwrap(completed(events), "\(events)")
    XCTAssertNil(failure(events))
    XCTAssertEqual(saves.count, 2)
    XCTAssertFalse(store.isSaving)
    XCTAssertTrue(store.isCurrent(ticket))
    XCTAssertEqual(try store.usage().answers, 1)
    XCTAssertEqual(try store.threads(sourceKey: source.identifier, ticket: ticket), [])
    let memoryThread = await service.thread(for: source)
    XCTAssertEqual(memoryThread?.turns.map(\.id), [turn.id])
  }

  func testFixtureServiceAndPreview() async throws {
    let service = try AIConversationService.fixture()
    let preview = try await service.preview(preset: AIBuiltInPresets.question, source: source, options: options(AIMaterialSettings(disabled: [.comments])))
    XCTAssertEqual(preview.rows.first(where: { $0.kind == .comments })?.state, .switchedOff)
    XCTAssertEqual(preview.rows.first(where: { $0.kind == .subtitles })?.state, .sent)
    XCTAssertGreaterThan(preview.totalTokens, 0)
    XCTAssertEqual(preview.availability, .available)
    for preset in [AIBuiltInPresets.chapters, AIBuiltInPresets.clips, AIBuiltInPresets.highlights, AIBuiltInPresets.danmakuTalk, AIBuiltInPresets.commentViews] {
      let events = await collect(await service.start(preset: preset, source: source, options: options()))
      let turn = try XCTUnwrap(completed(events), "\(preset.id): \(events)")
      XCTAssertTrue(turn.content.isUsableResult, "\(preset.id): \(turn.content)")
    }
  }
}

actor AsyncGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() { opened = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}
