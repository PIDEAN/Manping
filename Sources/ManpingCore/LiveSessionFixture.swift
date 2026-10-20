import Foundation
import Synchronization

/// Explicit offline scenarios execute the same session and HTTP contract builder as the App.
/// They only work with a fixture-backed BiliService and never open production mutation gates.
public enum LiveSessionFixture {
  public static let uiScenes = [
    "main", "reply", "own", "gifts", "bag", "paid-locked", "gift-confirm", "gift-confirm-high",
    "gift-sending",
    "emotes", "style", "medals", "user-muted", "all-muted", "send-failed", "closed", "fullscreen",
    "sidebar-hidden", "anchor-tab", "narrow", "effects", "effects-reduced", "effects-power", "pure",
    "hide-gifting",
    "lottery-free", "lottery-gift-required", "lottery-joined", "lottery-award",
    "redpocket-free", "redpocket-required", "redpocket-joined", "redpocket-award",
    "balance-unknown",
    "unknown-cross-room", "fullscreen-unknown", "sidebar-unknown", "settings-live", "settings-paid", "settings-pure", "sc-fulltext", "reply-hover", "effects-disabled", "lottery-hidden", "redpocket-hidden",
  ]
  public static let legacyScenes = [
    "parsing", "anonymous", "web-only", "app-authorized", "paid-disabled",
    "confirmation-required", "gift-success", "rejected", "timeout", "late", "executedResponseLost",
    "risk", "sc-deleted", "lottery-unknown",
  ]
  public static let scenes = legacyScenes + uiScenes
  public static func run(
    scene: String, session: LiveInteractionSession,
    context: LiveInteractionContext, waitForLateHandoff: (@Sendable () async -> Void)? = nil
  ) async throws -> [String] {
    guard scenes.contains(scene) else {
      throw BiliError.invalidResponse("Unknown live fixture scene")
    }
    await session.bind(context)
    if ["unknown-cross-room", "fullscreen-unknown", "sidebar-unknown"].contains(scene) {
      return try await run(scene: "executedResponseLost", session: session, context: context)
    }
    if uiScenes.contains(scene) { return [] }
    switch scene {
    case "parsing": return ["欢迎来到山野电台"]
    case "anonymous":
      do {
        try await session.updateDraft(LiveDanmakuDraft(text: "示例弹幕"), expected: context)
      } catch LiveInteractionError.needsLogin { return ["匿名：请先登录后互动"] }
      return ["当前账号暂不能互动"]
    case "web-only":
      do { try await session.setFollowing(true, expected: context) } catch LiveInteractionError
        .needsAppLogin
      { return ["网页登录：弹幕使用 Cookie；关注主播需要 App 扫码授权"] }
      return ["当前账号暂不能互动"]
    case "app-authorized": return ["App 授权：互动会话已绑定示例账号"]
    case "lottery-unknown":
      let activity = LiveActivity(
        id: 400, kind: .lottery, deadline: Date().timeIntervalSince1970 + 60,
        isFree: true, conditionsKnown: false, automaticDanmaku: nil, automaticallyFollows: nil)
      do {
        _ = try await session.confirmActivity(activity, expected: context)
      } catch LiveInteractionError.unknownConditions { return ["抽奖条件与副作用尚未核实，暂不能参加"] }
      return []
    case "sc-deleted":
      let messages =
        (try LiveEnvelope.parse(LiveContractFixture.sample(.superChatList))).data["list"].array?
        .compactMap(LiveSuperChat.init) ?? []
      try await session.mergeSuperChats(messages, expected: context)
      try await session.receive([.superChatDeleted(messages.map(\.id))], expected: context)
      try await session.mergeSuperChats(messages, expected: context)
      return ["醒目留言已删除"]
    default: break
    }
    let gift = LiveGift(
      .object([
        "id": .integer(100), "name": .string("示例礼物"), "price": .integer(100),
        "coin_type": .string("gold"),
      ]))!
    await session.updatePolicy(
      LiveGiftPolicy(allowPaid: scene != "paid-disabled", fixedGoldPrices: [100: 100]))
    let ticket: LiveGiftConfirmation
    do {
      let quote = try await session.makeQuote(
        gift: gift, quantity: scene == "confirmation-required" ? 101 : 1, expected: context)
      ticket = try await session.confirmGift(quote, expected: context)
    } catch LiveInteractionError.paidGiftsDisabled {
      return ["付费礼物已锁定：请在设置 › 直播中允许送付费礼物"]
    } catch LiveInteractionError.extraConfirmationRequired { return ["单次 101 电池：需要额外勾选确认"] }
    if scene == "late" {
      let finished = Mutex(false)
      let send = Task {
        defer { finished.withLock { $0 = true } }
        try await session.sendGift(ticket, expected: context)
      }
      // The fixture delay is controlled in tests. The UI sample deliberately changes generation
      // after handoff, so the later synthetic receipt cannot turn the new session successful.
      if let waitForLateHandoff {
        await waitForLateHandoff()
      } else {
        while await session.giftState == .idle, !finished.withLock({ $0 }) { await Task.yield() }
      }
      guard case .sending = await session.giftState else {
        _ = await send.result
        return ["请求未送出"]
      }
      await session.bind(
        LiveInteractionContext(
          identity: context.identity, accountMid: context.accountMid,
          roomID: context.roomID, anchorID: context.anchorID, generation: context.generation &+ 1))
      _ = await send.result
      return ["已切换会话；迟到结果已丢弃，原交易保留待核对"]
    }
    do { try await session.sendGift(ticket, expected: context) } catch {}
    switch await session.giftState {
    case .succeeded: return ["示例礼物 ×1 已送出"]
    case .rejected(_, let message):
      if scene == "risk" { return ["风控暂停：到期后需手动重新操作"] }
      return ["送礼被明确拒绝：\(message)"]
    case .unknown: return ["结果未知：可能已扣费，请到官方消费记录核对；不会自动重送"]
    default: return ["请求未送出；确认已失效"]
    }
  }
}
