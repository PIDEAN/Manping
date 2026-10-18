import Foundation

public struct DownloadSubtitleCue: Equatable, Sendable {
  public let start: Double
  public let end: Double
  public let text: String
  public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}
public enum DownloadExport {
  /// XML contains only the fields available in the parsed comments; no account identifiers are fabricated.
  public static func danmakuXML(_ comments: [DanmakuComment]) -> Data {
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><i>"
    for comment in comments where comment.time.isFinite && comment.time >= 0 {
      xml += "<d p=\"\(comment.time),\(comment.mode),25,\(comment.color),0,0,0,0\">\(escapeXML(comment.text))</d>"
    }
    xml += "</i>"
    return Data(xml.utf8)
  }
  public static func parseSubtitleJSON(_ data: Data) throws -> [DownloadSubtitleCue] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let body = object["body"] as? [[String: Any]] else { throw BiliError.invalidResponse("字幕格式无效") }
    return try body.map { item in
      guard let start = item["from"] as? Double, let end = item["to"] as? Double,
        start.isFinite, end.isFinite, start >= 0, end > start, end < 86_400_000,
        let text = item["content"] as? String else { throw BiliError.invalidResponse("字幕时间或正文无效") }
      return DownloadSubtitleCue(start: start, end: end, text: text)
    }
  }
  public static func subtitleSRT(_ cues: [DownloadSubtitleCue]) -> Data {
    let lines = cues.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end < 86_400_000 }
      .sorted { $0.start < $1.start }.enumerated().map { index, cue in
        "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text.replacingOccurrences(of: "\r\n", with: "\n"))\n"
      }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }
  public static func write(_ data: Data, to destination: URL) throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadFailure.outputExists }
    // withoutOverwriting makes the existence check race-safe; exports never replace a user file.
    do { try data.write(to: destination, options: .withoutOverwriting) }
    catch { throw DownloadFailure.disk("导出文件", error) }
  }
  private static func timestamp(_ seconds: Double) -> String {
    let ms = Int((seconds * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
  }
  private static func escapeXML(_ text: String) -> String {
    let valid = String(String.UnicodeScalarView(text.unicodeScalars.filter {
      $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value <= 0xd7ff)
        || ($0.value >= 0xe000 && $0.value <= 0xfffd) || ($0.value >= 0x10000 && $0.value <= 0x10ffff)
    }))
    return valid.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
  }
}
