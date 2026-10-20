import AppKit
import ManpingCore
import SwiftUI

struct LiveComposer: View {
  @ObservedObject var interaction: LiveInteractionModel
  @ObservedObject var settings: M7SettingsModel
  var login: () -> Void
  var compact = false
  /// Gives the gift panel its context when opened from this composer's 「礼物」.
  var giftModel: AppModel? = nil
  @FocusState private var focused: Bool
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !compact, let reply = interaction.draft.reply {
        HStack {
          Text("回复 @\(reply.name)").lineLimit(1)
          Spacer()
          Button {
            interaction.reply(to: nil)
          } label: {
            Image(systemName: "xmark")
          }.help("取消回复")
        }.font(Theme.Font.caption).foregroundStyle(Theme.accentText(scheme))
      }
      HStack(spacing: 6) {
        if !compact {
          Button {
            interaction.panel = .medals
          } label: {
            HStack(spacing: 3) {
              if let medal = interaction.wornMedal {
                LiveMedalBadge(medal: medal)
              } else {
                Text("未佩戴").font(.system(size: 10)).foregroundStyle(Theme.secondaryText(scheme))
              }
              Image(systemName: "chevron.down").font(.system(size: 8))
            }
          }.buttonStyle(.plain).help("切换佩戴的粉丝勋章")
            .popover(
              isPresented: Binding(
                get: { interaction.panel == .medals },
                set: { if !$0 && interaction.panel == .medals { interaction.panel = nil } }
              ), arrowEdge: .bottom
            ) {
              LiveMedalPanel(interaction: interaction).padding(16).frame(width: 340)
                .floatingGlassPanel(radius: Theme.Radius.lg)
            }
            .task(id: interaction.metadataReady) {
              #if DEBUG
                guard DebugUIFixtures.liveScene == "medals", interaction.metadataReady else {
                  return
                }
                await Task.yield()
                guard !Task.isCancelled else { return }
                interaction.panel = .medals
              #endif
            }
            .onDisappear { if interaction.panel == .medals { interaction.panel = nil } }
        }
        TextField(
          interaction.canInteract ? "发一条友善的弹幕" : "登录后发弹幕、送礼物",
          text: Binding(
            get: { interaction.draft.text }, set: interaction.setText)
        )
        .textFieldStyle(.plain).font(Theme.Font.body).focused($focused).demoAnchor("live.composer")
        .onSubmit { interaction.send() }.disabled(
          !interaction.canInteract || interaction.muted != nil)
        if let limit = interaction.limit {
          Text("\(interaction.draft.text.count)/\(limit)").font(Theme.Font.caption2)
            .monospacedDigit()
            .foregroundStyle(
              interaction.draft.text.count > limit ? Theme.live : Theme.tertiaryText(scheme))
        }
        action("表情", "face.smiling") { interaction.open(.emotes, from: anchor("emotes")) }
          .modifier(LivePanelPopover(panel: .emotes, anchor: anchor("emotes"), model: nil, interaction: interaction))
        Button {
          interaction.send()
        } label: {
          Image(systemName: "paperplane.fill").frame(width: 24, height: 24)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.accent).disabled(!interaction.canSend).help(
          "发送弹幕").demoAnchor("live.send")
      }.padding(.horizontal, 9).frame(height: compact ? 34 : 40)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
          RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(
            Theme.separator(scheme), lineWidth: 0.5))
      if !compact {
        if let message = interaction.composerMessage {
          HStack(alignment: .top) {
            Text(message).font(Theme.Font.caption2).fixedSize(horizontal: false, vertical: true)
            if !interaction.canInteract { Button("登录", action: login).buttonStyle(.link) }
          }.foregroundStyle(Theme.secondaryText(scheme))
        }
        HStack(spacing: 5) {
          if interaction.settings.liveEffective.giftMessages {
            toolbarPill("礼物", "gift") { interaction.open(.gifts, from: "sidebar-gifts") }.demoAnchor("live.gifts")
              .modifier(LivePanelPopover(panel: .gifts, anchor: "sidebar-gifts", model: giftModel, interaction: interaction))
          }
          LiveLikeButton(interaction: interaction, compact: false)
          toolbarPill("样式", "textformat") { interaction.open(.style, from: "sidebar-style") }
            .modifier(LivePanelPopover(panel: .style, anchor: "sidebar-style", model: nil, interaction: interaction))
          Spacer(minLength: 0)
          Button {
            settings.set(.liveHideGifting, .bool(!settings.values.bool(.liveHideGifting)))
          } label: {
            Label(
              settings.values.bool(.liveHideGifting) ? "已屏蔽送礼" : "屏蔽送礼", systemImage: "gift.slash"
            )
            .font(Theme.Font.caption2).padding(.horizontal, 7).frame(height: 28)
            .background(
              settings.values.bool(.liveHideGifting)
                ? Theme.accent.opacity(0.18) : Theme.fill(scheme),
              in: Capsule()
            )
            .overlay(Capsule().strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
          }.buttonStyle(.plain).foregroundStyle(
            settings.values.bool(.liveHideGifting)
              ? Theme.accentText(scheme) : Theme.tertiaryText(scheme))
        }
      }
    }.padding(compact ? 0 : 12).background(compact ? Color.clear : Theme.panel(scheme))
      .onAppear { if interaction.composeShown { focused = true } }
      .onChange(of: focused) { _, value in interaction.focused = value }
      .onChange(of: interaction.focusRequest) { _, _ in focused = true }
      .onDisappear { if focused { interaction.focused = false } }
  }
  private func anchor(_ name: String) -> String { (compact ? "compact-" : "sidebar-") + name }
  private func toolbarPill(_ title: String, _ icon: String, _ action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 4) {
        if icon == "textformat" {
          Text("Aa").font(.system(size: 11, weight: .medium))
        } else {
          Image(systemName: icon)
        }
        Text(title)
      }.font(Theme.Font.caption2)
        .padding(.horizontal, 8).frame(height: 28)
        .background(Theme.fill(scheme), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
    }.buttonStyle(.plain).foregroundStyle(Theme.secondaryText(scheme))
  }
  private func action(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View
  {
    Button(action: action) { Image(systemName: icon).frame(width: 24, height: 24) }
      .buttonStyle(.plain).help(title).accessibilityLabel(title).foregroundStyle(
        Theme.secondaryText(scheme))
  }
}

struct LiveLikeButton: View {
  @ObservedObject var interaction: LiveInteractionModel
  var compact = true
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var power = PowerState.shared
  var body: some View {
    Button {
      interaction.like()
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "heart").symbolEffect(
          .bounce, options: .nonRepeating,
          isActive: LiveEffectMotion.animates(reduceMotion: reduceMotion, saving: power.level)
            && interaction.likes > 0)
        if !compact { Text("点赞").font(Theme.Font.caption2) }
        if interaction.likes > 0 {
          Text("+\(interaction.likes)").font(Theme.Font.caption2).contentTransition(.numericText())
        }
      }.padding(.horizontal, compact ? 0 : 8).frame(minWidth: 24, minHeight: compact ? 24 : 28)
        .background(compact ? Color.clear : Theme.fill(scheme), in: Capsule())
        .overlay(Capsule().strokeBorder(compact ? .clear : Theme.separator(scheme), lineWidth: 0.5))
    }.buttonStyle(.plain).foregroundStyle(Theme.live).help("点赞").accessibilityLabel("点赞").demoAnchor("live.like")
      .animation(
        LiveEffectMotion.animates(reduceMotion: reduceMotion, saving: power.level)
          ? .easeOut(duration: 0.2) : nil, value: interaction.likes)
  }
}

struct LiveInteractionHost: ViewModifier {
  @ObservedObject var model: AppModel
  @ObservedObject var interaction: LiveInteractionModel
  func body(content: Content) -> some View {
    content
      // Panels opened from a menu (no button to point at) present from the page.
      .popover(
        item: Binding(
          get: { interaction.panel == .medals || interaction.panelAnchor != nil ? nil : interaction.panel },
          set: { if interaction.panel != .medals, interaction.panelAnchor == nil { interaction.panel = $0 } }
        ), arrowEdge: .bottom
      ) { panel in LivePanelContent(panel: panel, model: model, interaction: interaction) }
      .popover(isPresented: $interaction.composeShown, arrowEdge: .bottom) {
        LiveComposer(
          interaction: interaction, settings: model.settingsModel,
          login: { model.showingLogin = true }, giftModel: model
        )
        .frame(width: 340).padding(8)
      }
      .sheet(
        item: Binding(
          get: { interaction.quote }, set: { if $0 == nil { interaction.invalidateQuote() } })
      ) { quote in
        LiveGiftConfirmationView(interaction: interaction, quote: quote)
      }
  }
}

/// A gift, emote or style panel in its glass popover.
struct LivePanelContent: View {
  let panel: LiveInteractionModel.Panel
  let model: AppModel?
  @ObservedObject var interaction: LiveInteractionModel
  var body: some View {
    Group {
      switch panel {
      case .gifts: if let model { LiveGiftPanel(model: model, interaction: interaction) }
      case .emotes: LiveEmotePanel(interaction: interaction)
      case .style: LiveStylePanel(interaction: interaction)
      case .medals: EmptyView()
      }
    }.padding(16).frame(width: panel == .gifts ? 420 : 340)
      .floatingGlassPanel(radius: Theme.Radius.lg)
  }
}

/// Presents `panel` from the button it is attached to while that button opened it.
struct LivePanelPopover: ViewModifier {
  let panel: LiveInteractionModel.Panel
  let anchor: String
  /// Needed by the gift panel only; other panels may pass nil.
  let model: AppModel?
  @ObservedObject var interaction: LiveInteractionModel
  func body(content: Content) -> some View {
    content.popover(
      isPresented: Binding(
        get: { interaction.panel == panel && interaction.panelAnchor == anchor },
        set: { if !$0, interaction.panel == panel, interaction.panelAnchor == anchor { interaction.panel = nil } }
      ), arrowEdge: .top
    ) { LivePanelContent(panel: panel, model: model, interaction: interaction) }
  }
}

private struct LiveGiftPanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject var interaction: LiveInteractionModel
  @Environment(\.colorScheme) private var scheme
  private var quantities: [Int64] {
    let raw = interaction.gift?.raw["count_map"]
    let values = raw?.array?.compactMap { $0.int64 ?? $0["num"].int64 } ?? []
    return values.filter { $0 > 0 }.isEmpty ? [1] : values.filter { $0 > 0 }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("送礼物").font(Theme.Font.section)
        Spacer()
        Text("礼物送出后不能退回").font(Theme.Font.caption2).foregroundStyle(.secondary)
      }
      Picker("礼物来源", selection: $interaction.bagTab) {
        Text("礼物").tag(false)
        Text("背包").tag(true)
      }.pickerStyle(.segmented)
      if interaction.paidLockedNotice {
        HStack(alignment: .top) {
          Label("付费礼物已锁定。需要在设置中允许送付费礼物。", systemImage: "lock.fill")
          Button("打开设置") {
            interaction.panel = nil
            model.openSettings(.live)
          }
        }.font(Theme.Font.caption).padding(10).background(
          Theme.highlight.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
      }
      ScrollView {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10
        ) {
          if interaction.bagTab {
            ForEach(interaction.bag, id: \.bagID) { bag in
              if let gift = interaction.gifts.first(where: { $0.id == bag.giftID }) {
                giftCell(gift, bag: bag)
              }
            }
          } else {
            ForEach(interaction.gifts) { giftCell($0) }
          }
        }
        if interaction.bagTab && interaction.bag.isEmpty && interaction.bagReadFailed {
          HStack {
            Text("没能读取背包").font(Theme.Font.caption)
            Button("重新读取背包") { interaction.refreshBag() }.font(Theme.Font.caption)
          }.padding()
        } else if interaction.bagTab && interaction.bag.isEmpty {
          Text("背包为空或尚未取得背包信息").font(Theme.Font.caption).padding()
        }
        if !interaction.bagTab && interaction.gifts.isEmpty {
          Text("暂未取得本房间礼物").font(Theme.Font.caption).padding()
        }
      }.frame(height: 210)
      HStack(spacing: 6) {
        Text("数量").font(Theme.Font.caption)
        ForEach(quantities, id: \.self) { count in
          Button(String(count)) { interaction.quantity = String(count) }.buttonStyle(
            AppButtonStyle(size: .small))
        }
        TextField("自定义", text: $interaction.quantity).textFieldStyle(.roundedBorder).frame(
          width: 64
        ).help("自定义正整数数量")
      }
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          if let total = interaction.selectedTotal {
            Text("合计 \(LiveMoney.batteries(total)) 电池").font(Theme.Font.headline).foregroundStyle(
              Theme.highlight)
            Text(
              "约 ¥\(LiveMoney.yuan(total)) · 余额 \(interaction.balance.map { LiveMoney.batteries($0) + " 电池" } ?? "未知")"
            ).font(Theme.Font.caption).foregroundStyle(.secondary)
          } else {
            Text("请选择礼物和有效数量").font(Theme.Font.caption)
          }
        }
        Spacer()
        Button("核对并送出…") { interaction.prepareGift() }.buttonStyle(
          AppButtonStyle(role: .primary, size: .small)
        )
        .disabled(
          interaction.gift == nil || interaction.selectedTotal == nil
            || (interaction.bagTab && interaction.bagItem == nil))
      }
      if let status = interaction.status {
        Text(status).font(Theme.Font.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack {
        official("充值", "请在官方直播个人中心选择充值", url: "https://link.bilibili.com/p/center/index")
        Spacer()
        official("上舰", "请在官方直播间选择上舰", url: roomURL)
        Spacer()
        official("醒目留言", "请在官方直播间选择醒目留言", url: roomURL)
      }
    }
  }
  private var roomURL: String { "https://live.bilibili.com/\(interaction.context?.roomID ?? 0)" }
  private func official(_ title: String, _ help: String, url: String) -> some View {
    Button(title + " ↗") { if let url = URL(string: url) { NSWorkspace.shared.open(url) } }
      .buttonStyle(.link).help(help)
  }
  private func giftCell(_ gift: LiveGift, bag: LiveBagItem? = nil) -> some View {
    let locked = bag == nil && !interaction.settings.bool(.liveAllowPaidGifts)
    let selected =
      interaction.selectedGift == gift.id
      && (!interaction.bagTab || interaction.selectedBag == bag?.bagID)
    return Button {
      interaction.select(gift, bag: bag)
    } label: {
      VStack(spacing: 5) {
        if let image = gift.imageURL {
          CachedImage(url: image).frame(width: 44, height: 44)
        } else {
          Image(systemName: "gift.fill").font(.system(size: 28)).foregroundStyle(Theme.highlight)
            .frame(height: 44)
        }
        Text(gift.name).font(Theme.Font.caption).lineLimit(1)
        if let bag {
          Text("×\(bag.count)").font(Theme.Font.caption2)
          Text(
            bag.expiresAt.map {
              Date(timeIntervalSince1970: Double($0)).formatted(date: .abbreviated, time: .omitted)
                + " 到期"
            } ?? "永久"
          )
          .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        } else {
          Label(
            "\(LiveMoney.batteries(gift.price)) 电池", systemImage: locked ? "lock.fill" : "bolt.fill"
          ).font(.system(size: 10))
        }
      }.frame(maxWidth: .infinity).padding(6).opacity(locked ? 0.5 : 1)
        .background(
          selected ? Theme.accent.opacity(0.14) : Theme.fill(scheme),
          in: RoundedRectangle(cornerRadius: Theme.Radius.sm)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(
            selected ? Theme.accent : Color.clear))
    }.buttonStyle(.plain)
  }
}

private struct LiveEmotePanel: View {
  @ObservedObject var interaction: LiveInteractionModel
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("表情").font(Theme.Font.section)
      if interaction.emotes.isEmpty { Text("暂未取得可用表情").foregroundStyle(.secondary) }
      ForEach(Array(interaction.emotes.enumerated()), id: \.offset) { _, package in
        Text(package.name).font(Theme.Font.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
          ForEach(Array(package.emoticons.enumerated()), id: \.offset) { _, emote in
            let allowed = emote["perm"].int64 == 1
            Button {
              if let token = emote["emoticon_unique"].string { interaction.setEmote(token) }
            } label: {
              VStack(spacing: 3) {
                CachedImage(url: emote["url"].string.flatMap(URL.init(string:))).frame(
                  width: 34, height: 34)
                Text(allowed ? (emote["emoji"].string ?? "表情") : "需满足身份条件").font(.system(size: 9))
                  .lineLimit(2)
                if !allowed { Image(systemName: "lock.fill").font(.system(size: 9)) }
              }.opacity(allowed ? 1 : 0.45)
            }.buttonStyle(.plain).disabled(!allowed).help(allowed ? "插入表情" : "当前账号未满足此表情的使用条件")
          }
        }
      }
    }
  }
}

private struct LiveStylePanel: View {
  @ObservedObject var interaction: LiveInteractionModel
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("弹幕样式").font(Theme.Font.section)
      ForEach(Array(interaction.config.groups.enumerated()), id: \.offset) { _, group in
        Text(group["name"].string ?? "颜色").font(Theme.Font.caption).foregroundStyle(.secondary)
        HStack {
          ForEach(Array((group["color"].array ?? []).enumerated()), id: \.offset) { _, color in
            let allowed = color["status"].int64 == 1
            let value = UInt32(clamping: color["color"].int64 ?? 0xffffff)
            Button {
              interaction.setStyle(color: value)
            } label: {
              Circle().fill(liveColor(Int64(value))).frame(width: 26, height: 26)
                .overlay {
                  if !allowed {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.black)
                  }
                }
                .opacity(allowed ? 1 : 0.4)
                .overlay(
                  Circle().strokeBorder(
                    interaction.appliedColor == value ? Theme.accent : .clear, lineWidth: 2))
            }.buttonStyle(.plain).disabled(!allowed).help(allowed ? "应用此颜色" : "需满足本房间的身份条件")
          }
        }
      }
      HStack {
        ForEach(Array(interaction.config.modes.enumerated()), id: \.offset) { _, mode in
          let value = Int(mode["mode"].int64 ?? 1)
          Button(value == 1 ? "滚动" : value == 4 ? "底部" : "顶部") { interaction.setStyle(mode: value) }
            .disabled(mode["status"].int64 != 1).help(
              mode["status"].int64 == 1 ? "应用此位置" : "需满足本房间的身份条件")
        }
      }
      Text(interaction.status ?? "锁定的样式需要满足房间身份条件").font(Theme.Font.caption).foregroundStyle(
        .secondary)
    }
  }
}

private struct LiveMedalPanel: View {
  @ObservedObject var interaction: LiveInteractionModel
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("粉丝勋章").font(Theme.Font.section)
      if interaction.medals.isEmpty { Text("暂未取得粉丝勋章").foregroundStyle(.secondary) }
      ForEach(Array(interaction.medals.enumerated()), id: \.offset) { _, entry in
        let medal = entry["medal_info"] == .null ? entry : entry["medal_info"]
        let lighted = medal["is_lighted"].int64 == 1
        Button {
          interaction.wearMedal(medal["medal_id"].int64)
        } label: {
          HStack {
            Text("\(medal["medal_name"].string ?? "勋章") \(medal["level"].int64 ?? 0)")
              .padding(5).background(
                lighted ? liveColor(medal["medal_color"].int64 ?? 0x3e6fd8) : .gray, in: Capsule()
              ).foregroundStyle(.white)
            Text(entry["anchor_info"]["uname"].string ?? "").foregroundStyle(.secondary)
            Spacer()
            Text(!lighted ? "未点亮" : entry["wearing_status"].int64 == 1 ? "佩戴中" : "佩戴").font(
              Theme.Font.caption)
          }
        }.buttonStyle(.plain).disabled(!lighted || medal["medal_id"].int64 == nil || interaction.medalBusy)
      }
      if interaction.gate.allows(.takeOffMedal) {
        Button("摘下勋章") { interaction.wearMedal(nil) }.disabled(interaction.medalBusy)
      } else {
        Text("摘下勋章暂未开放 · 可以改戴其他勋章，或在官方直播间摘下").font(Theme.Font.caption)
          .foregroundStyle(.secondary)
      }
      if let status = interaction.status {
        Text(status).font(Theme.Font.caption).foregroundStyle(.secondary)
      }
    }
  }
}

private struct LiveGiftConfirmationView: View {
  @ObservedObject var interaction: LiveInteractionModel
  let quote: LiveGiftQuote
  @State private var extraConfirmed = false
  @Environment(\.colorScheme) private var scheme
  private var highValue: Bool {
    quote.total > interaction.settings.liveGiftPolicy().extraConfirmationThreshold
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("确认送出礼物", systemImage: "gift").font(Theme.Font.title)
      Text(
        "收款主播 \(interaction.quoteAnchorName) · UID \(quote.context.anchorID) · 直播间 \(quote.context.roomID)"
      ).font(Theme.Font.body)
      Text("\(interaction.quoteGiftName) ×\(quote.quantity)")
        .font(Theme.Font.headline)
      Text("合计 \(LiveMoney.batteries(quote.total)) 电池 · 约 ¥\(LiveMoney.yuan(quote.total))")
        .foregroundStyle(Theme.highlight).font(Theme.Font.section)
      LabeledContent(
        "当前余额", value: interaction.balance.map { LiveMoney.batteries($0) + " 电池" } ?? "未知")
      LabeledContent(
        "预计余额",
        value: LiveMoney.remaining(balance: interaction.balance, total: quote.total).map {
          LiveMoney.batteries($0) + " 电池"
        } ?? "未知")
      if highValue {
        Toggle("我已核对收款主播和金额，确认送出 \(LiveMoney.batteries(quote.total)) 电池", isOn: $extraConfirmed)
      }
      Text("礼物送出后不能退回。请点击按钮确认；回车和数字键盘 Enter 不会送出。").font(Theme.Font.caption).foregroundStyle(
        .secondary)
      HStack {
        Button {
          interaction.invalidateQuote()
        } label: {
          Text("取消").padding(.horizontal, 18).frame(height: 34)
            .overlay(Capsule().strokeBorder(Theme.separator(scheme), lineWidth: 1))
        }.buttonStyle(.plain)
        Spacer()
        Button {
          interaction.confirmGift(extraConfirmed: extraConfirmed)
        } label: {
          Text("送出 \(LiveMoney.batteries(quote.total)) 电池")
            .font(Theme.Font.headline).padding(.horizontal, 18).frame(height: 34)
            .foregroundStyle(
              highValue && !extraConfirmed ? liveColor(0x9c8a66) : liveColor(0x2a1600)
            )
            .background(
              highValue && !extraConfirmed ? liveColor(0x4a3a1c) : Theme.highlight, in: Capsule())
        }.buttonStyle(.plain).disabled(highValue && !extraConfirmed)
      }
    }.padding(24).frame(width: 450).background(ConfirmationEnterShield().frame(width: 0, height: 0))
  }
}

/// Local monitor exists only while the sheet's view is mounted and only swallows its own window.
private struct ConfirmationEnterShield: NSViewRepresentable {
  final class Shield: NSView {
    var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      removeMonitor()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        let same =
          event.window != nil && event.window === self.window && self.window?.isKeyWindow == true
        return LiveConfirmationKeyboardPolicy.suppress(
          keyCode: event.keyCode, inConfirmationWindow: same) ? nil : event
      }
    }
    func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
  func makeNSView(context: Context) -> Shield { Shield() }
  func updateNSView(_ view: Shield, context: Context) {}
  static func dismantleNSView(_ view: Shield, coordinator: ()) { view.removeMonitor() }
}

func liveColor(_ hex: Int64) -> Color {
  Color(
    red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
    blue: Double(hex & 255) / 255)
}
