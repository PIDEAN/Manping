import Foundation

public struct AIPhrase: Sendable, Equatable, Codable {
  public let text: String
  public let count: Int
  public init(text: String, count: Int) { self.text = text; self.count = count }
}

/// A representative danmaku line. Structured answers cite the ID and the original text is filled
/// back in locally, so a quote shown as viewers' words always comes from the material.
public struct AIDanmakuQuote: Sendable, Equatable, Codable {
  public let id: String
  public let time: Double
  public let text: String
  /// How many counted lines in the same range had this text.
  public let count: Int
  public init(id: String, time: Double, text: String, count: Int) { self.id = id; self.time = time; self.text = text; self.count = count }
}

public struct AIDanmakuPeak: Sendable, Equatable, Codable {
  public let id: String
  public let start: Double
  public let end: Double
  /// Counted lines in the range (after flood limits).
  public let count: Int
  /// Density relative to the whole-video average.
  public let ratio: Double
  public let phrases: [AIPhrase]
  public let quotes: [AIDanmakuQuote]
}

/// Statistics of the loaded danmaku, never the raw list. Adaptive windows (15–60 s), smoothed
/// counts and local peaks; constant density yields no peaks rather than invented highlights.
public struct AIDanmakuDigest: Sendable, Equatable, Codable {
  public let loadedCount: Int
  public let countedCount: Int
  public let window: Double
  public let duration: Double
  public let peaks: [AIDanmakuPeak]
  public let topPhrases: [AIPhrase]
  public let samples: [AIDanmakuQuote]
  /// Smoothed density per window for the mini curve.
  public let density: [Double]

  public static let minimumComments = 20
  /// 高能时刻 needs at least one real peak with representative lines.
  public var highlightsAvailable: Bool { peaks.contains { !$0.quotes.isEmpty } }
  public var allQuotes: [AIDanmakuQuote] { peaks.flatMap(\.quotes) + samples }
  public func quote(_ id: String) -> AIDanmakuQuote? { allQuotes.first { $0.id == id } }
  public func peak(_ id: String) -> AIDanmakuPeak? { peaks.first { $0.id == id } }

  /// nil when fewer than 20 lines remain after flood limits, or no usable duration exists.
  public static func make(_ comments: [DanmakuComment], duration rawDuration: Double) -> AIDanmakuDigest? {
    let valid = comments.filter { $0.time.isFinite && $0.time >= 0 }
    let latest = valid.map(\.time).max() ?? 0
    let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : latest + 1
    guard duration > 0, duration.isFinite else { return nil }
    let window = min(60, max(15, (duration / 40).rounded()))
    let bins = max(1, Int((duration / window).rounded(.up)))
    // Flood limits: one line per sender+text per window and three overall; without a sender
    // hash, ten identical lines per window.
    var perWindow: [String: Int] = [:], overall: [String: Int] = [:]
    var counted: [(comment: DanmakuComment, text: String, bin: Int)] = []
    for comment in valid.sorted(by: { $0.time < $1.time }) where comment.time <= duration + 1 {
      let text = normalized(comment.text)
      guard text.count >= 1 else { continue }
      let bin = min(bins - 1, Int(comment.time / window))
      let key = (comment.userHash.map { "h:" + $0 + "|" } ?? "t:") + text
      let windowKey = key + "#\(bin)"
      let windowCap = comment.userHash == nil ? 10 : 1
      guard perWindow[windowKey, default: 0] < windowCap else { continue }
      if comment.userHash != nil { guard overall[key, default: 0] < 3 else { continue } }
      perWindow[windowKey, default: 0] += 1; overall[key, default: 0] += 1
      counted.append((comment, text, bin))
    }
    guard counted.count >= minimumComments else { return nil }
    var counts = Array(repeating: 0.0, count: bins)
    for item in counted { counts[item.bin] += 1 }
    let smoothed = counts.indices.map { index -> Double in
      let left = counts[max(0, index - 1)], right = counts[min(bins - 1, index + 1)]
      return 0.25 * left + 0.5 * counts[index] + 0.25 * right
    }
    let mean = smoothed.reduce(0, +) / Double(bins)
    let variance = smoothed.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(bins)
    let deviation = variance.squareRoot()
    let rawMean = Double(counted.count) / Double(bins)
    var peaks: [AIDanmakuPeak] = []
    var quoteNumber = 0
    if bins >= 3, deviation > 1e-9, mean > 0 {
      let candidates = smoothed.indices.filter { index in
        let value = smoothed[index]
        let left = index > 0 ? smoothed[index - 1] : -1, right = index < bins - 1 ? smoothed[index + 1] : -1
        return value >= left && value >= right && (value - mean) / deviation >= 1.0 && value >= 1.5 * mean && counts[index] >= 5
      }.sorted { smoothed[$0] > smoothed[$1] || (smoothed[$0] == smoothed[$1] && $0 < $1) }
      var ranges: [ClosedRange<Int>] = []
      for index in candidates where ranges.count < 8 {
        var low = index, high = index
        while low > 0, index - low < 2, smoothed[low - 1] > mean + 0.5 * deviation { low -= 1 }
        while high < bins - 1, high - index < 2, smoothed[high + 1] > mean + 0.5 * deviation { high += 1 }
        let range = low...high
        if ranges.contains(where: { $0.overlaps(range) }) { continue }
        ranges.append(range)
      }
      for (number, range) in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }).enumerated() {
        let start = Double(range.lowerBound) * window, end = min(duration, Double(range.upperBound + 1) * window)
        let items = counted.filter { range.contains($0.bin) }
        let ratio = rawMean > 0 ? (Double(items.count) / Double(range.count) / rawMean * 10).rounded() / 10 : 0
        let quotes = representatives(items.map { ($0.comment, $0.text) }, limit: 3).map { item -> AIDanmakuQuote in
          quoteNumber += 1
          return AIDanmakuQuote(id: "q\(quoteNumber)", time: item.time, text: item.text, count: item.count)
        }
        peaks.append(AIDanmakuPeak(id: "d\(number + 1)", start: start, end: end, count: items.count, ratio: ratio,
          phrases: phrases(items.map(\.text), limit: 5), quotes: quotes))
      }
    }
    let samples = representatives(counted.map { ($0.comment, $0.text) }, limit: 8).map { item -> AIDanmakuQuote in
      quoteNumber += 1
      return AIDanmakuQuote(id: "q\(quoteNumber)", time: item.time, text: item.text, count: item.count)
    }
    return AIDanmakuDigest(loadedCount: comments.count, countedCount: counted.count, window: window, duration: duration,
      peaks: peaks, topPhrases: phrases(counted.map(\.text), limit: 20), samples: samples, density: smoothed)
  }

  /// Lower-cased, whitespace removed, runs of one character capped at three (哈哈哈哈 → 哈哈哈).
  static func normalized(_ text: String) -> String {
    var result = "", last: Character?, run = 0
    for character in text.lowercased() where !character.isWhitespace {
      if character == last { run += 1 } else { run = 1; last = character }
      if run <= 3 { result.append(character) }
    }
    return result
  }
  private static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }
  static let stopGrams: Set<String> = ["这个", "那个", "我们", "你们", "他们", "就是", "什么", "一个", "不是", "没有", "可以",
    "真的", "这样", "还是", "因为", "所以", "但是", "然后", "自己", "这么", "怎么", "现在", "已经", "觉得"]
  /// Whole short lines (2–10 characters) count as phrases; longer lines contribute 2–4 character
  /// grams. A phrase is dropped when a longer or shorter accepted phrase covers almost the same lines.
  static func phrases(_ texts: [String], limit: Int) -> [AIPhrase] {
    var counts: [String: Int] = [:]
    for text in texts {
      let characters = Array(text)
      var seen = Set<String>()
      if (2...10).contains(characters.count), characters.contains(where: isWordCharacter) { seen.insert(text) }
      else if characters.count > 10 {
        for size in 2...4 where characters.count >= size {
          for start in 0...(characters.count - size) {
            let gram = characters[start..<(start + size)]
            guard gram.allSatisfy(isWordCharacter), !gram.allSatisfy(\.isNumber) else { continue }
            let value = String(gram)
            if !stopGrams.contains(value) { seen.insert(value) }
          }
        }
      }
      for phrase in seen { counts[phrase, default: 0] += 1 }
    }
    let ranked = counts.filter { $0.value >= 2 }.sorted {
      $0.value != $1.value ? $0.value > $1.value : $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key
    }
    var accepted: [AIPhrase] = []
    for (text, count) in ranked where accepted.count < limit {
      let covered = accepted.contains { other in
        (other.text.contains(text) || text.contains(other.text)) && Double(min(other.count, count)) >= 0.8 * Double(max(other.count, count))
      }
      if !covered { accepted.append(AIPhrase(text: text, count: count)) }
    }
    return accepted
  }
  /// Most repeated lines in the range, one per sender, preferring higher shield weight; a missing
  /// weight is neutral, never a reason to drop a line.
  static func representatives(_ items: [(DanmakuComment, String)], limit: Int) -> [(time: Double, text: String, count: Int)] {
    var groups: [String: [DanmakuComment]] = [:]
    for (comment, text) in items where text.count >= 2 && text.count <= 40 { groups[text, default: []].append(comment) }
    let ranked = groups.sorted { lhs, rhs in
      if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
      let left = lhs.value.map { $0.weight ?? 5 }.max() ?? 0, right = rhs.value.map { $0.weight ?? 5 }.max() ?? 0
      return left != right ? left > right : lhs.key < rhs.key
    }
    var senders = Set<String>(), result: [(Double, String, Int)] = []
    for (_, lines) in ranked where result.count < limit {
      guard let best = lines.max(by: { ($0.weight ?? 5) < ($1.weight ?? 5) }) else { continue }
      if (best.weight ?? 5) < 1 { continue }
      if let hash = best.userHash { guard senders.insert(hash).inserted else { continue } }
      let original = best.text.trimmingCharacters(in: .whitespacesAndNewlines)
      result.append((best.time, String(original.prefix(60)), lines.count))
    }
    return result
  }

  /// Body of `<danmaku_digest>`.
  public func render() -> String {
    var lines: [String] = []
    for peak in peaks {
      var line = "[\(peak.id)] \(AITimecode.format(peak.start))-\(AITimecode.format(peak.end)) ×\(peak.ratio) 共 \(peak.count) 条"
      if !peak.phrases.isEmpty { line += " 高频：" + peak.phrases.map(\.text).joined(separator: "、") }
      lines.append(line)
      for quote in peak.quotes { lines.append("  [\(quote.id) \(AITimecode.format(quote.time))] 「\(quote.text)」×\(quote.count)") }
    }
    if peaks.isEmpty { lines.append("没有明显的密度峰值。") }
    if !topPhrases.isEmpty { lines.append("全片高频：" + topPhrases.map { "\($0.text)(\($0.count))" }.joined(separator: "、")) }
    if !samples.isEmpty {
      lines.append("代表弹幕：")
      for quote in samples { lines.append("  [\(quote.id) \(AITimecode.format(quote.time))] 「\(quote.text)」×\(quote.count)") }
    }
    return lines.joined(separator: "\n")
  }
}
