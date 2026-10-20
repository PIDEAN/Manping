import Foundation

public actor LiveInteractionSession {
  public typealias Send = @Sendable () async throws -> LiveEnvelope
  public typealias Prepare =
    @Sendable (LiveRoute, [String: String], LiveInteractionContext) async throws -> Send
  public typealias Sleep = @Sendable (Duration) async throws -> Void
  private struct Operation {
    let id: UUID
    let context: LiveInteractionContext
    let task: Task<LiveEnvelope, Error>
    var handedOff = false
    let gift: LiveGiftConfirmation?
  }
  public private(set) var context: LiveInteractionContext?
  public private(set) var draft = LiveDanmakuDraft()
  public private(set) var danmakuColor: UInt32 = 0xffffff
  public private(set) var danmakuMode = 1
  public private(set) var giftState: LiveGiftState = .idle
  public private(set) var pausedUntil: TimeInterval?
  public private(set) var lastLikeFailure: String?
  public private(set) var superChats = LiveSuperChatStore()
  public private(set) var moderation = LiveModerationState()
  private let prepare: Prepare
  private let identityCurrent: @Sendable (LiveInteractionContext) async -> Bool
  private let follow: @Sendable (LiveInteractionContext, Bool) async throws -> Void
  private let now: @Sendable () -> TimeInterval
  private let sleep: Sleep
  private let receipts: LiveReceiptPolicy
  private let limiter: LiveAccountLimiter
  private let pending: LivePendingGiftStore
  private let riskPause: TimeInterval
  public nonisolated let lifetime: LiveInteractionLifetime
  private let policySource: LiveGiftPolicySource
  private var policy: LiveGiftPolicy { policySource.snapshot.policy }
  private var quotePolicyRevision: UInt64?
  private var operations: [LiveAction: Operation] = [:]
  private var reads: [UUID: Task<LiveEnvelope, Error>] = [:]
  private var followingTask: Task<Void, Error>?
  private var followingID: UUID?
  private var quote: LiveGiftQuote?
  private var quoteVersion: UInt64 = 0
  private var issuedQuote: UUID?
  private var confirmation: LiveGiftConfirmation?
  private var activities: [UUID: LiveActivityConfirmation] = [:]
  private var likeTimer: Task<Void, Never>?
  private var likeTimerID: UUID?
  private var likes: Int64 = 0

  public init(
    prepare: @escaping Prepare,
    identityCurrent: @escaping @Sendable (LiveInteractionContext) async -> Bool = { _ in true },
    follow: @escaping @Sendable (LiveInteractionContext, Bool) async throws -> Void = { _, _ in
      throw LiveInteractionError.needsAppLogin
    },
    policy: LiveGiftPolicy = LiveGiftPolicy(), policySource: LiveGiftPolicySource? = nil,
    lifetime: LiveInteractionLifetime = LiveInteractionLifetime(),
    receipts: LiveReceiptPolicy = LiveReceiptPolicy(),
    limiter: LiveAccountLimiter = .shared, pending: LivePendingGiftStore = .shared,
    now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, riskPause: TimeInterval = 60
  ) {
    self.prepare = prepare
    self.identityCurrent = identityCurrent
    self.follow = follow
    self.policySource = policySource ?? LiveGiftPolicySource(policy)
    self.lifetime = lifetime
    self.receipts = receipts
    self.limiter = limiter
    self.pending = pending
    self.now = now
    self.sleep = sleep
    self.riskPause = max(1, riskPause)
  }
  public init(
    service: BiliService, gate: LiveMutationGate = LiveMutationGate(),
    policy: LiveGiftPolicy = LiveGiftPolicy(), policySource: LiveGiftPolicySource? = nil,
    receipts: LiveReceiptPolicy = LiveReceiptPolicy()
  ) {
    let source = policySource ?? LiveGiftPolicySource(policy)
    let lifetime = LiveInteractionLifetime()
    self.init(
      prepare: { route, fields, context in
        let request = try await service.prepareLiveRequest(
          route, fields: fields, expectedIdentity: context.identity, gate: gate)
        let policyRevision = source.snapshot.revision
        return {
          try await service.executeLiveRequest(
            request,
            beforeSend: {
              guard lifetime.matches(context) else { throw LiveInteractionError.staleContext }
              if route == .sendGold {
                let current = source.snapshot
                guard current.policy.allowPaid else { throw LiveInteractionError.paidGiftsDisabled }
                guard current.revision == policyRevision else {
                  throw LiveInteractionError.invalidConfirmation
                }
              }
            })
        }
      },
      identityCurrent: { context in
        let latest = await service.authSnapshot()
        guard latest.epoch == context.identity.epoch,
          latest.identityRevision == context.identity.identityRevision
        else { return false }
        let mid = await service.accountMid()
        let after = await service.authSnapshot()
        return mid == context.accountMid && latest.epoch == after.epoch
          && latest.identityRevision == after.identityRevision
      },
      follow: { context, following in
        try await service.setFollowing(
          mid: context.anchorID, following: following, expectedIdentity: context.identity,
          beforeSend: {
            guard lifetime.matches(context) else { throw LiveInteractionError.staleContext }
          })
      }, policy: policy, policySource: source, lifetime: lifetime, receipts: receipts)
  }

  public func bind(_ next: LiveInteractionContext, lifetimeRevision: UInt64? = nil) {
    let revision = lifetimeRevision ?? lifetime.revision
    guard revision == lifetime.revision else { return }
    if context == next, lifetime.matches(next) { return }
    guard lifetime.activate(next, revision: revision) else { return }
    invalidate()
    context = next
  }
  public func shutdown(lifetimeRevision: UInt64? = nil) {
    if let lifetimeRevision, lifetimeRevision != lifetime.revision { return }
    lifetime.retire()
    invalidate()
    context = nil
  }
  private func invalidate() {
    for operation in operations.values {
      operation.task.cancel()
      if operation.handedOff, let gift = operation.gift { pending.markUnknown(gift) }
    }
    for task in reads.values { task.cancel() }
    reads = [:]
    followingTask?.cancel()
    followingTask = nil
    followingID = nil
    operations = [:]
    likeTimer?.cancel()
    likeTimer = nil
    likeTimerID = nil
    likes = 0
    quote = nil
    confirmation = nil
    issuedQuote = nil
    activities = [:]
    draft = LiveDanmakuDraft()
    danmakuColor = 0xffffff
    danmakuMode = 1
    superChats = LiveSuperChatStore()
    moderation.reset()
    giftState = .idle
    // Risk pauses survive a room/account rebind; reconnecting is not a way around a pause.
  }
  public func updatePolicy(_ next: LiveGiftPolicy) {
    guard next != policy else { return }
    policySource.update(next)
    quote = nil
    confirmation = nil
    issuedQuote = nil
  }
  public func updateDraft(_ next: LiveDanmakuDraft, expected: LiveInteractionContext) throws {
    try check(expected)
    draft = next
  }
  private func check(_ expected: LiveInteractionContext, requiresLogin: Bool = true) throws {
    try Task.checkCancellation()
    guard context == expected, lifetime.matches(expected), expected.roomID > 0,
      expected.anchorID > 0
    else {
      throw LiveInteractionError.staleContext
    }
    if requiresLogin, expected.identity.state == .needsLogin || expected.accountMid == nil {
      throw LiveInteractionError.needsLogin
    }
    if let until = pausedUntil, now() < until { throw LiveInteractionError.paused(until: until) }
  }
  private func checkIdentity(_ expected: LiveInteractionContext, requiresLogin: Bool = true)
    async throws
  {
    try check(expected, requiresLogin: requiresLogin)
    let current = await identityCurrent(expected)
    try check(expected, requiresLogin: requiresLogin)
    guard current else { throw LiveInteractionError.staleContext }
  }
  private func risk(_ error: Error) {
    if case BiliError.api(-352, _) = error { pausedUntil = now() + riskPause }
    if case BiliError.http(let code) = error, [412, 429].contains(code) {
      pausedUntil = now() + riskPause
    }
  }
  public func isBusy(_ action: LiveAction) -> Bool { operations[action] != nil }

  /// Each action reserves its slot before the first suspension. The slot UUID prevents a
  /// retiring task from clearing a replacement generation's operation.
  private func perform(
    _ action: LiveAction, route: LiveRoute, fields: [String: String],
    expected: LiveInteractionContext,
    gift: LiveGiftConfirmation? = nil, content: String? = nil, activityDeadline: TimeInterval? = nil
  ) async throws -> LiveEnvelope {
    try check(expected)
    guard operations[action] == nil else { throw LiveInteractionError.busy }
    let id = UUID()
    let task = Task { [prepare] in
      try await self.checkIdentity(expected)
      let send = try await prepare(route, fields, expected)
      try await self.checkIdentity(expected)
      if let activityDeadline, self.now() >= activityDeadline {
        throw LiveInteractionError.invalidActivity
      }
      try self.handoff(action, id: id, expected: expected, gift: gift, content: content)
      return try await send()
    }
    operations[action] = Operation(id: id, context: expected, task: task, gift: gift)
    defer { finish(action, expected: expected, id: id) }
    return try await withTaskCancellationHandler {
      do {
        let envelope = try await task.value
        // Even a cancellation-ignoring transport cannot turn a retired operation into success.
        try check(expected)
        guard operations[action]?.id == id else { throw LiveInteractionError.staleContext }
        try await checkIdentity(expected)
        guard operations[action]?.id == id else { throw LiveInteractionError.staleContext }
        if envelope.code != 0 { throw BiliError.api(envelope.code, envelope.message) }
        if let gift {
          guard receipts.accepts(route, envelope, quote: gift.quote) else {
            throw LiveInteractionError.unverifiedReceipt
          }
          guard giftState == .sending(gift.nonce) else { throw LiveInteractionError.staleContext }
          pending.resolve(gift.nonce)
          giftState = .succeeded(gift.nonce)
        }
        return envelope
      } catch {
        if context == expected, operations[action]?.id == id {
          risk(error)
          if let gift {
            if confirmation?.nonce == gift.nonce { confirmation = nil }
            if operations[action]?.handedOff == true {
              if case BiliError.api(let code, let message) = error, code != 0 {
                pending.resolve(gift.nonce)
                giftState = .rejected(
                  gift.nonce, LiveDanmakuFailure.message(code: code, message: message))
              } else {
                pending.markUnknown(gift)
                giftState = .unknown(gift.nonce)
              }
            }
          }
        }
        throw error
      }
    } onCancel: {
      task.cancel()
      Task { await self.cancel(action, id: id) }
    }
  }
  private func handoff(
    _ action: LiveAction, id: UUID, expected: LiveInteractionContext,
    gift: LiveGiftConfirmation?, content: String?
  ) throws {
    try check(expected)
    guard operations[action]?.id == id else { throw LiveInteractionError.staleContext }
    if action == .danmaku, moderation.message(now: now()) != nil {
      throw LiveInteractionError.muted
    }
    if let gift {
      try validate(gift, expected: expected)
      confirmation = nil  // Consumption is synchronous, before handing the request to transport.
      pending.begin(gift)
      giftState = .sending(gift.nonce)
    }
    if let content, let mid = expected.accountMid {
      try limiter.reserve(account: mid, content: content, now: now())
    }
    operations[action]?.handedOff = true
  }
  private func cancel(_ action: LiveAction, id: UUID) {
    guard let operation = operations[action], operation.id == id else { return }
    operation.task.cancel()
    if let gift = operation.gift {
      if confirmation?.nonce == gift.nonce { confirmation = nil }
      if operation.handedOff {
        pending.markUnknown(gift)
        giftState = .unknown(gift.nonce)
      }
    }
    operations[action] = nil
  }
  private func finish(_ action: LiveAction, expected: LiveInteractionContext, id: UUID?) {
    guard context == expected, operations[action]?.id == id else { return }
    operations[action] = nil
  }

  public func sendDanmaku(
    expected: LiveInteractionContext, limit: Int? = nil,
    algorithm: LiveLengthAlgorithm = .character
  ) async throws {
    try check(expected)
    guard moderation.message(now: now()) == nil else { throw LiveInteractionError.muted }
    let captured = draft
    let message = captured.emoticon ?? captured.text
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LiveInteractionError.emptyDraft
    }
    if let limit, captured.emoticon == nil, algorithm.count(message) > limit {
      throw LiveInteractionError.tooLong
    }
    var fields = [
      "msg": message, "roomid": String(expected.roomID), "rnd": String(Int64(now())),
      "color": String(danmakuColor), "mode": String(danmakuMode),
    ]
    if captured.emoticon != nil {
      fields["dm_type"] = "1"
      fields["emoticonOptions"] = "[object Object]"
    } else if let reply = captured.reply {
      fields["reply_mid"] = String(reply.mid)
      fields["reply_uname"] = reply.name
      fields["replay_dmid"] = reply.messageID
      fields["reply_type"] = "1"
      fields["reply_attr"] = "0"
    }
    do {
      let envelope = try await perform(
        .danmaku, route: .sendDanmaku, fields: fields, expected: expected, content: message)
      guard envelope.message.isEmpty else { throw BiliError.api(0, envelope.message) }
      if draft == captured { draft = LiveDanmakuDraft() }
    } catch { throw error }
  }
  public func setStyle(color: UInt32? = nil, mode: Int? = nil, expected: LiveInteractionContext)
    async throws
  {
    guard (color == nil) != (mode == nil) else { throw LiveRouteError.invalidFields(.setDMConfig) }
    var fields = ["room_id": String(expected.roomID)]
    if let color { fields["color"] = String(format: "0x%06X", color) }
    if let mode { fields["mode"] = String(mode) }
    try await simple(.style, route: .setDMConfig, fields: fields, expected: expected)
    try check(expected)
    if let color { danmakuColor = color }
    if let mode { danmakuMode = mode }
  }
  public func wearMedal(_ id: Int64?, expected: LiveInteractionContext) async throws {
    if let id, id <= 0 { throw LiveRouteError.invalidFields(.wearMedal) }
    try await simple(
      .medal, route: id == nil ? .takeOffMedal : .wearMedal,
      fields: id.map { ["medal_id": String($0), "target_id": String(expected.anchorID)] } ?? [:], expected: expected)
  }
  private func simple(
    _ action: LiveAction, route: LiveRoute, fields: [String: String],
    expected: LiveInteractionContext
  ) async throws {
    do {
      _ = try await perform(action, route: route, fields: fields, expected: expected)
    } catch { throw error }
  }
  public func like(expected: LiveInteractionContext) throws {
    try check(expected)
    guard operations[.like] == nil else { throw LiveInteractionError.busy }
    let addition = likes.addingReportingOverflow(1)
    guard !addition.overflow else { throw LiveInteractionError.overflow }
    likes = addition.partialValue
    likeTimer?.cancel()
    let id = UUID()
    likeTimerID = id
    likeTimer = Task { [sleep] in
      do {
        try await sleep(.milliseconds(800))
        try Task.checkCancellation()
      } catch { return }
      await self.flushLikes(id: id, expected: expected)
    }
  }
  private func flushLikes(id: UUID, expected: LiveInteractionContext) async {
    guard likeTimerID == id, context == expected else { return }
    let count = likes
    likes = 0
    likeTimer = nil
    likeTimerID = nil
    do {
      try await simple(
        .like, route: .like,
        fields: [
          "click_time": String(count), "room_id": String(expected.roomID),
          "uid": String(expected.accountMid ?? 0), "anchor_id": String(expected.anchorID),
        ], expected: expected)
      if context == expected { lastLikeFailure = nil }
    } catch {
      if context == expected {
        if case LiveRouteError.mutationClosed = error {
          lastLikeFailure = "点赞暂未开放，请在浏览器中打开直播间"
        } else if case BiliError.api(let code, let message) = error {
          lastLikeFailure = LiveDanmakuFailure.message(code: code, message: message)
        } else {
          lastLikeFailure = error.localizedDescription
        }
      }
    }
  }

  public func makeQuote(
    gift: LiveGift, quantity: Int64, bag: LiveBagItem? = nil,
    expected: LiveInteractionContext, lifetime: TimeInterval = 60
  ) throws -> LiveGiftQuote {
    try check(expected)
    let policySnapshot = policySource.snapshot
    let policy = policySnapshot.policy
    // Any new selection invalidates the previous sheet, even if the new selection is invalid.
    quote = nil
    confirmation = nil
    issuedQuote = nil
    guard quantity > 0, lifetime > 0, lifetime.isFinite else {
      throw LiveInteractionError.unsupportedGift
    }
    let price: Int64
    let coin: String
    if let bag {
      guard bag.giftID == gift.id, bag.bagID > 0, bag.count >= quantity,
        bag.expiresAt.map({ Double($0) > now() }) ?? true
      else { throw LiveInteractionError.insufficientBag }
      price = 0
      coin = "bag"
    } else {
      guard policy.allowPaid else { throw LiveInteractionError.paidGiftsDisabled }
      guard gift.coinType == "gold", gift.price > 0, policy.fixedGoldPrices[gift.id] == gift.price,
        gift.raw["blind_gift"] == .null || gift.raw["blind_gift"] == .integer(0),
        gift.raw["discount_price"] == .null || gift.raw["discount_price"].int64 == gift.price,
        gift.raw["gift_type"] == .null || gift.raw["gift_type"].int64 == 0
      else { throw LiveInteractionError.unsupportedGift }
      price = gift.price
      coin = "gold"
    }
    let total = price.multipliedReportingOverflow(by: quantity)
    guard !total.overflow else { throw LiveInteractionError.overflow }
    quoteVersion &+= 1
    let value = LiveGiftQuote(
      version: quoteVersion, context: expected, giftID: gift.id, bagID: bag?.bagID,
      quantity: quantity, coin: coin, unitPrice: price, total: total.partialValue,
      expiresAt: now() + min(lifetime, 60))
    quote = value
    quotePolicyRevision = policySnapshot.revision
    return value
  }
  public func invalidateGiftQuote(_ id: UUID, expected: LiveInteractionContext) {
    guard context == expected, quote?.id == id else { return }
    quote = nil
    confirmation = nil
    issuedQuote = nil
  }
  public func confirmGift(
    _ value: LiveGiftQuote, extraConfirmed: Bool = false,
    expected: LiveInteractionContext
  ) throws -> LiveGiftConfirmation {
    try check(expected)
    if value.bagID == nil, !policy.allowPaid { throw LiveInteractionError.paidGiftsDisabled }
    guard value.context == expected, quote == value, issuedQuote != value.id,
      quotePolicyRevision == policySource.snapshot.revision
    else {
      throw LiveInteractionError.invalidConfirmation
    }
    guard now() < value.expiresAt else { throw LiveInteractionError.expiredQuote }
    if value.total > policy.extraConfirmationThreshold, !extraConfirmed {
      throw LiveInteractionError.extraConfirmationRequired
    }
    let ticket = LiveGiftConfirmation(
      quote: value, expiresAt: min(value.expiresAt, now() + 60), extraConfirmed: extraConfirmed)
    issuedQuote = value.id
    confirmation = ticket
    return ticket
  }
  private func validate(_ ticket: LiveGiftConfirmation, expected: LiveInteractionContext) throws {
    if ticket.quote.bagID == nil, !policy.allowPaid { throw LiveInteractionError.paidGiftsDisabled }
    guard ticket.quote.context == expected, quote == ticket.quote,
      quotePolicyRevision == policySource.snapshot.revision,
      confirmation?.nonce == ticket.nonce
    else {
      throw LiveInteractionError.invalidConfirmation
    }
    guard now() < ticket.expiresAt, now() < ticket.quote.expiresAt else {
      throw LiveInteractionError.expiredQuote
    }
  }
  public func sendGift(_ ticket: LiveGiftConfirmation, expected: LiveInteractionContext)
    async throws
  {
    try check(expected)
    try validate(ticket, expected: expected)
    let q = ticket.quote
    let route: LiveRoute = q.bagID == nil ? .sendGold : .sendBag
    var fields = [
      "uid": String(expected.accountMid ?? 0), "gift_id": String(q.giftID),
      "ruid": String(expected.anchorID),
      "gift_num": String(q.quantity), "biz_id": String(expected.roomID),
    ]
    if let bag = q.bagID {
      fields["bag_id"] = String(bag)
    } else {
      fields["price"] = String(q.unitPrice)
      fields["coin_type"] = q.coin
    }
    _ = try await perform(.gift, route: route, fields: fields, expected: expected, gift: ticket)
  }
  public func pendingGifts() -> [LiveGiftConfirmation] { pending.pending }
  public func acknowledgeGiftChecked(_ nonce: UUID) { pending.acknowledgeChecked(nonce) }

  public func confirmActivity(_ activity: LiveActivity, expected: LiveInteractionContext) throws
    -> LiveActivityConfirmation
  {
    try check(expected)
    guard activity.isFree == true, activity.conditionsKnown, activity.automaticallyFollows != nil,
      activity.automaticDanmaku != nil
    else { throw LiveInteractionError.unknownConditions }
    guard activity.id > 0, activity.deadline > now() else {
      throw LiveInteractionError.invalidActivity
    }
    let value = LiveActivityConfirmation(activity: activity, context: expected)
    activities[value.nonce] = value
    return value
  }
  public func joinActivity(_ ticket: LiveActivityConfirmation, expected: LiveInteractionContext)
    async throws
  {
    try check(expected)
    guard ticket.context == expected, activities[ticket.nonce] != nil,
      ticket.activity.deadline > now()
    else {
      throw LiveInteractionError.invalidActivity
    }
    guard operations[.lottery] == nil else { throw LiveInteractionError.busy }
    activities[ticket.nonce] = nil
    let route: LiveRoute = ticket.activity.kind == .lottery ? .joinLottery : .drawRedPocket
    let fields =
      route == .joinLottery
      ? ["room_id": String(expected.roomID), "id": String(ticket.activity.id)]
      : [
        "uid": String(expected.accountMid ?? 0), "room_id": String(expected.roomID),
        "ruid": String(expected.anchorID),
        "lot_id": String(ticket.activity.id), "ts": String(Int64(now())),
      ]
    do {
      let result = try await perform(
        .lottery, route: route, fields: fields, expected: expected,
        activityDeadline: ticket.activity.deadline)
      guard now() < ticket.activity.deadline,
        receipts.acceptsActivity(route, result, ticket: ticket)
      else { throw LiveInteractionError.unverifiedReceipt }
    } catch { throw error }
  }
  public func setFollowing(_ value: Bool, expected: LiveInteractionContext) async throws {
    try check(expected)
    guard expected.identity.state == .appAuthorized else {
      throw LiveInteractionError.needsAppLogin
    }
    guard followingTask == nil else { throw LiveInteractionError.busy }
    let id = UUID()
    let task = Task {
      try await self.checkIdentity(expected)
      try await self.follow(expected, value)
      try await self.checkIdentity(expected)
    }
    followingID = id
    followingTask = task
    defer {
      if followingID == id {
        followingTask = nil
        followingID = nil
      }
    }
    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard followingID == id else { throw LiveInteractionError.staleContext }
      try await checkIdentity(expected)
      guard followingID == id else { throw LiveInteractionError.staleContext }
    } catch {
      if context == expected { risk(error) }
      throw error
    }
  }
  public func mergeSuperChats(_ messages: [LiveSuperChat], expected: LiveInteractionContext) throws
  {
    guard context == expected, lifetime.matches(expected), !Task.isCancelled else {
      throw LiveInteractionError.staleContext
    }
    superChats.merge(messages)
  }
  public func receive(_ events: [LiveChatEvent], expected: LiveInteractionContext) throws {
    guard context == expected, lifetime.matches(expected), !Task.isCancelled else {
      throw LiveInteractionError.staleContext
    }
    for event in events {
      switch event {
      case .superChat(let message): superChats.merge([message])
      case .superChatDeleted(let ids): superChats.delete(ids)
      case .moderation(let notice): moderation.receive(notice, accountMid: expected.accountMid)
      default: break
      }
    }
  }
  public func read(_ route: LiveRoute, fields: [String: String], expected: LiveInteractionContext)
    async throws -> LiveEnvelope
  {
    guard !route.isMutation else { throw LiveRouteError.invalidFields(route) }
    let roomKey: String? =
      route == .medalPanel
      ? nil : route == .lotteryInfo ? "roomid" : route == .danmuInfo ? "id" : "room_id"
    if let roomKey, fields[roomKey] != String(expected.roomID) {
      throw LiveRouteError.invalidFields(route)
    }
    // Anonymous reads are cancellable and retain the same room/identity boundary.
    try check(expected, requiresLogin: false)
    let moderationRevision = moderation.revision
    let id = UUID()
    let task = Task { [prepare] in
      let current = await self.identityCurrent(expected)
      try self.check(expected, requiresLogin: false)
      guard current else { throw LiveInteractionError.staleContext }
      let send = try await prepare(route, fields, expected)
      try self.check(expected, requiresLogin: false)
      guard await self.identityCurrent(expected) else { throw LiveInteractionError.staleContext }
      try self.check(expected, requiresLogin: false)
      let response = try await send()
      try self.check(expected, requiresLogin: false)
      guard await self.identityCurrent(expected) else { throw LiveInteractionError.staleContext }
      try self.check(expected, requiresLogin: false)
      if response.code != 0 { throw BiliError.api(response.code, response.message) }
      return response
    }
    reads[id] = task
    defer { reads[id] = nil }
    do {
      let response = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard reads[id] != nil else { throw LiveInteractionError.staleContext }
      try await checkIdentity(expected, requiresLogin: false)
      guard reads[id] != nil else { throw LiveInteractionError.staleContext }
      if route == .infoByUser {
        moderation.mergeUser(response.data, expectedRevision: moderationRevision)
      }
      return response
    } catch {
      if context == expected { risk(error) }
      throw error
    }
  }
}
