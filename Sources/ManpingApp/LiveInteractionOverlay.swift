import AppKit
import ManpingCore
import SwiftUI

struct LiveInteractionOverlay: View {
  @ObservedObject var interaction: LiveInteractionModel
  @ObservedObject private var power = PowerState.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading) {
      if interaction.settings.liveEffective.lotteryBanner, !interaction.activityHidden,
        let activity = interaction.activity
      {
        LiveActivityBanner(interaction: interaction, activity: activity).frame(maxWidth: 580).frame(
          maxWidth: .infinity)
      }
      Spacer(minLength: 10)
      if let effect = interaction.effects.active {
        LiveEffectCapsule(
          effect: effect,
          giftImage: effect.imageURL
            ?? interaction.gifts.first(where: { $0.id == effect.giftID })?.imageURL
        )
        .id(effect.id).transition(
          animates ? .move(edge: .leading).combined(with: .opacity) : .opacity
        )
        .task(id: effect.id) {
          do { try await Task.sleep(for: .seconds(power.level == .normal ? 4 : 2)) } catch {
            return
          }
          if interaction.effects.active?.id == effect.id { interaction.advanceEffect() }
        }
      }
    }.padding(18).padding(.bottom, 82).foregroundStyle(.white).environment(\.colorScheme, .dark)
      .animation(animates ? .easeOut(duration: 0.25) : nil, value: interaction.effects.active?.id)
  }
  private var animates: Bool {
    LiveEffectMotion.animates(
      reduceMotion: reduceMotion || interaction.previewReduceMotion, saving: power.level)
  }
}

private struct LiveEffectCapsule: View {
  let effect: LiveEffect
  let giftImage: URL?
  private var tint: Color {
    switch effect.kind {
    case .gift: Theme.highlight
    case .guardPurchase: liveColor(0x3e6fd8)
    case .superChat: superChatColor(effect.price ?? 0)
    }
  }
  private var icon: String {
    effect.kind == .gift
      ? "gift.fill" : effect.kind == .guardPurchase ? "shield.fill" : "text.bubble.fill"
  }
  var body: some View {
    HStack(spacing: 10) {
      Group {
        if let url = effect.avatarURL {
          CachedImage(url: url)
        } else {
          Image(systemName: "person.fill").resizable().scaledToFit().padding(9)
        }
      }.frame(width: 36, height: 36).background(.white.opacity(0.28), in: Circle()).clipShape(
        Circle())
      Group {
        if let user = effect.user {
          Text(user).bold()
            + Text(
              effect.kind == .gift
                ? " 送出 " + (effect.giftName ?? "")
                : effect.kind == .guardPurchase
                  ? " 开通了" + (effect.giftName ?? "大航海") : " · ¥" + String(effect.price ?? 0))
        } else {
          Text(effect.title)
        }
      }.font(Theme.Font.body).lineLimit(1)
      if effect.kind == .superChat {
        Text(effect.detail).font(Theme.Font.caption).lineLimit(1)
      }
      if effect.kind == .gift {
        Group {
          if let giftImage {
            CachedImage(url: giftImage)
          } else {
            Image(systemName: icon).resizable().scaledToFit().padding(5)
          }
        }.frame(width: 34, height: 34)
      }
      if let count = effect.count {
        Text("×" + String(count)).font(.system(size: 24, weight: .bold)).italic()
          .foregroundStyle(.white).shadow(color: .black.opacity(0.4), radius: 1, y: 1)
      }
    }.padding(.leading, 4).padding(.trailing, 16).frame(height: 44)
      .frame(maxWidth: effect.kind == .superChat ? 480 : nil)
      .foregroundStyle(effect.kind == .gift ? liveColor(0x2a1600) : .white)
      .background(
        LinearGradient(
          colors: [tint.opacity(0.9), tint.opacity(0.25)], startPoint: .leading, endPoint: .trailing
        ),
        in: Capsule()
      )
      .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
      .accessibilityLabel(effect.title + " " + effect.detail)
      .help(effect.detail)
  }
}

private struct LiveActivityBanner: View {
  @ObservedObject var interaction: LiveInteractionModel
  let activity: LiveActivity
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: activity.kind == .redPocket ? "envelope.badge.fill" : "gift.fill").font(
        .system(size: 26)
      ).foregroundStyle(Theme.highlight)
      VStack(alignment: .leading, spacing: 5) {
        Text((activity.kind == .redPocket ? "人气红包 · " : "天选时刻 · ") + interaction.activityTitle)
          .font(Theme.Font.headline)
        if let result = interaction.activityResult {
          Text(result).foregroundStyle(Theme.highlight)
        } else if interaction.activityJoined {
          Text("已参加 · 等待开奖").foregroundStyle(.green)
        } else {
          TimelineView(.periodic(from: .now, by: 1)) { time in
            Text(
              activity.deadline > 0
                ? "剩余 \(max(0, Int(activity.deadline - time.date.timeIntervalSince1970))) 秒"
                : "活动条件待核实")
          }
          if activity.conditionsKnown {
            Text(
              activity.automaticDanmaku.map { $0.isEmpty ? "不会自动发弹幕" : "参加后会自动发送弹幕「\($0)」" }
                ?? "弹幕副作用未知")
            Text(activity.automaticallyFollows == true ? "参加后会关注主播" : "不会自动关注主播")
          } else {
            Text("参加条件与副作用尚未核实，请在官方页面查看")
          }
        }
      }.font(Theme.Font.caption).frame(maxWidth: .infinity, alignment: .leading)
      if !interaction.activityJoined && interaction.activityResult == nil {
        if activity.isFree == true && activity.conditionsKnown {
          Button("参加") { interaction.joinActivity() }.disabled(
            activity.deadline <= Date().timeIntervalSince1970
          ).buttonStyle(
            AppButtonStyle(role: .primary, size: .small))
        } else {
          Button("在浏览器中参与 ↗") { openRoom() }.buttonStyle(.link)
        }
      }
      Button {
        interaction.hideActivity()
      } label: {
        Image(systemName: "xmark")
      }.buttonStyle(.plain).help("收起本场横幅")
    }.padding(12).floatingGlassPanel(radius: Theme.Radius.lg, readingTint: .black.opacity(0.35))
  }
  private func openRoom() {
    if let room = interaction.context?.roomID,
      let url = URL(string: "https://live.bilibili.com/\(room)")
    {
      NSWorkspace.shared.open(url)
    }
  }
}

struct LiveGiftResultCards: View {
  @ObservedObject var interaction: LiveInteractionModel
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let result = interaction.result, result != .unknown {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            switch result {
            case .sending: Label("正在送出…", systemImage: "clock")
            case .sent: Label("已送出", systemImage: "checkmark.circle.fill")
            case .rejected(let message):
              Label("被拒绝", systemImage: "exclamationmark.circle")
              Text(message).font(Theme.Font.caption)
            case .closed:
              Label("送礼暂未开放", systemImage: "lock.fill")
              Text("请在官方直播间手动送礼").font(Theme.Font.caption)
            case .unknown: EmptyView()
            }
          }
          Spacer()
          if result != .sending {
            Button {
              interaction.dismissResult()
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain).help("关闭结果卡片")
          }
        }.padding(10).background(
          Theme.highlight.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
      }
      ForEach(interaction.pending, id: \.nonce) { ticket in
        VStack(alignment: .leading, spacing: 6) {
          Label("结果未知 · 可能已扣费", systemImage: "exclamationmark.triangle.fill").font(
            Theme.Font.headline)
          Text("直播间 \(ticket.quote.context.roomID) · 主播 UID \(ticket.quote.context.anchorID)")
          Text(
            "礼物 ID \(ticket.quote.giftID) ×\(ticket.quote.quantity) · \(LiveMoney.batteries(ticket.quote.total)) 电池"
          )
          Text("不会自动重送。请在官方直播个人中心选择消费记录核对。")
          HStack {
            Button("查看消费记录 ↗") {
              if let url = URL(string: "https://link.bilibili.com/p/center/index") {
                NSWorkspace.shared.open(url)
              }
            }.buttonStyle(.link)
            Spacer()
            Button("我已核对") { interaction.acknowledge(ticket.nonce) }.buttonStyle(
              AppButtonStyle(size: .small))
          }
        }.font(Theme.Font.caption).padding(10).background(
          Theme.highlight.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
      }
    }.padding(.horizontal, 12)
  }
}
