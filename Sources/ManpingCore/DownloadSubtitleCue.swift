public struct DownloadSubtitleCue: Equatable, Sendable {
  public let start: Double
  public let end: Double
  public let text: String
  public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}
