import AppKit
import Combine
import Foundation
import ManpingCore
import UniformTypeIdentifiers

/// The AI panel of one source: its thread, the answer being generated, the model choice, this
/// panel's 本次 content switches and the official-summary fallback.
@MainActor final class AIPanelModel: ObservableObject {
  /// The answer being generated.
  struct Pending: Equatable {
    let presetName: String
    let question: String?
    let position: Double?
    let structured: Bool
    var status: AIConversationStatus = .loadingMaterials
    var text = ""
    var notes: [String] = []
    /// Replaces this turn when done.
    let replacing: String?
  }
  struct Request: Equatable {
    let preset: AIPreset
    let question: String?
    let oneTime: Set<AIMaterialKind>
    let replacing: String?
  }
  struct Failure: Equatable {
    let message: String
    let usageLimit: Bool
    let request: Request
  }
  enum Official: Equatable {
    case idle, loading
    case loaded(AIOfficialSummary)
  }

  private(set) var source: AISource
  @Published private(set) var turns: [AITurn] = []
  @Published private(set) var pending: Pending?
  @Published private(set) var failure: Failure?
  @Published private(set) var providers: [AIProvider] = []
  @Published private(set) var models: [AIProvider: [AIModel]] = [:]
  @Published private(set) var provider: AIProvider?
  @Published private(set) var modelID = ""
  @Published private(set) var providersLoaded = false
  @Published var question = ""
  /// The 当前进度 chip: questions carry the subtitles around the playhead.
  @Published var includePosition = true
  /// 本次 overrides of 默认发送的内容 from the context popover.
  @Published private(set) var sessionOff: Set<AIMaterialKind> = []
  @Published private(set) var sessionOn: Set<AIMaterialKind> = []
  @Published private(set) var sessionLanguages: [String]?
  @Published private(set) var preview: AIContextPreview?
  @Published private(set) var previewMessage: String?
  @Published private(set) var official: Official = .idle
  /// The preset the popover previews: the one used last, else the first action preset.
  @Published private(set) var focusPresetID: String?
  @Published private(set) var threadLoaded = false
  private unowned let runtime: AIRuntime
  /// Viewer positions sent with questions of this session (not part of the saved turn).
  private var positions: [String: Double] = [:]
  private var flight: Task<Void, Never>?
  private var threadID: String?
  private var loadTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var presetObservation: AnyCancellable?

  init(source: AISource, runtime: AIRuntime) {
    self.source = source; self.runtime = runtime
    // Preset or material edits change chips and availability; republish.
    presetObservation = runtime.presets.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    loadTask = Task { [weak self] in
      await self?.loadProviders()
      await self?.reloadThread()
    }
  }
  func shutdown() {
    flight?.cancel(); flight = nil; loadTask?.cancel(); previewTask?.cancel()
    if let threadID, let service = runtime.conversations { Task { await service.cancel(threadID: threadID) } }
  }
  /// Fresh details for the same source (stats, title) replace the stored copy.
  func update(source: AISource) {
    if source != self.source, source.identifier == self.source.identifier { self.source = source }
  }

  // MARK: Derived state

  var presets: AIPresetStore { runtime.presets }
  var panelPresets: [AIPreset] { presets.panelPresets(for: source).filter { $0.style == .action } }
  var conversationPreset: AIPreset {
    presets.panelPresets(for: source).first { $0.style == .conversation }
      ?? (source.kind == .article ? AIBuiltInPresets.articleQuestion : AIBuiltInPresets.question)
  }
  var hasService: Bool { !providers.isEmpty && !modelID.isEmpty && runtime.conversations != nil }
  var busy: Bool { pending != nil }
  var settings: AIMaterialSettings {
    var value = presets.currentMaterials
    value.disabled.formUnion(sessionOff)
    if let sessionLanguages { value.subtitleLanguages = sessionLanguages }
    return value
  }
  func allows(_ kind: AIMaterialKind) -> Bool { settings.allows(kind, oneTime: sessionOn) }
  func availability(_ preset: AIPreset) -> AIPresetAvailability {
    AIConversationService.availability(preset, source: source, settings: settings, oneTime: sessionOn)
  }
  var focusPreset: AIPreset {
    focusPresetID.flatMap(presets.preset) ?? panelPresets.first ?? conversationPreset
  }
  var modelName: String {
    models[provider ?? .openAI]?.first { $0.id == modelID }?.name ?? (modelID.isEmpty ? "选择模型" : modelID)
  }
  /// The times the newest answer cites, for the progress bar.
  var markTimes: [Double] {
    if let pending, pending.structured { return [] }
    return turns.last { !$0.content.citedTimes.isEmpty }?.content.citedTimes ?? []
  }
  func position(of turn: AITurn) -> Double? { positions[turn.id] }
  var currentPosition: Double? { runtime.position(for: source) }
  var positionAllowed: Bool { source.kind.isTimeline && allows(.viewerPosition) && currentPosition != nil }
  var isCurrentMedia: Bool { runtime.isCurrentMedia(source) }

  // MARK: Providers and models

  func loadProviders() async {
    var available: [AIProvider] = []
    var values: [AIProvider: [AIModel]] = [:]
    if runtime.fixtures {
      if runtime.scene != "official" {
        available = [.openAI]; values[.openAI] = [AIModel(id: "fixture-model", name: "本地样本模型", contextTokens: 128_000, maxOutputTokens: 8_192)]
      }
    } else {
      for provider in (try? await runtime.configuration.configuredProviders()) ?? [] {
        let list = (try? await runtime.configuration.configuration(for: provider))?.availableModels(for: provider) ?? []
        if !list.isEmpty { available.append(provider); values[provider] = list }
      }
    }
    guard !Task.isCancelled else { return }
    providers = available; models = values; providersLoaded = true
    let remembered = runtime.lastModel.flatMap { last in values[last.provider]?.contains { $0.id == last.modelID } == true ? last : nil }
    if let provider, values[provider]?.contains(where: { $0.id == modelID }) == true { return }
    if let remembered { provider = remembered.provider; modelID = remembered.modelID }
    else if let first = available.first { provider = first; modelID = values[first]?.first?.id ?? "" }
    else { provider = nil; modelID = "" }
    if available.isEmpty, source.kind.isTimeline { loadOfficial() }
  }
  func select(provider: AIProvider, modelID: String) {
    guard models[provider]?.contains(where: { $0.id == modelID }) == true else { return }
    self.provider = provider; self.modelID = modelID
    runtime.lastModel = (provider, modelID)
    preview = nil
  }
  func configurationChanged() {
    cancel()
    loadTask?.cancel()
    loadTask = Task { [weak self] in await self?.loadProviders() }
  }
  func identityChanged() {
    cancel(); failure = nil; positions = [:]; official = .idle; preview = nil
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      await self?.reloadThread()
      if self?.providers.isEmpty == true { self?.loadOfficial() }
    }
  }

  // MARK: Thread

  func reloadThread() async {
    guard let service = runtime.conversations else { threadLoaded = true; return }
    let thread = await service.thread(for: source)
    guard !Task.isCancelled else { return }
    turns = thread?.turns ?? []
    threadLoaded = true
  }

  /// Runs an action preset (or asks with the conversation preset).
  func run(_ preset: AIPreset, question: String? = nil, oneTime extra: Set<AIMaterialKind> = [], replacing: String? = nil) {
    guard let service = runtime.conversations, let provider, !modelID.isEmpty else { return }
    cancel()
    failure = nil
    runtime.markIntroShown()
    if preset.style == .action { focusPresetID = preset.id }
    let conversation = preset.style == .conversation
    let position = conversation && includePosition && positionAllowed ? currentPosition : nil
    var settings = self.settings
    if conversation && !includePosition { settings.disabled.insert(.viewerPosition) }
    let options = AIRunOptions(provider: provider, modelID: modelID, settings: settings, oneTime: sessionOn.union(extra),
      systemPrompt: presets.systemPrompt, detail: presets.answerDetail, saveConversations: runtime.fixtures || presets.saveConversations,
      viewerPosition: position, fallbackChapters: runtime.fallbackChapters(for: source), streaming: runtime.prompts.streaming)
    let request = Request(preset: preset, question: question, oneTime: extra, replacing: replacing)
    pending = Pending(presetName: preset.name, question: question, position: position,
      structured: preset.output.isStructured, replacing: replacing)
    let source = self.source
    flight = Task { [weak self] in
      let run: AIConversationRun
      if let replacing { run = await service.regenerate(turnID: replacing, preset: preset, source: source, options: options) }
      else { run = await service.start(preset: preset, source: source, question: question, options: options) }
      for await event in run.events {
        guard let self, !Task.isCancelled else { return }
        await self.apply(event, request: request)
      }
    }
  }
  /// Sends the composer's question.
  func ask() {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !busy else { return }
    question = ""
    run(conversationPreset, question: text)
  }
  func regenerate(_ turn: AITurn) {
    guard let preset = presets.preset(turn.presetID), !busy else { return }
    run(preset, question: turn.question, replacing: turn.id)
  }
  func retry() {
    guard let failure else { return }
    run(failure.request.preset, question: failure.request.question, oneTime: failure.request.oneTime, replacing: failure.request.replacing)
  }
  func cancel() {
    flight?.cancel(); flight = nil
    if let threadID, let service = runtime.conversations { Task { await service.cancel(threadID: threadID) } }
    pending = nil
  }
  func dismissFailure() { failure = nil }

  private func apply(_ event: AIConversationEvent, request: Request) async {
    switch event {
    case .started(let threadID, _):
      self.threadID = threadID
    case .status(let status):
      if case .degraded(let note) = status {
        if !note.isEmpty, pending?.notes.contains(note) == false { pending?.notes.append(note) }
      } else { pending?.status = status }
    case .textDelta(let delta):
      pending?.text += delta
    case .structured:
      break
    case .completed(let turn):
      if let position = pending?.position { positions[turn.id] = position }
      await reloadThread()
      // Saving off and the thread unreadable: keep the answer on screen anyway.
      if !turns.contains(where: { $0.id == turn.id }) {
        if let index = turns.firstIndex(where: { $0.id == request.replacing }) { turns = Array(turns.prefix(index)) + [turn] }
        else { turns.append(turn) }
      }
      pending = nil; flight = nil
    case .failed(let message):
      pending = nil; flight = nil
      failure = Failure(message: message, usageLimit: message == AIChatFailure.planUsageLimit.errorDescription, request: request)
    case .cancelled:
      pending = nil; flight = nil
    }
  }

  // MARK: Context switches (本次)

  func setAllowed(_ kind: AIMaterialKind, _ on: Bool) {
    guard kind.isSwitchable else { return }
    if on {
      sessionOff.remove(kind)
      if !settings.allows(kind) { sessionOn.insert(kind) }
    } else {
      sessionOn.remove(kind)
      if presets.materials.allows(kind) { sessionOff.insert(kind) }
    }
    refreshPreview()
  }
  func focus(_ preset: AIPreset) {
    focusPresetID = preset.id
    refreshPreview()
  }
  func setLanguages(_ languages: [String]) {
    sessionLanguages = languages == presets.materials.subtitleLanguages ? nil : languages
    refreshPreview()
  }
  func refreshPreview() {
    previewTask?.cancel()
    guard let service = runtime.conversations else { previewMessage = "AI 服务暂时不可用。"; return }
    guard let provider, !modelID.isEmpty else { preview = nil; previewMessage = "配置 AI 服务后可以预览要发送的内容。"; return }
    let preset = focusPreset, source = self.source
    let options = AIRunOptions(provider: provider, modelID: modelID, settings: settings, oneTime: sessionOn,
      systemPrompt: presets.systemPrompt, detail: presets.answerDetail, saveConversations: false,
      viewerPosition: preset.style == .conversation ? currentPosition : nil, fallbackChapters: runtime.fallbackChapters(for: source))
    previewMessage = nil
    previewTask = Task { [weak self] in
      do {
        let value = try await service.preview(preset: preset, source: source, options: options)
        guard let self, !Task.isCancelled else { return }
        self.preview = value
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.preview = nil; self.previewMessage = AIConversationServiceMessage.text(error)
      }
    }
  }

  // MARK: Official summary

  func loadOfficial() {
    guard source.kind.isTimeline, official == .idle || isRetryable else { return }
    if runtime.fixtures { official = .loaded(AIFixtureMaterialProvider.officialSummary); return }
    guard case .video(let info) = source else {
      official = .loaded(.unavailable(reason: "番剧没有官方 AI 总结。")); return
    }
    official = .loading
    let service = runtime.service
    Task { [weak self] in
      let snapshot = await service.authSnapshot()
      let value: AIOfficialSummary
      do {
        value = try await service.officialSummary(aid: info.aid, cid: info.cid, bvid: info.bvid, uploaderMid: info.uploaderMid,
          expectedIdentity: snapshot)
      } catch is CancellationError { return } catch { value = .retryableError("没能读取官方总结，请稍后重试。") }
      self?.official = .loaded(value)
    }
  }
  private var isRetryable: Bool { if case .loaded(.retryableError) = official { return true }; return false }

  // MARK: Thread actions

  func exportMarkdown() {
    let title = source.title
    let thread = AIThread(sourceKey: source.identifier, title: title, turns: turns)
    let text = thread.markdown(sourceTitle: title)
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (title.isEmpty ? "AI 对话" : String(title.prefix(60))).replacingOccurrences(of: "/", with: "-") + ".md"
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      try? text.write(to: url, atomically: true, encoding: .utf8)
    }
  }
  func clearThread() {
    cancel(); failure = nil; positions = [:]
    let source = self.source
    Task { [weak self, service = runtime.conversations] in
      try? await service?.clearThread(for: source)
      await self?.reloadThread()
    }
  }
}

/// Error text for the popover (sanitized messages only).
enum AIConversationServiceMessage {
  static func text(_ error: Error) -> String {
    if let error = error as? LocalizedError, let text = error.errorDescription { return text }
    return "没能读取要发送的内容。"
  }
}
