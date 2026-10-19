import Foundation

public struct AITimeRange: Sendable, Equatable, Codable {
  public let start: Double
  public let end: Double
  public init(start: Double, end: Double) { self.start = start; self.end = max(start, end) }
}

/// Material IDs (cue c…, chapter ch…, official outline o…, segment summary g…, danmaku peak d…,
/// danmaku quote q…) and the original time range each covers.
public struct AIEvidenceIndex: Sendable, Equatable, Codable {
  public private(set) var ranges: [String: AITimeRange] = [:]
  public init(ranges: [String: AITimeRange] = [:]) { self.ranges = ranges }
  public mutating func add(_ id: String, start: Double, end: Double) {
    guard start.isFinite, end.isFinite, start >= 0 else { return }
    ranges[id] = AITimeRange(start: start, end: max(start, end))
  }
  public mutating func merge(_ other: AIEvidenceIndex) { ranges.merge(other.ranges) { first, _ in first } }
  /// True when `time` falls inside a cited item's original range, ±tolerance.
  public func supports(_ time: Double, cited ids: [String], tolerance: Double = 1) -> Bool {
    ids.contains { id in
      guard let range = ranges[id] else { return false }
      return time >= range.start - tolerance && time <= range.end + tolerance
    }
  }
  public func knows(_ id: String) -> Bool { ranges[id] != nil }
}

/// A cited time. Only `seekable` times get a playback link; the rest stay plain text.
public struct AITimestamp: Sendable, Equatable, Codable {
  public let seconds: Double
  public let text: String
  public let seekable: Bool
}

public struct AIChapterItem: Sendable, Equatable, Codable {
  public let start: AITimestamp
  public let end: AITimestamp?
  public let title: String
  public let points: [String]
  public let highlight: Bool
  public let evidence: [String]
}
public struct AIChaptersResult: Sendable, Equatable, Codable {
  public let overview: String
  public let chapters: [AIChapterItem]
  public let sources: [String]
  public let insufficient: Bool
}

public struct AIClipItem: Sendable, Equatable, Codable {
  public let start: Double
  public let end: Double
  public let reason: String
  public let evidence: [String]
}
/// 只看 3 分钟. `valid` is false when any clip breaks a rule; the UI then offers no playback.
public struct AIClipsResult: Sendable, Equatable, Codable {
  public let clips: [AIClipItem]
  /// Recomputed from the intervals, never taken from the model.
  public let totalSeconds: Double
  public let limitSeconds: Double
  public let summary: String
  public let valid: Bool
  public let problems: [String]
}

public struct AIHighlightMoment: Sendable, Equatable, Codable {
  public let peakID: String
  public let start: AITimestamp
  public let end: AITimestamp
  public let title: String
  public let why: String
  /// Original danmaku text filled in from the digest by ID.
  public let quotes: [AIDanmakuQuote]
  public let evidence: [String]
}
public struct AIHighlightsResult: Sendable, Equatable, Codable {
  public let moments: [AIHighlightMoment]
  /// Density curve for the card's mini chart.
  public let density: [Double]
  public let window: Double
}

public enum AIStructuredResult: Sendable, Equatable, Codable {
  case chapters(AIChaptersResult)
  case clips(AIClipsResult)
  case highlights(AIHighlightsResult)
}

/// The content of one answer as the UI renders it.
public enum AIAnswerContent: Sendable, Equatable, Codable {
  case markdown(String)
  case structured(AIStructuredResult)
  /// Structured output that could not be parsed, shown as text; the reason is shown with it.
  case fallback(text: String, reason: String)
  public var isUsableResult: Bool {
    switch self {
    case .markdown(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .structured(.clips(let clips)): clips.valid
    case .structured: true
    case .fallback: false
    }
  }
}

/// Parses and validates structured answers. Valid JSON is not trusted: every time is checked
/// against the media length and the cited material's original range.
public struct AIStructuredValidator: Sendable {
  public let duration: Double?
  public let evidence: AIEvidenceIndex
  public let danmaku: AIDanmakuDigest?
  public static let tolerance = 1.0
  public init(duration: Double?, evidence: AIEvidenceIndex, danmaku: AIDanmakuDigest?) {
    self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }; self.evidence = evidence; self.danmaku = danmaku
  }
  /// The 只看 3 分钟 limit: min(180 s, media length).
  public static func clipLimit(duration: Double?) -> Double {
    guard let duration, duration.isFinite, duration > 0 else { return 180 }
    return min(180, duration)
  }
  public static func clipMinimum(duration: Double?) -> Double { (duration ?? 600) < 60 ? 1 : 15 }

  public func validate(_ text: String, mode: AIOutputMode) -> AIAnswerContent {
    guard mode.isStructured else { return .markdown(text) }
    guard let object = Self.extractJSON(text) else {
      return .fallback(text: text, reason: "结构化结果无法解析，已按原文显示；其中的时间点不可点击。")
    }
    if hasImplausibleTime(object, mode: mode) {
      return .fallback(text: text, reason: "结构化结果中的时间超出视频时长，已按原文显示；其中的时间点不可点击。")
    }
    switch mode {
    case .chaptersJSON:
      if let result = chapters(object) { return .structured(.chapters(result)) }
    case .clipsJSON:
      if let result = clips(object) { return .structured(.clips(result)) }
    case .highlightsJSON:
      if let result = highlights(object) { return .structured(.highlights(result)) }
    case .markdown: break
    }
    return .fallback(text: text, reason: "结构化结果缺少必要字段，已按原文显示；其中的时间点不可点击。")
  }

  /// Accepts a bare object or one wrapped in a ```json fence or short prose.
  static func extractJSON(_ text: String) -> [String: Any]? {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("```") {
      body = body.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
      body = body.replacingOccurrences(of: #"\s*```\s*$"#, with: "", options: .regularExpression)
    }
    if let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] { return object }
    guard let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(body[open...close].utf8))) as? [String: Any]
  }
  static func strings(_ value: Any?) -> [String] {
    (value as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }
  /// True when any start/end the model gave parses but lies past what the media could hold. Such
  /// output is not trusted at all; the whole answer falls back to text.
  func hasImplausibleTime(_ object: [String: Any], mode: AIOutputMode) -> Bool {
    let key: String
    switch mode {
    case .chaptersJSON: key = "chapters"
    case .clipsJSON: key = "clips"
    case .highlightsJSON: key = "moments"
    case .markdown: return false
    }
    let ceiling = AITimecode.ceiling(duration: duration)
    return (object[key] as? [Any] ?? []).contains { item in
      guard let item = item as? [String: Any] else { return false }
      return ["start", "end"].contains { field in
        AITimecode.parse(item[field]).map { $0 > ceiling || $0 < 0 } ?? false
      }
    }
  }
  func withinMedia(_ time: Double) -> Bool {
    time.isFinite && time >= 0 && (duration.map { time <= $0 + Self.tolerance } ?? true)
  }
  func timestamp(_ value: Any?, cited: [String]) -> AITimestamp? {
    guard let seconds = AITimecode.parse(value), seconds.isFinite, seconds >= 0 else { return nil }
    let seekable = withinMedia(seconds) && evidence.supports(seconds, cited: cited, tolerance: Self.tolerance)
    return AITimestamp(seconds: seconds, text: AITimecode.format(seconds), seekable: seekable)
  }

  func chapters(_ object: [String: Any]) -> AIChaptersResult? {
    let overview = (object["overview"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = object["chapters"] as? [[String: Any]]
    guard raw != nil || !overview.isEmpty else { return nil }
    let peaks = danmaku?.peaks ?? []
    let items = (raw ?? []).compactMap { item -> AIChapterItem? in
      let cited = Self.strings(item["evidence"])
      guard let start = timestamp(item["start"], cited: cited),
        let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
      var end = timestamp(item["end"], cited: cited)
      if let value = end, value.seconds <= start.seconds { end = AITimestamp(seconds: value.seconds, text: value.text, seekable: false) }
      // The amber mark is only kept when the chapter really overlaps a danmaku peak.
      let claimed = item["highlight"] as? Bool ?? false
      let finish = end?.seconds ?? start.seconds
      let overlaps = peaks.contains { $0.start <= finish + Self.tolerance && $0.end >= start.seconds - Self.tolerance }
      return AIChapterItem(start: start, end: end, title: title, points: Self.strings(item["points"]),
        highlight: claimed && overlaps, evidence: cited)
    }
    return AIChaptersResult(overview: overview, chapters: items, sources: Self.strings(object["sources"]),
      insufficient: object["insufficient"] as? Bool ?? false)
  }

  func clips(_ object: [String: Any]) -> AIClipsResult? {
    guard let raw = object["clips"] as? [[String: Any]] else { return nil }
    let limit = Self.clipLimit(duration: duration), minimum = Self.clipMinimum(duration: duration)
    var problems: [String] = []
    var items: [AIClipItem] = []
    for (index, item) in raw.enumerated() {
      let cited = Self.strings(item["evidence"])
      let reason = (item["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard let start = AITimecode.parse(item["start"]), let end = AITimecode.parse(item["end"]), start.isFinite, end.isFinite else {
        problems.append("第 \(index + 1) 段的时间无效"); continue
      }
      var clippedEnd = end
      if let duration, end > duration, end <= duration + Self.tolerance { clippedEnd = duration }
      if !withinMedia(start) || !withinMedia(clippedEnd) { problems.append("第 \(index + 1) 段超出视频时长") }
      if start >= clippedEnd { problems.append("第 \(index + 1) 段的开始不早于结束") }
      else if clippedEnd - start < minimum - 0.001 { problems.append("第 \(index + 1) 段短于 \(Int(minimum)) 秒") }
      if !evidence.supports(start, cited: cited) || !evidence.supports(clippedEnd, cited: cited) {
        problems.append("第 \(index + 1) 段的时间没有对应的材料依据")
      }
      items.append(AIClipItem(start: start, end: clippedEnd, reason: reason, evidence: cited))
    }
    if items.isEmpty { problems.append("没有片段") }
    if items.count > 5 { problems.append("片段多于 5 个") }
    let sorted = items.sorted { $0.start < $1.start }
    for index in sorted.indices.dropFirst() where sorted[index].start < sorted[index - 1].end - 0.001 {
      problems.append("片段之间有重叠")
      break
    }
    let total = sorted.reduce(0) { $0 + max(0, $1.end - $1.start) }
    if total > limit + Self.tolerance { problems.append("总时长 \(AITimecode.wholeSeconds(total)) 秒，超过 \(Int(limit)) 秒") }
    return AIClipsResult(clips: sorted, totalSeconds: total, limitSeconds: limit,
      summary: (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
      valid: problems.isEmpty, problems: problems)
  }

  func highlights(_ object: [String: Any]) -> AIHighlightsResult? {
    guard let raw = object["moments"] as? [[String: Any]] else { return nil }
    let moments = raw.compactMap { item -> AIHighlightMoment? in
      // A moment must come from a real peak; otherwise there is nothing to support it.
      guard let peakID = item["peak"] as? String, let peak = danmaku?.peak(peakID) else { return nil }
      let cited = [peakID] + Self.strings(item["evidence"])
      guard let start = timestamp(item["start"], cited: cited), let end = timestamp(item["end"], cited: cited) else { return nil }
      let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let quotes = Self.strings(item["quotes"]).compactMap { danmaku?.quote($0) }
      let inPeak = start.seconds >= peak.start - Self.tolerance && start.seconds <= peak.end + Self.tolerance
      let startStamp = AITimestamp(seconds: start.seconds, text: start.text, seekable: start.seekable && inPeak)
      return AIHighlightMoment(peakID: peakID, start: startStamp, end: end, title: title.isEmpty ? "高能时刻" : title,
        why: (item["why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), quotes: quotes, evidence: cited)
    }.sorted { $0.start.seconds < $1.start.seconds }
    return AIHighlightsResult(moments: moments, density: danmaku?.density ?? [], window: danmaku?.window ?? 30)
  }
}
