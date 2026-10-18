import ManpingCore
import Combine
import Foundation

@MainActor final class M8AIResponseModel: ObservableObject {
  @Published private(set) var providers: [AIProvider] = []
  @Published private(set) var models: [AIModel] = []
  @Published private(set) var provider: AIProvider?
  @Published private(set) var modelID = ""
  @Published var question = ""
  @Published private(set) var output = ""
  @Published private(set) var request = ""
  @Published private(set) var busy = false
  @Published private(set) var status = ""
  @Published private(set) var error: String?
  /// ChatGPT plan usage limit: the UI offers managing usage as the primary action.
  @Published private(set) var usageLimitReached = false
  private let service: BiliService
  private let rpc: (any BiliRPCService)?
  private let configuration: AIConfigurationStore
  private let prompts: AIPromptStore
  private let fixtures: Bool
  private let client: AIChatClient
  private var source: AIContextSource?
  private var generation = UUID()
  private var loadGeneration = UUID()
  private var lastTask: AIPromptTask?
  private var lastQuestion = ""
  private var flight: Task<Void, Never>?
  private var providerFlight: Task<Void, Never>?
  private var identityObserver: Task<Void, Never>?
  private var configurationObserver: Task<Void, Never>?
  init(service: BiliService, rpc: (any BiliRPCService)?, configuration: AIConfigurationStore,
    prompts: AIPromptStore, fixtures: Bool, client: AIChatClient = AIChatClient()) {
    self.service = service; self.rpc = rpc; self.configuration = configuration
    self.prompts = prompts; self.fixtures = fixtures; self.client = client
  }
  deinit { flight?.cancel(); providerFlight?.cancel(); identityObserver?.cancel(); configurationObserver?.cancel() }
  func prepare(_ source: AIContextSource) async {
    if self.source == source { return }
    invalidate(clearQuestion: true); self.source = source
    identityObserver?.cancel(); configurationObserver?.cancel()
    let preparedGeneration = generation
    let snapshot = await service.authSnapshot()
    guard !Task.isCancelled, preparedGeneration == generation, self.source == source else { return }
    identityObserver = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        if event.epoch != snapshot.epoch || event.identityRevision != snapshot.identityRevision {
          self.invalidate(clearQuestion: true)
          self.status = "登录状态已改变，请重新打开当前页面。"
          self.source = nil
        }
      }
    }
    if !fixtures {
      let revision = await configuration.revision
      guard !Task.isCancelled, preparedGeneration == generation, self.source == source else { return }
      configurationObserver = Task { [weak self, configuration] in
        for await changed in await configuration.changes() {
          guard let self, !Task.isCancelled else { return }
          if changed != revision {
            self.invalidate(clearQuestion: true)
            await self.reloadProviders()
          }
        }
      }
    }
    await reloadProviders()
  }
  func reloadProviders() async {
    let current = UUID(); loadGeneration = current
    do {
      let available: [AIProvider]
      if fixtures { available = [.openAI] }
      else { available = try await configuration.configuredProviders() }
      guard !Task.isCancelled, current == loadGeneration else { return }
      providers = available
      let selected = available.contains(where: { $0 == provider }) ? provider : available.first
      provider = selected
      if let selected { await loadModels(selected, generation: current) }
      else { models = []; modelID = "" }
    } catch {
      guard current == loadGeneration, !Task.isCancelled else { return }
      self.error = "没能读取 AI 配置，请在 设置 › AI 中检查。"
    }
  }
  func selectProvider(_ value: AIProvider) {
    guard provider != value else { return }
    invalidate(clearQuestion: true); provider = value; models = []; modelID = ""
    providerFlight?.cancel()
    let current = UUID(); loadGeneration = current
    providerFlight = Task { [weak self] in await self?.loadModels(value, generation: current) }
  }
  private func loadModels(_ provider: AIProvider, generation: UUID) async {
    do {
      let values: [AIModel]
      if fixtures { values = [AIModel(id: "fixture-model", name: "本地样本模型")] }
      else {
        guard let config = try await configuration.configuration(for: provider) else { return }
        values = config.availableModels(for: provider)
      }
      guard !Task.isCancelled, generation == loadGeneration else { return }
      models = values
      if !values.contains(where: { $0.id == modelID }) { modelID = values.first?.id ?? "" }
    } catch {
      guard !Task.isCancelled, generation == loadGeneration else { return }
      self.error = "没能读取模型配置，请在 设置 › AI 中检查。"
    }
  }
  func selectModel(_ id: String) {
    guard id != modelID, models.contains(where: { $0.id == id }) else { return }
    invalidate(clearQuestion: true); modelID = id
  }
  func generate(_ task: AIPromptTask) {
    guard !busy, let source, let provider, !modelID.isEmpty, task.isArticle == source.isArticle else { return }
    let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
    if task.isQuestion && query.isEmpty { error = "请输入关于当前内容的问题。"; return }
    if query.utf8.count > 64 * 1024 { error = "问题过长，请缩短后重试。"; return }
    invalidate(clearQuestion: false)
    lastTask = task; lastQuestion = query
    busy = true; status = "正在读取上下文…"
    request = task.isQuestion ? query : "\(task.title)《\(source.title)》"
    let current = generation, model = modelID
    let template = prompts.template(for: task), streaming = prompts.streaming
    flight = Task { [weak self, service, configuration, client, rpc] in
      guard let self else { return }
      do {
        let identity = await service.authSnapshot()
        let context: AIPromptContext
        if self.fixtures {
          context = AIPromptContext(source: source,
            subtitle: "00:00 - 00:12: 穿过星海，记录旅途中的发现。\n00:12 - 00:25: 与伙伴共同探索新的世界。",
            comments: "画面与叙事节奏令人印象深刻。\n------", question: query)
        } else {
          context = try await service.aiPromptContext(source: source, task: task, question: query, rpc: rpc, expectedIdentity: identity)
        }
        try Task.checkCancellation()
        guard current == self.generation else { return }
        let prompt = try AIPromptRenderer.render(template: template, values: context.values)
        self.status = "正在生成…"
        if self.fixtures {
          // This branch never reads Keychain or creates a provider HTTP request.
          let answer = self.fixtureAnswer(task)
          if streaming {
            for piece in answer.split(separator: "\n", omittingEmptySubsequences: false) {
              try await Task.sleep(for: .milliseconds(80)); try Task.checkCancellation()
              guard current == self.generation else { return }
              self.output += String(piece) + "\n"
            }
          } else { self.output = answer }
        } else {
          let config = try await configuration.snapshot(for: provider)
          try Task.checkCancellation()
          try await self.verify(identity: identity, revision: config.revision, generation: current)
          // Summaries and evaluations need little deliberation; questions get a bit more.
          let options = AIResponseOptions(effort: task.isQuestion ? "medium" : "low")
          let refresh: (@Sendable () async throws -> String)? = provider == .chatGPTPlan
            ? configuration.chatGPT.map { auth in { try await auth.refreshAfterRejection() } } : nil
          let response = client.response(provider: provider, configuration: config.configuration, secrets: config.secrets,
            model: model, prompt: prompt, streaming: streaming, options: options, refreshBearer: refresh)
          for try await delta in response {
            try Task.checkCancellation()
            try await self.verify(identity: identity, revision: config.revision, generation: current)
            self.output += delta
          }
          try await self.verify(identity: identity, revision: config.revision, generation: current)
        }
        guard !Task.isCancelled, current == self.generation else { return }
        guard !self.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw BiliError.invalidResponse("AI 返回空响应，请重试。")
        }
        self.output = self.output.trimmingCharacters(in: .whitespacesAndNewlines)
        self.busy = false; self.status = self.fixtures ? "本地样本 · 未调用 AI 服务" : "生成完成"
      } catch is CancellationError {
        guard current == self.generation else { return }
        self.busy = false; self.status = "已取消"; self.output = ""
      } catch {
        guard !Task.isCancelled, current == self.generation else { return }
        self.busy = false; self.status = ""
        // AI errors carry sanitized, static messages; never include provider response bodies or secrets.
        self.usageLimitReached = (error as? AIChatFailure) == .planUsageLimit
        self.error = error.localizedDescription
      }
    }
  }
  private func verify(identity: AuthSnapshot, revision: UInt64, generation: UUID) async throws {
    let current = await service.authSnapshot()
    let configurationRevision = await configuration.revision
    guard !Task.isCancelled, generation == self.generation, current.epoch == identity.epoch,
      current.identityRevision == identity.identityRevision, configurationRevision == revision else { throw CancellationError() }
  }
  func retry() {
    guard let task = lastTask else { return }
    question = lastQuestion; generate(task)
  }
  func cancel() { invalidate(clearQuestion: false); status = "已取消" }
  func discard() { invalidate(clearQuestion: true); lastTask = nil; lastQuestion = "" }
  func templatesChanged() { invalidate(clearQuestion: true) }
  private func invalidate(clearQuestion: Bool) {
    generation = UUID(); flight?.cancel(); flight = nil
    busy = false; output = ""; request = ""; status = ""; error = nil; usageLimitReached = false
    if clearQuestion { question = ""; lastTask = nil; lastQuestion = "" }
  }
  func shutdown() {
    invalidate(clearQuestion: true); providerFlight?.cancel(); identityObserver?.cancel(); configurationObserver?.cancel()
    providerFlight = nil; identityObserver = nil; configurationObserver = nil; source = nil
    loadGeneration = UUID()
  }
  private func fixtureAnswer(_ task: AIPromptTask) -> String {
    switch task {
    case .articleSummary:
      "## 概述\n文章记录了一次探索星海的旅程，以及伙伴之间的协作。\n\n## 要点\n- 🌌 介绍旅途与探索目标。\n- 🤝 伙伴共同解决问题，继续前行。"
    case .videoSummary:
      "## 概述\n这段内容记录了一次探索星海的旅程，以及伙伴之间的协作。\n\n## 要点\n- 🌌 00:00 - 00:12：介绍旅途与探索目标。\n- 🤝 00:12 - 00:25：伙伴共同解决问题，继续前行。"
    case .videoEvaluation, .articleEvaluation:
      "## 评价\n内容清晰，叙事节奏自然。\n\n## 优点\n- 🎨 画面与主题表达连贯。\n- 💬 评论关注内容本身，讨论友善。\n\n## 缺点\n- ⏱️ 部分细节可以进一步展开。"
    case .videoQuestion, .articleQuestion:
      "根据当前内容，作者强调了探索和协作。这是本地样本回答，未连接任何 AI 服务。"
    }
  }
}
