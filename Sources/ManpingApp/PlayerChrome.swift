import AppKit
import ManpingCore
import OSLog
import SwiftUI
import VideoToolbox

// The playback chrome shared by the video, episode and live pages (DesignSystem.md §11): a
// Liquid Glass control panel inset 16pt from the bottom of the picture that hides itself, its
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

/// The glass control panel: 16pt from the picture's edges, `lg` radius, always dark.
struct PlayerControlPanel<Content: View>: View {
  let chrome: PlayerChromeState
  @ViewBuilder var content: Content
  var body: some View {
    VStack(spacing: 6) { content }
      .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
      .foregroundStyle(.white)
      .glassEffect(.regular.tint(.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
      .environment(\.colorScheme, .dark)
      .onHover { chrome.setOverControls($0) }
      .padding(16)
  }
}

/// Which optional controls fit the panel. Below 640pt they fold away in a fixed order — comment
/// field, subtitles, speed, quality — and the folded ones move into the player settings menu.
struct PlayerPanelLayout: Equatable {
  /// Width of the panel's content row.
  let width: CGFloat
  init(pictureWidth: CGFloat) { width = pictureWidth - 32 - 24 }
  var showsDanmakuInput: Bool { width >= 616 }
  var showsSubtitles: Bool { width >= 566 }
  var showsSpeed: Bool { width >= 516 }
  var showsQuality: Bool { width >= 456 }
  /// The time readout goes last, only when even the folded row would not fit.
  var showsTime: Bool { width >= 400 }
}

extension View {
  /// Reports the picture's width so the panel can fold its optional controls.
  func reportsPictureWidth(_ width: Binding<CGFloat>) -> some View {
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

/// Mini window and full screen. The full-screen button follows the window the picture is in.
struct PlayerWindowButtons: View {
  let model: AppModel
  let player: PlayerModel
  @State private var fullScreen = false
  var body: some View {
    Button { model.toggleCompactPlayer() } label: { Image(systemName: "pip.enter") }
      .buttonStyle(PlayerControlButtonStyle(size: 32)).help("小窗（⇧⌘P）").accessibilityLabel("小窗")
    Button { model.togglePlayerFullScreen() } label: {
      Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
    }.buttonStyle(PlayerControlButtonStyle(size: 32))
      .help(fullScreen ? "退出全屏幕" : "进入全屏幕").accessibilityLabel(fullScreen ? "退出全屏幕" : "进入全屏幕")
      .onAppear(perform: refresh)
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in refresh() }
  }
  private func refresh() {
    let value = player.surface?.window?.styleMask.contains(.fullScreen) ?? false
    if value != fullScreen { fullScreen = value }
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

/// 播放器设置: a menu whose items each page supplies, the danmaku settings popover and, for
/// videos and episodes, 「网络与节点…」 (the CDN panel). A dot on the button reports a low
/// forward buffer.
struct PlayerSettingsMenu<Items: View>: View {
  let player: PlayerModel
  let settings: M7SettingsModel
  var cdn: CDNController? = nil
  var setCDNSetting: (MacSettingKey, Bool) -> Void = { _, _ in }
  var setProxyRoute: (MediaRoute) -> Void = { _ in }
  @Binding var danmakuShown: Bool
  @Binding var networkShown: Bool
  /// 「更多弹幕设置…」: opens the settings window on 弹幕.
  var openDanmakuSettings: () -> Void
  @ViewBuilder var items: () -> Items
  var body: some View {
    Menu { items() } label: {
      Image(systemName: "slider.horizontal.3")
        .overlay(alignment: .topTrailing) { if let cdn { CDNHealthDot(cdn: cdn).offset(x: 5, y: -4) } }
    }
    .menuStyle(.button).buttonStyle(PlayerControlButtonStyle(size: 32)).menuIndicator(.hidden).fixedSize()
    .help("播放器设置").accessibilityLabel("播放器设置")
    .popover(isPresented: $danmakuShown, arrowEdge: .top) {
      DanmakuSettingsPopover(settings: settings, player: player) {
        danmakuShown = false
        openDanmakuSettings()
      }
    }
    .background {
      if let cdn {
        Color.clear.popover(isPresented: $networkShown, arrowEdge: .top) {
          CDNPanel(cdn: cdn, setSetting: setCDNSetting, setProxyRoute: setProxyRoute)
        }
      }
    }
  }
}

/// 画面增强 ▸ family ▸ 关闭 / presets. Presets this Mac cannot run stay listed but disabled.
struct PlayerShaderMenu: View {
  @ObservedObject var model: AppModel
  var body: some View {
    Menu("画面增强") {
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
/// 显示 / 隐藏右侧栏. The pages put them in `.pageToolbar(accessory:)`; 返回 / 前进 belong to the
/// main window's toolbar, and the standalone window draws the same toolbar without them.
struct PlayerToolbarActions: View {
  @ObservedObject var model: AppModel
  @Binding var sidebarHidden: Bool
  /// Live rooms keep 在独立窗口播放 in their settings menu only.
  var windowToggle = true
  var body: some View {
    HStack(spacing: 8) {
      if windowToggle {
        Button { model.togglePlaybackWindow() } label: {
          Image(systemName: model.playbackDetached ? "macwindow" : "macwindow.on.rectangle")
        }.buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true))
          .help(model.playbackDetached ? "回到主窗口" : "在独立窗口播放")
          .accessibilityLabel(model.playbackDetached ? "回到主窗口" : "在独立窗口播放")
      }
      Button { withAnimation(.snappy(duration: 0.25)) { sidebarHidden.toggle() } } label: { Image(systemName: "sidebar.right") }
        .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true))
        .help(sidebarHidden ? "显示右侧栏" : "隐藏右侧栏").accessibilityLabel(sidebarHidden ? "显示右侧栏" : "隐藏右侧栏")
    }
  }
}

/// A plain share button for a page's toolbar.
struct ToolbarShareButton: View {
  let url: URL
  var body: some View {
    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
      .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("分享").accessibilityLabel("分享")
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
  }
}

/// Symbol over a figure, the content of a `GlassTileButtonStyle` button.
struct GlassTileLabel: View {
  let symbol: String
  let value: String
  var body: some View {
    VStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 16, weight: .medium))
      Text(value).font(Theme.Font.caption2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
    }
  }
}
