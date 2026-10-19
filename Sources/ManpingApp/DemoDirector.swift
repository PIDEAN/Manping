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
  /// Only over the offline samples: a scene never shows an account or online content.
  static var active: Bool { scene != nil && output != nil && DebugUIFixtures.enabled }
  /// Scenes on a playing video or live room load the local file into the real player.
  static var playsLocalMedia: Bool { active && media != nil && ["hero", "danmaku", "mini", "live"].contains(scene ?? "") }

  /// Synthetic danmaku (list.so XML) for the local file: made-up lines, a few top, bottom and
  /// coloured ones, about three a second over the first minute.
  static func danmakuXML() -> Data? {
    guard playsLocalMedia else { return nil }
    let lines = [
      "前排围观", "这段画面好治愈", "原生播放器真顺滑", "120Hz 下弹幕一点都不抖", "打卡打卡", "配乐好舒服",
      "山间的风好温柔", "这个转场绝了", "已三连", "收藏了周末再看", "弹幕护体", "好想去这里走走",
      "镜头好稳", "第一次来，路过", "颜色好好看", "慢下来真好", "这里可以当壁纸", "小窗边看边写代码",
      "画质好清楚", "节奏刚刚好", "求背景音乐", "看完心情变好了", "每一帧都好看", "光影绝了",
    ]
    let colors: [UInt32] = [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0x6FD0F5, 0xFFB13B, 0xFF4F95]
    var body = #"<?xml version="1.0" encoding="UTF-8"?><i>"#
    for index in 0..<180 {
      let time = Double(index) / 3 + Double(index % 5) * 0.07
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
}

@MainActor enum DemoStage {
  static let signals = PassthroughSubject<DemoSignal, Never>()
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
    switch scene {
    case "hero", "live", "settings": break
    case "danmaku":
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
    case "settings": try await settings()
    default: break
    }
  }

  /// 首页 → hover a card → open it → playing with danmaku → hover the progress bar → controls fade.
  private func hero() async throws {
    guard let window = mainWindow else { return }
    caption("原生 SwiftUI 界面，首页网格悬停浮起")
    await pause(0.5)
    let card = target(["本地热门 · 1"], in: window, fallback: CGPoint(x: 0.29, y: 0.18))
    await move(to: card.point)
    DemoStage.signals.send(.hoverPoint(local(card.point, in: window)))
    await pause(0.9)
    click()
    DemoStage.signals.send(.hoverPoint(nil))
    if !(card.element?.accessibilityPerformPress() ?? false) {
      model.open(Video(bvid: DebugUIFixtures.bvid, title: "本地热门 · 1", aid: 100))
    }
    try await waitForPlayback()
    caption("Metal 弹幕跟随屏幕刷新率匀速滚动，液态玻璃控制面板")
    let picture = point(fraction: CGPoint(x: 0.42, y: 0.42), of: window)
    await move(to: picture)
    for _ in 0..<4 { DemoStage.signals.send(.playerActivity); await pause(0.45) }
    let bar = target(["播放进度"], in: window, fallback: CGPoint(x: 0.44, y: 0.905))
    let track = bar.frame ?? CGRect(x: bar.point.x - 300, y: bar.point.y - 8, width: 600, height: 16)
    caption("悬停进度条：预览画面与「时间 · 章节名」")
    let start = 0.32, end = 0.6
    await move(to: CGPoint(x: track.minX + track.width * start, y: track.midY))
    DemoStage.signals.send(.seekHover(start))
    await pause(0.6)
    // Slide along the track; the preview follows.
    let slide = 1.2
    log(["type": "move", "x": track.minX + track.width * end, "y": track.midY, "dur": slide * 1000])
    let steps = 24
    for step in 1...steps {
      DemoStage.signals.send(.playerActivity)
      DemoStage.signals.send(.seekHover(start + (end - start) * glide(Double(step) / Double(steps))))
      await pause(slide / Double(steps))
    }
    pointer = CGPoint(x: track.minX + track.width * end, y: track.midY)
    await pause(1.0)
    caption("指针停下 2.5 秒后，控件自动淡出")
    await move(to: point(fraction: CGPoint(x: 0.46, y: 0.3), of: window))
    DemoStage.signals.send(.seekHover(nil))
    DemoStage.signals.send(.playerActivity)
    await pause(3.6)
  }

  /// Danmaku close-up → the danmaku panel: display area 半屏 → 全屏, larger text → danmaku off and on.
  private func danmaku() async throws {
    guard let window = mainWindow else { return }
    caption("弹幕由 Metal 绘制，随屏幕刷新率匀速滚动")
    let picture = window.frame
    let band = globalRect(NSRect(x: picture.minX + picture.width * 0.18, y: picture.minY + picture.height * 0.55,
      width: picture.width * 0.45, height: picture.height * 0.33))
    zoom(band, for: 3.6)
    await pause(4.2)
    caption("弹幕面板：显示区域、字号即时生效")
    let gear = target(["播放器设置"], in: window, fallback: CGPoint(x: 0.638, y: 0.949))
    await move(to: gear.point)
    DemoStage.signals.send(.playerActivity)
    await pause(0.3)
    click()
    DemoStage.signals.send(.danmakuPanel(true))
    await pause(1.0)
    let panel = popoverWindow()
    let full = panel.map { target(["全屏"], in: $0, fallback: CGPoint(x: 0.82, y: 0.66)) }
    if let full {
      await move(to: full.point)
      await pause(0.25)
      click()
      DemoStage.signals.send(.danmakuAppearance(fontSize: nil, area: 1))
      await pause(1.2)
    } else { notes.append("danmaku panel window not found") }
    if let panel {
      let slider = target(["字号"], in: panel, fallback: CGPoint(x: 0.5, y: 0.2))
      let track = slider.frame ?? CGRect(x: slider.point.x - 120, y: slider.point.y - 6, width: 240, height: 12)
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
      await pause(1.4)
      DemoStage.signals.send(.danmakuAppearance(fontSize: from, area: nil))
    }
    DemoStage.signals.send(.danmakuPanel(false))
    caption("一键关闭、再打开弹幕")
    let toggle = target(["弹幕"], in: window, fallback: CGPoint(x: 0.331, y: 0.949), exact: true)
    await move(to: toggle.point)
    DemoStage.signals.send(.playerActivity)
    await pause(0.3)
    click(); model.player.commentsEnabled = false
    await pause(1.4)
    click(); model.player.commentsEnabled = true
    await pause(1.6)
  }

  /// ⇧⌘P → the mini window in the bottom-right corner; the main window browses on; hover → drag → snap.
  private func mini() async throws {
    guard let window = mainWindow else { return }
    caption("⇧⌘P 打开小窗，画面浮在屏幕一角")
    await pause(0.6)
    keys(["⇧", "⌘", "P"])
    model.toggleCompactPlayer()
    try await wait(5) { self.miniPanel != nil }
    await pause(1.4)
    caption("主窗口继续浏览首页和专栏，播放不中断")
    let home = target(["首页"], in: window, fallback: CGPoint(x: 0.07, y: 0.155), exact: true)
    await move(to: home.point)
    click(); model.navigate(to: .popular)
    await pause(1.3)
    let articles = target(["专栏"], in: window, fallback: CGPoint(x: 0.07, y: 0.405), exact: true)
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

  /// 直播 grid → a room → the chat scrolls, a 醒目留言 → scrolled up, 「N 条新弹幕」 → back down.
  private func live() async throws {
    guard let window = mainWindow else { return }
    if model.page != .live { model.navigate(to: .live) }
    caption("直播：分区网格，悬停浮起")
    await pause(0.6)
    let room = target(["傍晚音乐会"], in: window, fallback: CGPoint(x: 0.29, y: 0.24))
    await move(to: room.point)
    DemoStage.signals.send(.hoverPoint(local(room.point, in: window)))
    await pause(0.9)
    click()
    DemoStage.signals.send(.hoverPoint(nil))
    if !(room.element?.accessibilityPerformPress() ?? false) { model.openLive(5000) }
    try await wait(8) { self.model.livePlayback != nil }
    await pause(1.0)
    guard let chat = model.livePlayback?.chat else { throw Failure.missing("live chat") }
    caption("聊天实时滚动，醒目留言单独标出")
    let names = ["样本观众 12", "晚风", "小林同学", "路过的猫", "今天也要早睡", "山野记录粉丝", "一只企鹅", "阿青"]
    let texts = ["晚上好呀", "这首歌好好听", "来了来了", "打卡", "主播今天状态好好", "前奏一响就爱了", "再来一首！", "声音好温柔",
      "从首页点进来的", "好治愈", "第一次看直播，好热闹", "背景好好看", "点歌点歌", "明天还播吗", "坐等下一首", "已关注"]
    var line = 0
    func say(_ count: Int, every seconds: Double) async {
      for _ in 0..<count {
        chat.add(user: names[line % names.count], text: texts[(line * 5) % texts.count], kind: .danmaku)
        line += 1
        await pause(seconds)
      }
    }
    await say(10, every: 0.3)
    chat.add(user: "晚风", text: "谢谢今晚的歌，祝大家周末愉快！", kind: .superChat(30))
    await pause(1.2)
    await say(4, every: 0.3)
    caption("往上翻看时，新消息收进「N 条新弹幕」")
    let list = point(fraction: CGPoint(x: 0.86, y: 0.5), of: window)
    await move(to: list)
    DemoStage.signals.send(.chatScrollUp)
    await pause(0.6)
    await say(9, every: 0.32)
    let pill = target(["条新弹幕"], in: window, fallback: CGPoint(x: 0.86, y: 0.9))
    await move(to: pill.point)
    await pause(0.3)
    click()
    if !(pill.element?.accessibilityPerformPress() ?? false) { notes.append("new-lines pill not pressed") }
    await say(4, every: 0.3)
    await pause(0.8)
  }

  /// ⌘, → the settings window → 网络 → 致谢.
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
    caption("网络：节点优选、代理与连接状态")
    let network = target(["网络"], in: settings, fallback: CGPoint(x: 0.12, y: 0.33), exact: true)
    await move(to: network.point)
    await pause(0.2)
    click(); model.openSettings(.network)
    await pause(1.0)
    await move(to: point(fraction: CGPoint(x: 0.6, y: 0.45), of: settings))
    await pause(1.8)
    caption("致谢：用到的开源项目与许可证")
    let thanks = target(["致谢"], in: settings, fallback: CGPoint(x: 0.12, y: 0.9), exact: true)
    await move(to: thanks.point)
    await pause(0.2)
    click()
    if !(thanks.element?.accessibilityPerformPress() ?? false) {
      SettingsWindowController.shared.show(model: model, page: .acknowledgements)
    }
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
    model.open(Video(bvid: DebugUIFixtures.bvid, title: "本地热门 · 1", aid: 100))
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
    var frame: CGRect?
    var element: NSAccessibilityProtocol?
  }

  /// The first accessibility element in `window` labelled with one of `labels` (buttons first), or
  /// `fallback` as a fraction of the window. Positions are global points, top-left origin.
  private func target(_ labels: [String], in window: NSWindow, fallback: CGPoint, exact: Bool = false) -> Target {
    var matches: [(NSAccessibilityProtocol, NSRect, Bool)] = []
    var queue: [Any] = [window.contentView as Any]
    var visited = 0
    while !queue.isEmpty, visited < 8000 {
      let item = queue.removeFirst()
      visited += 1
      guard let element = item as? NSAccessibilityProtocol else { continue }
      let texts = [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
      if texts.contains(where: { text in labels.contains { exact ? text == $0 : text.contains($0) } }) {
        let frame = element.accessibilityFrame()
        if frame.width > 1, frame.height > 1, window.frame.intersects(frame) {
          matches.append((element, frame, element.accessibilityRole() == .button))
        }
      }
      queue.append(contentsOf: element.accessibilityChildren() ?? [])
    }
    if let best = matches.first(where: { $0.2 }) ?? matches.min(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) {
      let frame = globalRect(best.1)
      return Target(point: CGPoint(x: frame.midX, y: frame.midY), frame: frame, element: best.0)
    }
    notes.append("\(labels.joined(separator: "/")): not found, fallback \(fallback)")
    return Target(point: point(fraction: fallback, of: window))
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
#endif
