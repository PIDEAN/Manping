import Foundation

/// A slice of the transcript or article body small enough for one summary request.
public struct AISegmentChunk: Sendable, Equatable {
  public let index: Int
  public let start: Double
  public let end: Double
  /// Paragraph range for articles (`p3-p9`); nil for timeline media.
  public let label: String?
  public let body: String
  public var tokens: Int { AITokenEstimator.estimate(body) }
  /// Hash of the original material in this slice.
  public var materialHash: String { AIHash.sha256(body) }
  public var rangeText: String { label ?? "\(AITimecode.format(start))-\(AITimecode.format(end))" }
}

public enum AISegmentationFailure: Error, LocalizedError, Equatable {
  case tooLittleCoverage(covered: Int, total: Int)
  case budgetTooSmall
  public var errorDescription: String? {
    switch self {
    case .tooLittleCoverage(let covered, let total): "长内容分段整理失败（只完成 \(covered)/\(total) 段），请稍后重试。"
    case .budgetTooSmall: "当前模型的上下文太小，无法分段整理这段内容。"
    }
  }
}

/// Time boundaries are preferred cut points (chapters, else every five minutes); a window still
/// over budget is split by cue, and a single oversized cue or paragraph by characters.
public enum AISegmentPlanner {
  public static let promptVersion = 1
  public static let span: Double = 300

  public static func transcriptChunks(_ transcript: AITranscript, boundaries: [Double], maxTokens: Int, duration: Double?) -> [AISegmentChunk] {
    guard maxTokens >= 64, !transcript.cues.isEmpty else { return [] }
    let last = max(duration ?? 0, transcript.cues.map(\.end).max() ?? 0)
    var cuts = boundaries.filter { $0.isFinite && $0 > 0 && $0 < last }.sorted()
    if cuts.isEmpty { cuts = stride(from: span, to: last, by: span).map { $0 } }
    var windows: [[AITranscriptCue]] = Array(repeating: [], count: cuts.count + 1)
    for cue in transcript.cues {
      let index = cuts.firstIndex(where: { cue.start < $0 }) ?? cuts.count
      windows[index].append(cue)
    }
    // Lines (or line pieces) packed greedily inside each window, adjacent small windows merged.
    var pieces: [[(start: Double, end: Double, line: String)]] = []
    for window in windows where !window.isEmpty {
      var lines: [(Double, Double, String)] = []
      for cue in window {
        let line = AITranscript.render([cue])
        if AITokenEstimator.estimate(line) <= maxTokens { lines.append((cue.start, cue.end, line)); continue }
        for part in split(cue.text, maxTokens: max(16, maxTokens - 16)) {
          lines.append((cue.start, cue.end, "[\(cue.id) \(AITimecode.format(cue.start))-\(AITimecode.format(cue.end))] " + part))
        }
      }
      pieces.append(lines)
    }
    var chunks: [[(start: Double, end: Double, line: String)]] = []
    var current: [(start: Double, end: Double, line: String)] = [], tokens = 0
    for (windowIndex, window) in pieces.enumerated() {
      let windowTokens = window.reduce(0) { $0 + AITokenEstimator.estimate($1.line) + 1 }
      // Adjacent windows merge while the part stays within two spans (ten minutes) and the budget.
      let mergedSpan = (window.map(\.end).max() ?? 0) - (current.first?.start ?? 0)
      if !current.isEmpty, windowIndex > 0, tokens + windowTokens > maxTokens || mergedSpan > span * 2 {
        chunks.append(current); current = []; tokens = 0
      }
      for line in window {
        let cost = AITokenEstimator.estimate(line.line) + 1
        if !current.isEmpty, tokens + cost > maxTokens { chunks.append(current); current = []; tokens = 0 }
        current.append(line); tokens += cost
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks.enumerated().map { index, lines in
      AISegmentChunk(index: index, start: lines.map(\.start).min() ?? 0, end: lines.map(\.end).max() ?? 0, label: nil,
        body: lines.map(\.line).joined(separator: "\n"))
    }
  }

  public static func articleChunks(_ info: AIArticleInfo, maxTokens: Int) -> [AISegmentChunk] {
    guard maxTokens >= 64 else { return [] }
    var units: [(id: String, line: String, heading: Bool)] = []
    for (id, paragraph) in AIArticleText.identified(info) {
      let line = AIArticleText.render([(id, paragraph)])
      if AITokenEstimator.estimate(line) <= maxTokens { units.append((id, line, paragraph.heading != nil)); continue }
      for part in split(paragraph.text, maxTokens: max(16, maxTokens - 16)) { units.append((id, "[\(id)] " + part, false)) }
    }
    var groups: [[(id: String, line: String, heading: Bool)]] = []
    var current: [(id: String, line: String, heading: Bool)] = [], tokens = 0
    for unit in units {
      let cost = AITokenEstimator.estimate(unit.line) + 1
      // A heading starts a new part once the current one is reasonably full.
      if !current.isEmpty, tokens + cost > maxTokens || (unit.heading && tokens > maxTokens / 2) {
        groups.append(current); current = []; tokens = 0
      }
      current.append(unit); tokens += cost
    }
    if !current.isEmpty { groups.append(current) }
    return groups.enumerated().map { index, group in
      let first = group.first!.id, last = group.last!.id
      return AISegmentChunk(index: index, start: Double(index), end: Double(index + 1), label: first == last ? first : "\(first)-\(last)",
        body: group.map(\.line).joined(separator: "\n"))
    }
  }

  /// Splits text at sentence ends, then by characters, into pieces of at most `maxTokens`.
  static func split(_ text: String, maxTokens: Int) -> [String] {
    var pieces: [String] = [], current = ""
    let sentences = text.split(omittingEmptySubsequences: true) { "。！？!?；;\n".contains($0) }.map(String.init)
    for sentence in sentences.isEmpty ? [text] : sentences {
      var remainder = Substring(sentence)
      while AITokenEstimator.estimate(String(remainder)) > maxTokens {
        // Each CJK character is about 1.1 tokens; take a safely small prefix.
        let take = max(1, Int(Double(maxTokens) / 1.2))
        if !current.isEmpty { pieces.append(current); current = "" }
        pieces.append(String(remainder.prefix(take))); remainder = remainder.dropFirst(take)
      }
      let next = current.isEmpty ? String(remainder) : current + "。" + remainder
      if AITokenEstimator.estimate(next) > maxTokens { pieces.append(current); current = String(remainder) } else { current = next }
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
  }

  public static func mapPrompt(_ chunk: AISegmentChunk, total: Int, article: Bool) -> String {
    article ? """
      任务：上面是专栏正文的第 \(chunk.index + 1)/\(total) 部分（段落 \(chunk.rangeText)）。用 3–10 条要点概括这一部分：
      - 保留观点、数据和例子，每条以对应段落编号开头，如「[p3]」。
      - 不要评论，不要编造正文里没有的内容。只输出要点列表。
      """ : """
      任务：上面是视频字幕的第 \(chunk.index + 1)/\(total) 段（\(chunk.rangeText)）。用 5–12 条要点概括这一段：
      - 按时间顺序，每条以「[mm:ss]」开头，时间取自本段字幕。
      - 具体到人、事、数字；不要评论，不要编造字幕里没有的内容。只输出要点列表。
      """
  }
  public static func mapRequest(_ chunk: AISegmentChunk, total: Int, metadata: String, system: String, article: Bool,
    budget: AIRequestBudget) -> AIConversationRequest {
    let tag = article ? AIContextTag.article : .transcript
    let body = AIContextLayer(tag: tag, material: article ? .articleBody : .subtitles,
      attributes: [("part", "\(chunk.index + 1)/\(total)"), ("range", chunk.rangeText)], body: chunk.body)
    let meta = AIContextLayer(tag: .metadata, material: .metadata, body: metadata)
    let text = "<context>\n" + meta.rendered + "\n" + body.rendered + "\n</context>\n\n" + mapPrompt(chunk, total: total, article: article)
    return AIConversationRequest(system: system, messages: [.user(text)], format: .text, budget: budget)
  }
  /// Merges several summaries into one shorter summary (used when the summaries themselves are too long).
  public static func reduceRequest(_ summaries: [AISegmentSummary], metadata: String, system: String, budget: AIRequestBudget) -> AIConversationRequest {
    let body = summaries.map { "[\($0.id) " + ($0.label ?? "\(AITimecode.format($0.start))-\(AITimecode.format($0.end))") + "]\n" + $0.text }
      .joined(separator: "\n\n")
    let layer = AIContextLayer(tag: .segmentSummaries, material: .subtitles, body: body)
    let meta = AIContextLayer(tag: .metadata, material: .metadata, body: metadata)
    let text = "<context>\n" + meta.rendered + "\n" + layer.rendered + "\n</context>\n\n"
      + "任务：把上面几段分段摘要合并成一段更短的摘要，保留原有的时间点（[mm:ss]）或段落编号（[p…]），不超过 12 条要点，不要编造。只输出要点列表。"
    return AIConversationRequest(system: system, messages: [.user(text)], format: .text, budget: budget)
  }
}

public struct AISegmentRunResult: Sendable, Equatable {
  public let summaries: [AISegmentSummary]
  public let failed: [AISegmentChunk]
  public let total: Int
  /// Shown with the answer when some segments failed: “部分内容未覆盖：…”.
  public var coverageNote: String? {
    failed.isEmpty ? nil : "部分内容未覆盖：" + failed.map(\.rangeText).joined(separator: "、")
  }
}

/// Map step with a hard per-request budget, at most two requests at a time, one retry per
/// segment and cached results. Cancellation, identity changes and account-level failures stop the
/// whole run; when less than 60 % is covered the run fails instead of passing off a partial summary.
public enum AISegmentRunner {
  public typealias Generate = @Sendable (AIConversationRequest) async throws -> String
  public static func run(_ chunks: [AISegmentChunk], request: @escaping @Sendable (AISegmentChunk) -> AIConversationRequest,
    cacheKey: @escaping @Sendable (AISegmentChunk) -> String, cached: @escaping @Sendable (String) async -> String?,
    store: @escaping @Sendable (String, String) async -> Void, generate: @escaping Generate,
    progress: @escaping @Sendable (Int, Int) async -> Void, concurrency: Int = 2, attempts: Int = 2) async throws -> AISegmentRunResult {
    let total = chunks.count
    var results: [Int: String] = [:], failed: [AISegmentChunk] = []
    var done = 0
    await progress(0, total)
    try await withThrowingTaskGroup(of: (Int, String?).self) { group in
      var next = 0
      func launch() {
        guard next < chunks.count else { return }
        let chunk = chunks[next]; next += 1
        group.addTask {
          let key = cacheKey(chunk)
          if let hit = await cached(key) { return (chunk.index, hit) }
          var attempt = 0
          while true {
            try Task.checkCancellation()
            do {
              let text = try await generate(request(chunk)).trimmingCharacters(in: .whitespacesAndNewlines)
              guard !text.isEmpty else { throw AIChatFailure.emptyResponse }
              await store(key, text)
              return (chunk.index, text)
            } catch {
              if isFatal(error) { throw error }
              attempt += 1
              if attempt >= attempts { return (chunk.index, nil) }
            }
          }
        }
      }
      for _ in 0..<max(1, concurrency) { launch() }
      while let (index, text) = try await group.next() {
        if let text { results[index] = text } else if let chunk = chunks.first(where: { $0.index == index }) { failed.append(chunk) }
        done += 1
        await progress(done, total)
        launch()
      }
    }
    let summaries = chunks.compactMap { chunk -> AISegmentSummary? in
      results[chunk.index].map { AISegmentSummary(id: "g\(chunk.index + 1)", start: chunk.start, end: chunk.end, label: chunk.label, text: $0) }
    }
    let covered = coverage(chunks, succeeded: Set(results.keys))
    guard !summaries.isEmpty, covered >= 0.6 else { throw AISegmentationFailure.tooLittleCoverage(covered: summaries.count, total: total) }
    return AISegmentRunResult(summaries: summaries, failed: failed.sorted { $0.index < $1.index }, total: total)
  }
  static func coverage(_ chunks: [AISegmentChunk], succeeded: Set<Int>) -> Double {
    let weights = chunks.map { max(0.001, $0.label == nil ? $0.end - $0.start : Double($0.tokens)) }
    let all = weights.reduce(0, +)
    guard all > 0 else { return 0 }
    return zip(chunks, weights).filter { succeeded.contains($0.0.index) }.reduce(0) { $0 + $1.1 } / all
  }
  /// Errors that no retry of the same request can fix.
  static func isFatal(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    guard let failure = error as? AIChatFailure else { return false }
    switch failure {
    case .missingConfiguration, .invalidEndpoint, .unauthorized, .rateLimited, .planUsageLimit, .planNotEligible,
      .planSignInRequired, .unsupportedCapability, .localModelUnavailable, .refused, .localRefused: return true
    // The same request overflows again; the caller plans smaller chunks instead.
    case .contextTooLong: return true
    default: return false
    }
  }
}
