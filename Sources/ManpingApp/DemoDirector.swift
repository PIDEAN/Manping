#if DEBUG
import AppKit
import Combine
import Foundation
import ManpingCore
import QuartzCore
import SwiftUI

/// Debug-only: the README animations' director (docs/media/README.md). With `--ui-fixture` and
/// `MANPING_DEMO_SCENE=<scene>` the app plays one scripted scene on its offline samples: it
/// navigates, opens panels and the mini window, and sets the hover states the pointer would cause
/// (through `DemoStage.signals`, never through synthetic mouse or keyboard events). Every step is
/// written to `MANPING_DEMO_OUT/events.json` with its time and the screen position of what it
/// points at, so the composition can draw the pointer, clicks and captions over the recording
/// (docs/media/record.swift). `MANPING_DEMO_MEDIA` is a local video file played instead of the
/// samples' still covers, with synthetic danmaku. Nothing here exists in Release builds.
enum DemoConfig {
  static let environment = ProcessInfo.processInfo.environment
  static let scene: String? = environment["MANPING_DEMO_SCENE"]
  static let output: URL? = environment["MANPING_DEMO_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
  static let media: URL? = environment["MANPING_DEMO_MEDIA"].map { URL(fileURLWithPath: $0) }
    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
  /// `MANPING_DEMO_ASSETS` (docs/media/fetch_assets.py): CC0 photos the samples' covers and avatars
  /// show instead of their drawn placeholders, `covers/<n>.jpg` and `avatars/<n>.jpg`.
  static let assets: URL? = environment["MANPING_DEMO_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
  @MainActor private static var photos: [String: NSImage] = [:]
  @MainActor static func photo(_ index: Int, avatar: Bool) -> NSImage? {
    guard DebugUIFixtures.enabled, let assets else { return nil }
    let folder = avatar ? "avatars" : "covers"
    let count = (try? FileManager.default.contentsOfDirectory(atPath: assets.appendingPathComponent(folder).path))?
      .filter { $0.hasSuffix(".jpg") }.count ?? 0
    guard count > 0 else { return nil }
    let name = "\(folder)/\(abs(index) % count).jpg"
    if let photo = photos[name] { return photo }
    let photo = NSImage(contentsOf: assets.appendingPathComponent(name))
    photos[name] = photo
    return photo
  }
  /// Only over the offline samples: a scene never shows an account or online content.
  static var active: Bool { scene != nil && output != nil && DebugUIFixtures.enabled }
  /// Scenes on a playing video or live room load the local file into the real player.
  static var playsLocalMedia: Bool { active && media != nil && ["hero", "danmaku", "mini", "live", "ai"].contains(scene ?? "") }

  /// Synthetic danmaku (list.so XML) for the local file: made-up lines, a few top, bottom and
  /// coloured ones, two a second over the 70 s video.
  static func danmakuXML() -> Data? {
    guard playsLocalMedia else { return nil }
    // Each line names one thing the app does, so the README's danmaku double as its feature list.
    let lines = [
      "Metal 渲染弹幕，跟着屏幕刷新率走", "120Hz 下弹幕一点都不抖", "先描边再填充，白底画面也看得清", "同一行弹幕绝不重叠",
      "显示区域、字号、速度随时调", "关键词和正则都能屏蔽", "同步你在 B 站设的屏蔽词", "⇧⌘D 一键开关弹幕",
      "mpv + VideoToolbox 硬件解码", "8K、杜比视界、HDR10 都能放", "进度条按官方章节分段", "悬停进度条看预览和章节名",
      "琥珀色曲线就是高能进度", "按住画面临时倍速", "⇧⌘P 小窗，边看边干活", "小窗拖到哪个角就吸在哪个角",
      "⌃⌘F 沉浸全屏，只剩画面", "控制条图标可以自由排", "Anime4K、FSRCNNX 画面增强", "番剧自动跳过片头片尾",
      "合集和收藏夹连续播放", "节点测速，卡了自动换线", "支持 HTTP、SOCKS5 和 Shadowsocks", "AI 一键总结章节",
      "只看 3 分钟：挑出最值得看的片段", "AI 回答里的时间点一点就跳", "29 个 AI 服务任你选", "Apple 智能可以完全本机处理",
      "直播里发弹幕、点赞、送背包礼物", "纯享模式：一键关掉所有特效", "付费礼物默认锁定，送前再确认", "醒目留言按金额配色",
      "登录信息本地加密，不进钥匙串", "没配置 AI 就不会发送任何内容", "控制中心和媒体键都能用", "聚焦搜索能找到看过的视频",
      "⌘L 直接打开 B 站链接", "实况文本：暂停后选取画面文字", "原生 SwiftUI，为 Mac 而做", "满屏，开源免费",
    ]
    let colors: [UInt32] = [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0x6FD0F5, 0xFFB13B, 0xFF4F95]
    var body = #"<?xml version="1.0" encoding="UTF-8"?><i>"#
    // Two a second: denser danmaku would make every GIF frame change across the whole picture.
    for index in 0..<140 {
      let time = Double(index) / 2 + Double(index % 5) * 0.07
      let mode = index % 23 == 7 ? 5 : index % 31 == 11 ? 4 : 1
      let color = mode == 1 ? colors[index % colors.count] : 0xFFB13B
      body += #"<d p="\#(String(format: "%.2f", time)),\#(mode),25,\#(color),1760000000,0,demo\#(index),\#(index),5">\#(lines[(index * 7) % lines.count])</d>"#
    }
    return Data((body + "</i>").utf8)
  }
}

/// What a scene changes in views that normally react to the pointer.
enum DemoSignal {
  /// The pointer moved over the player: its controls come in (and fade after the idle delay).
  case playerActivity
  /// Hover on the progress bar at this fraction, or none.
  case seekHover(Double?)
  /// The pointer is at this point of the main window (SwiftUI global coordinates), or gone.
  case hoverPoint(CGPoint?)
  case danmakuPanel(Bool)
  case danmakuAppearance(fontSize: Double?, area: Double?)
  case miniActivity
  /// The reader scrolled the live chat up a little.
  case chatScrollUp
  /// The video page's side panel shows the tab with this title.
  case videoSection(String)
}

@MainActor enum DemoStage {
  static let signals = PassthroughSubject<DemoSignal, Never>()
}

// MARK: - Anchors

/// The controls a scene points at. A view marked `.demoAnchor(id)` registers its backing NSView;
/// the director reads that view's on-screen frame at the moment it points, so the drawn pointer
/// lands exactly on the control in the recording (popovers and other windows included).
@MainActor enum DemoAnchors {
  private final class Entry { weak var view: NSView? }
  private static var entries: [String: [Entry]] = [:]

  static func register(_ view: NSView, as id: String, replacing old: String? = nil) {
    if let old { entries[old]?.removeAll { $0.view == nil || $0.view === view } }
    entries[id, default: []].removeAll { $0.view == nil || $0.view === view }
    let entry = Entry()
    entry.view = view
    entries[id, default: []].append(entry)
  }

  /// Registered ids that start with `prefix` and are on screen now.
  static func ids(prefix: String) -> [String] { entries.keys.filter { $0.hasPrefix(prefix) && frame($0) != nil }.sorted() }

  /// Global points with a top-left origin (as CGWindowList) of the largest visible instance.
  static func frame(_ id: String) -> CGRect? {
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    return (entries[id] ?? []).compactMap { entry -> CGRect? in
      guard let view = entry.view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
        !view.visibleRect.isEmpty else { return nil }
      let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
      guard rect.width > 1, rect.height > 1 else { return nil }
      return CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
    }.max { $0.width * $0.height < $1.width * $1.height }
  }
}

private struct DemoAnchorView: NSViewRepresentable {
  let id: String
  func makeNSView(context: Context) -> DemoAnchorNSView {
    let view = DemoAnchorNSView()
    view.id = id
    return view
  }
  func updateNSView(_ view: DemoAnchorNSView, context: Context) { view.id = id }
}

final class DemoAnchorNSView: NSView {
  var id = "" {
    didSet { if window != nil, id != oldValue { DemoAnchors.register(self, as: id, replacing: oldValue) } }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { DemoAnchors.register(self, as: id) }
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
  /// Names this control for the README director (docs/media/README.md). Does nothing outside a scene.
  @ViewBuilder func demoAnchor(_ id: String) -> some View {
    if DemoConfig.active { background(DemoAnchorView(id: id)) } else { self }
  }
}

// MARK: - View hooks (each one line at its view, inside `#if DEBUG`)

/// Card hover (`cardHover()`): lifts the card under the director's pointer.
struct DemoHoverProbe: ViewModifier {
  @Binding var hovering: Bool
  @State private var frame = CGRect.zero
  @ViewBuilder func body(content: Content) -> some View {
    if DemoConfig.active {
      content
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onReceive(DemoStage.signals) { signal in
          guard case .hoverPoint(let point) = signal else { return }
          let inside = point.map(frame.contains) ?? false
          if inside != hovering { withAnimation(.easeOut(duration: 0.16)) { hovering = inside } }
        }
    } else { content }
  }
}

/// The video page's player: controls and the danmaku panel.
struct DemoPlayerHooks: ViewModifier {
  let chrome: PlayerChromeState
  @Binding var danmakuShown: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if DemoConfig.active {
      content.onReceive(DemoStage.signals) { signal in
        switch signal {
        case .playerActivity: chrome.activity()
        case .danmakuPanel(let shown): danmakuShown = shown
        default: break
        }
      }
    } else { content }
  }
}

/// The progress bar's hover preview.
struct DemoSeekHover: ViewModifier {
  @Binding var fraction: Double?
  @ViewBuilder func body(content: Content) -> some View {
    if DemoConfig.active {
      content.onReceive(DemoStage.signals) { signal in
        if case .seekHover(let value) = signal { fraction = value }
      }
    } else { content }
  }
}

/// The danmaku panel's sliders and display area.
struct DemoDanmakuAppearance: ViewModifier {
  let apply: (Double?, Double?) -> Void
  @ViewBuilder func body(content: Content) -> some View {
    if DemoConfig.active {
      content.onReceive(DemoStage.signals) { signal in
        if case .danmakuAppearance(let size, let area) = signal { apply(size, area) }
      }
    } else { content }
  }
}

/// The mini window's controls.
struct DemoMiniHooks: ViewModifier {
  let chrome: PlayerChromeState
  @ViewBuilder func body(content: Content) -> some View {
    if DemoConfig.active {
      content.onReceive(DemoStage.signals) { signal in
        if case .miniActivity = signal { chrome.activity() }
      }
    } else { content }
  }
}

/// The live chat list.
struct DemoChatScroll: ViewModifier {
  let scrollUp: () -> Void
  @ViewBuilder func body(content: Content) -> some View {
    if DemoConfig.active {
      content.onReceive(DemoStage.signals) { signal in
        if case .chatScrollUp = signal { scrollUp() }
      }
    } else { content }
  }
}

/// The video page's side tabs (简介, 评论, AI…).
struct DemoVideoSection: ViewModifier {
  let select: (String) -> Void
  @ViewBuilder func body(content: Content) -> some View {
    if DemoConfig.active {
      content.onReceive(DemoStage.signals) { signal in
        if case .videoSection(let title) = signal { select(title) }
      }
    } else { content }
  }
}

// MARK: - Director

@MainActor final class DemoDirector {
  private static var started = false

  /// Called once the main window shows its content.
  static func startIfRequested(model: AppModel) {
    guard DemoConfig.active, !started, let scene = DemoConfig.scene, let output = DemoConfig.output else { return }
    started = true
    let director = DemoDirector(model: model, scene: scene, output: output)
    Task { await director.run() }
  }

  private let model: AppModel
  private let scene: String
  private let output: URL
  private var origin: CFTimeInterval = 0
  private var events: [[String: Any]] = []
  private var notes: [String] = []
  /// Where the drawn pointer is (global points, top-left origin).
  private var pointer: CGPoint?
  private var keepIgnoringMouse: Task<Void, Never>?

  private init(model: AppModel, scene: String, output: URL) {
    self.model = model; self.scene = scene; self.output = output
  }

  private var mainWindow: NSWindow? { (NSApp.delegate as? AppDelegate)?.window }

  private func run() async {
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    do {
      try await wait(20) { self.model.fixtureReady && self.mainWindow != nil }
      guard let window = mainWindow else { throw Failure.missing("main window") }
      ignoreRealPointer()
      try await prepare()
      await pause(1.5)
      try write(["pid": Int(ProcessInfo.processInfo.processIdentifier), "main": window.windowNumber, "scene": scene], to: "ready.json")
      // The recorder starts capturing every window of this process, then answers with `go`.
      let go = output.appendingPathComponent("go")
      try await wait(60) { FileManager.default.fileExists(atPath: go.path) }
      origin = CACurrentMediaTime()
      try await perform()
    } catch {
      notes.append("FAIL \(error)")
    }
    keepIgnoringMouse?.cancel()
    let report: [String: Any] = ["scene": scene, "origin": origin, "duration": elapsed, "events": events, "notes": notes]
    try? write(report, to: "events.json")
    try? Data().write(to: output.appendingPathComponent("done"))
  }

  enum Failure: Error { case timedOut(String), missing(String) }

  // MARK: Scenes

  /// Set-up before recording starts.
  private func prepare() async throws {
    // Video scenes start with the right panel folded, the live room with its chat shown (it is the
    // viewer's last choice otherwise).
    PerformanceEnvironment.defaults.set(scene != "live", forKey: PlayerPreferences.sidebarHiddenKey)
    switch scene {
    case "hero", "live", "settings": break
    case "danmaku", "ai":
      try await openSampleVideo()
      model.player.setDanmakuArea(0.5)
      await pause(3)
    case "mini":
      // Start from the default corner (bottom right) every time.
      for key in ["Manping.miniPlayerFrame", "Manping.miniPlayerFree"] { PerformanceEnvironment.defaults.removeObject(forKey: key) }
      try await openSampleVideo()
      await pause(2)
    default: throw Failure.missing("scene \(scene)")
    }
  }

  private func perform() async throws {
    switch scene {
    case "hero": try await hero()
    case "danmaku": try await danmaku()
    case "mini": try await mini()
    case "live": try await live()
    case "ai": try await ai()
    case "settings": try await settings()
    default: break
    }
  }

  /// The first card of the home grid, which every video scene opens.
  private static let sampleTitle = M3FixtureRPCTransport.popularTitles[0]

  /// 首页 → hover a card → open it → playing with danmaku → hover the chapter-segmented progress bar → controls fade.
  private func hero() async throws {
    guard let window = mainWindow else { return }
    caption("原生 SwiftUI 界面，首页卡片悬停浮起")
    await pause(0.6)
    let card = try await target("card.\(Self.sampleTitle)")
    await move(to: card.point)
    DemoStage.signals.send(.hoverPoint(local(card.point, in: window)))
    await pause(1.0)
    click()
    DemoStage.signals.send(.hoverPoint(nil))
    model.open(Video(bvid: DebugUIFixtures.bvid, title: Self.sampleTitle, aid: 100))
    try await waitForPlayback()
    caption("Metal 弹幕跟随屏幕刷新率匀速滚动，玻璃控制面板浮在画面上")
    await move(to: point(fraction: CGPoint(x: 0.4, y: 0.4), of: window))
    for _ in 0..<5 { DemoStage.signals.send(.playerActivity); await pause(0.45) }
    let bar = try await target("seek")
    let track = bar.frame
    caption("进度条按章节分段，悬停显示预览与「时间 · 章节名」")
    let start = 0.12, end = 0.62
    await move(to: CGPoint(x: track.minX + track.width * start, y: track.midY))
    DemoStage.signals.send(.seekHover(start))
    await pause(0.6)
    // Slide along the track; the preview and the chapter name follow.
    let slide = 1.8
    log(["type": "move", "x": track.minX + track.width * end, "y": track.midY, "dur": slide * 1000])
    let steps = 36
    for step in 1...steps {
      DemoStage.signals.send(.playerActivity)
      DemoStage.signals.send(.seekHover(start + (end - start) * glide(Double(step) / Double(steps))))
      await pause(slide / Double(steps))
    }
    pointer = CGPoint(x: track.minX + track.width * end, y: track.midY)
    await pause(1.0)
    caption("指针停下 2.5 秒后，控件自动淡出")
    await move(to: point(fraction: CGPoint(x: 0.42, y: 0.3), of: window))
    DemoStage.signals.send(.seekHover(nil))
    DemoStage.signals.send(.playerActivity)
    await pause(3.6)
  }

  /// Danmaku → 更多 › 弹幕设置: display area 半屏 → 全屏, larger text → danmaku off and on.
  private func danmaku() async throws {
    // No push-in: a zoom changes every pixel of every frame, which a GIF cannot afford over a photo.
    caption("弹幕由 Metal 绘制，先描边再填充，同一行不重叠")
    await pause(2.4)
    caption("更多 › 弹幕设置：显示区域、字号即时生效")
    DemoStage.signals.send(.playerActivity)
    // The default bar keeps 弹幕设置 in 「更多」, and its panel opens from that button.
    let gear = try await target(DemoAnchors.frame("bar.danmakuSettings") != nil ? "bar.danmakuSettings" : "bar.more")
    await move(to: gear.point)
    DemoStage.signals.send(.playerActivity)
    await pause(0.3)
    click()
    DemoStage.signals.send(.danmakuPanel(true))
    await pause(1.0)
    let full = try await target("tab.全屏")
    await move(to: full.point)
    await pause(0.25)
    click()
    DemoStage.signals.send(.danmakuAppearance(fontSize: nil, area: 1))
    await pause(1.2)
    let slider = try await target("slider.字号")
    let track = slider.frame.insetBy(dx: 8, dy: 0)
    let range = MacSettingsCatalog.descriptor(.danmakuFontSize).numberRange?.range ?? 12...48
    let from = model.settingsModel.values.number(.danmakuFontSize), to = min(range.upperBound, from + 10)
    let x = { (size: Double) in track.minX + track.width * (size - range.lowerBound) / (range.upperBound - range.lowerBound) }
    await move(to: CGPoint(x: x(from), y: track.midY))
    log(["type": "move", "x": x(to), "y": track.midY, "dur": 900])
    for step in 1...10 {
      DemoStage.signals.send(.danmakuAppearance(fontSize: (from + (to - from) * Double(step) / 10).rounded(), area: nil))
      await pause(0.09)
    }
    pointer = CGPoint(x: x(to), y: track.midY)
    await pause(1.0)
    DemoStage.signals.send(.danmakuAppearance(fontSize: from, area: nil))
    DemoStage.signals.send(.danmakuPanel(false))
    caption("⇧⌘D 或点一下，关闭、再打开弹幕")
    DemoStage.signals.send(.playerActivity)
    let toggle = try await target("bar.danmaku")
    await move(to: toggle.point)
    DemoStage.signals.send(.playerActivity)
    await pause(0.3)
    click(); model.player.commentsEnabled = false
    await pause(1.1)
    DemoStage.signals.send(.playerActivity)
    click(); model.player.commentsEnabled = true
    await pause(1.2)
  }

  /// ⇧⌘P → the mini window in the bottom-right corner; the main window browses on; hover → drag → snap.
  private func mini() async throws {
    caption("⇧⌘P 打开小窗，画面浮在屏幕一角")
    await pause(0.6)
    keys(["⇧", "⌘", "P"])
    model.toggleCompactPlayer()
    try await wait(5) { self.miniPanel != nil }
    await pause(1.4)
    caption("主窗口继续浏览首页和专栏，播放不中断")
    let home = try await target("sidebar.\(AppModel.Destination.page(.popular).title)")
    await move(to: home.point)
    click(); model.navigate(to: .popular)
    await pause(1.3)
    let articles = try await target("sidebar.\(AppModel.Destination.page(.article).title)")
    await move(to: articles.point)
    click(); model.navigate(to: .article)
    await pause(1.5)
    guard let panel = miniPanel else { throw Failure.missing("mini window") }
    caption("悬停小窗出现玻璃控件；拖到任意角落，松手自动吸附")
    let frame = globalRect(panel.frame)
    await move(to: CGPoint(x: frame.midX + 30, y: frame.midY + 10))
    for _ in 0..<4 { DemoStage.signals.send(.miniActivity); await pause(0.4) }
    // Grab the panel near its top edge and drag it most of the way to the top-left corner.
    let grab = CGPoint(x: frame.width / 2, y: 36)
    await move(to: CGPoint(x: frame.minX + grab.x, y: frame.minY + grab.y), duration: 0.45)
    let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
    let start = panel.frame.origin
    let drop = NSPoint(x: visible.minX + 70, y: visible.maxY - panel.frame.height - 60)
    let dragTime = 1.1
    let begin = elapsed
    for step in 1...Int(dragTime * 60) {
      let p = glide(Double(step) / (dragTime * 60))
      DemoStage.signals.send(.miniActivity)
      panel.setFrameOrigin(NSPoint(x: start.x + (drop.x - start.x) * p, y: start.y + (drop.y - start.y) * p))
      await pause(1 / 60)
    }
    log(["type": "drag", "window": "w\(panel.windowNumber)", "dx": grab.x, "dy": grab.y, "until": elapsed], at: begin)
    let released = globalRect(panel.frame)
    pointer = CGPoint(x: released.minX + grab.x, y: released.minY + grab.y)
    // Released without ⌥: the panel snaps into the corner.
    panel.onMoveEnded?(false)
    await pause(0.8)
    await move(to: CGPoint(x: pointer!.x + 160, y: pointer!.y + 150))
    await pause(1.6)
  }

  /// 直播 grid → a room → chat with a 醒目留言 and a gift → send a danmaku → like.
  private func live() async throws {
    guard let window = mainWindow else { return }
    if model.page != .live { model.navigate(to: .live) }
    caption("直播：分区网格，悬停浮起")
    await pause(0.8)
    let roomID: Int64 = 5005
    let room = try await target("live.\(roomID)")
    await move(to: room.point)
    DemoStage.signals.send(.hoverPoint(local(room.point, in: window)))
    await pause(0.9)
    click()
    DemoStage.signals.send(.hoverPoint(nil))
    model.openLive(roomID)
    try await wait(8) { self.model.livePlayback != nil }
    await pause(1.2)
    guard let live = model.livePlayback else { throw Failure.missing("live room") }
    try await wait(8) { live.room != nil }
    await live.bindDemoInteraction()
    try await wait(8) { live.ui.canInteract }
    let chat = live.chat
    caption("实时弹幕同时上屏，醒目留言和礼物单独标出")
    let names = ["晚风", "小林同学", "路过的猫", "今天也要早睡", "山野记录粉丝", "一只企鹅", "阿青", "北岸"]
    let texts = [
      "直播弹幕也是 Metal 渲染", "从首页点进来的", "城市夜景好治愈", "醒目留言按金额配色", "纯享模式可以关掉所有特效",
      "画面好稳", "小窗挂着边看边写代码", "付费礼物默认锁定", "直播里也能发弹幕点赞了", "节点卡了会自动换",
    ]
    var line = 0
    func say(_ count: Int, every seconds: Double) async {
      for _ in 0..<count {
        let text = texts[line % texts.count]
        chat.add(user: names[line % names.count], text: text, kind: .danmaku)
        model.player.timeline.append(DanmakuComment(time: model.player.mediaClock + 0.05, color: 0xFFFFFF, text: text))
        line += 1
        await pause(seconds)
      }
    }
    await say(6, every: 0.35)
    chat.add(user: "晚风", text: "满屏的直播弹幕和醒目留言都在侧栏，翻看历史也不打断", kind: .superChat(30))
    live.ui.enqueue(LiveEffect(kind: .superChat, title: "醒目留言 ¥30", detail: "满屏的直播弹幕和醒目留言都在侧栏", user: "晚风", price: 30))
    await pause(1.0)
    await say(3, every: 0.35)
    chat.add(user: "小林同学", text: "赠送 小心心 ×5", kind: .gift)
    live.ui.enqueue(LiveEffect(kind: .gift, title: "小林同学", detail: "赠送 小心心", user: "小林同学", giftName: "小心心", count: 5))
    await pause(1.2)
    await say(2, every: 0.35)
    caption("在侧栏发弹幕、点赞，和官方直播间一样")
    let composer = try await target("live.composer")
    await move(to: composer.point)
    click()
    await pause(0.3)
    let message = "满屏发的第一条弹幕"
    for count in 1...message.count {
      live.ui.setText(String(message.prefix(count)))
      await pause(0.08)
    }
    await pause(0.3)
    let send = try await target("live.send")
    await move(to: send.point)
    click()
    live.ui.setText("")
    chat.add(user: "我", text: message, kind: .danmaku)
    model.player.timeline.append(DanmakuComment(time: model.player.mediaClock + 0.05, color: 0xFFFFFF, text: message))
    await pause(0.8)
    await say(2, every: 0.35)
    let like = try await target("live.like")
    await move(to: like.point)
    for _ in 0..<3 { click(); live.ui.like(); await pause(0.28) }
    chat.add(user: "", text: "我 点了赞", kind: .notice)
    await pause(0.6)
    await say(3, every: 0.35)
    await pause(0.8)
  }

  /// The video page's AI tab → 章节总结 streams in → a time in the answer jumps the player.
  private func ai() async throws {
    caption("AI 面板：预设一键生成，只在你点按时发送")
    let toggle = try await target("toolbar.sidebar")
    await move(to: toggle.point)
    await pause(0.2)
    click()
    withAnimation(.snappy(duration: 0.25)) { PerformanceEnvironment.defaults.set(false, forKey: PlayerPreferences.sidebarHiddenKey) }
    await pause(1.0)
    // A narrow panel keeps AI behind the tabs' 「⋯」.
    let tab = try await target(DemoAnchors.frame("tab.AI") != nil ? "tab.AI" : "tab.more")
    await move(to: tab.point)
    await pause(0.2)
    click()
    DemoStage.signals.send(.videoSection("AI"))
    await pause(1.0)
    let preset = try await target("ai.章节总结", within: 6)
    await move(to: preset.point)
    await pause(0.3)
    click()
    guard let video = model.videoDetails else { throw Failure.missing("video details") }
    let panel = model.ai.panel(for: model.aiVideoSource(video))
    if let chapters = panel.panelPresets.first(where: { $0.name == "章节总结" }) { panel.run(chapters) }
    try await wait(15) { !panel.busy && !panel.turns.isEmpty }
    await pause(1.6)
    caption("回答里的时间点一点就跳到那一刻")
    let times = DemoAnchors.ids(prefix: "ai.time.").compactMap { id -> (String, Double)? in
      let parts = id.dropFirst("ai.time.".count).split(separator: ":").compactMap { Double($0) }
      guard parts.count == 2 else { return nil }
      return (id, parts[0] * 60 + parts[1])
    }.filter { $0.1 > 5 && $0.1 < 60 }.sorted { $0.1 < $1.1 }
    guard let jump = times.dropFirst().first ?? times.first else { throw Failure.missing("a time link under 01:00") }
    let pill = try await target(jump.0)
    await move(to: pill.point)
    await pause(0.3)
    click()
    model.player.seek(jump.1)
    DemoStage.signals.send(.playerActivity)
    await pause(2.4)
  }

  /// ⌘, → the settings window → 直播 (纯享模式) → 网络 → 致谢.
  private func settings() async throws {
    guard let window = mainWindow else { return }
    caption("⌘, 打开设置窗口")
    await move(to: point(fraction: CGPoint(x: 0.62, y: 0.4), of: window))
    await pause(0.4)
    keys(["⌘", ","])
    model.openSettings(.general)
    guard let settings = SettingsWindowController.shared.window else { throw Failure.missing("settings window") }
    // Over the middle of the main window, wherever it was left last time.
    settings.setFrameOrigin(NSPoint(x: window.frame.midX - settings.frame.width / 2, y: window.frame.midY - settings.frame.height / 2))
    await pause(1.4)
    caption("直播：纯享模式、逐项关闭特效、付费礼物默认锁定")
    let liveGroup = try await target("settings.\(MacSettingGroup.live.rawValue)")
    await move(to: liveGroup.point)
    await pause(0.2)
    click(); model.openSettings(.live)
    await pause(2.4)
    caption("网络：节点优选、代理与连接状态")
    let network = try await target("settings.\(MacSettingGroup.network.rawValue)")
    await move(to: network.point)
    await pause(0.2)
    click(); model.openSettings(.network)
    await pause(2.0)
    caption("致谢：用到的开源项目与许可证")
    let thanks = try await target("settings.致谢")
    await move(to: thanks.point)
    await pause(0.2)
    click()
    SettingsWindowController.shared.show(model: model, page: .acknowledgements)
    await pause(1.2)
    await move(to: point(fraction: CGPoint(x: 0.62, y: 0.55), of: settings))
    await pause(2.0)
  }

  // MARK: Steps

  private var elapsed: Double { origin == 0 ? 0 : (CACurrentMediaTime() - origin) * 1000 }

  private func log(_ event: [String: Any], at time: Double? = nil) {
    var event = event
    event["t"] = ((time ?? elapsed) * 10).rounded() / 10
    events.append(event)
  }
  private func caption(_ text: String) { log(["type": "caption", "text": text]) }
  private func keys(_ keys: [String]) { log(["type": "keys", "keys": keys]) }
  private func click() { log(["type": "click"]) }
  private func zoom(_ rect: CGRect, for seconds: Double) {
    log(["type": "zoom", "x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height, "until": elapsed + seconds * 1000])
  }
  /// The drawn pointer travels to `point`; the step returns when it arrives.
  private func move(to point: CGPoint, duration: Double? = nil) async {
    let distance = pointer.map { hypot($0.x - point.x, $0.y - point.y) } ?? 200
    let seconds = duration ?? min(0.8, max(0.38, 0.28 + distance * 0.0006))
    log(["type": "move", "x": point.x, "y": point.y, "dur": seconds * 1000])
    pointer = point
    await pause(seconds)
  }
  private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
  private func wait(_ seconds: Double, until condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = CACurrentMediaTime() + seconds
    while !condition() {
      guard CACurrentMediaTime() < deadline else { throw Failure.timedOut("\(scene) at \(Int(elapsed)) ms") }
      await pause(0.05)
    }
  }
  private func write(_ object: [String: Any], to name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
  }
  private func glide(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }

  /// The real pointer never changes what is recorded: the app's windows ignore it during a scene.
  private func ignoreRealPointer() {
    keepIgnoringMouse = Task { @MainActor in
      while !Task.isCancelled {
        for window in NSApp.windows where window.isVisible && !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  // MARK: Playback

  /// Opens the sample video and plays the local file in the real player.
  private func openSampleVideo() async throws {
    model.open(Video(bvid: DebugUIFixtures.bvid, title: Self.sampleTitle, aid: 100))
    try await waitForPlayback()
  }
  private func waitForPlayback() async throws {
    try await wait(10) { self.model.videoDetails != nil && self.model.selectedStream != nil && self.model.player.surface != nil }
    guard let media = DemoConfig.media else { notes.append("no MANPING_DEMO_MEDIA: covers instead of video"); return }
    let player = model.player
    player.load(video: media, audio: nil)
    player.set("loop-file", "inf")
    player.set("mute", "yes")
    try await wait(10) { player.duration > 0 && player.time > 0.1 }
  }

  private var miniPanel: MiniPlayerPanel? { NSApp.windows.lazy.compactMap { $0 as? MiniPlayerPanel }.first { $0.isVisible } }
  private func popoverWindow() -> NSWindow? {
    NSApp.windows.last { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
  }

  // MARK: Targets

  struct Target {
    var point: CGPoint
    var frame: CGRect
  }

  /// The control marked `.demoAnchor(id)`, where it is on screen now. Waits a moment for one that
  /// appears after a navigation or popover; a scene never guesses, so a missing anchor stops it and
  /// the recorder refuses to render that scene.
  private func target(_ id: String, within seconds: Double = 3) async throws -> Target {
    let deadline = CACurrentMediaTime() + seconds
    while true {
      if let frame = DemoAnchors.frame(id) { return Target(point: CGPoint(x: frame.midX, y: frame.midY), frame: frame) }
      guard CACurrentMediaTime() < deadline else {
        throw Failure.missing("anchor \(id); on screen: \(DemoAnchors.ids(prefix: "").joined(separator: ", "))")
      }
      await pause(0.05)
    }
  }

  private func point(fraction: CGPoint, of window: NSWindow) -> CGPoint {
    let frame = globalRect(window.frame)
    return CGPoint(x: frame.minX + frame.width * fraction.x, y: frame.minY + frame.height * fraction.y)
  }
  /// AppKit screen rect (bottom-left origin) → global points with a top-left origin (as CGWindowList).
  private func globalRect(_ rect: NSRect) -> CGRect {
    let height = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
  }
  /// A global point → SwiftUI global coordinates of `window` (its content fills the window).
  private func local(_ point: CGPoint, in window: NSWindow) -> CGPoint {
    let frame = globalRect(window.frame)
    return CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
  }
}
#else
import SwiftUI
extension View {
  func demoAnchor(_ id: String) -> some View { self }
}
#endif
