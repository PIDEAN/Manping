import Foundation
import os

/// User danmaku shield: keywords, `/regex/` rules, comment types and the smart-shield level.
/// Applied while lanes are laid out, so a changed rule set takes effect on the running video
/// and every live line that arrives afterwards.
public struct DanmakuFilter: Equatable, Sendable, Codable {
  /// Plain keywords (case-insensitive substring) or `/pattern/` regular expressions.
  public var rules: [String]
  public var hideScrolling: Bool
  public var hideTop: Bool
  public var hideBottom: Bool
  /// Hides every comment that is not plain white.
  public var hideColored: Bool
  /// Bilibili smart-shield level 0–10: comments whose server weight is below it are hidden.
  /// 0 turns the shield off; comments without a weight are never hidden by it.
  public var level: Int
  /// Shield words synced from the signed-in account (read-only); nil when none.
  public var account: DanmakuAccountShield?

  public static let maximumRules = 500
  public static let maximumRuleLength = 200

  public init(rules: [String] = [], hideScrolling: Bool = false, hideTop: Bool = false, hideBottom: Bool = false,
    hideColored: Bool = false, level: Int = 0) {
    self.rules = rules; self.hideScrolling = hideScrolling; self.hideTop = hideTop
    self.hideBottom = hideBottom; self.hideColored = hideColored; self.level = level
  }

  public var isEmpty: Bool { self == DanmakuFilter() }

  /// Normalises a typed rule: trimmed, bounded, and for `/…/` a pattern that compiles.
  /// Returns nil with a reason for rules that would never match or could not be evaluated.
  public static func validate(_ raw: String) -> Result<String, RuleError> {
    let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rule.isEmpty else { return .failure(.empty) }
    guard rule.count <= maximumRuleLength else { return .failure(.tooLong) }
    if let pattern = regexPattern(rule) {
      guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return .failure(.invalidRegex)
      }
      // Patterns like ^(a+)+$ backtrack exponentially. Try them on inputs that provoke it.
      for probe in complexityProbes where Self.match(expression, in: probe, budget: 0.005) == nil {
        return .failure(.tooComplex)
      }
    }
    return .success(rule)
  }
  public enum RuleError: Error, Equatable { case empty, tooLong, invalidRegex, tooComplex }

  static let complexityProbes = [
    String(repeating: "a", count: 40) + "!", String(repeating: "哈", count: 40) + "!",
    String(repeating: "ab", count: 30) + "!", String(repeating: "1", count: 40) + "x",
  ]

  /// Runs a pattern with a time budget: true / false for match / no match, nil when the budget
  /// ran out. `.reportProgress` lets the matcher stop in the middle of a long backtrack.
  static func match(_ expression: NSRegularExpression, in text: String, budget: TimeInterval) -> Bool? {
    let deadline = Date().addingTimeInterval(budget)
    var matched = false, expired = false
    expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) {
      result, _, stop in
      if result != nil { matched = true; stop.pointee = true }
      else if Date() > deadline { expired = true; stop.pointee = true }
    }
    return expired && !matched ? nil : matched
  }

  static func regexPattern(_ rule: String) -> String? {
    guard rule.count >= 3, rule.hasPrefix("/"), rule.hasSuffix("/") else { return nil }
    return String(rule.dropFirst().dropLast())
  }

  /// A rule set ready to test lines; built once per change, not per comment.
  public func compiled() -> Matcher { Matcher(self) }

  public struct Matcher: @unchecked Sendable {
    // NSRegularExpression is immutable and documented thread-safe.
    let filter: DanmakuFilter
    let keywords: [String]
    let expressions: [NSRegularExpression]
    let users: Set<String>
    /// Patterns that ran out of time once are switched off for this matcher (stored rules can
    /// predate validation, or hit a slow case on real text).
    private let disabled = OSAllocatedUnfairLock(initialState: Set<Int>())
    /// Per comment and pattern; a stuck pattern costs at most this once before it is disabled.
    static let budget: TimeInterval = 0.002
    init(_ filter: DanmakuFilter) {
      self.filter = filter
      var keywords: [String] = []
      var expressions: [NSRegularExpression] = []
      for rule in filter.rules.prefix(DanmakuFilter.maximumRules) where rule.count <= DanmakuFilter.maximumRuleLength {
        if let pattern = DanmakuFilter.regexPattern(rule) {
          if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            expressions.append(expression)
          }
        } else if !rule.isEmpty {
          keywords.append(rule.lowercased())
        }
      }
      if let account = filter.account, account.enabled {
        keywords += account.keywords.prefix(DanmakuAccountShield.maximumRules).map { $0.lowercased() }.filter { !$0.isEmpty }
        // Synced patterns were checked for runaway backtracking when they were stored.
        expressions += account.patterns.prefix(DanmakuAccountShield.maximumRules).compactMap {
          try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        users = Set(account.users.prefix(DanmakuAccountShield.maximumRules).map { $0.lowercased() })
      } else {
        users = []
      }
      self.keywords = keywords
      self.expressions = expressions
    }
    public func allows(_ comment: DanmakuComment) -> Bool {
      switch comment.mode {
      case 4: if filter.hideBottom { return false }
      case 5: if filter.hideTop { return false }
      default: if filter.hideScrolling { return false }
      }
      if filter.hideColored, comment.color & 0xffffff != 0xffffff { return false }
      if filter.level > 0, let weight = comment.weight, weight < filter.level { return false }
      if !users.isEmpty, let hash = comment.userHash, users.contains(hash) { return false }
      if !keywords.isEmpty {
        let text = comment.text.lowercased()
        if keywords.contains(where: text.contains) { return false }
      }
      for (index, expression) in expressions.enumerated() where !disabled.withLock({ $0.contains(index) }) {
        switch DanmakuFilter.match(expression, in: comment.text, budget: Self.budget) {
        case true?: return false
        case false?: continue
        case nil: disabled.withLock { _ = $0.insert(index) }
        }
      }
      return true
    }
  }
}

/// One change to the user's shield. Every editor applies its change to the latest stored rule
/// set, so two open editors never overwrite each other with an older copy.
public enum DanmakuFilterEdit: Sendable, Equatable {
  public enum CommentType: Sendable, Equatable, CaseIterable { case scrolling, top, bottom, colored }
  case hide(CommentType, Bool)
  case level(Int)
  /// A rule already checked with `DanmakuFilter.validate`; duplicates and rules over the limit are ignored.
  case addRule(String)
  case removeRule(String)
}

extension DanmakuFilter {
  public func hides(_ type: DanmakuFilterEdit.CommentType) -> Bool {
    switch type {
    case .scrolling: hideScrolling
    case .top: hideTop
    case .bottom: hideBottom
    case .colored: hideColored
    }
  }
  public func applying(_ edit: DanmakuFilterEdit) -> DanmakuFilter {
    var result = self
    switch edit {
    case .hide(.scrolling, let on): result.hideScrolling = on
    case .hide(.top, let on): result.hideTop = on
    case .hide(.bottom, let on): result.hideBottom = on
    case .hide(.colored, let on): result.hideColored = on
    case .level(let level): result.level = min(10, max(0, level))
    case .addRule(let rule):
      guard !rule.isEmpty, !result.rules.contains(rule), result.rules.count < Self.maximumRules else { break }
      result.rules.append(rule)
    case .removeRule(let rule): result.rules.removeAll { $0 == rule }
    }
    return result
  }
}

/// The account's own shield list on Bilibili (keywords, regular expressions and blocked users),
/// read with `/x/dm/filter/user`. Read-only: edits stay on Bilibili.
public struct DanmakuAccountShield: Equatable, Sendable, Codable {
  public var keywords: [String]
  /// Bare patterns (no slashes) that compiled and passed the backtracking probe.
  public var patterns: [String]
  /// Hashed sender ids as they appear in danmaku XML.
  public var users: [String]
  /// Patterns skipped as invalid or too slow.
  public var skipped: Int
  public var syncedAt: Date
  /// Applied only while the user keeps 使用账号屏蔽词 on.
  public var enabled: Bool
  public static let maximumRules = 5_000

  public init(keywords: [String] = [], patterns: [String] = [], users: [String] = [], skipped: Int = 0,
    syncedAt: Date = Date(), enabled: Bool = true) {
    self.keywords = keywords; self.patterns = patterns; self.users = users
    self.skipped = skipped; self.syncedAt = syncedAt; self.enabled = enabled
  }
  public var count: Int { keywords.count + patterns.count + users.count }

  /// `data.rule`: type 0 keyword, 1 regular expression, 2 user hash.
  /// A missing or malformed `rule` is an error (the cached list is kept); null or [] is an
  /// account with no rules.
  public static func parse(_ data: [String: Any], now: Date = Date()) throws -> DanmakuAccountShield {
    let rules: [[String: Any]]
    if data["rule"] is NSNull { rules = [] }
    else if let list = data["rule"] as? [[String: Any]] { rules = list }
    else { throw BiliError.invalidResponse("Invalid danmaku shield list") }
    var shield = DanmakuAccountShield(syncedAt: now)
    var seen = Set<String>()
    for rule in rules.prefix(maximumRules) {
      guard let text = (rule["filter"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
        text.count <= DanmakuFilter.maximumRuleLength else { continue }
      let type = (rule["type"] as? NSNumber)?.intValue ?? -1
      guard seen.insert("\(type):\(text)").inserted else { continue }
      switch type {
      case 0: shield.keywords.append(text)
      case 1:
        if case .success = DanmakuFilter.validate("/" + text + "/") { shield.patterns.append(text) } else { shield.skipped += 1 }
      case 2: shield.users.append(text.lowercased())
      default: continue
      }
    }
    return shield
  }
}

extension BiliService {
  /// The signed-in account's danmaku shield list (needs the Web login).
  public func danmakuAccountShield(expectedIdentity: AuthSnapshot) async throws -> DanmakuAccountShield {
    try checkRESTIdentity(expectedIdentity)
    let data = try await json("/x/dm/filter/user")
    try checkRESTIdentity(expectedIdentity)
    return try DanmakuAccountShield.parse(data)
  }
}
