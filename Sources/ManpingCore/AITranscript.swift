import Foundation

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
  // Immutable Foundation objects are safe to share across concurrent material requests.
  private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
  private static let ignoredFillerCharacters = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces)

  /// Merges adjacent cues (gap < 1.2 s, ≤ 60 characters), drops exact repeats of the previous line
  /// and lines that are only filler words or punctuation. IDs are assigned after cleaning.
  public static func clean(_ cues: [DownloadSubtitleCue], language: String, isAI: Bool) -> AITranscript {
    var merged: [(start: Double, end: Double, text: String)] = []
    merged.reserveCapacity(cues.count)
    var lastText = ""
    // NaN breaks the ordering required by sort and can place an earlier cue after a later one.
    let valid = cues.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }
    for cue in valid.sorted(by: { $0.start < $1.start }) {
      let text = whitespace.stringByReplacingMatches(in: cue.text, range: NSRange(cue.text.startIndex..., in: cue.text), withTemplate: " ")
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
    let stripped = text.lowercased().unicodeScalars.filter { !ignoredFillerCharacters.contains($0) }
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

