import Foundation

public struct DanmakuComment: Equatable, Sendable {
  public let time: Double
  public let mode: Int
  public let color: UInt32
  public let text: String
  /// Server smart-shield weight (0–11) when the source provides it.
  public let weight: Int?
  /// The sender's hashed id (list.so `p[6]`), used by account user shields.
  public let userHash: String?
  public init(time: Double, mode: Int = 1, color: UInt32 = 0xffffff, text: String, weight: Int? = nil,
    userHash: String? = nil) {
    self.time = time
    self.mode = mode
    self.color = color
    self.text = text
    self.weight = weight
    self.userHash = userHash
  }
}
public final class DanmakuParser: NSObject, XMLParserDelegate {
  private var result: [DanmakuComment] = []
  private var properties: [String]?
  private var text = ""
  public static func parse(_ data: Data) throws -> [DanmakuComment] {
    let delegate = DanmakuParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else { throw BiliError.invalidResponse("Invalid danmaku XML") }
    return delegate.result.sorted { $0.time < $1.time }
  }
  public func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    if name == "d" {
      properties = attributes["p"]?.components(separatedBy: ",")
      text = ""
    }
  }
  public func parser(_ parser: XMLParser, foundCharacters string: String) {
    if properties != nil { text += string }
  }
  public func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    guard name == "d", let p = properties else { return }
    defer { properties = nil }
    guard p.count >= 4, let time = Double(p[0]), time.isFinite, time >= 0, let mode = Int(p[1]),
      [1, 4, 5].contains(mode), let color = UInt32(p[3]), !text.isEmpty
    else { return }
    // list.so: time, mode, size, color, sent, pool, user hash, id, weight.
    let weight = p.count >= 9 ? Int(p[8]) : nil
    let hash = p.count >= 7 && !p[6].isEmpty ? p[6].lowercased() : nil
    result.append(
      DanmakuComment(time: time, mode: mode, color: color, text: String(text.prefix(160)), weight: weight, userHash: hash))
  }
}
public struct PositionedComment: Sendable {
  public let comment: DanmakuComment
  public let lane: Int
  public let progress: Double
}
/// Deterministic media-clock scheduling: pause, speed changes and seeking don't depend on wall time.
///
/// Scrolling comments all take the same time to cross, so a long line moves faster than a short
/// one. A lane only takes a new line once the previous tail has left the right edge and the new
/// head cannot catch it before it leaves on the left; text widths are estimated in ems against a
/// deliberately narrow view, which keeps wider views (and smaller fonts) collision-free too.
/// Top comments take a lane no scrolling line is using; bottom comments have their own stack.
public struct DanmakuTimeline: Sendable {
  private struct Entry {
    let comment: DanmakuComment
    let lane: Int
  }
  private struct Lane {
    var start = -Double.infinity
    var length = 0.0
    var fixedUntil = -Double.infinity
  }
  /// View width in ems that placement assumes (about a 670pt player at 24pt).
  static let assumedWidth = 28.0
  /// Space kept between two lines in one lane, in ems.
  static let spacing = 1.0
  private var entries: [Entry] = []
  /// Every accepted comment, so a speed change can lay the lanes out again.
  private var comments: [DanmakuComment] = []
  private var lanes: [Lane]
  private var bottomUntil: [Double]
  public let duration: Double
  /// Playback speed multiplier the lanes are laid out for (0.5–2).
  public private(set) var speed: Double = 1
  /// Shield applied while laying out; hidden lines keep no lane.
  public private(set) var filter = DanmakuFilter()
  private var matcher = DanmakuFilter().compiled()
  public init(comments: [DanmakuComment], lanes: Int = 16, duration: Double = 8) {
    self.duration = max(1, duration)
    self.lanes = [Lane](repeating: Lane(), count: max(1, lanes))
    bottomUntil = [Double](repeating: -Double.infinity, count: max(1, lanes / 2))
    self.comments = comments.filter { $0.time.isFinite }.sorted(by: { $0.time < $1.time })
    for comment in self.comments { place(comment) }
  }
  public var count: Int { entries.count }
  /// Comment density over the video, `bins` buckets scaled to 0…1 (peak = 1). Counts every
  /// loaded comment, shielded or not, so the curve shows where the audience reacted.
  public func density(duration: Double, bins: Int = 100) -> [Double] {
    guard duration.isFinite, duration > 0, bins > 0, comments.count >= 20 else { return [] }
    var counts = [Double](repeating: 0, count: bins)
    for comment in comments where comment.time >= 0 && comment.time <= duration {
      counts[min(bins - 1, Int(comment.time / duration * Double(bins)))] += 1
    }
    // Light smoothing so single spikes read as moments rather than noise.
    let smoothed = counts.indices.map { index -> Double in
      let window = counts[max(0, index - 1)...min(bins - 1, index + 1)]
      return window.reduce(0, +) / Double(window.count)
    }
    guard let peak = smoothed.max(), peak > 0 else { return [] }
    return smoothed.map { $0 / peak }
  }
  /// Lays the lanes out again for a new speed: a slower crawl needs wider gaps.
  public mutating func setSpeed(_ value: Double) {
    let clamped = value.isFinite ? min(2, max(0.5, value)) : 1
    guard clamped != speed else { return }
    speed = clamped
    relayout()
  }
  /// Applies a new shield to the comments already loaded and to later live lines.
  public mutating func setFilter(_ value: DanmakuFilter) {
    guard value != filter else { return }
    filter = value
    matcher = value.compiled()
    relayout()
  }
  private mutating func relayout() {
    entries.removeAll(keepingCapacity: true)
    lanes = [Lane](repeating: Lane(), count: lanes.count)
    bottomUntil = [Double](repeating: -Double.infinity, count: bottomUntil.count)
    for comment in comments { place(comment) }
  }
  /// Live chat: adds a comment at the current media clock. Comments must arrive in time order
  /// (a reload that restarts the clock should start a new timeline). Lines that scrolled off
  /// long ago are dropped so a long live session keeps a bounded timeline.
  @discardableResult public mutating func append(_ comment: DanmakuComment) -> Bool {
    if let last = comments.last, comment.time < last.time { return false }
    guard comment.time.isFinite else { return false }
    comments.append(comment)
    let placed = place(comment)
    if comments.count > 1_500 {
      let cutoff = comment.time - duration * 4
      if let keep = comments.firstIndex(where: { $0.time >= cutoff }), keep > 0 { comments.removeFirst(keep) }
      if let keep = entries.firstIndex(where: { $0.comment.time >= cutoff }), keep > 0 { entries.removeFirst(keep) }
      // A paused stream keeps the media clock still while chat keeps arriving, so the time
      // window alone never shrinks: hold at most the newest 1,500 whatever their timestamps.
      if comments.count > 1_500 { comments.removeFirst(comments.count - 1_500) }
      if entries.count > 1_500 { entries.removeFirst(entries.count - 1_500) }
    }
    return placed
  }
  /// Rough advance in ems: ASCII is about half as wide as CJK and emoji.
  static func estimatedLength(_ text: String) -> Double {
    text.unicodeScalars.reduce(0) { total, scalar in
      if scalar.properties.generalCategory == .nonspacingMark || scalar.value == 0xfe0f { return total }
      return total + (scalar.isASCII ? 0.56 : 1)
    }
  }
  @discardableResult private mutating func place(_ comment: DanmakuComment) -> Bool {
    guard matcher.allows(comment) else { return false }
    let time = comment.time
    let crossing = duration / speed
    let lane: Int?
    switch comment.mode {
    case 4:
      if let index = bottomUntil.firstIndex(where: { $0 <= time }) {
        bottomUntil[index] = time + crossing
        entries.append(Entry(comment: comment, lane: index))
        return true
      }
      return false
    case 5:
      lane = lanes.firstIndex { $0.fixedUntil <= time && $0.start + crossing <= time }
      if let lane { lanes[lane].fixedUntil = time + crossing }
    default:
      let length = Self.estimatedLength(comment.text)
      let width = Self.assumedWidth
      lane = lanes.firstIndex { previous in
        guard previous.fixedUntil <= time else { return false }
        // The previous tail must clear the right edge, and the new head must not reach the
        // previous tail before that line leaves on the left.
        let clear = crossing * (previous.length + Self.spacing) / (width + previous.length)
        let catchUp = crossing * (length + Self.spacing) / (width + length)
        return time - previous.start >= max(clear, catchUp)
      }
      if let lane { lanes[lane].start = time; lanes[lane].length = length }
    }
    guard let lane else { return false }
    entries.append(Entry(comment: comment, lane: lane))
    return true
  }
  public func visible(at clock: Double, speed: Double = 1) -> [PositionedComment] {
    guard clock.isFinite, clock >= 0 else { return [] }
    let duration = self.duration / (speed.isFinite ? min(2, max(0.5, speed)) : 1)
    var lo = 0
    var hi = entries.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if entries[mid].comment.time <= clock - duration { lo = mid + 1 } else { hi = mid }
    }
    var result: [PositionedComment] = []
    for entry in entries.dropFirst(lo) {
      if entry.comment.time > clock { break }
      result.append(
        PositionedComment(
          comment: entry.comment, lane: entry.lane,
          progress: (clock - entry.comment.time) / duration))
    }
    return result
  }
}
