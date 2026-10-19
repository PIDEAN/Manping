import Foundation

/// One earlier exchange of a thread, with the material kinds whose content (directly or through
/// earlier history) was in that exchange. A turn is never re-sent once one of them is switched off.
public struct AIHistoryTurn: Sendable, Equatable, Codable {
  public let question: String
  public let answer: String
  public let materials: Set<AIMaterialKind>
  public init(question: String, answer: String, materials: Set<AIMaterialKind>) {
    self.question = question; self.answer = answer; self.materials = materials
  }
}

public struct AIAssembly: Sendable, Equatable {
  public let request: AIConversationRequest
  public let droppedTags: [AIContextTag]
  /// Recent turns sent verbatim and older turns sent compressed.
  public let recentTurns: Int
  public let compressedTurns: Int
  /// Kinds whose content this request carries; stored with the turn.
  public let materials: Set<AIMaterialKind>
  /// Plain-language notes on what was left out to fit the budget.
  public let notes: [String]
  /// Estimated tokens of the history this request carries (verbatim turns and the summary of older ones).
  public var historyTokens: Int = 0
}

/// How a request would use the thread's history, for the context preview.
public struct AIHistoryUse: Sendable, Equatable {
  /// Earlier exchanges sent (verbatim or compressed).
  public let turns: Int
  public let tokens: Int
  /// Why history is not sent although the preset could use it; nil when it is sent or not used at all.
  public let note: String?
  public init(turns: Int, tokens: Int, note: String?) { self.turns = turns; self.tokens = tokens; self.note = note }
}

public enum AIAssemblyOutcome: Sendable, Equatable {
  case ready(AIAssembly)
  /// The transcript or article body has to be summarized in segments first.
  case needsSegmentation
  case tooLong(String)
}

/// Builds the final request and fits it into the budget, measuring the whole serialized request:
/// L2 (comments, danmaku) and history go first, then the viewer window and official material;
/// L0 and the question always stay; a body that still does not fit is segmented.
public enum AIPromptAssembler {
  public struct Input: Sendable {
    public var system: String
    public var preset: AIPreset
    public var pack: AIContextPack
    public var question: String?
    public var history: [AIHistoryTurn]
    public var settings: AIMaterialSettings
    public var oneTime: Set<AIMaterialKind>
    public var detail: AIAnswerDetail
    public var budget: AIRequestBudget
    public var format: AIResponseFormat
    /// Text-only models (Apple) use the preset's Markdown prompt when it has one.
    public var preferMarkdownPrompt: Bool
    public init(system: String, preset: AIPreset, pack: AIContextPack, question: String? = nil, history: [AIHistoryTurn] = [],
      settings: AIMaterialSettings, oneTime: Set<AIMaterialKind> = [], detail: AIAnswerDetail = .standard, budget: AIRequestBudget,
      format: AIResponseFormat = .text, preferMarkdownPrompt: Bool = false) {
      self.system = system; self.preset = preset; self.pack = pack; self.question = question; self.history = history
      self.settings = settings; self.oneTime = oneTime; self.detail = detail; self.budget = budget; self.format = format
      self.preferMarkdownPrompt = preferMarkdownPrompt
    }
  }
  public static let recentTarget = 3

  /// History that may still be sent under the current switches.
  public static func allowedHistory(_ history: [AIHistoryTurn], settings: AIMaterialSettings, oneTime: Set<AIMaterialKind>) -> [AIHistoryTurn] {
    guard settings.allows(.history, oneTime: oneTime) else { return [] }
    return history.filter { turn in turn.materials.allSatisfy { settings.allows($0, oneTime: oneTime) } }
  }

  public static func taskText(_ input: Input) -> String {
    let preset = input.preset
    var text = input.preferMarkdownPrompt ? (preset.markdownPrompt ?? preset.taskPrompt) : preset.taskPrompt
    if !preset.legacyTemplate {
      let duration = input.pack.source.duration
      let limit = AIStructuredValidator.clipLimit(duration: duration)
      let values = ["clip_limit": String(Int(limit)), "clip_minimum": String(Int(AIStructuredValidator.clipMinimum(duration: duration))),
        "clip_count": (duration ?? 600) < 120 ? "1–3" : "3–5", "duration": AITimecode.format(duration ?? 0)]
      for (key, value) in values { text = text.replacingOccurrences(of: "{\(key)}", with: value) }
    }
    if let instruction = input.detail.instruction { text += "\n" + instruction }
    return text
  }

  public static func assemble(_ input: Input) -> AIAssemblyOutcome {
    let history = input.preset.style == .conversation && !input.preset.legacyTemplate
      ? allowedHistory(input.history, settings: input.settings, oneTime: input.oneTime) : []
    let required = Set(input.preset.required)
    var dropped: Set<AIContextTag> = []
    var recent = min(recentTarget, history.count)
    var keepCompressed = true
    var notes: [String] = []
    var steps: [(apply: () -> Void, note: String)] = []
    func dropTag(_ tags: Set<AIContextTag>, material: AIMaterialKind, note: String) {
      guard !required.contains(material), tags.contains(where: { input.pack.layer($0) != nil }) else { return }
      steps.append(({ dropped.formUnion(tags) }, note))
    }
    dropTag([.comments], material: .comments, note: "评论精选因长度限制未发送")
    dropTag([.danmakuDigest], material: .danmaku, note: "弹幕统计因长度限制未发送")
    if history.count > recent { steps.append(({ keepCompressed = false }, "更早的对话未发送")) }
    for count in stride(from: recent - 1, through: 0, by: -1) {
      steps.append(({ recent = count }, count == 0 ? "对话历史因长度限制未发送" : "只发送了最近 \(count) 轮对话"))
    }
    dropTag([.viewer], material: .viewerPosition, note: "当前进度附近的字幕未发送")
    dropTag([.chapters, .officialSummary], material: .officialSummary, note: "官方章节与总结因长度限制未发送")

    func build() -> AIAssembly {
      let pack = input.pack.without(dropped)
      let recentTurns = Array(history.suffix(recent))
      let older = keepCompressed ? Array(history.dropLast(recent)) : []
      var prefix: String
      if input.preset.legacyTemplate {
        prefix = (try? AIPromptRenderer.render(template: input.preset.taskPrompt, values: legacyValues(pack, question: input.question)))
          ?? input.preset.taskPrompt
        if let instruction = input.detail.instruction { prefix += "\n" + instruction }
      } else {
        prefix = pack.rendered()
        if let block = historySummary(older) { prefix += "\n\n" + block }
        prefix += "\n\n" + taskText(input)
      }
      var messages: [AIMessage]
      let questionLine = input.question.map { "问题：" + $0 }
      if input.preset.legacyTemplate || input.preset.style == .action {
        messages = [.user(prefix)]
      } else if let first = recentTurns.first {
        messages = [.user(prefix + "\n\n" + first.question), .assistant(first.answer)]
        for turn in recentTurns.dropFirst() { messages += [.user(turn.question), .assistant(turn.answer)] }
        messages.append(.user(questionLine ?? "请继续。"))
      } else {
        messages = [.user(prefix + (questionLine.map { "\n\n" + $0 } ?? ""))]
      }
      var materials = pack.materials
      let sentTurns = recentTurns + older
      if !sentTurns.isEmpty { materials.insert(.history); for turn in sentTurns { materials.formUnion(turn.materials) } }
      let request = AIConversationRequest(system: input.system, messages: messages, format: input.format, budget: input.budget)
      var assembly = AIAssembly(request: request,
        droppedTags: input.pack.layers.map(\.tag).filter { dropped.contains($0) },
        recentTurns: recentTurns.count, compressedTurns: older.count, materials: materials, notes: notes)
      assembly.historyTokens = historyCost(recent: recentTurns, older: older, legacy: input.preset.legacyTemplate)
      return assembly
    }
    var assembly = build()
    var index = 0
    while assembly.request.estimatedInputTokens > input.budget.inputLimit, index < steps.count {
      steps[index].apply(); notes.append(steps[index].note); index += 1
      assembly = build()
    }
    if assembly.request.estimatedInputTokens <= input.budget.inputLimit { return .ready(assembly) }
    if input.pack.layer(.transcript) != nil || input.pack.layer(.article) != nil { return .needsSegmentation }
    return .tooLong("内容超出当前模型可用的长度（约 \(input.budget.inputLimit) tokens），请缩短问题或改用上下文更大的模型。")
  }

  /// The compressed block for turns older than the verbatim ones; nil when there are none.
  static func historySummary(_ older: [AIHistoryTurn]) -> String? {
    guard !older.isEmpty else { return nil }
    let summary = older.map { "问：\(clipped($0.question, 120))\n答：\(clipped($0.answer, 300))" }.joined(separator: "\n")
    return "<history_summary>\n" + AIContextLayer.neutralized(summary, tag: .viewer) + "\n</history_summary>"
  }
  static func historyCost(recent: [AIHistoryTurn], older: [AIHistoryTurn], legacy: Bool) -> Int {
    guard !legacy else { return 0 }
    return AITokenEstimator.estimate(historySummary(older) ?? "")
      + recent.reduce(0) { $0 + AITokenEstimator.estimate($1.question) + AITokenEstimator.estimate($1.answer) }
  }

  /// What the real assembly does with the history: the same filtering, the same budget steps.
  /// When the body still has to be segmented, the request is assembled again after segmentation;
  /// the preview then assumes all allowed history fits, as it usually does next to the summaries.
  public static func historyUse(_ input: Input) -> AIHistoryUse {
    guard input.preset.style == .conversation, !input.preset.legacyTemplate else { return AIHistoryUse(turns: 0, tokens: 0, note: nil) }
    guard input.settings.allows(.history, oneTime: input.oneTime) else { return AIHistoryUse(turns: 0, tokens: 0, note: nil) }
    guard !input.history.isEmpty else { return AIHistoryUse(turns: 0, tokens: 0, note: "还没有可带上的对话") }
    let allowed = allowedHistory(input.history, settings: input.settings, oneTime: input.oneTime)
    guard !allowed.isEmpty else { return AIHistoryUse(turns: 0, tokens: 0, note: "之前的对话用到了已关闭的内容，不会发送") }
    switch assemble(input) {
    case .ready(let assembly):
      let turns = assembly.recentTurns + assembly.compressedTurns
      return AIHistoryUse(turns: turns, tokens: assembly.historyTokens, note: turns == 0 ? "对话历史因长度限制未发送" : nil)
    case .needsSegmentation, .tooLong:
      let recent = Array(allowed.suffix(recentTarget)), older = Array(allowed.dropLast(recentTarget))
      return AIHistoryUse(turns: allowed.count, tokens: historyCost(recent: recent, older: older, legacy: false), note: nil)
    }
  }

  /// The old template variables, filled from what the pack is allowed to carry.
  static func legacyValues(_ pack: AIContextPack, question: String?) -> [String: String] {
    var values = ["title": pack.source.title, "question": question ?? "", "comments": "无评论", "subtitle": "无字幕", "description": "", "content": ""]
    switch pack.source {
    case .video(let info): values["description"] = info.description
    case .pgc(let info): values["description"] = info.description
    case .article: break
    }
    if let body = (pack.layer(.transcript) ?? pack.layer(.segmentSummaries))?.body, pack.source.kind.isTimeline { values["subtitle"] = body }
    if let body = pack.layer(.article)?.body ?? (pack.source.kind == .article ? pack.layer(.segmentSummaries)?.body : nil) { values["content"] = body }
    if let body = pack.layer(.comments)?.body { values["comments"] = body }
    return values
  }
  static func clipped(_ text: String, _ limit: Int) -> String {
    let value = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return value.count > limit ? String(value.prefix(limit)) + "…" : value
  }
}
