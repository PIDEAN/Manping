import CryptoKit
import Foundation

/// Conservative token estimate without a tokenizer dependency: one CJK character ≈ one token,
/// four ASCII characters ≈ one token, other scalars one token each, then a 1.1 safety factor.
/// It is a planning estimate, not a tokenizer bound; the request budget keeps its own margin and
/// unknown models shrink and retry when a provider still reports an overflow.
public enum AITokenEstimator {
  public static func estimate(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    var wide = 0, ascii = 0
    for scalar in text.unicodeScalars {
      if scalar.isASCII { ascii += 1 } else { wide += 1 }
    }
    let raw = Double(wide) + (Double(ascii) / 4).rounded(.up)
    return Int((raw * 1.1).rounded(.up))
  }
}

/// The per-request token limits. The same value plans the context (budgeter) and sets the
/// output cap in the protocol body (adapters), so the two can never disagree.
public struct AIRequestBudget: Sendable, Equatable, Codable {
  /// Total context window the request is planned against.
  public var contextTokens: Int
  /// Output reserved for the answer and sent as the request's max output tokens.
  public var maxOutputTokens: Int
  /// False when the model's window is not known: planned at 32K and shrunk on overflow.
  public var known: Bool
  public init(contextTokens: Int, maxOutputTokens: Int, known: Bool) {
    self.contextTokens = max(1024, contextTokens)
    self.maxOutputTokens = max(256, min(maxOutputTokens, self.contextTokens / 2))
    self.known = known
  }
  /// Safety margin for estimate error and protocol framing.
  public var safetyMargin: Int { max(512, contextTokens / 20) }
  /// Tokens available for every input part of the serialized request (system, layers, template,
  /// history, question).
  public var inputLimit: Int { max(256, contextTokens - maxOutputTokens - safetyMargin) }
  /// One step smaller after a provider reported a context overflow; nil when nothing smaller makes sense.
  public func reduced() -> AIRequestBudget? {
    guard contextTokens > 4096 else { return nil }
    let next = contextTokens / 2
    return AIRequestBudget(contextTokens: next, maxOutputTokens: min(maxOutputTokens, max(1024, next / 4)), known: known)
  }
  public static let unknownContext = 32_768
}

/// Known context windows and output limits of predefined models. Values not listed stay unknown.
public enum AIModelCapacity {
  public struct Entry: Sendable, Equatable { public let context: Int; public let output: Int }
  static let table: [String: Entry] = [
    "claude-opus-5-5": .init(context: 200_000, output: 64_000), "claude-sonnet-5-5": .init(context: 200_000, output: 64_000),
    "claude-haiku-5-5": .init(context: 200_000, output: 64_000), "claude-fable-5-1": .init(context: 200_000, output: 64_000),
    "gpt-5": .init(context: 400_000, output: 128_000), "gpt-5-mini": .init(context: 400_000, output: 128_000),
    "gpt-5-nano": .init(context: 400_000, output: 128_000), "gpt-5-pro": .init(context: 400_000, output: 128_000),
    "gpt-4.1": .init(context: 1_047_576, output: 32_768), "gpt-4o": .init(context: 128_000, output: 16_384),
    "gpt-4o-mini": .init(context: 128_000, output: 16_384), "gpt-4.5-preview": .init(context: 128_000, output: 16_384),
    "o4-mini": .init(context: 200_000, output: 100_000), "o3": .init(context: 200_000, output: 100_000),
    "o3-mini": .init(context: 200_000, output: 100_000), "o1": .init(context: 200_000, output: 100_000),
    "o1-mini": .init(context: 128_000, output: 65_536), "o1-preview": .init(context: 128_000, output: 32_768),
    "gpt-4": .init(context: 8_192, output: 4_096), "gpt-3.5-turbo": .init(context: 16_385, output: 4_096),
    "gemini-2.5-pro": .init(context: 1_048_576, output: 65_536), "gemini-2.5-flash": .init(context: 1_048_576, output: 65_536),
    "gemini-2.0-flash": .init(context: 1_048_576, output: 8_192), "gemini-1.5-flash": .init(context: 1_048_576, output: 8_192),
    "gemini-1.5-flash-8b": .init(context: 1_048_576, output: 8_192), "gemini-1.5-pro": .init(context: 2_097_152, output: 8_192),
    "deepseek-chat": .init(context: 64_000, output: 8_192), "deepseek-reasoner": .init(context: 64_000, output: 32_768),
    "grok-4-0709": .init(context: 256_000, output: 32_768), "grok-3": .init(context: 131_072, output: 16_384),
    "grok-3-mini": .init(context: 131_072, output: 16_384),
    "glm-4.6": .init(context: 200_000, output: 32_768), "glm-4.5": .init(context: 128_000, output: 32_768),
    "glm-4-plus": .init(context: 128_000, output: 4_096), "glm-4-long": .init(context: 1_000_000, output: 4_096),
    "qwen-max": .init(context: 32_768, output: 8_192), "qwen-plus": .init(context: 131_072, output: 8_192),
    "qwen-turbo": .init(context: 1_000_000, output: 8_192), "qwen-long-latest": .init(context: 1_000_000, output: 8_192),
    "mistral-large-latest": .init(context: 128_000, output: 8_192), "codestral-latest": .init(context: 256_000, output: 8_192),
    "llama-3.3-70b-versatile": .init(context: 128_000, output: 32_768), "llama-3.1-8b-instant": .init(context: 128_000, output: 8_192),
    "yi-lightning": .init(context: 16_000, output: 4_096), "yi-large": .init(context: 32_000, output: 4_096),
  ]
  /// A size spelled in the model id ("…-8k", "…128k…", "…-8192") is taken at its word.
  static func spelledSize(_ id: String) -> Int? {
    let lower = id.lowercased()
    for (marker, size) in [("1m", 1_000_000), ("256k", 256_000), ("200k", 200_000), ("128k", 128_000), ("32k", 32_768),
      ("32768", 32_768), ("16k", 16_384), ("8k", 8_192), ("8192", 8_192)] {
      if lower.range(of: "(^|[^0-9a-z])" + marker + "([^0-9a-z]|$)", options: .regularExpression) != nil { return size }
    }
    return nil
  }
  /// Models whose output cap also pays for hidden reasoning; they get a larger output reserve so
  /// the planned cap does not cut the answer short.
  public static func isReasoning(_ id: String) -> Bool {
    let lower = id.lowercased()
    let prefixes = ["gpt-5", "o1", "o3", "o4", "gemini-2.5", "deepseek-reasoner", "qwq", "glm-z1", "magistral", "hunyuan-t1", "x1"]
    return prefixes.contains { lower.hasPrefix($0) } || lower.contains("thinking") || lower.contains("reasoning")
      || lower.contains("-r1") || lower.contains("/qwq")
  }
  public static func known(modelID: String) -> Entry? {
    if let entry = table[modelID] { return entry }
    if let size = spelledSize(modelID) { return Entry(context: size, output: min(8_192, size / 4)) }
    return nil
  }
}

extension AIModel {
  /// The budget a request to this model is planned with. `desiredOutput` is what the task wants to
  /// reserve; the model's own output limit caps it.
  public func requestBudget(desiredOutput: Int) -> AIRequestBudget {
    let known = AIModelCapacity.known(modelID: id)
    let context = contextTokens ?? known?.context
    let output = min(desiredOutput, maxOutputTokens ?? known?.output ?? desiredOutput)
    guard let context else {
      return AIRequestBudget(contextTokens: AIRequestBudget.unknownContext, maxOutputTokens: min(output, 8_192), known: false)
    }
    return AIRequestBudget(contextTokens: context, maxOutputTokens: output, known: true)
  }
}

public enum AIHash {
  public static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
  public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  /// Canonical digest of labelled parts; labels and lengths are framed so parts cannot run together.
  public static func digest(_ parts: [(String, String)]) -> String {
    var data = Data()
    for (label, value) in parts {
      data.append(contentsOf: Array("\(label.utf8.count):\(label)=\(value.utf8.count):".utf8))
      data.append(contentsOf: Array(value.utf8)); data.append(0x0a)
    }
    return sha256(data)
  }
}

/// mm:ss or h:mm:ss, the format the system prompt asks models to cite.
public enum AITimecode {
  /// Times past this are not plausible for any video; model output beyond it is rejected rather
  /// than formatted (a huge finite Double would trap when converted to Int).
  public static let plausibleLimit: Double = 86_400
  /// The ceiling for model-supplied times: a day, or the media length when that is longer.
  public static func ceiling(duration: Double?) -> Double {
    guard let duration, duration.isFinite, duration > 0 else { return plausibleLimit }
    return max(plausibleLimit, duration + 1)
  }
  /// Whole seconds for display, clamped so no finite or infinite input can trap.
  public static func wholeSeconds(_ seconds: Double, rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Int {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int(min(seconds, 1e12).rounded(rule))
  }
  public static func format(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = wholeSeconds(seconds, rule: .down)
    return total >= 3600
      ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
      : String(format: "%02d:%02d", total / 60, total % 60)
  }
  /// Accepts "mm:ss", "h:mm:ss", "m:ss.f" and plain finite numbers of seconds.
  public static func parse(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      // JSON booleans arrive as NSNumber too; only real numbers are times.
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
      let double = number.doubleValue
      return double.isFinite ? double : nil
    }
    guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if let plain = Double(raw) { return plain.isFinite ? plain : nil }
    let pieces = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard (2...3).contains(pieces.count) else { return nil }
    var total = 0.0
    for (index, piece) in pieces.enumerated() {
      guard let value = Double(piece), value.isFinite, value >= 0 else { return nil }
      if index > 0, value >= 60 { return nil }
      total = total * 60 + value
    }
    return total
  }
}
