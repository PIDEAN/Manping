import Foundation

extension AIAnswerContent {
  /// The answer as Markdown: what 拷贝 puts on the pasteboard and what an export contains.
  public var markdownText: String {
    switch self {
    case .markdown(let text): return text
    case .fallback(let text, let reason): return text + "\n\n> " + reason
    case .structured(.chapters(let result)):
      var lines: [String] = []
      if !result.overview.isEmpty { lines.append(result.overview); lines.append("") }
      for chapter in result.chapters {
        let range = chapter.start.text + (chapter.end.map { "–" + $0.text } ?? "")
        lines.append("- **\(range) \(chapter.title)**" + (chapter.points.isEmpty ? "" : "：" + chapter.points.joined(separator: "；")))
      }
      if result.insufficient { lines.append(""); lines.append("> 材料不足，总结可能不完整。") }
      return lines.joined(separator: "\n")
    case .structured(.clips(let result)):
      var lines: [String] = []
      if !result.summary.isEmpty { lines.append(result.summary); lines.append("") }
      for clip in result.clips {
        lines.append("- \(AITimecode.format(clip.start))–\(AITimecode.format(clip.end))" + (clip.reason.isEmpty ? "" : "：" + clip.reason))
      }
      lines.append("")
      lines.append("共 \(AITimecode.wholeSeconds(result.totalSeconds)) 秒（上限 \(Int(result.limitSeconds)) 秒）")
      if !result.valid { lines.append("> 不符合要求：" + result.problems.joined(separator: "；")) }
      return lines.joined(separator: "\n")
    case .structured(.highlights(let result)):
      return result.moments.map { moment in
        var line = "- **\(moment.start.text) \(moment.title)**"
        if !moment.why.isEmpty { line += "：" + moment.why }
        if !moment.quotes.isEmpty { line += " " + moment.quotes.map { "「\($0.text)」" }.joined() }
        return line
      }.joined(separator: "\n")
    }
  }
  /// Seekable times cited by a structured answer, for the progress bar marks.
  public var citedTimes: [Double] {
    guard case .structured(let result) = self else { return [] }
    let times: [Double]
    switch result {
    case .chapters(let value): times = value.chapters.filter(\.start.seekable).map(\.start.seconds)
    case .highlights(let value): times = value.moments.filter(\.start.seekable).map(\.start.seconds)
    case .clips(let value): times = value.valid ? value.clips.map(\.start) : []
    }
    return Array(Set(times)).sorted()
  }
}

extension AIThread {
  /// 导出 Markdown: every turn with its question or preset, the answer, model and time.
  public func markdown(sourceTitle: String, materialTitle: (AIMaterialKind) -> String = { $0.title }) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
    var parts = ["# " + sourceTitle]
    for turn in turns {
      var section = "## " + (turn.question ?? turn.presetName)
      if turn.question != nil { section += "\n\n> 追问（\(turn.presetName)）" }
      section += "\n\n" + turn.content.markdownText
      let materials = turn.materials.sorted().map(materialTitle).joined(separator: "、")
      section += "\n\n_\(turn.model) · \(formatter.string(from: turn.createdAt))" + (materials.isEmpty ? "" : " · 依据：" + materials) + "_"
      parts.append(section)
    }
    return parts.joined(separator: "\n\n") + "\n"
  }
}

/// Finds mm:ss and h:mm:ss times in free text (Markdown answers).
public enum AITimestampScanner {
  public struct Match: Sendable, Equatable {
    public let range: Range<String.Index>
    public let seconds: Double
  }
  private static let expression = try! NSRegularExpression(pattern: #"(?<![\d:.])(?:(\d{1,2}):)?([0-5]?\d):([0-5]\d)(?![\d:])"#)
  public static func matches(in text: String) -> [Match] {
    let ns = text as NSString
    return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { result in
      guard let range = Range(result.range, in: text), let seconds = AITimecode.parse(String(text[range])) else { return nil }
      return Match(range: range, seconds: seconds)
    }
  }
}
