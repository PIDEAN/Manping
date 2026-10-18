import ManpingCore
import SwiftUI

/// Player danmaku settings: 外观 (font size, opacity, speed, display area) and 屏蔽
/// (comment types, smart-shield level, keywords and `/regex/` rules).
/// Dragging previews on `player` only; releasing a slider writes the value through
/// `M7SettingsModel`, which persists it and re-applies it to the app's players. The sliders use
/// the settings window's ranges, and closing the panel commits only what was moved, so a value
/// the panel merely showed is never rewritten. The shield edits `DanmakuFilterStore`, the same
/// source as 设置 › 弹幕 › 屏蔽.
struct DanmakuSettingsPopover: View {
  @ObservedObject var settings: M7SettingsModel
  let player: PlayerModel
  /// 「更多弹幕设置…」: the danmaku settings in the app's settings.
  var openMore: (() -> Void)? = nil
  @Environment(\.colorScheme) private var scheme
  @ObservedObject private var power = PowerState.shared
  @ObservedObject private var accountShield = DanmakuShieldSync.shared
  @ObservedObject private var store = DanmakuFilterStore.shared
  @State private var fontSize: Double = 24
  @State private var opacity: Double = 1
  @State private var speed: Double = 1
  @State private var area: Double = 1
  /// The sliders the viewer moved since the panel opened.
  @State private var edits = MacSettingsEdits()
  @State private var page = ProcessInfo.processInfo.arguments.contains("--ui-danmaku-shield") ? Page.shield : Page.appearance
  @State private var draftRule = ""
  @State private var ruleError: String?
  enum Page: Hashable { case appearance, shield }

  /// Named speeds shown as tick labels under the speed slider (seconds a scrolling comment
  /// takes to cross the screen; the timeline's base is 8 s, so the multiplier is `8 / seconds`).
  /// They only label the scale: any stored multiplier in the settings range stays as it is.
  static let speedMarks: [(seconds: Double, title: String)] = [
    (12, "很慢"), (10, "慢"), (8, "适中"), (6.5, "快"), (5, "很快"),
  ]
  static let baseDuration = 8.0
  private static func range(_ key: MacSettingKey) -> (range: ClosedRange<Double>, step: Double) {
    MacSettingsCatalog.descriptor(key).numberRange ?? (0...1, 0.1)
  }

  #if DEBUG
  /// `--ui-danmaku-panel`: opens the popover on launch for screenshot checks (live data only).
  static let debugOpen = ProcessInfo.processInfo.arguments.contains("--ui-danmaku-panel")
  #else
  static let debugOpen = false
  #endif
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("弹幕设置").font(Theme.Font.headline).foregroundStyle(Theme.text(scheme))
        Spacer()
        SegmentedTabs(options: [(Page.appearance, "外观"), (Page.shield, store.filter.rules.isEmpty ? "屏蔽" : "屏蔽 \(store.filter.rules.count)")], selection: $page)
      }
      switch page {
      case .appearance: appearance
      case .shield: shield
      }
      if let openMore {
        Hairline()
        Button("更多弹幕设置…", action: openMore).buttonStyle(AppButtonStyle(role: .plain, size: .small))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .frame(width: 280)
    .onAppear {
      load()
      // AppKit focuses the first text field of a new popover; nobody opens this to type.
      DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
    // Keyboard and accessibility adjustments don't report an editing end; persist on close,
    // but only the sliders that were actually moved.
    .onDisappear {
      for change in edits.changes(from: settings.values) { commit(change.key, change.value) }
      edits.removeAll()
    }
  }

  private var appearance: some View {
    VStack(alignment: .leading, spacing: 14) {
      let font = Self.range(.danmakuFontSize), alpha = Self.range(.danmakuOpacity), pace = Self.range(.danmakuSpeed)
      sliderRow("字号", value: "\(Int(fontSize.rounded()))", binding: $fontSize, range: font.range, step: font.step,
        key: .danmakuFontSize)
      sliderRow("不透明度", value: "\(Int((opacity * 100).rounded()))%", binding: $opacity, range: alpha.range, step: alpha.step,
        key: .danmakuOpacity)
      VStack(alignment: .leading, spacing: 2) {
        sliderRow("速度", value: Self.speedText(speed), binding: $speed, range: pace.range, step: pace.step, key: .danmakuSpeed)
        SpeedMarks(range: pace.range).frame(height: 12)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("显示区域").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        SegmentedTabs(options: [(0.25, "四分之一"), (0.5, "半屏"), (1.0, "全屏")], selection: Binding(
          get: { area }, set: { area = $0; player.setDanmakuArea($0) }))
      }
      if power.constrained {
        Label("低电量或发热中：弹幕暂以最高 60 帧、最多 40 条显示", systemImage: "leaf")
          .font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
      }
    }
  }

  /// 「1.2×」, with the named speed when the value sits on one of the marks.
  private static func speedText(_ speed: Double) -> String {
    let value = String(format: "%.1f×", speed)
    guard let mark = speedMarks.first(where: { abs(baseDuration / $0.seconds - speed) < 0.02 }) else { return value }
    return "\(mark.title) · \(value)"
  }

  private var shield: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("隐藏类型").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        HStack(spacing: 6) {
          typeChip("滚动", .scrolling)
          typeChip("顶部", .top)
          typeChip("底部", .bottom)
          typeChip("彩色", .colored)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("智能屏蔽等级").foregroundStyle(Theme.secondaryText(scheme))
          Spacer()
          Text(store.filter.level == 0 ? "关" : "\(store.filter.level)").monospacedDigit().foregroundStyle(Theme.text(scheme))
        }.font(Theme.Font.caption)
        Slider(value: Binding(get: { Double(store.filter.level) }, set: { store.apply(.level(Int($0.rounded()))) }),
          in: 0...10, step: 1)
          .controlSize(.small).tint(Theme.accent).accessibilityLabel("智能屏蔽等级")
        Text("等级越高，隐藏的低质量弹幕越多；直播弹幕不带等级，不受影响。")
          .font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)).fixedSize(horizontal: false, vertical: true)
      }
      accountSection
      VStack(alignment: .leading, spacing: 6) {
        Text("屏蔽词（\(store.filter.rules.count)）").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        HStack(spacing: 6) {
          TextField("关键词，或 /正则/", text: $draftRule)
            .textFieldStyle(AppTextFieldStyle(height: Theme.compactControlHeight))
            .onSubmit(addRule)
          Button("添加", action: addRule).buttonStyle(.bordered).controlSize(.small)
            .disabled(draftRule.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let ruleError { InlineErrorText(message: ruleError) }
        if !store.filter.rules.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(store.filter.rules, id: \.self) { rule in
                HStack(spacing: 6) {
                  Text(rule).font(Theme.Font.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Theme.text(scheme))
                  Spacer(minLength: 0)
                  Button { store.apply(.removeRule(rule)) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                  }.buttonStyle(.borderless).foregroundStyle(Theme.tertiaryText(scheme)).help("移除「\(rule)」")
                }.padding(.horizontal, 8).frame(height: 22)
              }
            }
          }
          // A ScrollView has no ideal height inside a popover; size it to its rows (up to six).
          .frame(height: min(132, CGFloat(store.filter.rules.count) * 22 + 4))
            .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
      }
    }
  }

  /// The account's shield list from Bilibili (read-only here).
  @ViewBuilder private var accountSection: some View {
    if accountShield.signedIn {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Toggle("使用账号屏蔽词", isOn: Binding(get: { accountShield.shield?.enabled ?? true },
            set: { accountShield.setEnabled($0) }))
            .toggleStyle(.switch).controlSize(.small).tint(Theme.accent).disabled(accountShield.shield == nil)
          Spacer()
          if accountShield.syncing { ProgressView().controlSize(.small) }
          else {
            Button("同步") { accountShield.sync() }.buttonStyle(.borderless).font(Theme.Font.caption)
              .help("从哔哩哔哩账号重新读取屏蔽词")
          }
        }.font(Theme.Font.caption)
        Text(accountSummary).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
        if let message = accountShield.message {
          Text(message).font(Theme.Font.caption2).foregroundStyle(Theme.secondaryText(scheme))
        }
      }
    }
  }
  private var accountSummary: String {
    guard let shield = accountShield.shield else { return "尚未同步。规则在哔哩哔哩网页或手机 App 中管理。" }
    let time = shield.syncedAt.formatted(date: .omitted, time: .shortened)
    return "关键词 \(shield.keywords.count) · 正则 \(shield.patterns.count) · 用户 \(shield.users.count)，\(time) 同步；在哔哩哔哩中管理。"
  }

  private func typeChip(_ title: String, _ type: DanmakuFilterEdit.CommentType) -> some View {
    let on = store.filter.hides(type)
    return Button { store.apply(.hide(type, !on)) } label: {
      Text(title).font(Theme.Font.caption).fontWeight(on ? .semibold : .regular)
        .foregroundStyle(on ? Theme.accentText(scheme) : Theme.secondaryText(scheme))
        .padding(.horizontal, 10).frame(height: 24)
        .background(on ? Theme.accent.opacity(0.18) : Theme.fill(scheme), in: Capsule())
    }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).help(on ? "显示\(title)弹幕" : "隐藏\(title)弹幕")
  }

  private func addRule() {
    switch DanmakuFilter.validate(draftRule) {
    case .success(let rule):
      guard !store.filter.rules.contains(rule) else { draftRule = ""; return }
      guard store.filter.rules.count < DanmakuFilter.maximumRules else { ruleError = "最多 \(DanmakuFilter.maximumRules) 条。"; return }
      store.apply(.addRule(rule)); draftRule = ""; ruleError = nil
    case .failure(.empty): break
    case .failure(.tooLong): ruleError = "单条不超过 \(DanmakuFilter.maximumRuleLength) 个字符。"
    case .failure(.invalidRegex): ruleError = "正则表达式无效，请检查括号与转义。"
    case .failure(.tooComplex): ruleError = "这个正则可能非常慢（嵌套重复），请改写得更具体一些。"
    }
  }

  private func sliderRow(_ title: String, value: String, binding: Binding<Double>, range: ClosedRange<Double>,
    step: Double, key: MacSettingKey) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).foregroundStyle(Theme.secondaryText(scheme))
        Spacer()
        Text(value).monospacedDigit().foregroundStyle(Theme.text(scheme))
      }.font(Theme.Font.caption)
      Slider(value: Binding(get: { binding.wrappedValue }, set: {
        binding.wrappedValue = $0; edits.record(key, .number($0)); preview(key, .number($0))
      }), in: range, step: step) { editing in
        if !editing, edits.changes(from: settings.values).contains(where: { $0.key == key }) {
          commit(key, .number(binding.wrappedValue))
        }
      }
      .controlSize(.small).tint(Theme.accent).accessibilityLabel(title).accessibilityValue(value)
    }
  }

  /// Shows the stored values as they are (the catalog already keeps them in range).
  private func load() {
    let values = settings.values
    fontSize = values.number(.danmakuFontSize)
    opacity = values.number(.danmakuOpacity)
    speed = values.number(.danmakuSpeed)
    area = player.danmakuArea
    edits.removeAll()
  }

  /// Live preview while dragging; nothing is written until the slider is released.
  private func preview(_ key: MacSettingKey, _ value: MacSettingValue) {
    var draft = settings.values
    guard draft.set(key, value, capabilities: settings.capabilities) else { return }
    player.applyDanmakuPreferences(draft)
  }

  private func commit(_ key: MacSettingKey, _ value: MacSettingValue) {
    guard settings.values[key] != value else { return }
    settings.set(key, value)
    // The settings path updates the main and PGC players; a live or detached player is
    // updated here directly.
    player.applyDanmakuPreferences(settings.values)
  }
}

/// 很慢 · 慢 · 适中 · 快 · 很快 under the speed slider, each at its multiplier's position.
private struct SpeedMarks: View {
  let range: ClosedRange<Double>
  @Environment(\.colorScheme) private var scheme
  /// The small slider's knob centre stays this far inside the track's ends.
  private let inset: CGFloat = 8
  var body: some View {
    GeometryReader { geometry in
      let span = range.upperBound - range.lowerBound
      ForEach(DanmakuSettingsPopover.speedMarks, id: \.seconds) { mark in
        let fraction = (DanmakuSettingsPopover.baseDuration / mark.seconds - range.lowerBound) / span
        Text(mark.title).font(.system(size: 9)).foregroundStyle(Theme.tertiaryText(scheme)).fixedSize()
          .position(x: inset + (geometry.size.width - 2 * inset) * CGFloat(min(1, max(0, fraction))), y: geometry.size.height / 2)
      }
    }.accessibilityHidden(true)
  }
}
