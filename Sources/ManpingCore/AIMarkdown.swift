import Foundation

public struct AICommentSections {
  public let sections: [(title: String, body: String)]
  public init?(_ text: String) {
    var result: [(String, String)] = []
    var title: String?
    var lines: [String] = []
    func flush() {
      if let title { result.append((title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
      lines = []
    }
    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("## ") { flush(); title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
      else if title != nil { lines.append(line) }
      else if !line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
    }
    flush()
    guard result.count >= 2 else { return nil }
    sections = result
  }
}


public enum AIMarkdownBlock: Equatable {
  public struct Item: Equatable { public let text: String; public let depth: Int }
  case heading(Int, String)
  case paragraph(String)
  case list([Item], ordered: Bool)
  case code(String)
  case quote(String)
  case table([String], [[String]])
  case rule

  public static let seekScheme = "manping-seek"

  public static func parse(_ text: String) -> [AIMarkdownBlock] {
    var blocks: [AIMarkdownBlock] = []
    var paragraph: [String] = []
    var items: [Item] = [], ordered = false
    var quote: [String] = []
    var code: [String]?
    var table: [[String]] = []
    func flushParagraph() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
    func flushList() { if !items.isEmpty { blocks.append(.list(items, ordered: ordered)); items = [] } }
    func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
    func flushTable() {
      defer { table = [] }
      guard !table.isEmpty else { return }
      let body = table.dropFirst().filter { row in !row.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
      if table.count >= 2 { blocks.append(.table(table[0], Array(body))) }
      else { blocks.append(.paragraph(table[0].joined(separator: " | "))) }
    }
    func flushAll() { flushParagraph(); flushList(); flushQuote(); flushTable() }
    for raw in text.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if var lines = code {
        if line.hasPrefix("```") { blocks.append(.code(lines.joined(separator: "\n"))); code = nil }
        else { lines.append(raw); code = lines }
        continue
      }
      if line.hasPrefix("```") { flushAll(); code = []; continue }
      if line.isEmpty { flushAll(); continue }
      if line.hasPrefix("|"), line.hasSuffix("|"), line.count > 1 {
        flushParagraph(); flushList(); flushQuote()
        table.append(line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
          .map { $0.trimmingCharacters(in: .whitespaces) })
        continue
      }
      flushTable()
      if let level = heading(line) {
        flushAll(); blocks.append(.heading(level, String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
        continue
      }
      if ["---", "***", "___"].contains(line) { flushAll(); blocks.append(.rule); continue }
      if line.hasPrefix(">") {
        flushParagraph(); flushList()
        quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
      }
      flushQuote()
      let depth = (raw.prefix { $0 == " " }.count) / 2
      if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
        flushParagraph()
        if !items.isEmpty && ordered && depth == 0 { flushList() }
        if items.isEmpty { ordered = false }
        items.append(Item(text: String(line.dropFirst(2)), depth: min(depth, 3))); continue
      }
      if let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
        flushParagraph()
        if !items.isEmpty && !ordered && depth == 0 { flushList() }
        if items.isEmpty { ordered = true }
        items.append(Item(text: String(line[range.upperBound...]), depth: min(depth, 3))); continue
      }
      if !items.isEmpty, raw.hasPrefix("  ") {
        // Continuation of the previous list item.
        let last = items.removeLast(); items.append(Item(text: last.text + " " + line, depth: last.depth)); continue
      }
      flushList()
      paragraph.append(line)
    }
    if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
    flushAll()
    return blocks
  }
  private static func heading(_ line: String) -> Int? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    return hashes
  }
  /// Wraps mm:ss times outside code spans in seek links (only times inside the media).
  public static func linkTimes(_ text: String, duration: Double?) -> String {
    let pieces = text.components(separatedBy: "`")
    return pieces.enumerated().map { index, piece in
      guard index % 2 == 0, !piece.contains("](") else { return piece }
      let result = NSMutableString(string: piece)
      for match in AITimestampScanner.matches(in: piece).reversed() {
        if let duration, duration > 0, match.seconds > duration + 1 { continue }
        let label = String(piece[match.range])
        result.replaceCharacters(in: NSRange(match.range, in: piece), with: "[\(label)](\(seekScheme)://\(Int(match.seconds)))")
      }
      return result as String
    }.joined(separator: "`")
  }
}

/// A view-owned cache. It stores values, never UI actions or closures. Each text slot and
/// inline entry has a byte limit; streamed answers cannot grow a process-wide cache.
@MainActor public final class AIMarkdownParseCache {
  private let maximumBytes: Int
  private let maximumEntries: Int
  private var blockText: String?
  private var parsedBlocks: [AIMarkdownBlock] = []
  private var commentText: String?
  private var parsedComments: AICommentSections?
  private struct InlineKey: Hashable {
    let source: String
    let seekable: Bool
    let duration: Double?
  }
  private var inlines: [InlineKey: AttributedString] = [:]
  private var inlineBytes = 0
  private(set) var blockParses = 0
  private(set) var inlineParses = 0
  private(set) var commentParses = 0
  var inlineEntryCount: Int { inlines.count }
  public init(maximumBytes: Int = 512 * 1024, maximumEntries: Int = 256) {
    self.maximumBytes = max(0, maximumBytes)
    self.maximumEntries = max(0, maximumEntries)
  }
  public func blocks(_ text: String) -> [AIMarkdownBlock] {
    if blockText == text { return parsedBlocks }
    blockParses += 1
    let value = AIMarkdownBlock.parse(text)
    // Retain only one document, and never retain an oversized document.
    blockText = text.utf8.count <= maximumBytes ? text : nil
    parsedBlocks = blockText == nil ? [] : value
    return value
  }
  public func comments(_ text: String) -> AICommentSections? {
    if commentText == text { return parsedComments }
    commentParses += 1
    let value = AICommentSections(text)
    commentText = text.utf8.count <= maximumBytes ? text : nil
    parsedComments = commentText == nil ? nil : value
    return value
  }
  public func inline(_ source: String, seekable: Bool, duration: Double?) -> AttributedString {
    let key = InlineKey(source: source, seekable: seekable, duration: duration?.isFinite == true ? duration : nil)
    if let value = inlines[key] { return value }
    inlineParses += 1
    let linked = seekable ? AIMarkdownBlock.linkTimes(source, duration: key.duration) : source
    let value = (try? AttributedString(markdown: linked,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    // Include parser expansion in the budget (timestamps can add seek URLs).
    let bytes = source.utf8.count + linked.utf8.count
    if bytes <= maximumBytes, maximumEntries > 0 {
      if inlines.count >= maximumEntries || inlineBytes + bytes > maximumBytes {
        inlines.removeAll(keepingCapacity: true); inlineBytes = 0
      }
      inlines[key] = value; inlineBytes += bytes
    }
    return value
  }
}
