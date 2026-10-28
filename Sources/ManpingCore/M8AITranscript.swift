import Foundation

/// Picks the subtitle track sent to AI: human subtitles in the preferred language order; AI
/// subtitles only when no human track exists and 设置 › AI › 使用 AI 字幕 is on.
public enum AITranscriptSelector {
  /// The note when a video has only AI subtitles and 设置 › AI › 使用 AI 字幕 is off; the panel
  /// offers to turn it on from the failure card.
  public static let aiSubtitlesOffNote = "只有 AI 字幕，已在 设置 › AI 中关闭「使用 AI 字幕」"
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
