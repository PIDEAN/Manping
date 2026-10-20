import Foundation

/// Display conversion never participates in pricing or receipt verification.
public enum LiveMoney {
  public static func batteries(_ seeds: Int64) -> String { decimal(seeds, divisor: 100, places: 2) }
  public static func yuan(_ seeds: Int64) -> String { decimal(seeds, divisor: 1000, places: 3) }
  private static func decimal(_ value: Int64, divisor: UInt64, places: Int) -> String {
    let magnitude = value.magnitude
    let whole = magnitude / divisor
    let remainder = magnitude % divisor
    var fraction = String(remainder)
    fraction = String(repeating: "0", count: max(0, places - fraction.count)) + fraction
    while fraction.last == "0" { fraction.removeLast() }
    return (value < 0 ? "-" : "") + String(whole) + (fraction.isEmpty ? "" : "." + fraction)
  }
  public static func total(price: Int64, quantity: Int64) -> Int64? {
    guard price >= 0, quantity > 0 else { return nil }
    let product = price.multipliedReportingOverflow(by: quantity)
    return product.overflow ? nil : product.partialValue
  }
  public static func remaining(balance: Int64?, total: Int64) -> Int64? {
    guard let balance, balance >= 0, total >= 0 else { return nil }
    let difference = balance.subtractingReportingOverflow(total)
    return difference.overflow ? nil : difference.partialValue
  }
}

public struct LiveEffect: Identifiable, Sendable, Equatable {
  public enum Kind: Sendable { case gift, guardPurchase, superChat }
  public let id: UUID
  public let kind: Kind
  public let title: String
  public let detail: String
  public let user: String?
  public let giftName: String?
  public let giftID: Int64?
  public let avatarURL: URL?
  public let imageURL: URL?
  public let count: Int64?
  public let price: Int?
  /// The server's id of what the effect shows (a super chat), so a deletion can withdraw it.
  public let sourceID: String?
  public init(
    kind: Kind, title: String, detail: String, user: String? = nil, giftName: String? = nil,
    giftID: Int64? = nil, avatarURL: URL? = nil, imageURL: URL? = nil, count: Int64? = nil,
    price: Int? = nil, sourceID: String? = nil
  ) {
    id = UUID()
    self.sourceID = sourceID
    self.kind = kind
    self.title = title
    self.detail = detail
    self.user = user
    self.giftName = giftName
    self.giftID = giftID
    self.avatarURL = LiveGift.imageURL(avatarURL?.absoluteString)
    self.imageURL = LiveGift.imageURL(imageURL?.absoluteString)
    self.count = count
    self.price = price
  }
}

/// Admission is gated, not just rendering. Disabling a category purges its active and queued items.
public struct LiveEffectQueue: Sendable {
  public private(set) var active: LiveEffect?
  public private(set) var pending: [LiveEffect] = []
  public let capacity: Int
  /// Super chats deleted by the server, newest last; a late broadcast of one is not shown.
  private var withdrawn: [String] = []
  public init(capacity: Int = 6) { self.capacity = max(1, capacity) }
  /// A deleted super chat leaves the screen and the queue, and is refused if it arrives later.
  public mutating func withdraw(_ sourceIDs: [String]) {
    let ids = Set(sourceIDs)
    guard !ids.isEmpty else { return }
    withdrawn = Array((withdrawn.filter { !ids.contains($0) } + sourceIDs).suffix(200))
    pending.removeAll { $0.sourceID.map(ids.contains) ?? false }
    if let current = active, let source = current.sourceID, ids.contains(source) { advance() }
  }
  private func permits(_ effect: LiveEffect, _ flags: LiveEffectiveSettings) -> Bool {
    switch effect.kind {
    case .gift: flags.giftEffects
    case .guardPurchase: flags.guardEffects
    case .superChat: flags.superChatEffects
    }
  }
  public mutating func update(_ flags: LiveEffectiveSettings) {
    pending = pending.filter { permits($0, flags) }
    if let current = active, !permits(current, flags) { active = nil }
    if active == nil, !pending.isEmpty { active = pending.removeFirst() }
  }
  public mutating func enqueue(_ effect: LiveEffect, flags: LiveEffectiveSettings) {
    update(flags)
    guard permits(effect, flags), !(effect.sourceID.map(withdrawn.contains) ?? false) else { return }
    if active == nil {
      active = effect
      return
    }
    guard capacity > 1 else { return }
    if pending.count >= capacity - 1 { pending.removeFirst() }
    pending.append(effect)
  }
  public mutating func advance() { active = pending.isEmpty ? nil : pending.removeFirst() }
  public mutating func reset() {
    active = nil
    pending = []
    withdrawn = []
  }
}

public enum LiveConfirmationKeyboardPolicy {
  public static func suppress(keyCode: UInt16, inConfirmationWindow: Bool) -> Bool {
    inConfirmationWindow && (keyCode == 36 || keyCode == 76)
  }
}

public enum LiveGiftResultCard: Sendable, Equatable {
  case sending, sent
  case rejected(String)
  case unknown, closed
}

/// A prior transaction's persistent state cannot describe a new confirmation attempt.
public enum LiveGiftPresentationPolicy {
  public static func result(_ state: LiveGiftState, matching nonce: UUID) -> LiveGiftResultCard? {
    guard state.transactionNonce == nonce else { return nil }
    switch state {
    case .idle: return nil
    case .sending: return .sending
    case .succeeded: return .sent
    case .rejected(_, let message): return .rejected(message)
    case .unknown: return .unknown
    }
  }
  public static func failure(
    ticketNonce: UUID?, state: LiveGiftState, message: String, closed: Bool
  ) -> LiveGiftResultCard {
    if let ticketNonce, let owned = result(state, matching: ticketNonce) { return owned }
    return closed ? .closed : .rejected(message)
  }
}

extension LiveGiftState {
  public var transactionNonce: UUID? {
    switch self {
    case .idle: nil
    case .sending(let nonce), .succeeded(let nonce), .rejected(let nonce, _), .unknown(let nonce):
      nonce
    }
  }
}

/// Initial metadata and socket-triggered refreshes share one latest-request snapshot.
public struct LiveActivitySnapshot: Sendable {
  public private(set) var revision: UInt64 = 0
  public private(set) var value: LiveJSON = .null
  public init() {}
  @discardableResult public mutating func begin() -> UInt64 {
    revision &+= 1
    return revision
  }
  public mutating func invalidate() { revision &+= 1 }
  public func isCurrent(_ request: UInt64) -> Bool { request == revision }
  @discardableResult public mutating func apply(_ data: LiveJSON, request: UInt64) -> Bool {
    guard isCurrent(request) else { return false }
    value = data
    return true
  }
}

public struct LiveGiftClickGate: Sendable {
  private var last: TimeInterval?
  public init() {}
  public mutating func reserve(now: TimeInterval) -> Bool {
    guard now.isFinite, last.map({ now - $0 >= 2 }) ?? true else { return false }
    last = now
    return true
  }
}

/// Missing moderation fields do not invent a mute. Server notices apply only to their bound account.
public struct LiveModerationState: Sendable, Equatable {
  public struct Revision: Sendable, Equatable {
    public let user: UInt64
    public let room: UInt64
  }
  private var userRevision: UInt64 = 0
  private var roomRevision: UInt64 = 0
  public var revision: Revision { Revision(user: userRevision, room: roomRevision) }
  public private(set) var allMuted = false
  public private(set) var userMuted = false
  public private(set) var userUntil: Int64?
  public init() {}
  public mutating func reset() {
    userRevision &+= 1
    roomRevision &+= 1
    allMuted = false
    userMuted = false
    userUntil = nil
  }
  public mutating func mergeUser(_ data: LiveJSON, expectedRevision: Revision? = nil) {
    let shield = data["shield_info"]
    if shield["is_block"] != .null,
      expectedRevision.map({ $0.user == userRevision }) ?? true
    {
      userRevision &+= 1
      userMuted = shield["is_block"] == .bool(true) || shield["is_block"].int64 == 1
      userUntil = shield["block_expired"].int64
    }
    if data["room_silent"]["type"] != .null,
      expectedRevision.map({ $0.room == roomRevision }) ?? true
    {
      roomRevision &+= 1
      allMuted = data["room_silent"]["type"].string == "all"
    }
  }
  public mutating func receive(_ notice: LiveNoticeEvent, accountMid: Int64?) {
    switch notice.command {
    case "ROOM_SILENT_OFF":
      roomRevision &+= 1
      allMuted = false
    case "ROOM_SILENT_ON":
      roomRevision &+= 1
      allMuted = notice.data["type"].string == "all"
    case "ROOM_BLOCK_MSG":
      if let accountMid, notice.data["uid"].int64 == accountMid {
        userRevision &+= 1
        userMuted = true
        userUntil = notice.data["block_expired"].int64
      }
    default: break
    }
  }
  public func message(now: TimeInterval) -> String? {
    if allMuted { return "主播开启了全员禁言" }
    guard userMuted, userUntil.map({ $0 <= 0 || Double($0) > now }) ?? true else { return nil }
    return "你在本房间被禁言"
  }
}

public enum LiveEffectMotion {
  public static func animates(reduceMotion: Bool, saving: PowerSaving) -> Bool {
    !reduceMotion && saving == .normal
  }
}

extension LiveChatLine {
  public var replyTarget: LiveDanmakuReply? {
    guard kind == .danmaku, uid > 0, let danmakuID, !danmakuID.isEmpty else { return nil }
    return LiveDanmakuReply(mid: uid, name: user, messageID: danmakuID)
  }
  public var inlineEmotes: [RPCEmote] {
    guard case .object(let entries) = emotes else { return [] }
    return entries.sorted { $0.key < $1.key }.compactMap { token, value in
      guard let url = value["url"].string,
        let data = try? JSONEncoder().encode(
          ["text": token, "image": url])
      else { return nil }
      return try? JSONDecoder().decode(RPCEmote.self, from: data)
    }
  }
}
