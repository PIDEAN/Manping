import AppKit
import ManpingCore
import SwiftUI

// The settings window (⌘,): a glass sidebar with nine categories and a grouped `Form` per
// category, built from `MacSettingsCatalog`. It replaces the old settings page in the main window.

extension MacSettingGroup {
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .playback: "play.rectangle"
    case .danmaku: "text.bubble"
    case .network: "network"
    case .download: "arrow.down.circle"
    case .notifications: "bell.badge"
    case .privacy: "hand.raised"
    case .ai: "sparkles"
    case .advanced: "slider.horizontal.3"
    }
  }
}

final class SettingsSelection: ObservableObject {
  @Published var group: MacSettingGroup = .general
}

/// Owns the one settings window. AppKit-hosted like the main window, so ⌘, works the same way
/// with the app's own `NSApplication` lifecycle; the frame is remembered between launches.
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()
  private(set) var window: NSWindow?
  private let selection = SettingsSelection()
  /// `--ui-theme` for screenshot checks; nil follows the app's theme.
  var diagnosticTheme: AppTheme?

  func show(model: AppModel, group: MacSettingGroup? = nil) {
    if let group { selection.group = group }
    let window = self.window ?? makeWindow(model: model)
    self.window = window
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // Nobody opens settings to type; do not focus the first number field.
    DispatchQueue.main.async { window.makeFirstResponder(nil) }
  }

  func close() { window?.close() }

  private func makeWindow(model: AppModel) -> NSWindow {
    let root = SettingsView(model: model, settings: model.settingsModel, selection: selection, diagnosticTheme: diagnosticTheme)
      .defaultAppStorage(PerformanceEnvironment.defaults)
    let hosting = NSHostingController(rootView: root)
    hosting.sizingOptions = []
    let window = NSWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.title = "设置"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.minSize = NSSize(width: 760, height: 560)
    window.setContentSize(NSSize(width: 760, height: 560))
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.center()
    window.setFrameAutosaveName("SettingsWindow")
    window.delegate = self
    return window
  }
}

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settings: M7SettingsModel
  @ObservedObject var selection: SettingsSelection
  var diagnosticTheme: AppTheme?
  var body: some View {
    SettingsLayout(model: model, settings: settings, selection: selection)
      .preferredColorScheme(diagnosticTheme?.colorScheme ?? model.theme.colorScheme)
      .tint(Theme.accent)
      .onAppear { settings.reload() }
  }
}

/// The same structure as the main window: a floating glass sidebar holding the window buttons and
/// the categories, and the category's title above its grouped form.
private struct SettingsLayout: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settings: M7SettingsModel
  @ObservedObject var selection: SettingsSelection
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Color.clear.frame(height: 40)
        ForEach(MacSettingGroup.allCases, id: \.self) { group in
          Button { selection.group = group } label: {
            HStack(spacing: 10) {
              Image(systemName: group.symbol).font(.system(size: 13)).frame(width: 20)
              Text(group.rawValue).font(Theme.Font.body)
              Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
          }.buttonStyle(SidebarRowStyle(selected: selection.group == group))
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .foregroundStyle(Theme.text(scheme))
      .frame(width: 192)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
      .padding([.leading, .top, .bottom], Theme.panelInset)
      VStack(alignment: .leading, spacing: 0) {
        Text(selection.group.rawValue).font(Theme.Font.title).foregroundStyle(Theme.text(scheme))
          .padding(.horizontal, 28).frame(height: 52, alignment: .bottom).padding(.bottom, 4)
        SettingsCategoryView(model: model, settings: settings, group: selection.group)
          .id(selection.group)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Theme.panel(scheme))
    .ignoresSafeArea(.container, edges: .top)
  }
}

private struct SettingsCategoryView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settings: M7SettingsModel
  let group: MacSettingGroup
  @State private var confirmClear = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Group {
      if group == .ai {
        ScrollView {
          M8AISettingsView(model: model.aiSettings, templates: AnyView(M8AITemplateSettingsView(store: model.aiPrompts)))
            .frame(maxWidth: 640, alignment: .leading).padding(20).frame(maxWidth: .infinity)
        }
      } else {
        Form {
          ForEach(MacSettingsCatalog.sections(of: group), id: \.title) { section in
            Section {
              leadingRows(section.title)
              ForEach(section.descriptors.filter { !MacSettingsCatalog.openModeKeys.contains($0.key) }) { descriptor in
                SettingRow(settings: settings, descriptor: descriptor)
              }
              trailingRows(section.title)
            } header: {
              Text(section.title)
            } footer: {
              footer(section.title)
            }
            sections(after: section.title)
          }
          if let status = settings.status {
            Section { Text(status).font(Theme.Font.caption).foregroundStyle(.secondary) }
          }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
      }
    }
    .confirmationDialog("清除图片缓存？", isPresented: $confirmClear) {
      Button("清除", role: .destructive) { Task { await settings.clearImageCache() } }
      Button("取消", role: .cancel) {}
    } message: { Text("封面和头像会在浏览时重新加载。登录信息、下载文件和观看记录不受影响。") }
  }

  @ViewBuilder private func leadingRows(_ section: String) -> some View {
    if group == .playback, section == "打开方式" {
      Picker(selection: Binding(get: { MacOpenMode(settings.values) }, set: { mode in
        for (key, value) in mode.values { settings.set(key, value) }
      })) {
        ForEach(MacOpenMode.allCases, id: \.self) { Text($0.title).tag($0) }
      } label: {
        SettingLabel(title: "打开视频时", detail: "视频在哪里开始播放。")
      }
    }
  }

  @ViewBuilder private func trailingRows(_ section: String) -> some View {
    if group == .danmaku, section == "外观" { DanmakuAreaRow(model: model) }
    if group == .download, section == "截图" {
      LabeledContent {
        Button("截取画面") { settings.takeScreenshot() }.disabled(!model.canTakeScreenshot)
      } label: {
        SettingLabel(title: "截取当前画面", detail: "按上面的格式和位置保存正在播放的画面。")
      }
    }
  }

  @ViewBuilder private func footer(_ section: String) -> some View {
    switch (group, section) {
    case (.general, "侧边栏项目"): Text("隐藏的项目仍可从菜单栏的「前往」打开。")
    case (.download, "BBDown"): Text("生成的命令不含 Cookie、令牌等登录信息；拷贝后请自行检查再运行。")
    default: EmptyView()
    }
  }

  @ViewBuilder private func sections(after section: String) -> some View {
    if group == .general, section == "滚动加速" {
      Section("图片缓存") {
        LabeledContent {
          Button(settings.clearing ? "正在清除…" : "清除图片缓存") { confirmClear = true }.disabled(!settings.canClearImages)
        } label: {
          SettingLabel(title: "封面与头像缓存", detail: "清除后浏览时会重新下载图片。")
        }
      }
    }
    if group == .danmaku, section == "外观" { DanmakuShieldSection() }
    if group == .network, section == "缓冲" {
      Section("代理") { ProxySettingsCard(model: model.proxySettingsModel, embedded: true) }
    }
  }
}

/// Title plus an optional one-line explanation, the label of every settings row.
struct SettingLabel: View {
  let title: String
  var detail = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      if !detail.isEmpty {
        Text(detail).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// How a number setting reads: 倍速 as 「1.0×」, durations in 秒, volume and opacity in %,
/// cache sizes in MB, matching the titles and notes in the catalog.
private struct NumberUnit {
  var symbol = ""
  var scale = 1.0
  var fractionDigits: ClosedRange<Int> = 0...2
  init(_ key: MacSettingKey) {
    switch key {
    case .speed, .temporarySpeed, .danmakuSpeed: symbol = "×"; fractionDigits = 1...2
    case .stepForward, .stepBackward, .cacheSeconds: symbol = "秒"; fractionDigits = 0...0
    case .volume, .maxVolume: symbol = "%"; fractionDigits = 0...0
    case .danmakuOpacity: symbol = "%"; scale = 100; fractionDigits = 0...0
    case .cacheMB, .backCacheMB: symbol = "MB"; fractionDigits = 0...0
    default: break
    }
  }
}

private struct SettingRow: View {
  @ObservedObject var settings: M7SettingsModel
  let descriptor: MacSettingDescriptor
  private var key: MacSettingKey { descriptor.key }
  private var reason: String? { settings.reason(descriptor) }
  private var label: SettingLabel {
    SettingLabel(title: descriptor.title, detail: reason.map { "不可用：\($0)" } ?? descriptor.detail)
  }
  var body: some View {
    Group {
      switch descriptor.control {
      case .toggle:
        Toggle(isOn: Binding(get: { settings.values.bool(key) }, set: { settings.set(key, .bool($0)) })) { label }
          .toggleStyle(.switch).controlSize(.small)
      case .choice(let choices):
        Picker(selection: Binding(get: { choices.firstIndex { $0.value == settings.values[key] } ?? 0 },
          set: { settings.set(key, choices[$0].value) })) {
          ForEach(choices.indices, id: \.self) { Text(choices[$0].title).tag($0) }
        } label: { label }
      case .number(let range, let step):
        LabeledContent {
          let unit = NumberUnit(key)
          // Shown in the unit's scale (opacity as a percentage); stored as the catalog defines it.
          let value = Binding(get: { settings.values.number(key) * unit.scale },
            set: { settings.set(key, .number($0 / unit.scale)) })
          HStack(spacing: 6) {
            HStack(spacing: 2) {
              TextField("", value: value, format: .number.precision(.fractionLength(unit.fractionDigits)))
                .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 64).labelsHidden()
              if !unit.symbol.isEmpty {
                Text(unit.symbol).monospacedDigit().foregroundStyle(.secondary).fixedSize()
              }
            }
            Stepper("", value: value, in: range.lowerBound * unit.scale...range.upperBound * unit.scale,
              step: step * unit.scale).labelsHidden()
          }
        } label: { label }
      case .directory, .executable:
        LabeledContent {
          HStack(spacing: 8) {
            Text(pathText).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
              .frame(maxWidth: 220, alignment: .trailing).help(settings.values.text(key))
            Button("选择…") { settings.choosePath(descriptor) }
            if case .directory = descriptor.control {
              Button { settings.openFolder(key) } label: { Image(systemName: "folder") }
                .disabled(settings.values.text(key).isEmpty).help("在 Finder 中显示")
            }
            if key == .customMpv || key == .customLibMpv {
              Button("使用内置") { settings.set(key, .text("")) }.disabled(settings.values.text(key).isEmpty)
            }
          }
        } label: { label }
      }
    }.disabled(reason != nil)
  }
  private var pathText: String {
    let path = settings.values.text(key)
    if path.isEmpty { return key == .customMpv || key == .customLibMpv ? "内置" : "默认位置" }
    return (path as NSString).abbreviatingWithTildeInPath
  }
}

/// The players a danmaku change applies to right away (the main one plus an open episode or room).
@MainActor private func danmakuPlayers(_ model: AppModel) -> [PlayerModel] {
  var seen = Set<ObjectIdentifier>()
  return [model.player, model.pgcPlayback?.player, model.livePlayback?.player].compactMap { $0 }
    .filter { seen.insert(ObjectIdentifier($0)).inserted }
}

/// 弹幕 › 外观 › 显示区域, the same stored preference the player's danmaku panel changes.
private struct DanmakuAreaRow: View {
  @ObservedObject var model: AppModel
  @State private var area: Double = 1
  var body: some View {
    Picker(selection: Binding(get: { area }, set: { value in
      area = value
      for player in danmakuPlayers(model) { player.setDanmakuArea(value) }
    })) {
      Text("四分之一").tag(0.25)
      Text("半屏").tag(0.5)
      Text("全屏").tag(1.0)
    } label: {
      SettingLabel(title: "显示区域", detail: "滚动和顶部弹幕可以占用的画面高度。")
    }
    .onAppear { area = model.player.danmakuArea }
  }
}

/// 弹幕 › 屏蔽: the user's shield (`DanmakuFilterStore`, the same source the player's danmaku
/// panel edits), plus the account's synced shield list.
private struct DanmakuShieldSection: View {
  @ObservedObject private var store = DanmakuFilterStore.shared
  @ObservedObject private var accountShield = DanmakuShieldSync.shared
  @State private var draftRule = ""
  @State private var ruleError: String?

  var body: some View {
    Section {
      typeToggle("隐藏滚动弹幕", .scrolling)
      typeToggle("隐藏顶部弹幕", .top)
      typeToggle("隐藏底部弹幕", .bottom)
      typeToggle("隐藏彩色弹幕", .colored)
      Picker(selection: Binding(get: { store.filter.level }, set: { store.apply(.level($0)) })) {
        Text("关闭").tag(0)
        ForEach(1...10, id: \.self) { Text("\($0) 级").tag($0) }
      } label: {
        SettingLabel(title: "智能屏蔽", detail: "等级越高，隐藏的低质量弹幕越多；直播弹幕不受影响。")
      }
      if accountShield.signedIn {
        Toggle(isOn: Binding(get: { accountShield.shield?.enabled ?? true }, set: { accountShield.setEnabled($0) })) {
          SettingLabel(title: "使用账号屏蔽词", detail: accountSummary)
        }.toggleStyle(.switch).controlSize(.small).disabled(accountShield.shield == nil)
        LabeledContent {
          if accountShield.syncing { ProgressView().controlSize(.small) }
          else { Button("同步") { accountShield.sync() } }
        } label: {
          SettingLabel(title: "从哔哩哔哩同步", detail: accountShield.message ?? "")
        }
      }
      LabeledContent {
        HStack(spacing: 6) {
          TextField("关键词，或 /正则/", text: $draftRule).frame(width: 200).onSubmit(addRule)
          Button("添加", action: addRule).disabled(draftRule.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      } label: {
        SettingLabel(title: "屏蔽词", detail: ruleError ?? "包含这些词的弹幕不再显示。")
      }
      ForEach(store.filter.rules, id: \.self) { rule in
        LabeledContent {
          Button { store.apply(.removeRule(rule)) } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless).help("移除「\(rule)」")
        } label: {
          Text(rule).font(Theme.Font.body.monospaced()).lineLimit(1).truncationMode(.middle)
        }
      }
    } header: {
      Text("屏蔽")
    }
  }

  private var accountSummary: String {
    guard let shield = accountShield.shield else { return "还没有同步。规则在哔哩哔哩网页或手机 App 中管理。" }
    let time = shield.syncedAt.formatted(date: .omitted, time: .shortened)
    return "关键词 \(shield.keywords.count) · 正则 \(shield.patterns.count) · 用户 \(shield.users.count)，\(time) 同步。"
  }

  private func typeToggle(_ title: String, _ type: DanmakuFilterEdit.CommentType) -> some View {
    Toggle(title, isOn: Binding(get: { store.filter.hides(type) }, set: { store.apply(.hide(type, $0)) }))
      .toggleStyle(.switch).controlSize(.small)
  }

  private func addRule() {
    switch DanmakuFilter.validate(draftRule) {
    case .success(let rule):
      guard !store.filter.rules.contains(rule) else { draftRule = ""; return }
      guard store.filter.rules.count < DanmakuFilter.maximumRules else { ruleError = "最多 \(DanmakuFilter.maximumRules) 条。"; return }
      store.apply(.addRule(rule)); draftRule = ""; ruleError = nil
    case .failure(.empty): break
    case .failure(.tooLong): ruleError = "每条不超过 \(DanmakuFilter.maximumRuleLength) 个字符。"
    case .failure(.invalidRegex): ruleError = "正则表达式无效，请检查括号与转义。"
    case .failure(.tooComplex): ruleError = "这个正则可能非常慢，请写得更具体一些。"
    }
  }
}
