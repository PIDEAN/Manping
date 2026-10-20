import Foundation
import Synchronization

public struct LiveInteractionContext: Sendable, Equatable {
  public let identity: AuthSnapshot
  public let accountMid: Int64?
  public let roomID: Int64
  public let anchorID: Int64
  public let generation: UInt64
  public init(
    identity: AuthSnapshot, accountMid: Int64?, roomID: Int64, anchorID: Int64, generation: UInt64
  ) {
    self.identity = identity
    self.accountMid = accountMid
    self.roomID = roomID
    self.anchorID = anchorID
    self.generation = generation
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity.epoch == rhs.identity.epoch
      && lhs.identity.identityRevision == rhs.identity.identityRevision
      && lhs.accountMid == rhs.accountMid && lhs.roomID == rhs.roomID
      && lhs.anchorID == rhs.anchorID
      && lhs.generation == rhs.generation
  }
}
public enum LiveInteractionError: Error, Equatable, Sendable {
  case staleContext, busy, needsLogin, needsAppLogin, muted
  case paused(until: TimeInterval)
  case rateLimited, duplicateContent, emptyDraft, tooLong, invalidConfirmation, expiredQuote
  case paidGiftsDisabled, extraConfirmationRequired, unsupportedGift, insufficientBag, overflow
  case unknownConditions, invalidActivity, unverifiedReceipt
}
public enum LiveAction: Sendable, Hashable { case danmaku, style, like, gift, medal, lottery }
public enum LiveGiftState: Sendable, Equatable {
  case idle
  case sending(UUID)
  case succeeded(UUID)
  case rejected(UUID, String)
  case unknown(UUID)
}
public enum LiveLengthAlgorithm: Sendable {
  case character, utf16
  public func count(_ text: String) -> Int { self == .character ? text.count : text.utf16.count }
}
public struct LiveDanmakuDraft: Sendable, Equatable {
  public var text: String
  public var reply: LiveDanmakuReply?
  public var emoticon: String?
  public init(text: String = "", reply: LiveDanmakuReply? = nil, emoticon: String? = nil) {
    self.text = text
    self.reply = reply
    self.emoticon = emoticon
  }
}
public struct LiveDanmakuReply: Sendable, Equatable {
  public let mid: Int64
  public let name: String
  public let messageID: String
  public init(mid: Int64, name: String, messageID: String) {
    self.mid = mid
    self.name = name
    self.messageID = messageID
  }
}
public enum LiveDanmakuFailure {
  public static func message(code: Int, message: String) -> String {
    if code == 0 {
      switch message {
      case "f": return "弹幕包含全站屏蔽词"
      case "k": return "弹幕包含主播屏蔽词"
      case "msg in 1s": return "发送太快，请稍后再发"
      case "msg repeat": return "请勿重复发送相同弹幕"
      default: break
      }
    }
    switch code {
    case 1_003_212: return "弹幕超过字数上限"
    case 10030, 10031: return "发送太快，请稍后再发"
    case 1003: return "你已被禁言"
    case -101: return "请先登录"
    default: return "B 站返回：\(message)（\(code)）"
    }
  }
}

/// Atomic process-wide reservations are never refunded or queued after a failed send.
public final class LiveAccountLimiter: Sendable {
  public static let shared = LiveAccountLimiter()
  private struct Entry {
    var last: TimeInterval?
    var contents: [String: TimeInterval] = [:]
  }
  private let entries = Mutex<[Int64: Entry]>([:])
  public init() {}
  public func reserve(account: Int64, content: String, now: TimeInterval) throws {
    try entries.withLock { values in
      var entry = values[account] ?? Entry()
      if let last = entry.last, now - last < 1.5 { throw LiveInteractionError.rateLimited }
      if let last = entry.contents[content], now - last < 5 {
        throw LiveInteractionError.duplicateContent
      }
      entry.contents = entry.contents.filter { now - $0.value < 5 }
      entry.last = now
      entry.contents[content] = now
      values[account] = entry
    }
  }
}
public struct LiveGiftQuote: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let version: UInt64
  public let context: LiveInteractionContext
  public let giftID: Int64
  public let bagID: Int64?
  public let quantity: Int64
  public let coin: String
  public let unitPrice: Int64
  public let total: Int64
  public let expiresAt: TimeInterval
  // Only the session may issue quotes and confirmation capabilities.
  init(
    version: UInt64, context: LiveInteractionContext, giftID: Int64, bagID: Int64?, quantity: Int64,
    coin: String, unitPrice: Int64, total: Int64, expiresAt: TimeInterval
  ) {
    id = UUID()
    self.version = version
    self.context = context
    self.giftID = giftID
    self.bagID = bagID
    self.quantity = quantity
    self.coin = coin
    self.unitPrice = unitPrice
    self.total = total
    self.expiresAt = expiresAt
  }
}
public struct LiveGiftConfirmation: Sendable {
  public let nonce: UUID
  public let quote: LiveGiftQuote
  public let expiresAt: TimeInterval
  public let extraConfirmed: Bool
  init(quote: LiveGiftQuote, expiresAt: TimeInterval, extraConfirmed: Bool) {
    nonce = UUID()
    self.quote = quote
    self.expiresAt = expiresAt
    self.extraConfirmed = extraConfirmed
  }
}
public final class LivePendingGiftStore: Sendable {
  public static let shared = LivePendingGiftStore()
  private struct Record: Sendable {
    let confirmation: LiveGiftConfirmation
    let unknown: Bool
  }
  private let records = Mutex<[UUID: Record]>([:])
  public init() {}
  /// In-flight transactions are retained internally but cannot be acknowledged prematurely.
  public var pending: [LiveGiftConfirmation] {
    records.withLock { $0.values.filter(\.unknown).map(\.confirmation) }
  }
  func begin(_ confirmation: LiveGiftConfirmation) {
    records.withLock { $0[confirmation.nonce] = Record(confirmation: confirmation, unknown: false) }
  }
  func markUnknown(_ confirmation: LiveGiftConfirmation) {
    records.withLock { $0[confirmation.nonce] = Record(confirmation: confirmation, unknown: true) }
  }
  func resolve(_ nonce: UUID) { records.withLock { $0[nonce] = nil } }
  public func acknowledgeChecked(_ nonce: UUID) {
    records.withLock { if $0[nonce]?.unknown == true { $0[nonce] = nil } }
  }
}
public struct LiveGiftPolicy: Sendable, Equatable {
  public var allowPaid: Bool
  public var extraConfirmationThreshold: Int64
  /// Verified ordinary gift IDs and their fixed gold-seed prices. Empty in production.
  public var fixedGoldPrices: [Int64: Int64]
  public init(
    allowPaid: Bool = false, extraConfirmationThreshold: Int64 = 10_000,
    fixedGoldPrices: [Int64: Int64] = [:]
  ) {
    self.allowPaid = allowPaid
    self.extraConfirmationThreshold = max(0, extraConfirmationThreshold)
    self.fixedGoldPrices = fixedGoldPrices
  }
}
public struct LiveActivity: Sendable, Equatable {
  public enum Kind: Sendable { case lottery, redPocket }
  public let id: Int64
  public let kind: Kind
  public let deadline: TimeInterval
  public let isFree: Bool?
  public let conditionsKnown: Bool
  public let automaticDanmaku: String?
  public let automaticallyFollows: Bool?
  public init(
    id: Int64, kind: Kind, deadline: TimeInterval, isFree: Bool?, conditionsKnown: Bool,
    automaticDanmaku: String?, automaticallyFollows: Bool?
  ) {
    self.id = id
    self.kind = kind
    self.deadline = deadline
    self.isFree = isFree
    self.conditionsKnown = conditionsKnown
    self.automaticDanmaku = automaticDanmaku
    self.automaticallyFollows = automaticallyFollows
  }
}
public struct LiveActivityConfirmation: Sendable {
  public let nonce: UUID
  public let activity: LiveActivity
  public let context: LiveInteractionContext
  init(activity: LiveActivity, context: LiveInteractionContext) {
    nonce = UUID()
    self.activity = activity
    self.context = context
  }
}
public struct LiveSuperChatStore: Sendable {
  private var values: [String: LiveSuperChat] = [:]
  private var deleted: Set<String> = []
  public init() {}
  public mutating func merge(_ messages: [LiveSuperChat]) {
    for message in messages where !deleted.contains(message.id) { values[message.id] = message }
  }
  public mutating func delete(_ ids: [String]) {
    for id in ids {
      deleted.insert(id)
      values[id] = nil
    }
  }
  public func active(now: TimeInterval) -> [LiveSuperChat] {
    values.values.filter { Double($0.endTime) > now }.sorted { $0.id < $1.id }
  }
  public func contains(_ id: String) -> Bool { values[id] != nil && !deleted.contains(id) }
}

/// Receipt validators must be backed by captured route-specific business evidence.
/// No production gift/activity validator has been verified yet.
public struct LiveReceiptPolicy: Sendable {
  private let verify: @Sendable (LiveRoute, LiveEnvelope, LiveGiftQuote?) -> Bool
  private let verifyActivity: @Sendable (LiveRoute, LiveEnvelope, LiveActivityConfirmation) -> Bool
  public init(
    verify: @escaping @Sendable (LiveRoute, LiveEnvelope, LiveGiftQuote?) -> Bool = { _, _, _ in
      false
    },
    verifyActivity:
      @escaping @Sendable (LiveRoute, LiveEnvelope, LiveActivityConfirmation) -> Bool = { _, _, _ in
        false
      }
  ) {
    self.verify = verify
    self.verifyActivity = verifyActivity
  }
  public func acceptsActivity(
    _ route: LiveRoute, _ envelope: LiveEnvelope, ticket: LiveActivityConfirmation
  ) -> Bool {
    envelope.code == 0 && verifyActivity(route, envelope, ticket)
  }
  public func accepts(_ route: LiveRoute, _ envelope: LiveEnvelope, quote: LiveGiftQuote? = nil)
    -> Bool
  {
    envelope.code == 0 && verify(route, envelope, quote)
  }
}

/// Shared by every window; policy reads at confirmation/handoff are synchronous.
public final class LiveGiftPolicySource: Sendable {
  public struct Snapshot: Sendable {
    public let policy: LiveGiftPolicy
    public let revision: UInt64
  }
  private let storage: Mutex<Snapshot>
  public init(_ policy: LiveGiftPolicy = LiveGiftPolicy()) {
    storage = Mutex(Snapshot(policy: policy, revision: 0))
  }
  public var snapshot: Snapshot { storage.withLock { $0 } }
  public func update(_ policy: LiveGiftPolicy) {
    storage.withLock { current in
      if current.policy != policy {
        current = Snapshot(policy: policy, revision: current.revision &+ 1)
      }
    }
  }
}

/// MainActor owners can retire a binding immediately, before an actor shutdown task runs.
public final class LiveInteractionLifetime: Sendable {
  private struct State {
    var context: LiveInteractionContext?
    var revision: UInt64 = 0
  }
  private let state = Mutex(State())
  public init() {}
  public var revision: UInt64 { state.withLock { $0.revision } }
  @discardableResult public func retire() -> UInt64 {
    state.withLock {
      $0.context = nil
      $0.revision &+= 1
      return $0.revision
    }
  }
  func activate(_ context: LiveInteractionContext, revision: UInt64) -> Bool {
    state.withLock {
      guard $0.revision == revision else { return false }
      $0.context = context
      $0.revision &+= 1
      return true
    }
  }
  public func matches(_ context: LiveInteractionContext) -> Bool {
    state.withLock { $0.context == context }
  }
}
