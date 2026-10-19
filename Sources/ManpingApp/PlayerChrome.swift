import AppKit
import ManpingCore
import OSLog
import SwiftUI
import VideoToolbox

// The playback chrome shared by the video, episode and live pages (DesignSystem.md §11): a
// Liquid Glass control panel inset 12pt from the bottom of the stage that hides itself, its
// buttons, menus and popovers. Everything here is white-on-video and independent of the theme.

// MARK: - Visibility

/// When the player controls are up. Pointer movement and playback shortcuts bring them in;
/// 2.5 s without movement, while the pointer is not over the controls, hides them (in full
/// screen the pointer too). Pages keep them up while `pinned`: paused, a popover open, typing
/// a comment or scrubbing.
@MainActor final class PlayerChromeState: ObservableObject {
  @Published private(set) var visible = true
  let idleDelay: TimeInterval
  private var deadline = Date.distantFuture
  private var timer: Timer?
  private var overControls = false
  /// Mirrors the page's pin so the idle timer never hides pinned controls; releasing the pin
  /// starts a fresh idle period.
  var pinned = false {
    didSet { if oldValue && !pinned { activity() } }
  }

  init(idleDelay: TimeInterval = 2.5) { self.idleDelay = idleDelay }

  /// The pointer moved over the player, or a shortcut changed playback.
  func activity() {
    if !visible { visible = true }
    deadline = Date().addingTimeInterval(idleDelay)
    arm(replacing: false)
  }

  /// The pointer left the player: hide shortly.
  func pointerLeft() {
    overControls = false
    deadline = Date().addingTimeInterval(0.35)
    arm(replacing: true)
  }

  func setOverControls(_ value: Bool) {
    guard value != overControls else { return }
    overControls = value
    if !value { activity() }
  }

  // One timer per idle period: pointer movement only moves the deadline. The timer runs in the
  // default run-loop mode, so it waits while a menu from the panel is tracking.
  private func arm(replacing: Bool) {
    if timer != nil && !replacing { return }
    timer?.invalidate()
    let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.fire() }
    }
    RunLoop.main.add(timer, forMode: .default)
    self.timer = timer
  }

  private func fire() {
    timer = nil
    if Date() < deadline { arm(replacing: true); return }
    guard !overControls, !pinned, visible else { return }
    visible = false
    if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
  }
}

extension View {
  /// Feeds pointer movement over the player into `chrome` and keeps its pin in sync.
  func tracksPlayerChrome(_ chrome: PlayerChromeState, pinned: Bool) -> some View {
    modifier(PlayerChromeTracking(chrome: chrome, pinned: pinned))
  }

  /// Fades the controls in (0.18 s) and out (0.3 s, sliding down 6pt unless 减弱动态效果 is on).
  /// They fade rather than leave the hierarchy, so a menu opened from them stays anchored.
  func playerChromeFade(_ shown: Bool) -> some View {
    modifier(PlayerChromeFade(shown: shown))
  }
}

private struct PlayerChromeTracking: ViewModifier {
  let chrome: PlayerChromeState
  let pinned: Bool
  func body(content: Content) -> some View {
    content
      .onContinuousHover { phase in
        switch phase {
        case .active: chrome.activity()
        case .ended: chrome.pointerLeft()
        }
      }
      .onAppear { chrome.pinned = pinned; chrome.activity() }
      .onChange(of: pinned) { _, value in chrome.pinned = value }
  }
}

private struct PlayerChromeFade: ViewModifier {
  let shown: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(y: shown || reduceMotion ? 0 : 6)
      .allowsHitTesting(shown)
      .animation(shown ? .easeOut(duration: 0.18) : .easeIn(duration: 0.3), value: shown)
  }
}

// MARK: - Panel

/// The glass control panel: `stageInset` (12pt) inside the stage's edges, never touching them,
/// `md` radius (the stage's 20 less the 12pt inset would leave 8, too tight for the 40pt play
/// button), always dark.
struct PlayerControlPanel<Content: View>: View {
  let chrome: PlayerChromeState
  @ViewBuilder var content: Content
  var body: some View {
    VStack(spacing: 6) { content }
      .padding(.horizontal, PlayerPanelLayout.padding).padding(.top, 8).padding(.bottom, 10)
      .foregroundStyle(.white)
      .glassEffect(.regular.tint(.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: PlayerPanelLayout.radius, style: .continuous))
      .environment(\.colorScheme, .dark)
      .onHover { chrome.setOverControls($0) }
      .padding(PlayerPanelLayout.inset)
  }
}

/// The panel's content row. What fits it is `PlayerBarLayout.fit` (设置 › 控制条): the comment
/// field shrinks to a button first, then the right group folds into 「更多」 from its left end.
struct PlayerPanelLayout: Equatable {
  /// The panel's distance from the stage's edges.
  static let inset: CGFloat = Theme.stageInset
  /// The panel's own horizontal padding around the row.
  static let padding: CGFloat = 12
  static let radius: CGFloat = Theme.Radius.md
  /// Width of the panel's content row.
  let width: CGFloat
  /// `stageWidth`: the stage as laid out now (the panel lives inside it).
  init(stageWidth: CGFloat) { width = stageWidth - Self.inset * 2 - Self.padding * 2 }
  /// The time readout goes last, only when even the folded row would not fit.
  var showsTime: Bool { width >= 400 }
}

extension View {
  /// Reports the stage's width so the panel can fold its optional controls.
  func reportsStageWidth(_ width: Binding<CGFloat>) -> some View {
    onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 }
  }
}

// MARK: - Buttons

/// The panel's main button: a 40pt mist disc with dark ink.
struct PlayerPlayButton: View {
  let paused: Bool
  var size: CGFloat = 40
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: size * 0.38, weight: .semibold))
        .offset(x: paused ? 1 : 0)
    }.buttonStyle(PlayerPrimaryButtonStyle(size: size))
      .help(paused ? "播放" : "暂停").accessibilityLabel(paused ? "播放" : "暂停")
  }
}

struct PlayerPrimaryButtonStyle: ButtonStyle {
  var size: CGFloat = 40
  func makeBody(configuration: Configuration) -> some View {
    PlayerPrimaryBody(configuration: configuration, size: size)
  }
}

private struct PlayerPrimaryBody: View {
  let configuration: ButtonStyleConfiguration
  let size: CGFloat
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false
  var body: some View {
    configuration.label
      .foregroundStyle(Theme.backdrop(.dark))
      .frame(width: size, height: size)
      .background(Circle().fill(Theme.mist.opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.78 : hovering ? 1 : 0.92)))
      .contentShape(Circle())
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value && isEnabled } }
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
  }
}

/// 弹幕开关: the brand's three-streak symbol, on an accent disc while comments show.
struct DanmakuToggleButton: View {
  @Binding var enabled: Bool
  var size: CGFloat = 32
  var openSettings: (() -> Void)? = nil
  var body: some View {
    Button { enabled.toggle() } label: {
      DanmakuSymbol().fill(.foreground).frame(width: 18, height: 18)
    }.buttonStyle(PlayerControlButtonStyle(size: size, active: enabled))
      .help(enabled ? "隐藏弹幕（⇧⌘D）" : "显示弹幕（⇧⌘D）")
      .accessibilityLabel("弹幕").accessibilityValue(enabled ? "显示" : "隐藏")
      .contextMenu {
        Button(enabled ? "隐藏弹幕" : "显示弹幕") { enabled.toggle() }
        if let openSettings { Button("弹幕设置…", action: openSettings) }
      }
  }
}

/// 「06:12 / 18:24」. Observes the clock on its own so only this text re-renders.
struct PlayerTimeLabel: View {
  @ObservedObject var clock: PlaybackClock
  let duration: Double
  var override: Double? = nil
  var body: some View {
    Text(PlaybackTimeline.format(override ?? clock.time) + " / " + PlaybackTimeline.format(duration))
      .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.86))
      .lineLimit(1).fixedSize()
  }
}


// MARK: - Menus and popovers

/// Speed choices plus the hold-to-speed reminder; used by the panel menu and, when folded, inside
/// the player settings menu.
struct PlayerSpeedItems: View {
  @ObservedObject var player: PlayerModel
  let holdSpeed: Double
  static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
  var body: some View {
    ForEach(Self.speeds, id: \.self) { speed in
      Toggle(Self.label(speed), isOn: Binding(get: { abs(player.speed - speed) < 0.001 }, set: { if $0 { player.setSpeed(speed) } }))
    }
    Divider()
    Text("按住画面临时 \(Self.label(holdSpeed))，松开恢复")
  }
  /// 1.0×, 1.25×, 0.75×: at least one decimal, two only when needed.
  static func label(_ value: Double) -> String {
    let hundredths = Int((value * 100).rounded())
    return (hundredths % 10 == 0 ? String(format: "%.1f", value) : String(format: "%.2f", value)) + "×"
  }
}

struct PlayerSpeedMenu: View {
  @ObservedObject var player: PlayerModel
  let holdSpeed: Double
  var body: some View {
    Menu { PlayerSpeedItems(player: player, holdSpeed: holdSpeed) } label: {
      Text(PlayerSpeedItems.label(player.speed)).font(.system(size: 12, weight: .semibold).monospacedDigit())
    }.playerMenuStyle().help("倍速").accessibilityLabel("倍速")
  }
}

/// 画质 and 编码 as two sections. Picking a quality keeps the current codec when that quality
/// offers it; picking a codec keeps the current quality.
struct PlayerQualityItems: View {
  let streams: [MediaStream]
  let selected: MediaStream?
  let choose: (MediaStream) -> Void
  var body: some View {
    let qualities = Self.qualities(streams)
    let current = selected ?? streams.first
    Section("画质") {
      ForEach(qualities, id: \.quality) { stream in
        Toggle(stream.label, isOn: Binding(get: { current?.quality == stream.quality }, set: { on in
          guard on else { return }
          choose(streams.first { $0.quality == stream.quality && $0.codec == current?.codec } ?? stream)
        }))
      }
    }
    let codecs = streams.filter { $0.quality == current?.quality }
    if codecs.count > 1 {
      Section("编码") {
        ForEach(codecs) { stream in
          Toggle(PlayerCodec.name(stream.codec), isOn: Binding(get: { current?.id == stream.id }, set: { if $0 { choose(stream) } }))
        }
      }
    }
  }
  /// One entry per quality, best first, in the order the manifest offers them.
  static func qualities(_ streams: [MediaStream]) -> [MediaStream] {
    var seen = Set<Int>()
    return streams.sorted { $0.quality > $1.quality }.filter { seen.insert($0.quality).inserted }
  }
}

struct PlayerQualityMenu: View {
  let streams: [MediaStream]
  let selected: MediaStream?
  let choose: (MediaStream) -> Void
  var body: some View {
    Menu { PlayerQualityItems(streams: streams, selected: selected, choose: choose) } label: {
      Text(selected?.label ?? "画质").font(.system(size: 12, weight: .semibold)).lineLimit(1)
    }.playerMenuStyle().disabled(streams.isEmpty)
      .help(selected.map { "画质：\($0.label) · \(PlayerCodec.name($0.codec))" } ?? "画质")
  }
}

enum PlayerCodec {
  /// Codec names as viewers know them; AV1 without a hardware decoder says so.
  static func name(_ codec: String) -> String {
    if codec.hasPrefix("avc") { return "H.264" }
    if codec.hasPrefix("hev") || codec.hasPrefix("hvc") { return "HEVC" }
    if codec.hasPrefix("av01") { return hardwareAV1 ? "AV1" : "AV1（软件解码）" }
    return codec.uppercased()
  }
  private static let hardwareAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
}

/// The volume button and its popover.
struct PlayerVolumeButton: View {
  @ObservedObject var player: PlayerModel
  let maximum: Double
  @Binding var shown: Bool
  var body: some View {
    Button { shown.toggle() } label: {
      Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }.buttonStyle(PlayerControlButtonStyle(size: 32)).help("音量").accessibilityLabel("音量")
      .accessibilityValue("\(Int(player.volume))%")
      .popover(isPresented: $shown, arrowEdge: .top) { PlayerVolumePanel(player: player, maximum: maximum) }
  }
}

private struct PlayerVolumePanel: View {
  @ObservedObject var player: PlayerModel
  let maximum: Double
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Text("音量").font(Theme.Font.caption)
        Spacer()
        Text("\(Int(player.volume))%").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText(scheme))
      }
      Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...max(1, maximum))
        .tint(Theme.accent).controlSize(.small).accessibilityLabel("音量")
      Button(player.volume == 0 ? "取消静音" : "静音") { player.setVolume(player.volume == 0 ? min(80, maximum) : 0) }
        .buttonStyle(AppButtonStyle(size: .small))
    }.padding(14).frame(width: 220).foregroundStyle(Theme.text(scheme))
  }
}

// MARK: - Control bar (设置 › 控制条)

/// The right group of the control bar, kept in `Manping.playerBarItems`. Every playback window
/// observes this one store, so a change in 设置 › 控制条 shows at once.
@MainActor final class PlayerBarStore: ObservableObject {
  static let shared = PlayerBarStore()
  @Published private(set) var items: [PlayerBarItem]
  private let defaults: UserDefaults

  init(defaults: UserDefaults? = nil) {
    let defaults = defaults ?? PerformanceEnvironment.defaults
    self.defaults = defaults
    items = Self.launchItems ?? PlayerBarLayout.decode(defaults.object(forKey: PlayerBarLayout.storageKey))
  }

  var isDefault: Bool { items == PlayerBarLayout.defaultItems }

  func set(_ items: [PlayerBarItem]) {
    guard items != self.items else { return }
    self.items = items
    defaults.set(PlayerBarLayout.encode(items), forKey: PlayerBarLayout.storageKey)
  }

  /// 恢复默认: forgets the stored list, so later default changes apply.
  func reset() {
    items = PlayerBarLayout.defaultItems
    defaults.removeObject(forKey: PlayerBarLayout.storageKey)
  }

  #if DEBUG
  /// `--ui-player-bar quality,speed,…` for screenshot checks: start with this bar instead of the
  /// stored one (edits still save).
  private static var launchItems: [PlayerBarItem]? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--ui-player-bar"), index + 1 < args.count else { return nil }
    return PlayerBarLayout.decode(args[index + 1].split(separator: ",").map(String.init))
  }
  #else
  private static let launchItems: [PlayerBarItem]? = nil
  #endif
}

#if DEBUG
/// `--ui-more-menu` (screenshot checks): clicks 「更多」 once, 3 s after it first lays out.
@MainActor enum PlayerBarDebug {
  private static let requested = ProcessInfo.processInfo.arguments.contains("--ui-more-menu")
  private static var scheduled = false
  private static var latest = CGRect.zero
  static func openMoreMenu(at newFrame: CGRect) {
    latest = newFrame
    guard requested, !scheduled, newFrame.width > 0 else { return }
    scheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      let frame = latest
      guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
        let content = window.contentView else { return }
      // `.global` is relative to the hosting view that draws the page, which may sit inside the window.
      func hosts(_ view: NSView) -> [NSView] {
        (String(describing: type(of: view)).contains("HostingView") ? [view] : []) + view.subviews.flatMap(hosts)
      }
      let host = hosts(content).filter { $0.bounds.width >= frame.maxX && $0.bounds.height >= frame.maxY }
        .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height } ?? content
      let local = NSPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY)
      let point = host.convert(local, to: nil)
      if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        window.sendEvent(down)
      }
    }
  }
}
#endif

/// An item's symbol on the bar and in 设置 › 控制条. 弹幕设置 is the app's danmaku mark with a gear
/// cut into its corner, so it reads apart from the 弹幕 switch.
struct PlayerBarGlyph: View {
  let item: PlayerBarItem
  var size: CGFloat = 13
  var body: some View {
    if item == .danmakuSettings {
      ZStack(alignment: .bottomTrailing) {
        DanmakuSymbol().fill(.foreground).frame(width: size * 1.35, height: size * 1.35)
        Circle().frame(width: size * 0.86, height: size * 0.86).offset(x: size * 0.2, y: size * 0.2)
          .blendMode(.destinationOut)
        Image(systemName: "gearshape.fill").font(.system(size: size * 0.62, weight: .bold))
          .frame(width: size * 0.86, height: size * 0.86).offset(x: size * 0.2, y: size * 0.2)
      }.compositingGroup().frame(width: size * 1.5, height: size * 1.5)
    } else {
      Image(systemName: item.symbol).font(.system(size: size, weight: .medium))
    }
  }
}

/// What a playback page puts on its control bar. Items outside `supported` are skipped and take
/// no room (a live room has no speed or subtitles); `slots` replaces the shared control and
/// 「更多」 entry where the data is the page's own (画质, 字幕, the live route).
struct PlayerBarPage {
  struct Slot {
    var control: () -> AnyView
    var menu: () -> AnyView
  }
  var supported: Set<PlayerBarItem> = Set(PlayerBarItem.allCases)
  var slots: [PlayerBarItem: Slot] = [:]
  /// Bar widths that differ from `PlayerBarLayout.Metrics`.
  var widths: [PlayerBarItem: Double] = [:]
  var downloadEnabled = true

  /// Live rooms: no speed, subtitles, shaders, audio-only or downloads.
  static let liveSupported = Set(PlayerBarItem.allCases).subtracting([.speed, .subtitle, .enhance, .audioOnly, .download])
}

extension PlayerBarPage.Slot {
  /// 画质 for videos and episodes: the text capsule, and 「画质 · 1080P」 in 「更多」.
  @MainActor static func quality(streams: [MediaStream], selected: MediaStream?, enabled: Bool = true,
    choose: @escaping (MediaStream) -> Void) -> Self {
    Self(control: {
      AnyView(PlayerQualityMenu(streams: streams, selected: selected, choose: choose).disabled(!enabled))
    }, menu: {
      AnyView(Menu {
        PlayerQualityItems(streams: streams, selected: selected, choose: choose)
      } label: {
        Label(selected.map { "画质 · \($0.label)" } ?? "画质", systemImage: PlayerBarItem.quality.symbol)
      }.disabled(streams.isEmpty || !enabled))
    })
  }

  /// 字幕 for videos and episodes.
  @MainActor static func subtitle(features: PlaybackFeaturesModel, player: PlayerModel, filterAI: Bool) -> Self {
    Self(control: {
      AnyView(PlaybackSubtitleMenu(features: features, player: player, filterAI: filterAI))
    }, menu: {
      AnyView(Menu {
        PlaybackSubtitleItems(features: features, player: player, filterAI: filterAI)
      } label: { Label("字幕", systemImage: PlayerBarItem.subtitle.symbol) })
    })
  }
}

/// The panel's button row: the page's fixed left group (播放、下一个、时间、弹幕开关), the comment
/// field, the viewer's right group as far as it fits, and 「更多」 on the far right. When the row is
/// short the comment field becomes a 「发弹幕」 button first, then the right group folds into
/// 「更多」 from its left end (`PlayerBarLayout.fit`, the same rule as the settings preview).
struct PlayerBarRow<Leading: View>: View {
  @ObservedObject var model: AppModel
  @ObservedObject var player: PlayerModel
  let layout: PlayerPanelLayout
  let page: PlayerBarPage
  var cdn: CDNController? = nil
  @Binding var danmakuShown: Bool
  @Binding var networkShown: Bool
  @Binding var volumeShown: Bool
  @Binding var composeShown: Bool
  /// The comment field; nil where there is none (live rooms).
  var input: (() -> AnyView)? = nil
  /// The page's own 「更多」 entries, after the items that are not on the bar.
  var extraMenu: () -> AnyView = { AnyView(EmptyView()) }
  @ViewBuilder var leading: () -> Leading
  @ObservedObject private var store = PlayerBarStore.shared
  @State private var leadingWidth: CGFloat = 220
  @State private var fullScreen = false
  private let metrics = PlayerBarLayout.Metrics()

  var body: some View {
    let items = store.items.filter { page.supported.contains($0) }
    let fit = PlayerBarLayout.fit(items, rowWidth: Double(layout.width), leadingWidth: Double(leadingWidth),
      hasInput: input != nil, metrics: metrics, width: { page.widths[$0] ?? metrics.width(of: $0) })
    HStack(spacing: 6) {
      HStack(spacing: 6) { leading() }.fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
      if let input {
        if fit.compactInput { composeButton(input) } else { input().padding(.leading, 2) }
      }
      Spacer(minLength: 6)
      ForEach(fit.visible, id: \.self) { item in control(item) }
      moreMenu(fit: fit, onBar: Set(items))
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PlayerBarDebug.openMoreMenu(at: $0) }
        #endif
    }
    .onAppear(perform: refreshFullScreen)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in refreshFullScreen() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in refreshFullScreen() }
  }

  private func refreshFullScreen() {
    let value = player.surface?.window?.styleMask.contains(.fullScreen) ?? false
    if value != fullScreen { fullScreen = value }
  }

  // MARK: Bar controls

  @ViewBuilder private func control(_ item: PlayerBarItem) -> some View {
    if let slot = page.slots[item] {
      slot.control()
    } else {
      switch item {
      case .quality, .subtitle: EmptyView()
      case .speed: PlayerSpeedMenu(player: player, holdSpeed: model.appSettings.number(.temporarySpeed))
      case .volume: PlayerVolumeButton(player: player, maximum: model.appSettings.number(.maxVolume), shown: $volumeShown)
      case .danmakuSettings:
        iconButton(item, help: "弹幕设置", active: false) { danmakuShown.toggle() }
          .popover(isPresented: $danmakuShown, arrowEdge: .top) { danmakuPopover }
      case .screenshot:
        iconButton(item, help: "截取画面（⇧⌘S）") { model.takePlayerScreenshot() }.disabled(!model.canTakeScreenshot)
      case .network:
        Button { networkShown.toggle() } label: {
          PlayerBarGlyph(item: item).overlay(alignment: .topTrailing) {
            if let cdn { CDNHealthDot(cdn: cdn).offset(x: 6, y: -4) }
          }
        }.buttonStyle(PlayerControlButtonStyle(size: 32)).help("网络与节点").accessibilityLabel("网络与节点")
          .popover(isPresented: cdn == nil ? .constant(false) : $networkShown, arrowEdge: .top) { networkPanel }
      case .enhance:
        Menu { PlayerShaderItems(model: model) } label: { PlayerBarGlyph(item: item) }
          .menuStyle(.button).buttonStyle(PlayerControlButtonStyle(size: 32, active: !model.shaderSelections.isEmpty))
          .menuIndicator(.hidden).fixedSize().help("画面增强").accessibilityLabel("画面增强")
      case .audioOnly:
        iconButton(item, help: player.audioOnly ? "恢复画面" : "只听声音", active: player.audioOnly) {
          player.setAudioOnly(!player.audioOnly)
        }.accessibilityValue(player.audioOnly ? "开" : "关")
      case .download:
        iconButton(item, help: "下载…") { model.enqueueDownload() }.disabled(!page.downloadEnabled)
      case .mini:
        iconButton(item, help: "小窗（⇧⌘P）") { model.toggleCompactPlayer() }
      case .detached:
        Button { model.togglePlaybackWindow() } label: {
          Image(systemName: model.playbackDetached ? "macwindow" : "macwindow.on.rectangle")
        }.buttonStyle(PlayerControlButtonStyle(size: 32))
          .help(model.playbackDetached ? "回到主窗口（⌥⌘P）" : "在独立窗口播放（⌥⌘P）")
          .accessibilityLabel(model.playbackDetached ? "回到主窗口" : "在独立窗口播放")
      case .fullscreen:
        Button { model.togglePlayerFullScreen() } label: {
          Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }.buttonStyle(PlayerControlButtonStyle(size: 32))
          .help(fullScreen ? "退出全屏幕（⌃⌘F）" : "进入全屏幕（⌃⌘F）").accessibilityLabel(fullScreen ? "退出全屏幕" : "进入全屏幕")
      }
    }
  }

  private func iconButton(_ item: PlayerBarItem, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) { PlayerBarGlyph(item: item) }
      .buttonStyle(PlayerControlButtonStyle(size: 32, active: active)).help(help).accessibilityLabel(item.title)
  }

  /// 「发弹幕」: the comment field once the row is too short for it; it opens above the button.
  private func composeButton(_ input: @escaping () -> AnyView) -> some View {
    Button { composeShown.toggle() } label: { Image(systemName: "pencil.line") }
      .buttonStyle(PlayerControlButtonStyle(size: 32, prominent: true)).help("发弹幕").accessibilityLabel("发弹幕")
      .popover(isPresented: $composeShown, arrowEdge: .top) {
        input().frame(width: 300).padding(12).preferredColorScheme(.dark)
      }
  }

  private var danmakuPopover: some View {
    DanmakuSettingsPopover(settings: model.settingsModel, player: player, openMore: {
      danmakuShown = false
      model.openSettings(.danmaku)
    }, openPowerSettings: {
      danmakuShown = false
      model.openSettings(.playback)
    })
  }

  @ViewBuilder private var networkPanel: some View {
    if let cdn {
      CDNPanel(cdn: cdn, setSetting: { key, value in model.settingsModel.set(key, .bool(value)) },
        setProxyRoute: model.setProxyMediaRoute)
    }
  }

  // MARK: 「更多」

  /// Three parts: the items folded off the bar (each keeps its submenu), the other functions that
  /// are not on the bar, then 「自定义控制条…」. Popovers whose button is not on the bar open here.
  private func moreMenu(fit: PlayerBarFit, onBar: Set<PlayerBarItem>) -> some View {
    let offBar = PlayerBarItem.allCases.filter { page.supported.contains($0) && !onBar.contains($0) }
    let visible = Set(fit.visible)
    let folded = fit.hidden.count
    return Menu {
      PowerSavingStatusItem()
      if !fit.hidden.isEmpty {
        Section("已收起") {
          ForEach(fit.hidden, id: \.self) { menuEntry($0) }
        }
        Divider()
      }
      ForEach(offBar, id: \.self) { menuEntry($0) }
      extraMenu()
      PowerSavingMenu(settings: model.settingsModel) { model.openSettings(.playback) }
      Divider()
      Button { model.openPlayerBarSettings() } label: { Label("自定义控制条…", systemImage: "pencil.line") }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
        .frame(width: 32, height: 32)
        .overlay(alignment: .topTrailing) {
          if folded > 0 {
            Text("\(folded)").font(.system(size: 9, weight: .heavy).monospacedDigit()).foregroundStyle(Theme.onAccent)
              .padding(.horizontal, 3).frame(minWidth: 15, minHeight: 15).background(Capsule().fill(Theme.accent))
              .offset(x: 3, y: -2).transition(.scale.combined(with: .opacity))
          }
        }
        .overlay(alignment: .topLeading) {
          if let cdn, !visible.contains(.network) { CDNHealthDot(cdn: cdn).offset(x: 4, y: 3) }
        }
    }
    .menuStyle(.button).buttonStyle(PlayerControlButtonStyle(size: 32)).menuIndicator(.hidden).fixedSize()
    .help(folded > 0 ? "更多（已收起 \(folded) 项）" : "更多")
    .accessibilityLabel("更多").accessibilityValue(folded > 0 ? "已收起 \(folded) 项" : "")
    .animation(.snappy(duration: 0.2), value: folded)
    .popover(isPresented: Self.gated($danmakuShown, !visible.contains(.danmakuSettings)), arrowEdge: .top) { danmakuPopover }
    .background {
      if cdn != nil {
        Color.clear.popover(isPresented: Self.gated($networkShown, !visible.contains(.network)), arrowEdge: .top) { networkPanel }
      }
    }
  }

  /// A popover binding that only this anchor presents (the other anchor is on the bar).
  private static func gated(_ binding: Binding<Bool>, _ active: Bool) -> Binding<Bool> {
    Binding(get: { active && binding.wrappedValue }, set: { binding.wrappedValue = $0 })
  }

  @ViewBuilder private func menuEntry(_ item: PlayerBarItem) -> some View {
    if let slot = page.slots[item] {
      slot.menu()
    } else {
      switch item {
      case .quality, .subtitle: EmptyView()
      case .speed:
        Menu { PlayerSpeedItems(player: player, holdSpeed: model.appSettings.number(.temporarySpeed)) } label: {
          Label("倍速 · " + PlayerSpeedItems.label(player.speed), systemImage: item.symbol)
        }
      case .volume:
        Menu { volumeItems } label: { Label("音量 · \(Int(player.volume))%", systemImage: item.symbol) }
      case .danmakuSettings:
        Button { danmakuShown = true } label: { Label("弹幕设置…", systemImage: item.symbol) }
      case .screenshot:
        Button { model.takePlayerScreenshot() } label: { Label("截取画面", systemImage: item.symbol) }
          .disabled(!model.canTakeScreenshot)
      case .network:
        Button { networkShown = true } label: { Label("网络与节点…", systemImage: item.symbol) }.disabled(cdn == nil)
      case .enhance:
        Menu { PlayerShaderItems(model: model) } label: { Label("画面增强", systemImage: item.symbol) }
      case .audioOnly:
        Toggle(isOn: Binding(get: { player.audioOnly }, set: { player.setAudioOnly($0) })) {
          Label("只听声音", systemImage: item.symbol)
        }
      case .download:
        Button { model.enqueueDownload() } label: { Label("下载…", systemImage: item.symbol) }.disabled(!page.downloadEnabled)
      case .mini:
        Button { model.toggleCompactPlayer() } label: { Label("小窗", systemImage: item.symbol) }
      case .detached:
        Button { model.togglePlaybackWindow() } label: {
          Label(model.playbackDetached ? "回到主窗口" : "在独立窗口播放", systemImage: item.symbol)
        }
      case .fullscreen:
        Button { model.togglePlayerFullScreen() } label: {
          Label(fullScreen ? "退出全屏幕" : "进入全屏幕", systemImage: fullScreen ? "arrow.down.right.and.arrow.up.left" : item.symbol)
        }
      }
    }
  }

  /// 音量 in 「更多」: mute and a few levels (the slider needs the button on the bar).
  @ViewBuilder private var volumeItems: some View {
    let maximum = max(1, model.appSettings.number(.maxVolume))
    Toggle("静音", isOn: Binding(get: { player.volume == 0 }, set: { player.setVolume($0 ? 0 : min(80, maximum)) }))
    Divider()
    ForEach(([25.0, 50, 75, 100] + (maximum > 100 ? [maximum] : [])).filter { $0 <= maximum }, id: \.self) { level in
      Toggle("\(Int(level))%", isOn: Binding(get: { abs(player.volume - level) < 0.5 }, set: { if $0 { player.setVolume(level) } }))
    }
  }
}

/// The families and 全部关闭, for 「更多」 and the 画面增强 button on the bar.
struct PlayerShaderItems: View {
  @ObservedObject var model: AppModel
  var body: some View {
    Group {
      ForEach(ShaderCatalog.families, id: \.self) { family in
        Menu(family) {
          Toggle("关闭", isOn: Binding(get: { model.shaderSelections[family] == nil }, set: { on in
            guard on else { return }
            model.shaderSelections[family] = nil; model.applyShaders()
          }))
          ForEach(ShaderCatalog.presets.filter { $0.family == family }) { preset in
            Toggle(preset.name + (preset.unavailable ? "（此 Mac 暂不支持）" : ""), isOn: Binding(
              get: { model.shaderSelections[family] == preset.name },
              set: { on in
                guard on else { return }
                model.shaderSelections[family] = preset.name; model.applyShaders()
              })).disabled(preset.unavailable)
          }
        }
      }
      Divider()
      Button("全部关闭") { model.shaderSelections = [:]; model.applyShaders() }.disabled(model.shaderSelections.isEmpty)
    }
  }
}

// MARK: - Errors

/// Engine errors ("mpv loadfile failed: -13") go to the log; viewers get one sentence and 「重试」.
/// Messages the app already wrote for people (Chinese text) are shown as they are.
enum PlayerErrorText {
  private static let log = Logger(subsystem: "io.github.pidean.manping", category: "player")
  static func isForPeople(_ raw: String) -> Bool { raw.range(of: "\\p{Han}", options: .regularExpression) != nil }
  static func title(_ raw: String) -> String { isForPeople(raw) ? raw : "这个视频没能开始播放" }
  static func detail(_ raw: String) -> String? { isForPeople(raw) ? nil : "可以重试，或在 播放器设置 › 网络与节点 中换一个节点。" }
  static func record(_ raw: String) {
    log.error("playback error: \(DiagnosticRedactor.sanitize(raw), privacy: .public)")
  }
}

// MARK: - Toolbar

/// Playback preferences kept outside the settings catalog.
enum PlayerPreferences {
  /// 显示 / 隐藏右侧栏 on the playback pages, kept across launches.
  static let sidebarHiddenKey = "Manping.playerSidebarHidden"
}

/// The playback pages' last toolbar controls, after their own (分享…): 在独立窗口播放 and
/// 显示 / 隐藏右侧栏, drawn as cells of the page's `ToolbarIconGroup`. The pages put them in
/// `.pageToolbar(accessory:)`; 返回 / 前进 belong to the main window's toolbar, and the standalone
/// window draws the same toolbar without them.
struct PlayerToolbarActions: View {
  @ObservedObject var model: AppModel
  @Binding var sidebarHidden: Bool
  /// Live rooms keep 在独立窗口播放 in their settings menu only.
  var windowToggle = true
  var body: some View {
    if windowToggle {
      Button { model.togglePlaybackWindow() } label: {
        ToolbarGroupIcon(model.playbackDetached ? "macwindow" : "macwindow.on.rectangle")
      }.help(model.playbackDetached ? "回到主窗口" : "在独立窗口播放")
        .accessibilityLabel(model.playbackDetached ? "回到主窗口" : "在独立窗口播放")
    }
    Button { withAnimation(.snappy(duration: 0.25)) { sidebarHidden.toggle() } } label: { ToolbarGroupIcon("sidebar.right") }
      .help(sidebarHidden ? "显示右侧栏" : "隐藏右侧栏").accessibilityLabel(sidebarHidden ? "显示右侧栏" : "隐藏右侧栏")
  }
}

/// A share cell for a page's toolbar `ToolbarIconGroup`.
struct ToolbarShareButton: View {
  let url: URL
  var body: some View {
    ShareLink(item: url) { ToolbarGroupIcon("square.and.arrow.up") }.help("分享").accessibilityLabel("分享")
  }
}

// MARK: - Side panel

/// 点赞 / 投币 / 收藏 / 三连: glass squares with the figure under the symbol.
struct GlassTileButtonStyle: ButtonStyle {
  var selected = false
  func makeBody(configuration: Configuration) -> some View {
    GlassTileBody(configuration: configuration, selected: selected)
  }
}

private struct GlassTileBody: View {
  let configuration: ButtonStyleConfiguration
  let selected: Bool
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous) }
  var body: some View {
    configuration.label
      .foregroundStyle(!isEnabled ? Theme.disabledText(scheme) : selected ? Theme.accentText(scheme) : Theme.text(scheme))
      .frame(maxWidth: .infinity).frame(height: 58)
      .background(shape.fill(isEnabled ? Color.clear : Theme.fill(scheme)))
      .glassEffect(!isEnabled ? .identity : selected ? .regular.tint(Theme.accent.opacity(0.22)).interactive() : .regular.interactive(), in: shape)
      .contentShape(shape)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
      .environment(\.glassTileSelected, selected)
  }
}

private extension EnvironmentValues {
  @Entry var glassTileSelected = false
}

/// Symbol over a figure, the content of a `GlassTileButtonStyle` button. Until the action is
/// active the symbol is the primary colour at 70% and the figure the secondary colour; an active
/// one keeps the accent on both.
struct GlassTileLabel: View {
  let symbol: String
  let value: String
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.glassTileSelected) private var selected
  var body: some View {
    let resting = isEnabled && !selected
    VStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 16, weight: .medium))
        .opacity(resting ? 0.7 : 1)
      Text(value).font(Theme.Font.caption2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
        .foregroundStyle(resting ? Theme.secondaryText(scheme) : (isEnabled ? Theme.accentText(scheme) : Theme.disabledText(scheme)))
    }
  }
}

// MARK: - 省电模式

/// The disabled first line of 「更多」 while playback saves power (「正在省电 · 用电池」), with a
/// divider under it; nothing otherwise.
private struct PowerSavingStatusItem: View {
  @ObservedObject private var power = PowerState.shared
  var body: some View {
    if let status = power.menuStatus {
      Button(status) {}.disabled(true)
      Divider()
    }
  }
}

/// 「更多」 › 省电模式: 自动 / 始终 / 关闭, then 「省电设置…」 (设置 › 播放). The choice is written
/// through `M7SettingsModel`, so every window and the settings page follow it.
private struct PowerSavingMenu: View {
  let settings: M7SettingsModel
  let openSettings: () -> Void
  @ObservedObject private var power = PowerState.shared
  var body: some View {
    Menu {
      Picker("省电模式", selection: Binding(
        get: { power.preferences.mode },
        set: { settings.set(.powerSavingMode, .text($0.rawValue)) })) {
        ForEach(PowerSavingMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.inline).labelsHidden()
      Divider()
      Button("省电设置…", action: openSettings)
    } label: {
      Label("省电模式", systemImage: "leaf")
    }
  }
}
