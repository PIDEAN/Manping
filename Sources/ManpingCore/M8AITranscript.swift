import Foundation

/// Picks the subtitle track sent to AI: human subtitles in the preferred language order; AI
/// subtitles only when no human track exists and 隐藏 AI 字幕 is off.
public enum AITranscriptSelector {
  public static func choose(_ tracks: [DownloadSubtitleTrack], settings: AIMaterialSettings) -> DownloadSubtitleTrack? {
    let human = tracks.filter { !$0.isAI }
    if let track = preferred(human, languages: settings.subtitleLanguages) ?? human.first { return track }
    guard !settings.excludeAISubtitles else { return nil }
    let ai = tracks.filter(\.isAI)
    return preferred(ai, languages: settings.subtitleLanguages) ?? ai.first
  }
  static func normalized(_ language: String) -> String {
    var value = language.lowercased()
    if value.hasPrefix("ai-") { value.removeFirst(3) }
    return value
  }
  static func preferred(_ tracks: [DownloadSubtitleTrack], languages: [String]) -> DownloadSubtitleTrack? {
    for language in languages.map({ $0.lowercased() }) {
      if let exact = tracks.first(where: { normalized($0.language) == language }) { return exact }
    }
    for language in languages.map({ $0.lowercased() }) {
      if let prefix = tracks.first(where: { normalized($0.language).hasPrefix(language + "-") }) { return prefix }
    }
    return nil
  }
}

/// A cleaned subtitle line. `start`/`end` cover every original cue merged into it, so a time cited
/// with this ID can be checked against the original material.
public struct AITranscriptCue: Sendable, Equatable, Codable {
  public let id: String
  public let start: Double
  public let end: Double
  public let text: String
  public init(id: String, start: Double, end: Double, text: String) {
    self.id = id; self.start = start; self.end = end; self.text = text
  }
}

public struct AITranscript: Sendable, Equatable, Codable {
  public let language: String
  public let isAI: Bool
  public let cues: [AITranscriptCue]
  public init(language: String, isAI: Bool, cues: [AITranscriptCue]) {
    self.language = language; self.isAI = isAI; self.cues = cues
  }
  static let fillers: Set<String> = ["嗯", "啊", "呃", "哦", "额", "唉", "哈", "诶", "欸", "噢", "嗯嗯", "啊啊", "呃呃", "那个",
    "um", "uh", "ah", "er", "hmm", "mm", "oh"]
  static let maxMergedCharacters = 60
  static let mergeGap = 1.2

  /// Merges adjacent cues (gap < 1.2 s, ≤ 60 characters), drops exact repeats of the previous line
  /// and lines that are only filler words or punctuation. IDs are assigned after cleaning.
  public static func clean(_ cues: [DownloadSubtitleCue], language: String, isAI: Bool) -> AITranscript {
    var merged: [(start: Double, end: Double, text: String)] = []
    var lastText = ""
    for cue in cues.sorted(by: { $0.start < $1.start }) {
      guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end >= cue.start else { continue }
      let text = cue.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, !isFiller(text) else { continue }
      if text == lastText, let last = merged.last, cue.start - last.end < 10 {
        merged[merged.count - 1].end = max(last.end, cue.end); continue
      }
      lastText = text
      if let last = merged.last, cue.start - last.end < mergeGap, last.text.count + text.count + 1 <= maxMergedCharacters {
        merged[merged.count - 1] = (last.start, max(last.end, cue.end), joined(last.text, text))
      } else {
        merged.append((cue.start, cue.end, text))
      }
    }
    let result = merged.enumerated().map { AITranscriptCue(id: "c\($0.offset + 1)", start: $0.element.start, end: $0.element.end, text: $0.element.text) }
    return AITranscript(language: language, isAI: isAI, cues: result)
  }
  static func isFiller(_ text: String) -> Bool {
    let stripped = text.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces).contains($0) }
    let value = String(String.UnicodeScalarView(stripped))
    return value.isEmpty || fillers.contains(value)
  }
  static func joined(_ first: String, _ second: String) -> String {
    guard let last = first.unicodeScalars.last, let next = second.unicodeScalars.first else { return first + second }
    if CharacterSet.punctuationCharacters.contains(last) { return first + second }
    return last.isASCII && next.isASCII ? first + " " + second : first + "，" + second
  }
  public func cues(in range: ClosedRange<Double>) -> [AITranscriptCue] {
    cues.filter { $0.end >= range.lowerBound && $0.start <= range.upperBound }
  }
  /// One line per cue: `[c12 01:02-01:15] text`.
  public static func render(_ cues: [AITranscriptCue]) -> String {
    cues.map { "[\($0.id) \(AITimecode.format($0.start))-\(AITimecode.format($0.end))] \($0.text)" }.joined(separator: "\n")
  }
}

public enum AIArticleText {
  /// Paragraph IDs `p1…` with Markdown-style heading markers.
  public static func render(_ paragraphs: [(id: String, paragraph: AIArticleParagraph)]) -> String {
    paragraphs.map { item in
      if let level = item.paragraph.heading, (1...6).contains(level) {
        return "[\(item.id)] " + String(repeating: "#", count: level) + " " + item.paragraph.text
      }
      return "[\(item.id)] " + item.paragraph.text
    }.joined(separator: "\n")
  }
  public static func identified(_ info: AIArticleInfo) -> [(id: String, paragraph: AIArticleParagraph)] {
    info.paragraphs.enumerated().map { ("p\($0.offset + 1)", $0.element) }
  }
}
