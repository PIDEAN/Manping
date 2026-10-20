import Combine
import Foundation
import ManpingCore

/// One presentation bridge per playback session, shared by sidebar, chrome and menu commands.
/// Core remains the owner of mutations, capabilities and transaction outcomes.
@MainActor final class LiveInteractionModel: ObservableObject {
  enum Panel: String, Identifiable {
    case gifts, emotes, style, medals
    var id: String { rawValue }
  }
  typealias ResultCard = LiveGiftResultCard
  @Published private(set) var draft = LiveDanmakuDraft()
  @Published var panel: Panel? {
    didSet {
      if let panel, panel != .medals { composeShown = false }
      if panel == nil { panelAnchor = nil }
    }
  }
  /// The button a panel was opened from, so its popover points at that button; nil (menus,
  /// scenes) presents it from the page.
  @Published private(set) var panelAnchor: String?
  func open(_ panel: Panel, from anchor: String?) {
    panelAnchor = anchor
    self.panel = panel
  }
  @Published var composeShown = false { didSet { if composeShown { panel = nil } } }
  @Published var focused = false
  @Published var detailShown = false
  var sidebarComposerVisible = true
  var anchorName = ""
  @Published var focusRequest = UUID()
  @Published private(set) var status: String?
  @Published private(set) var sending = false
  @Published private(set) var likes: Int64 = 0
  @Published private(set) var roomLikes: Int64?
  var wornMedal: LiveMedal? {
    if let current = user?.medal, let medal = LiveMedal(current) { return medal }
    guard let entry = medals.first(where: { $0["wearing_status"].int64 == 1 }) else { return nil }
    return LiveMedal(entry["medal_info"] == .null ? entry : entry["medal_info"])
  }
  @Published private(set) var gifts: [LiveGift] = []
  @Published private(set) var bag: [LiveBagItem] = []
  @Published private(set) var emotes: [LiveEmoticonPackage] = []
  @Published private(set) var medals: [LiveJSON] = []
  @Published private(set) var config = LiveDMConfig(.null)
  @Published private(set) var user: LiveUserInfo?
  @Published private(set) var superChats: [LiveSuperChat] = []
  @Published private(set) var pausedUntil: TimeInterval?
  @Published private(set) var quote: LiveGiftQuote?
  private(set) var quoteAnchorName = ""
  private(set) var quoteGiftName = ""
  @Published private(set) var appliedColor: UInt32 = 0xffffff
  @Published private(set) var appliedMode = 1
  private var hiddenActivities: Set<String> = []
  @Published private(set) var result: ResultCard?
  @Published private(set) var pending: [LiveGiftConfirmation] = []
  @Published private(set) var paidLockedNotice = false
  @Published private(set) var effects = LiveEffectQueue()
  @Published private(set) var activity: LiveActivity?
  @Published private(set) var activityTitle = ""
  @Published private(set) var activityResult: String?
  @Published private(set) var activityJoined = false
  @Published private(set) var activityHidden = false
  @Published private(set) var settings: MacSettings
  @Published var selectedGift: Int64? { didSet { invalidateQuote() } }
  @Published var selectedBag: Int64? { didSet { invalidateQuote() } }
  @Published var quantity = "1" { didSet { if oldValue != quantity { invalidateQuote() } } }
  @Published var bagTab = false { didSet { if oldValue != bagTab { invalidateQuote() } } }
  private(set) var context: LiveInteractionContext?
  let session: LiveInteractionSession
  let fixtures: Bool
  private var revision: UInt64 = 0
  private var draftTask: Task<Void, Never>?
  private var poll: Task<Void, Never>?
  private var observation: AnyCancellable?
  private let fixturePolicySource: LiveGiftPolicySource?
  private var clickGate = LiveGiftClickGate()
  private var settingsRevision: UInt64 = 0
  private var selectionRevision: UInt64 = 0
  private var lastGiftState = LiveGiftState.idle
  private var giftAttempt: UUID?
  private var giftTicketNonce: UUID?
  private var activityReads = LiveActivitySnapshot()
  @Published private(set) var moderation = LiveModerationState()
  private var sawPaidLock = false

  init(
    session: LiveInteractionSession, fixtures: Bool,
    fixturePolicySource: LiveGiftPolicySource? = nil
  ) {
    self.session = session
    self.fixtures = fixtures
    self.fixturePolicySource = fixturePolicySource
    settings = MacSettings.load(from: PerformanceEnvironment.defaults)
    observation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .sink { [weak self] _ in self?.reloadSettings() }
  }
  var pinned: Bool { detailShown || focused || composeShown || panel != nil || quote != nil }
  var canInteract: Bool { context?.accountMid != nil && context?.identity.state != .needsLogin }
  var limit: Int? { user?.danmakuLength }
  var balance: Int64? { user?.raw["wallet"]["gold"].int64.flatMap { $0 >= 0 ? $0 : nil } }
  var gift: LiveGift? { gifts.first { $0.id == selectedGift } }
  var bagItem: LiveBagItem? { bagTab ? bag.first { $0.bagID == selectedBag } : nil }
  var selectedTotal: Int64? {
    guard let gift, let count = Int64(quantity) else { return nil }
    return LiveMoney.total(price: bagTab ? 0 : gift.price, quantity: count)
  }
  var muted: String? { moderation.message(now: Date().timeIntervalSince1970) }
  var composerMessage: String? {
    if !canInteract { return "登录后发弹幕、送礼物" }
    if let muted { return muted }
    if let pausedUntil, pausedUntil > Date().timeIntervalSince1970 {
      return "操作太频繁，B 站暂时限制了发送；不会自动补发"
    }
    return status ?? (fixtures ? nil : "发弹幕暂未开放 · 在浏览器中打开直播间可以发送")
  }
  var canSend: Bool {
    canInteract && muted == nil && !sending && !(draft.text.isEmpty && draft.emoticon == nil)
  }
  private func current(_ captured: LiveInteractionContext) -> Bool {
    context == captured && session.lifetime.matches(captured) && !Task.isCancelled
  }
  func bind(_ next: LiveInteractionContext) {
    guard context != next else { return }
    retire()
    context = next
    let initialActivity = requestActivityRefresh(next)
    poll = Task { [weak self] in
      guard let self else { return }
      await self.loadMetadata(next)
      guard self.current(next) else { return }
      if self.fixtures {
        await initialActivity.value
        guard self.current(next) else { return }
      }
      self.metadataReady = true
      while self.current(next) {
        await self.sync(next)
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }
  func retire() {
    context = nil
    revision &+= 1
    draftTask?.cancel()
    poll?.cancel()
    draft = LiveDanmakuDraft()
    moderation = LiveModerationState()
    lastGiftState = .idle
    giftAttempt = nil
    giftTicketNonce = nil
    activityReads.invalidate()
    quote = nil
    panel = nil
    focused = false
    composeShown = false
    sending = false
    status = nil
    user = nil
    roomLikes = nil
    gifts = []
    bag = []
    emotes = []
    medals = []
    superChats = []
    effects.reset()
    activity = nil
    activityHidden = false
    hiddenActivities = []
    activityJoined = false
    activityResult = nil
    result = nil
    metadataReady = false
    pending = LivePendingGiftStore.shared.pending
  }
  func reloadSettings() {
    let next = MacSettings.load(from: PerformanceEnvironment.defaults)
    let changed = next.liveGiftPolicy() != settings.liveGiftPolicy()
    settings = next
    updateFixturePolicy()
    effects.update(next.liveEffective)
    if !next.liveEffective.giftMessages, panel == .gifts { panel = nil }
    if changed {
      settingsRevision &+= 1
      invalidateQuote()
    }
  }
  private func updateFixturePolicy() {
    guard fixtures else { return }
    fixturePolicySource?.update(
      settings.liveGiftPolicy(
        fixedGoldPrices: Dictionary(
          gifts.map { ($0.id, $0.price) }, uniquingKeysWith: { _, next in next })))
  }
  func setText(_ text: String) {
    var value = draft
    value.text = text
    value.emoticon = nil
    setDraft(value)
  }
  func reply(to target: LiveDanmakuReply?) {
    var value = draft
    value.reply = target
    setDraft(value)
    if target != nil { requestCompose() }
  }
  func requestCompose() {
    guard quote == nil else { return }
    composeShown = !sidebarComposerVisible
    focusRequest = UUID()
  }
  func setEmote(_ token: String) {
    var value = draft
    value.emoticon = token
    value.text = "[表情]"
    setDraft(value)
    panel = nil
  }
  private func setDraft(_ value: LiveDanmakuDraft) {
    revision &+= 1
    draft = value
    status = nil
    draftTask?.cancel()
    guard let captured = context else { return }
    let version = revision
    draftTask = Task { [weak self] in
      guard let self, self.current(captured), version == self.revision else { return }
      do { try await self.session.updateDraft(value, expected: captured) } catch {
        guard self.current(captured), version == self.revision else { return }
        self.status = Self.message(error)
      }
    }
  }
  func send() {
    guard canSend, let captured = context, current(captured) else { return }
    let version = revision
    let value = draft
    sending = true
    status = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.session.updateDraft(value, expected: captured)
        guard self.current(captured), version == self.revision else {
          self.finishDraftSend(captured)
          return
        }
        try await self.session.sendDanmaku(expected: captured, limit: self.limit)
        guard self.current(captured) else { return }
        if version == self.revision {
          let snapshot = await self.session.draft
          guard self.current(captured) else { return }
          if version == self.revision { self.draft = snapshot }
        }
      } catch {
        guard self.current(captured) else { return }
        if version == self.revision { self.status = Self.message(error) }
      }
      self.finishDraftSend(captured)
    }
  }
  private func finishDraftSend(_ captured: LiveInteractionContext) {
    if current(captured) { sending = false }
  }
  func like() {
    perform { session, captured in try await session.like(expected: captured) }
    if fixtures && canInteract { likes += 1 } else if !fixtures { status = "点赞暂未开放" }
  }
  func setStyle(color: UInt32? = nil, mode: Int? = nil) {
    perform { session, captured in
      try await session.setStyle(color: color, mode: mode, expected: captured)
    }
  }
  func wearMedal(_ id: Int64?) {
    perform { session, captured in try await session.wearMedal(id, expected: captured) }
  }
  private func perform(
    _ operation:
      @escaping @Sendable (LiveInteractionSession, LiveInteractionContext) async throws -> Void
  ) {
    guard let captured = context, current(captured) else { return }
    Task { [weak self] in
      guard let self else { return }
      do { try await operation(self.session, captured) } catch {
        guard self.current(captured) else { return }
        self.status = Self.message(error)
      }
      guard self.current(captured) else { return }
      await self.sync(captured)
    }
  }
  func select(_ gift: LiveGift, bag: LiveBagItem? = nil) {
    selectedGift = gift.id
    selectedBag = bag?.bagID
    if bag == nil && !settings.bool(.liveAllowPaidGifts) && !sawPaidLock {
      sawPaidLock = true
      paidLockedNotice = true
    }
  }
  func prepareGift() {
    guard let captured = context, current(captured), let gift, let count = Int64(quantity),
      count > 0
    else { return }
    guard !bagTab || bagItem != nil else {
      status = "请先选择背包里的礼物"
      return
    }
    if !bagTab && !settings.bool(.liveAllowPaidGifts) {
      paidLockedNotice = true
      return
    }
    guard fixtures else {
      result = .closed
      return
    }
    let selectedBag = bagItem
    let version = settingsRevision
    let selectionVersion = selectionRevision
    let selection = (selectedGift, self.selectedBag, quantity, bagTab)
    Task { [weak self] in
      guard let self else { return }
      do {
        let value = try await self.session.makeQuote(
          gift: gift, quantity: count, bag: selectedBag, expected: captured)
        guard self.current(captured), version == self.settingsRevision,
          selectionVersion == self.selectionRevision,
          selection == (self.selectedGift, self.selectedBag, self.quantity, self.bagTab),
          value.bagID != nil || self.settings.bool(.liveAllowPaidGifts)
        else {
          await self.session.invalidateGiftQuote(value.id, expected: captured)
          return
        }
        self.panel = nil
        self.quoteAnchorName = self.anchorName
        self.quoteGiftName = gift.name
        self.quote = value
      } catch {
        guard self.current(captured) else { return }
        self.status = Self.message(error)
      }
    }
  }
  func invalidateQuote() {
    let old = quote
    quote = nil
    selectionRevision &+= 1
    guard let captured = context, let old else { return }
    Task { await session.invalidateGiftQuote(old.id, expected: captured) }
  }
  func confirmGift(extraConfirmed: Bool) {
    guard let value = quote, let captured = context, current(captured), value.context == captured,
      value.bagID != nil || settings.bool(.liveAllowPaidGifts),
      clickGate.reserve(now: ProcessInfo.processInfo.systemUptime)
    else { return }
    quote = nil
    panel = nil
    result = .sending
    let attempt = value.id
    giftAttempt = attempt
    giftTicketNonce = nil
    let version = settingsRevision
    let selectionVersion = selectionRevision
    Task { [weak self] in
      guard let self else { return }
      var issuedNonce: UUID?
      do {
        let ticket = try await self.session.confirmGift(
          value, extraConfirmed: extraConfirmed, expected: captured)
        issuedNonce = ticket.nonce
        guard self.current(captured), self.giftAttempt == attempt, version == self.settingsRevision,
          selectionVersion == self.selectionRevision,
          value.bagID != nil || self.settings.bool(.liveAllowPaidGifts)
        else {
          await self.session.invalidateGiftQuote(value.id, expected: captured)
          guard self.current(captured), self.giftAttempt == attempt else { return }
          self.result = nil
          return
        }
        self.giftTicketNonce = ticket.nonce
        try await self.session.sendGift(ticket, expected: captured)
        guard self.current(captured), self.giftAttempt == attempt else { return }
      } catch {
        guard self.current(captured), self.giftAttempt == attempt else { return }
        self.status = Self.message(error)
        let state = await self.session.giftState
        guard self.current(captured), self.giftAttempt == attempt else { return }
        let closed: Bool
        if case LiveRouteError.mutationClosed = error { closed = true } else { closed = false }
        self.result = LiveGiftPresentationPolicy.failure(
          ticketNonce: issuedNonce, state: state, message: Self.message(error), closed: closed)
      }
      guard self.current(captured), self.giftAttempt == attempt else { return }
      await self.sync(captured)
    }
  }
  func acknowledge(_ nonce: UUID) {
    let captured = context
    Task { [weak self, session] in
      await session.acknowledgeGiftChecked(nonce)
      guard let self, self.context == captured, captured.map(self.current) ?? true else { return }
      self.pending = LivePendingGiftStore.shared.pending
      if self.pending.isEmpty, self.result == .unknown { self.result = nil }
    }
  }
  func dismissResult() { if result != .unknown { result = nil } }
  func enqueue(_ effect: LiveEffect) { effects.enqueue(effect, flags: settings.liveEffective) }
  func advanceEffect() { effects.advance() }
  private func activityKey(_ value: LiveActivity) -> String { "\(value.kind):\(value.id)" }
  func hideActivity() {
    if let activity { hiddenActivities.insert(activityKey(activity)) }
    activityHidden = true
  }
  func receive(_ event: LiveChatEvent) {
    switch event {
    case .gift(let value):
      enqueue(
        LiveEffect(
          kind: .gift, title: value.user + " 送出 " + value.name, detail: "×\(value.count)",
          user: value.user, giftName: value.name, giftID: value.giftID,
          avatarURL: value.raw["face"].string.flatMap(URL.init(string:)),
          imageURL: LiveGift.imageURL(in: value.raw)
            ?? gifts.first(where: { $0.id == value.giftID })?.imageURL,
          count: value.count))
    case .guardPurchase(let value):
      enqueue(
        LiveEffect(
          kind: .guardPurchase, title: value.user + " 开通大航海", detail: "×\(value.count)",
          user: value.user, giftName: guardName(value.level),
          avatarURL: value.raw["face"].string.flatMap(URL.init(string:)), count: value.count))
    case .superChat(let value):
      enqueue(
        LiveEffect(
          kind: .superChat, title: value.user + " · ¥\(value.price)", detail: value.text,
          user: value.user,
          avatarURL: value.raw["user_info"]["face"].string.flatMap(URL.init(string:)),
          price: value.price, sourceID: value.id))
    case .superChatDeleted(let ids):
      effects.withdraw(ids)
    case .like(let notice):
      if notice.command == "LIKE_INFO_V3_UPDATE", let count = notice.data["click_count"].int64,
        count >= 0
      {
        roomLikes = count
      }
    case .moderation(let notice):
      if notice.command == "ROOM_SILENT_ON" { status = "主播开启了禁言，请在官方直播间查看条件" }
      if notice.command == "ROOM_SILENT_OFF" { status = nil }
      if notice.command == "ROOM_BLOCK_MSG", notice.data["uid"].int64 == context?.accountMid {
        status = "你在本房间被禁言"
      }
    case .lottery(let notice), .redPocket(let notice):
      let kind: LiveActivity.Kind =
        notice.command.hasPrefix("POPULARITY_RED_POCKET_") ? .redPocket : .lottery
      if notice.command.hasSuffix("AWARD"), notice.data["id"].int64 == activity?.id,
        kind == activity?.kind
      {
        activityReads.invalidate()
        activityResult = "已开奖 · 请在官方直播间查看中奖名单"
      } else if let captured = context {
        requestActivityRefresh(captured)
      }
    default: break
    }
  }
  func joinActivity() {
    guard let captured = context, current(captured), let activity else { return }
    perform { [weak self] session, context in
      let ticket = try await session.confirmActivity(activity, expected: context)
      guard await self?.matchesForActivity(context, activity: activity) == true else { return }
      try await session.joinActivity(ticket, expected: context)
      await self?.didJoin(context, activity: activity)
    }
  }
  private func matchesForActivity(_ value: LiveInteractionContext, activity expected: LiveActivity)
    -> Bool
  { current(value) && activity?.id == expected.id && activity?.kind == expected.kind }
  private func didJoin(_ value: LiveInteractionContext, activity expected: LiveActivity) {
    if matchesForActivity(value, activity: expected) { activityJoined = true }
  }
  private func loadMetadata(_ captured: LiveInteractionContext) async {
    for route: LiveRoute in [
      .infoByUser, .dmConfig, .emoticons, .roomGiftList, .giftConfig, .bagList, .medalPanel,
      .superChatList,
    ] {
      guard current(captured) else { return }
      do {
        let key = route == .lotteryInfo ? "roomid" : "room_id"
        let fields = route == .medalPanel ? [:] : [key: String(captured.roomID)]
        let envelope = try await session.read(route, fields: fields, expected: captured)
        guard current(captured) else { return }
        let data = envelope.data
        switch route {
        case .infoByUser: user = LiveUserInfo(data)
        case .dmConfig: config = LiveDMConfig(data)
        case .emoticons:
          emotes = (data["data"].array ?? data["list"].array ?? []).map(LiveEmoticonPackage.init)
        case .roomGiftList: roomGiftPanel = data
        case .giftConfig:
          gifts = LiveGift.roomAvailable(panel: roomGiftPanel, config: data)
          updateFixturePolicy()
          selectedGift = gifts.first?.id
        case .bagList: bag = (data["list"].array ?? []).compactMap(LiveBagItem.init)
        case .medalPanel: medals = data["list"].array ?? []
        case .superChatList:
          try await session.mergeSuperChats(
            (data["list"].array ?? []).compactMap(LiveSuperChat.init), expected: captured)
          guard current(captured) else { return }
        default: break
        }
      } catch {
        guard current(captured) else { return }
        if case LiveInteractionError.paused = error {
          status = Self.message(error)
          break
        }
      }
    }
  }
  @discardableResult private func requestActivityRefresh(_ captured: LiveInteractionContext)
    -> Task<Void, Never>
  {
    let request = activityReads.begin()
    return Task { [weak self] in
      guard let self else { return }
      await self.refreshActivity(captured, request: request)
    }
  }
  private func refreshActivity(_ captured: LiveInteractionContext, request: UInt64) async {
    guard current(captured), activityReads.isCurrent(request) else { return }
    do {
      let response = try await session.read(
        .lotteryInfo, fields: ["roomid": String(captured.roomID)], expected: captured)
      guard current(captured), activityReads.isCurrent(request) else { return }
      if activityReads.apply(response.data, request: request) { applyActivity(activityReads.value) }
    } catch {
      guard current(captured), activityReads.isCurrent(request) else { return }
    }
  }
  private func applyActivity(_ data: LiveJSON) {
    let anchor = data["anchor"]
    let red = data["popularity_red_pocket"]
    let entry = (anchor["id"].int64 ?? 0) > 0 ? anchor : red
    guard let id = entry["id"].int64, id > 0 else {
      activity = nil
      return
    }
    let kind: LiveActivity.Kind = (anchor["id"].int64 ?? 0) > 0 ? .lottery : .redPocket
    var next = LiveActivity(
      id: id, kind: kind,
      deadline: Double(entry["deadline"].int64 ?? 0), isFree: nil, conditionsKnown: false,
      automaticDanmaku: nil, automaticallyFollows: nil)
    #if DEBUG
      if fixtures, entry["fixture_conditions_known"] == .bool(true) {
        next = LiveActivity(
          id: id, kind: kind, deadline: Double(entry["deadline"].int64 ?? 0),
          isFree: entry["fixture_is_free"] == .bool(true), conditionsKnown: true,
          automaticDanmaku: entry["fixture_automatic_danmaku"].string,
          automaticallyFollows: entry["fixture_automatically_follows"] == .bool(true))
      }
    #endif
    if activity?.id != next.id || activity?.kind != next.kind {
      activityJoined = false
      activityResult = nil
    }
    activity = next
    activityTitle = entry["award_name"].string ?? "直播间活动"
    activityHidden = hiddenActivities.contains(activityKey(next))
  }
  private var roomGiftPanel: LiveJSON = .null
  @Published private(set) var metadataReady = false
  func sync(_ captured: LiveInteractionContext) async {
    let state = await session.giftState
    guard current(captured) else { return }
    if state != lastGiftState {
      let nonce = giftAttempt == nil ? state.transactionNonce : giftTicketNonce
      if let nonce, let card = LiveGiftPresentationPolicy.result(state, matching: nonce) {
        lastGiftState = state
        result = card
      }
    }
    let color = await session.danmakuColor
    guard current(captured) else { return }
    appliedColor = color
    let mode = await session.danmakuMode
    guard current(captured) else { return }
    appliedMode = mode
    let moderation = await session.moderation
    guard current(captured) else { return }
    self.moderation = moderation
    let pause = await session.pausedUntil
    guard current(captured) else { return }
    pausedUntil = pause
    let store = await session.superChats
    guard current(captured) else { return }
    superChats = store.active(now: Date().timeIntervalSince1970)
    let records = await session.pendingGifts()
    guard current(captured) else { return }
    pending = records
    let failure = await session.lastLikeFailure
    guard current(captured) else { return }
    if let failure { status = failure }
  }
  static func message(_ error: Error) -> String {
    if case LiveRouteError.mutationClosed = error { return "此互动暂未开放，请在浏览器中打开直播间" }
    if case BiliError.api(let code, let message) = error {
      return LiveDanmakuFailure.message(code: code, message: message)
    }
    switch error {
    case LiveInteractionError.muted: return "你在本房间被禁言或主播开启了全员禁言"
    case LiveInteractionError.needsLogin: return "请先登录后互动"
    case LiveInteractionError.paused: return "操作太频繁，B 站暂时限制了发送；不会自动补发"
    case LiveInteractionError.paidGiftsDisabled: return "付费礼物已锁定，请在设置 › 直播中打开"
    case LiveInteractionError.extraConfirmationRequired: return "请先勾选额外金额确认"
    case LiveInteractionError.unsupportedGift: return "此礼物暂未开放原生送出，请前往官方直播间"
    case LiveInteractionError.insufficientBag: return "背包数量不足或已过期，不会使用电池补足"
    case LiveInteractionError.tooLong: return "弹幕超过本房间字数上限"
    case LiveInteractionError.rateLimited, LiveInteractionError.duplicateContent:
      return "发送太快或内容重复，请稍后手动再发"
    case LiveInteractionError.busy: return "正在处理上一次操作"
    case LiveInteractionError.unknownConditions: return "活动条件尚未核实，请前往官方直播间"
    case LiveInteractionError.staleContext, LiveInteractionError.invalidConfirmation,
      LiveInteractionError.expiredQuote:
      return "直播间或报价已变化，请重新核对"
    default: return "没有完成操作：\(error.localizedDescription)"
    }
  }
}

#if DEBUG
  extension LiveInteractionModel {
    var previewReduceMotion: Bool { fixtures && DebugUIFixtures.liveScene == "effects-reduced" }
    func configureScene(_ scene: String, expected captured: LiveInteractionContext) async {
      guard fixtures, current(captured) else { return }
      for _ in 0..<100 {
        if metadataReady { break }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        guard current(captured) else { return }
      }
      guard metadataReady, current(captured) else { return }
      updateFixturePolicy()
      guard current(captured) else { return }
      switch scene {
      // Scenes open panels from the composer's own buttons, as a click would.
      case "gifts", "paid-locked", "balance-unknown":
        open(.gifts, from: "sidebar-gifts")
        if scene == "paid-locked", let gift { select(gift) }
      case "bag":
        bagTab = true
        selectedBag = bag.first?.bagID
        open(.gifts, from: "sidebar-gifts")
      case "emotes": open(.emotes, from: "sidebar-emotes")
      case "style": open(.style, from: "sidebar-style")
      case "medals": break  // The mounted medal button presents its own popover.
      case "reply":
        reply(to: LiveDanmakuReply(mid: 900002, name: "阿青", messageID: "fixture-dm-1"))
        setText("我也想去")
      case "gift-confirm", "gift-confirm-high", "confirmation-required":
        quantity = scene == "gift-confirm" ? "10" : "101"
        prepareGift()
      case "gift-sending":
        guard let gift else { return }
        do {
          let quote = try await session.makeQuote(gift: gift, quantity: 1, expected: captured)
          guard current(captured) else { return }
          self.quote = quote
          confirmGift(extraConfirmed: false)
        } catch { if current(captured) { status = Self.message(error) } }
      case "send-failed":
        setText("晚上好呀")
        // This scene's transport returns the actual blocked-word business envelope.
        send()
      case "closed":
        setText("晚上好呀")
        status = "发弹幕暂未开放 · 在浏览器中打开直播间可以发送"
        result = .closed
      case "lottery-joined", "redpocket-joined": joinActivity()
      case "lottery-hidden", "redpocket-hidden": hideActivity()
      case "lottery-award", "redpocket-award":
        activityResult = "已开奖 · 中奖：阿青、北岸、云杉。你没有中奖"
      default: break
      }
      await sync(captured)
    }
  }
#else
  extension LiveInteractionModel { var previewReduceMotion: Bool { false } }
#endif
