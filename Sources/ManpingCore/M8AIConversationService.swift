import Foundation

public enum AIConversationStatus: Sendable, Equatable {
  case loadingMaterials
  /// Long material is being summarized in segments.
  case segmenting(done: Int, total: Int)
  /// Streaming a Markdown answer.
  case generating
  /// A structured answer is being received; it is shown once complete (正在整理…).
  case organizing
  /// Something was left out or reduced; the text says what.
  case degraded(String)
  /// The answer came from the local cache.
  case cached
}

public enum AIConversationEvent: Sendable, Equatable {
  case started(threadID: String, turnID: String)
  case status(AIConversationStatus)
  case textDelta(String)
  case structured(AIStructuredResult)
  case completed(AITurn)
  /// Sanitized message; never contains provider bodies or credentials.
  case failed(String)
  case cancelled
}

public struct AIConversationRun: Sendable {
  public let threadID: String
  public let turnID: String
  public let events: AsyncStream<AIConversationEvent>
}

/// Per-request choices the UI passes in.
public struct AIRunOptions: Sendable, Equatable {
  public var provider: AIProvider
  public var modelID: String
  public var settings: AIMaterialSettings
  /// Kinds the user allowed for this one request although they are switched off.
  public var oneTime: Set<AIMaterialKind>
  public var systemPrompt: String
  public var detail: AIAnswerDetail
  public var saveConversations: Bool
  public var viewerPosition: Double?
  /// mpv chapter list, used when the player metadata has no view points.
  public var fallbackChapters: [AIViewPoint]
  /// Danmaku already loaded by the player (avoids a second download).
  public var loadedDanmaku: [DanmakuComment]?
  public var streaming: Bool
  public var effort: String?
  public init(provider: AIProvider, modelID: String, settings: AIMaterialSettings = AIMaterialSettings(), oneTime: Set<AIMaterialKind> = [],
    systemPrompt: String = AISystemPrompt.defaultText, detail: AIAnswerDetail = .standard, saveConversations: Bool = true,
    viewerPosition: Double? = nil, fallbackChapters: [AIViewPoint] = [], loadedDanmaku: [DanmakuComment]? = nil, streaming: Bool = true,
    effort: String? = nil) {
    self.provider = provider; self.modelID = modelID; self.settings = settings; self.oneTime = oneTime; self.systemPrompt = systemPrompt
    self.detail = detail; self.saveConversations = saveConversations; self.viewerPosition = viewerPosition
    self.fallbackChapters = fallbackChapters; self.loadedDanmaku = loadedDanmaku; self.streaming = streaming; self.effort = effort
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.provider == rhs.provider && lhs.modelID == rhs.modelID && lhs.settings == rhs.settings && lhs.oneTime == rhs.oneTime
      && lhs.systemPrompt == rhs.systemPrompt && lhs.detail == rhs.detail && lhs.saveConversations == rhs.saveConversations
      && lhs.viewerPosition == rhs.viewerPosition && lhs.fallbackChapters == rhs.fallbackChapters && lhs.streaming == rhs.streaming
      && lhs.effort == rhs.effort && lhs.loadedDanmaku == rhs.loadedDanmaku
  }
}

/// Identity snapshots for checking that an answer still belongs to the account that asked.
public struct AIIdentityGate: Sendable {
  public let current: @Sendable () async -> AuthSnapshot?
  public init(current: @escaping @Sendable () async -> AuthSnapshot?) { self.current = current }
  public static func live(_ service: BiliService) -> AIIdentityGate { AIIdentityGate { await service.authSnapshot() } }
  public static let unchecked = AIIdentityGate { nil }
}

enum AIConversationFailure: Error, LocalizedError, Equatable {
  case identityChanged, configurationChanged, unavailable(String), tooLong(String)
  var errorDescription: String? {
    switch self {
    case .identityChanged: "登录状态已改变，请重新打开当前页面。"
    case .configurationChanged: "AI 设置已改变，请重新生成。"
    case .unavailable(let reason), .tooLong(let reason): reason
    }
  }
}

/// Starts preset tasks and follow-up questions, streams their progress, and keeps threads,
/// answer and segment caches in `AIConversationStore` under the current account.
public actor AIConversationService {
  private let store: AIConversationStore
  private let materials: any AIMaterialProvider
  private let backends: any AIBackendFactory
  private let identity: AIIdentityGate
  private var runs: [String: (id: UUID, task: Task<Void, Never>)] = [:]
  /// Threads kept only in memory while saving is off; dropped with the owner ticket.
  private var memoryThreads: [String: AIThread] = [:]
  private var memoryTicket: AIConversationStore.Ticket?
  private var bundles: [String: (key: String, bundle: AIMaterialBundle)] = [:]
  private var pendingThreads: [String: String] = [:]

  public init(store: AIConversationStore, materials: any AIMaterialProvider, backends: any AIBackendFactory, identity: AIIdentityGate) {
    self.store = store; self.materials = materials; self.backends = backends; self.identity = identity
  }
  /// The app's service: live materials and models, the on-disk store.
  public static func live(service: BiliService, rpc: (any BiliRPCService)?, configuration: AIConfigurationStore,
    store: AIConversationStore) -> AIConversationService {
    AIConversationService(store: store, materials: AIBiliMaterialProvider(service: service, rpc: rpc),
      backends: AILiveBackendFactory(configuration: configuration), identity: .live(service))
  }
  /// UI screenshots: canned materials and answers, an in-memory store, nothing leaves the Mac.
  public static func fixture() throws -> AIConversationService {
    AIConversationService(store: try AIConversationStore(url: nil), materials: AIFixtureMaterialProvider(),
      backends: AIFixtureBackendFactory(), identity: .unchecked)
  }

  /// Follows the saving switch. Off applies to running requests too: the store refuses every save
  /// once this returns (their thread stays in memory).
  public nonisolated func setSaving(_ enabled: Bool) { store.setSaving(enabled) }
  /// Whether a run may use the store right now: its own choice and the current switch. The store
  /// checks the switch again inside each write, so this is only the fast path.
  private nonisolated func persists(_ options: AIRunOptions) -> Bool { options.saveConversations && store.isSaving }

  // MARK: Availability and preview

  /// Switch-level availability: a needed kind that is switched off makes the preset unavailable.
  public nonisolated static func availability(_ preset: AIPreset, source: AISource, settings: AIMaterialSettings,
    oneTime: Set<AIMaterialKind> = [], bundle: AIMaterialBundle? = nil) -> AIPresetAvailability {
    guard preset.applies(to: source.kind) else { return .notApplicable }
    if let missing = preset.required.first(where: { !settings.allows($0, oneTime: oneTime) }) { return .needsMaterial(missing) }
    guard let bundle, !preset.legacyTemplate else { return .available }
    switch preset.output {
    case .highlightsJSON:
      guard let digest = bundle.danmaku else { return .insufficient(bundle.danmakuNote ?? "弹幕太少，无法判断高能时刻") }
      if !digest.highlightsAvailable { return .insufficient("弹幕没有明显的密度峰值") }
    case .clipsJSON:
      if bundle.transcript == nil { return .insufficient("没有可用字幕，无法挑选片段：" + (bundle.transcriptNote ?? "")) }
    case .chaptersJSON:
      if bundle.transcript == nil, bundle.viewPoints.isEmpty, bundle.official?.isAvailable != true {
        return .insufficient("没有字幕或官方章节：" + (bundle.transcriptNote ?? "没有可用字幕"))
      }
    case .markdown:
      if preset.required.contains(.danmaku), bundle.danmaku == nil { return .insufficient(bundle.danmakuNote ?? "弹幕太少") }
      if preset.required.contains(.comments), bundle.comments == nil { return .insufficient(bundle.commentsNote ?? "没有可用评论") }
    }
    return .available
  }

  /// What would be sent for this preset: per-kind state, estimated tokens and availability.
  public func preview(preset: AIPreset, source: AISource, options: AIRunOptions) async throws -> AIContextPreview {
    let snapshot = await identity.current()
    let bundle = try await bundle(for: source, preset: preset, options: options, identity: snapshot)
    let backend = try await backends.backend(provider: options.provider, modelID: options.modelID)
    let pack = AIContextPack.build(bundle, preset: preset, settings: options.settings, oneTime: options.oneTime,
      viewerPosition: options.viewerPosition)
    let budget = backend.budget(desiredOutput: preset.desiredOutputTokens)
    // History is measured by the same assembly a real request goes through.
    let textOnly = backend.descriptor.textOnly
    let mode: AIOutputMode = textOnly && preset.markdownPrompt != nil ? .markdown : preset.output
    let input = AIPromptAssembler.Input(system: options.systemPrompt, preset: preset, pack: pack, question: nil,
      history: history(for: source, replacing: nil), settings: options.settings, oneTime: options.oneTime, detail: options.detail,
      budget: budget, format: mode.isStructured ? .json : .text, preferMarkdownPrompt: textOnly)
    return AIContextPreview.make(pack: pack, bundle: bundle, preset: preset, settings: options.settings,
      budget: budget, systemPrompt: options.systemPrompt,
      availability: Self.availability(preset, source: source, settings: options.settings, oneTime: options.oneTime, bundle: bundle),
      oneTime: options.oneTime, history: AIPromptAssembler.historyUse(input))
  }
  /// The thread's earlier exchanges as a request sends them (up to the turn being replaced).
  private func history(for source: AISource, replacing: String?) -> [AIHistoryTurn] {
    (thread(for: source)?.turns ?? []).prefix { $0.id != replacing }.map(\.historyTurn)
  }

  // MARK: Threads

  /// The thread of a source under the current account (memory only while saving is off).
  public func thread(for source: AISource) -> AIThread? {
    let ticket = store.ticket()
    if memoryTicket != ticket { memoryThreads = [:]; pendingThreads = [:]; memoryTicket = ticket }
    if let thread = memoryThreads[source.identifier] { return thread }
    return (try? store.threads(sourceKey: source.identifier, ticket: ticket))?.first
  }
  /// Cancels running answers, then deletes every saved thread, answer and segment.
  public func clear() throws {
    for run in runs.values { run.task.cancel() }
    runs = [:]; memoryThreads = [:]; bundles = [:]; pendingThreads = [:]
    try store.clearAll()
  }
  /// 清除此视频的对话: cancels the source's running answer, then removes its threads (saved or
  /// memory-only). Answer and segment caches stay; they are not conversations.
  public func clearThread(for source: AISource) throws {
    let ticket = store.ticket()
    if let id = pendingThreads.removeValue(forKey: source.identifier) { cancel(threadID: id) }
    if memoryTicket == ticket, let memory = memoryThreads.removeValue(forKey: source.identifier) { cancel(threadID: memory.id) }
    for thread in try store.threads(sourceKey: source.identifier, ticket: ticket) {
      cancel(threadID: thread.id)
      _ = try store.deleteThread(id: thread.id, ticket: ticket)
    }
  }
  /// Applies 设置 › AI › 保存期限.
  public func purgeExpired(retentionDays: Int, now: Date = Date()) throws {
    guard retentionDays > 0 else { return }
    try store.purge(olderThan: now.addingTimeInterval(-Double(retentionDays) * 86_400))
  }
  /// What 设置 › AI shows next to 清除全部.
  public func usage() throws -> AIConversationStore.Usage { try store.usage() }
  public func cancel(threadID: String) {
    runs.removeValue(forKey: threadID)?.task.cancel()
  }
  public func cancelAll() {
    for run in runs.values { run.task.cancel() }
    runs = [:]
  }

  // MARK: Running

  /// Runs a preset (or, for a conversation preset, the first question) on a source.
  public func start(preset: AIPreset, source: AISource, question: String? = nil, options: AIRunOptions) -> AIConversationRun {
    launch(preset: preset, source: source, question: question, options: options, replacing: nil, bypassCache: false)
  }
  /// Re-runs a turn without the answer cache and replaces it in the thread.
  public func regenerate(turnID: String, preset: AIPreset, source: AISource, options: AIRunOptions) -> AIConversationRun {
    let question = thread(for: source)?.turns.first(where: { $0.id == turnID })?.question
    return launch(preset: preset, source: source, question: question, options: options, replacing: turnID, bypassCache: true)
  }

  private func launch(preset: AIPreset, source: AISource, question: String?, options: AIRunOptions, replacing: String?,
    bypassCache: Bool) -> AIConversationRun {
    let existing = thread(for: source)
    // Runs started before the first answer is saved share one thread per source.
    let threadID = existing?.id ?? pendingThreads[source.identifier] ?? UUID().uuidString
    pendingThreads[source.identifier] = threadID
    let turnID = replacing ?? UUID().uuidString
    let (stream, continuation) = AsyncStream<AIConversationEvent>.makeStream(bufferingPolicy: .unbounded)
    runs.removeValue(forKey: threadID)?.task.cancel()
    let runID = UUID()
    let task = Task { [weak self] in
      guard let self else { continuation.finish(); return }
      continuation.yield(.started(threadID: threadID, turnID: turnID))
      do {
        let turn = try await self.execute(preset: preset, source: source, question: question, options: options, threadID: threadID,
          turnID: turnID, replacing: replacing, bypassCache: bypassCache) { continuation.yield($0) }
        continuation.yield(.completed(turn))
      } catch is CancellationError {
        continuation.yield(.cancelled)
      } catch let failure as AIConversationFailure where failure == .identityChanged {
        continuation.yield(.failed(failure.localizedDescription))
      } catch {
        continuation.yield(.failed(Self.message(error)))
      }
      continuation.finish()
      await self.finished(threadID: threadID, runID: runID)
    }
    runs[threadID] = (runID, task)
    continuation.onTermination = { _ in task.cancel() }
    return AIConversationRun(threadID: threadID, turnID: turnID, events: stream)
  }
  private func finished(threadID: String, runID: UUID) {
    if runs[threadID]?.id == runID { runs.removeValue(forKey: threadID) }
  }
  nonisolated static func message(_ error: Error) -> String {
    if let error = error as? LocalizedError, let text = error.errorDescription { return text }
    return "AI 请求失败，请稍后重试。"
  }

  private func bundle(for source: AISource, preset: AIPreset, options: AIRunOptions, identity snapshot: AuthSnapshot?) async throws -> AIMaterialBundle {
    let kinds = Set(preset.materials.filter { options.settings.allows($0, oneTime: options.oneTime) })
    let key = AIHash.digest([("kinds", kinds.map(\.rawValue).sorted().joined(separator: ",")),
      ("identity", snapshot.map { "\($0.epoch):\($0.identityRevision)" } ?? "none"), ("ai", options.settings.excludeAISubtitles ? "1" : "0"),
      ("languages", options.settings.subtitleLanguages.joined(separator: ",")), ("fallback", options.fallbackChapters.map(\.title).joined(separator: "|")),
      ("danmaku", String(options.loadedDanmaku?.count ?? -1))])
    if let cached = bundles[source.identifier], cached.key == key { return cached.bundle }
    let bundle = try await materials.gather(source: source, kinds: kinds, settings: options.settings, identity: snapshot,
      fallbackChapters: options.fallbackChapters, loadedDanmaku: options.loadedDanmaku)
    // A material that failed for a passing reason is fetched again next time (重试 included).
    guard !bundle.transient else { bundles.removeValue(forKey: source.identifier); return bundle }
    if bundles.count > 8 { bundles.removeAll() }
    bundles[source.identifier] = (key, bundle)
    return bundle
  }

  private func execute(preset: AIPreset, source: AISource, question: String?, options: AIRunOptions, threadID: String, turnID: String,
    replacing: String?, bypassCache: Bool, emit: @escaping @Sendable (AIConversationEvent) -> Void) async throws -> AITurn {
    if preset.style == .conversation {
      guard let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AIConversationFailure.unavailable("请输入关于当前内容的问题。")
      }
      guard question.utf8.count <= 64 * 1024 else { throw AIConversationFailure.unavailable("问题过长，请缩短后重试。") }
    }
    try source.validate()
    let ticket = store.ticket()
    let snapshot = await identity.current()
    let initial = Self.availability(preset, source: source, settings: options.settings, oneTime: options.oneTime)
    if let reason = initial.reason { throw AIConversationFailure.unavailable(reason) }
    emit(.status(.loadingMaterials))
    let backend = try await backends.backend(provider: options.provider, modelID: options.modelID)
    let revision = backend.descriptor.revision
    let bundle = try await bundle(for: source, preset: preset, options: options, identity: snapshot)
    try await verify(snapshot: snapshot, ticket: ticket, revision: revision)
    let availability = Self.availability(preset, source: source, settings: options.settings, oneTime: options.oneTime, bundle: bundle)
    if let reason = availability.reason { throw AIConversationFailure.unavailable(reason) }

    let textOnly = backend.descriptor.textOnly
    let mode: AIOutputMode = textOnly && preset.markdownPrompt != nil ? .markdown : preset.output
    let format: AIResponseFormat = mode.isStructured ? .json : .text
    var budget = backend.budget(desiredOutput: preset.desiredOutputTokens)
    let pack = AIContextPack.build(bundle, preset: preset, settings: options.settings, oneTime: options.oneTime,
      viewerPosition: options.viewerPosition)
    let history = history(for: source, replacing: replacing)
    var reductions = 0
    while true {
      do {
        // Segment cut points come from the source's chapters whenever they may be used at all,
        // so every preset on the same video produces the same segments (and reuses them).
        let boundaries = options.settings.allows(.officialSummary, oneTime: options.oneTime) ? bundle.viewPoints.map(\.start) : []
        let prepared = try await prepare(pack: pack, boundaries: boundaries, preset: preset, question: question, history: history, options: options,
          budget: budget, format: format, textOnly: textOnly, backend: backend, ticket: ticket, snapshot: snapshot, emit: emit)
        let key = Self.answerKey(source: source, preset: preset, mode: mode, request: prepared.assembly.request, pack: prepared.pack,
          descriptor: backend.descriptor, options: options)
        let validator = AIStructuredValidator(duration: source.duration, evidence: prepared.pack.evidence, danmaku: bundle.danmaku)
        var notes = prepared.assembly.notes + (prepared.coverageNote.map { [$0] } ?? [])
        for note in notes { emit(.status(.degraded(note))) }
        if !bypassCache, persists(options), let hit = try? store.answer(key: key, ticket: ticket) {
          emit(.status(.cached))
          if case .structured(let result) = hit.content { emit(.structured(result)) } else { emit(.textDelta(hit.rawText)) }
          let turn = AITurn(id: turnID, presetID: preset.id, presetName: preset.name, question: question, content: hit.content,
            rawText: hit.rawText, materials: hit.materials, model: backend.descriptor.model.id, provider: backend.descriptor.provider.title,
            notes: hit.notes, fromCache: true)
          try await commit(turn, threadID: threadID, source: source, replacing: replacing, options: options, ticket: ticket)
          return turn
        }
        emit(.status(mode.isStructured ? .organizing : .generating))
        var text = ""
        let effort = options.effort ?? (preset.style == .conversation ? "medium" : "low")
        for try await delta in backend.stream(prepared.assembly.request, options: AIResponseOptions(effort: effort), streaming: options.streaming) {
          try Task.checkCancellation()
          try await verify(snapshot: snapshot, ticket: ticket, revision: revision)
          text += delta
          if !mode.isStructured { emit(.textDelta(delta)) }
        }
        try await verify(snapshot: snapshot, ticket: ticket, revision: revision)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIChatFailure.emptyResponse }
        let content = validator.validate(text, mode: mode)
        switch content {
        case .structured(let result):
          if case .clips(let clips) = result, !clips.valid { notes.append("片段结果不符合要求，不能播放：" + clips.problems.joined(separator: "；")) }
          emit(.structured(result))
        case .fallback(_, let reason): notes.append(reason); emit(.status(.degraded(reason)))
        case .markdown: break
        }
        if case .structured(.clips(let clips)) = content, !clips.valid { emit(.status(.degraded(notes.last ?? ""))) }
        let turn = AITurn(id: turnID, presetID: preset.id, presetName: preset.name, question: question, content: content, rawText: text,
          materials: prepared.assembly.materials, model: backend.descriptor.model.id, provider: backend.descriptor.provider.title, notes: notes)
        // Only usable results become cache entries; invalid or fallback answers are shown, not reused.
        if persists(options), content.isUsableResult {
          try store.save(answer: AIStoredAnswer(content: content, rawText: text, materials: turn.materials, notes: notes, createdAt: turn.createdAt),
            key: key, ticket: ticket)
        }
        try await commit(turn, threadID: threadID, source: source, replacing: replacing, options: options, ticket: ticket)
        return turn
      } catch let failure as AIChatFailure where failure == .contextTooLong && !budget.known && reductions < 2 {
        // Unknown window: plan one size smaller and try again (at most twice).
        guard let smaller = budget.reduced() else { throw failure }
        budget = smaller; reductions += 1
        emit(.status(.degraded("模型上下文长度未知，已按约 \(smaller.contextTokens / 1000)K 重新规划")))
      }
    }
  }

  private struct Prepared {
    let assembly: AIAssembly
    let pack: AIContextPack
    let coverageNote: String?
  }

  /// Fits the request; segments the body (and merges the summaries once more) when needed.
  private func prepare(pack: AIContextPack, boundaries: [Double], preset: AIPreset, question: String?, history: [AIHistoryTurn], options: AIRunOptions,
    budget: AIRequestBudget, format: AIResponseFormat, textOnly: Bool, backend: any AIModelBackend, ticket: AIConversationStore.Ticket,
    snapshot: AuthSnapshot?, emit: @escaping @Sendable (AIConversationEvent) -> Void) async throws -> Prepared {
    func input(_ pack: AIContextPack) -> AIPromptAssembler.Input {
      AIPromptAssembler.Input(system: options.systemPrompt, preset: preset, pack: pack, question: question, history: history,
        settings: options.settings, oneTime: options.oneTime, detail: options.detail, budget: budget, format: format,
        preferMarkdownPrompt: textOnly)
    }
    switch AIPromptAssembler.assemble(input(pack)) {
    case .ready(let assembly): return Prepared(assembly: assembly, pack: pack, coverageNote: nil)
    case .tooLong(let reason): throw AIConversationFailure.tooLong(reason)
    case .needsSegmentation: break
    }
    let metadata = AIContextPack.metadata(pack.source)
    let overhead = AITokenEstimator.estimate(options.systemPrompt) + AITokenEstimator.estimate(metadata) + 400
    // Chunk size depends only on the model and the shared prompt, not on the task: segments are reusable.
    // After an overflow of an unknown window the reduced context caps the chunks too.
    let modelMap = backend.budget(desiredOutput: 1_500)
    let mapBudget = AIRequestBudget(contextTokens: min(modelMap.contextTokens, budget.contextTokens),
      maxOutputTokens: modelMap.maxOutputTokens, known: modelMap.known)
    let maxTokens = mapBudget.inputLimit - overhead
    guard maxTokens >= 200 else { throw AISegmentationFailure.budgetTooSmall }
    let chunks: [AISegmentChunk]
    let article: Bool
    switch pack.source {
    case .article(let info): chunks = AISegmentPlanner.articleChunks(info, maxTokens: maxTokens); article = true
    case .video, .pgc:
      guard let layer = pack.layer(.transcript), !layer.body.isEmpty, let transcript = transcriptFrom(pack) else {
        throw AIConversationFailure.tooLong("内容过长，无法整理。")
      }
      chunks = AISegmentPlanner.transcriptChunks(transcript, boundaries: boundaries, maxTokens: maxTokens, duration: pack.source.duration)
      article = false
    }
    guard !chunks.isEmpty else { throw AISegmentationFailure.budgetTooSmall }
    let descriptor = backend.descriptor, system = options.systemPrompt, store = self.store
    let gate = identity
    let persist: @Sendable () -> Bool = { options.saveConversations && store.isSaving }
    let result = try await AISegmentRunner.run(chunks,
      request: { AISegmentPlanner.mapRequest($0, total: chunks.count, metadata: metadata, system: system, article: article, budget: mapBudget) },
      cacheKey: { Self.segmentKey($0, descriptor: descriptor, system: system) },
      cached: { key in persist() ? (try? store.segment(key: key, ticket: ticket)) ?? nil : nil },
      store: { key, text in if persist() { _ = try? store.save(segment: text, key: key, ticket: ticket) } },
      generate: { request in
        var text = ""
        for try await delta in backend.stream(request, options: AIResponseOptions(effort: "low"), streaming: true) {
          try Task.checkCancellation()
          if let snapshot, let now = await gate.current(), now.epoch != snapshot.epoch || now.identityRevision != snapshot.identityRevision {
            throw CancellationError()
          }
          guard store.isCurrent(ticket) else { throw CancellationError() }
          text += delta
        }
        return text
      },
      progress: { done, total in emit(.status(.segmenting(done: done, total: total))) })
    try await verify(snapshot: snapshot, ticket: ticket, revision: descriptor.revision)
    var summaries = result.summaries
    var segmented = pack.replacingBody(with: summaries, coverageNote: result.coverageNote)
    if case .ready(let assembly) = AIPromptAssembler.assemble(input(segmented)) {
      return Prepared(assembly: assembly, pack: segmented, coverageNote: result.coverageNote)
    }
    // One reduce level: merge neighbouring summaries in groups that fit, then try again.
    var groups: [[AISegmentSummary]] = [], current: [AISegmentSummary] = [], tokens = 0
    for summary in summaries {
      let cost = AITokenEstimator.estimate(summary.text) + 16
      if !current.isEmpty, tokens + cost > maxTokens { groups.append(current); current = []; tokens = 0 }
      current.append(summary); tokens += cost
    }
    if !current.isEmpty { groups.append(current) }
    guard groups.count < summaries.count else { throw AIConversationFailure.tooLong("内容过长，分段整理后仍超出当前模型的长度。") }
    var merged: [AISegmentSummary] = []
    for (index, group) in groups.enumerated() {
      emit(.status(.segmenting(done: index, total: groups.count)))
      var text = ""
      for try await delta in backend.stream(AISegmentPlanner.reduceRequest(group, metadata: metadata, system: system, budget: mapBudget),
        options: AIResponseOptions(effort: "low"), streaming: true) {
        try Task.checkCancellation(); text += delta
      }
      try await verify(snapshot: snapshot, ticket: ticket, revision: descriptor.revision)
      let first = group.first!, last = group.last!
      let label = article ? [first.label, last.label].compactMap { $0 }.joined(separator: "…") : nil
      merged.append(AISegmentSummary(id: "g\(index + 1)", start: first.start, end: last.end, label: label,
        text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    summaries = merged
    segmented = pack.replacingBody(with: summaries, coverageNote: result.coverageNote)
    if case .ready(let assembly) = AIPromptAssembler.assemble(input(segmented)) {
      return Prepared(assembly: assembly, pack: segmented, coverageNote: result.coverageNote)
    }
    throw AIConversationFailure.tooLong("内容过长，分段整理后仍超出当前模型的长度。")
  }
  private func transcriptFrom(_ pack: AIContextPack) -> AITranscript? {
    guard let source = pack.layer(.transcript) else { return nil }
    // Rebuild cues from the rendered layer's lines (IDs and times are preserved verbatim).
    let cues = source.body.split(separator: "\n").compactMap { line -> AITranscriptCue? in
      guard let close = line.firstIndex(of: "]"), line.hasPrefix("[") else { return nil }
      let header = line[line.index(after: line.startIndex)..<close].split(separator: " ")
      guard header.count == 2 else { return nil }
      let times = header[1].split(separator: "-")
      guard times.count == 2, let start = AITimecode.parse(String(times[0])), let end = AITimecode.parse(String(times[1])) else { return nil }
      return AITranscriptCue(id: String(header[0]), start: start, end: end,
        text: String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }
    return cues.isEmpty ? nil : AITranscript(language: "", isAI: false, cues: cues)
  }

  private func verify(snapshot: AuthSnapshot?, ticket: AIConversationStore.Ticket, revision: UInt64) async throws {
    try Task.checkCancellation()
    if let snapshot {
      guard let now = await identity.current(), now.epoch == snapshot.epoch, now.identityRevision == snapshot.identityRevision else {
        throw AIConversationFailure.identityChanged
      }
    }
    guard store.isCurrent(ticket) else { throw AIConversationFailure.identityChanged }
    guard await backends.revision() == revision else { throw AIConversationFailure.configurationChanged }
  }

  private func commit(_ turn: AITurn, threadID: String, source: AISource, replacing: String?, options: AIRunOptions,
    ticket: AIConversationStore.Ticket) async throws {
    guard store.isCurrent(ticket) else { throw AIConversationFailure.identityChanged }
    if memoryTicket != ticket { memoryThreads = [:]; memoryTicket = ticket }
    var thread: AIThread
    if let memory = memoryThreads[source.identifier] { thread = memory }
    else if let saved = try store.thread(id: threadID, ticket: ticket) { thread = saved }
    else { thread = AIThread(id: threadID, sourceKey: source.identifier, title: source.title) }
    if let replacing, let index = thread.turns.firstIndex(where: { $0.id == replacing }) {
      // Later turns were built on the replaced answer; they are dropped with it.
      thread.turns = Array(thread.turns.prefix(index)) + [turn]
    } else { thread.turns.append(turn) }
    thread.updatedAt = Date(); thread.title = source.title
    if persists(options), try store.save(thread, ticket: ticket) {
      memoryThreads.removeValue(forKey: source.identifier)
    } else {
      // Refused: the account changed, or saving was switched off meanwhile (kept in memory).
      guard store.isCurrent(ticket) else { throw AIConversationFailure.identityChanged }
      memoryThreads[source.identifier] = thread
    }
  }

  // MARK: Keys

  /// Answer key: SHA-256 over the typed source, preset and version, output mode, the provider,
  /// endpoint, API version and model, generation parameters, every layer's digest and the exact
  /// messages (task prompt, history and question included).
  nonisolated static func answerKey(source: AISource, preset: AIPreset, mode: AIOutputMode, request: AIConversationRequest,
    pack: AIContextPack, descriptor: AIBackendDescriptor, options: AIRunOptions) -> String {
    var parts: [(String, String)] = [("kind", "answer"), ("source", source.identifier), ("preset", preset.id),
      ("presetVersion", String(preset.version)), ("output", mode.rawValue), ("contextVersion", String(AISystemPrompt.contextVersion)),
      ("system", AIHash.sha256(request.system ?? "")), ("provider", descriptor.provider.rawValue), ("endpoint", descriptor.endpoint),
      ("apiVersion", descriptor.apiVersion ?? ""), ("model", descriptor.model.id), ("format", request.format.rawValue),
      ("maxOutput", String(request.budget?.maxOutputTokens ?? 0)), ("effort", options.effort ?? ""), ("detail", options.detail.rawValue),
      ("duration", source.duration.map { String($0) } ?? "")]
    for layer in pack.layers { parts.append(("layer." + layer.tag.rawValue, layer.digest)) }
    for (index, message) in request.messages.enumerated() { parts.append(("message.\(index).\(message.role.rawValue)", AIHash.sha256(message.text))) }
    return AIHash.digest(parts)
  }
  /// Segment key: the original material's hash, its range, the segment prompt version, the system
  /// prompt and the model with its service. Independent of task and question, so summaries are reused.
  nonisolated static func segmentKey(_ chunk: AISegmentChunk, descriptor: AIBackendDescriptor, system: String) -> String {
    AIHash.digest([("kind", "segment"), ("material", chunk.materialHash), ("range", chunk.rangeText),
      ("promptVersion", String(AISegmentPlanner.promptVersion)), ("system", AIHash.sha256(system)),
      ("provider", descriptor.provider.rawValue), ("endpoint", descriptor.endpoint), ("model", descriptor.model.id)])
  }
}
