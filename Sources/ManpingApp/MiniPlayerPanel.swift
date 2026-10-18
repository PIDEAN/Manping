import AppKit
import ManpingCore
import SwiftUI

/// 小窗 (DesignSystem.md §12): a borderless floating panel on every Space, over full-screen apps
/// too, locked to the video's aspect ratio and snapping to the nearest screen corner. Like the
/// standalone playback window it never creates a PlayerModel or a second render surface: the
/// root swaps the playback page for a placeholder, then this panel becomes the one owner of the
/// picture. The main window keeps its size and place.
@MainActor final class MiniPlayerCoordinator: NSObject, NSWindowDelegate {
  enum Key { case togglePause, back, forward }

  private(set) var panel: MiniPlayerPanel?
  /// Placed with ⌥ held: left where it was dropped instead of snapping to a corner.
  private var free = false

  static let defaultWidth: CGFloat = 480
  static let widths: ClosedRange<CGFloat> = 320...960
  /// Gap between the panel and the screen's visible frame when it snaps to a corner.
  static let margin: CGFloat = 16
  static let cornerRadius: CGFloat = 16
  private static let frameKey = "Manping.miniPlayerFrame"
  private static let freeKey = "Manping.miniPlayerFree"

  #if DEBUG
  /// `MANPING_UI_MINI_PLAYER=open|hover` with `--ui-fixture`: open the mini window once the
  /// fixture video page shows (`hover` also pins its controls) for screenshot checks.
  static let debugLaunch = ProcessInfo.processInfo.environment["MANPING_UI_MINI_PLAYER"].map { ["open", "hover"].contains($0) } ?? false
  static let debugHover = ProcessInfo.processInfo.environment["MANPING_UI_MINI_PLAYER"] == "hover"
  static var debugLaunched = false
  #else
  static let debugLaunch = false
  static let debugHover = false
  #endif

  /// Shows `content` in the panel. `aspect` is the video's width ÷ height.
  func present(content: NSView, aspect: CGFloat, onKey: @escaping (Key) -> Void) {
    let ratio = Self.ratio(aspect)
    let panel = self.panel ?? MiniPlayerPanel()
    panel.delegate = self
    panel.onKey = onKey
    panel.onMoveEnded = { [weak self] free in self?.moveEnded(free: free) }
    panel.contentView = MiniPlayerContainer(content: content, radius: Self.cornerRadius)
    self.panel = panel
    let frame = initialFrame(ratio: ratio)
    lock(panel, ratio: ratio, screen: Self.visibleFrame(containing: frame))
    panel.setFrame(frame, display: true)
    if !free { snap(animated: false) }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      panel.animator().alphaValue = 1
    }
    panel.invalidateShadow()
    #if DEBUG
    if Bundle.main.bundleURL.pathExtension == "app" {
      let file = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("mini-window-id")
      try? String(panel.windowNumber).write(to: file, atomically: true, encoding: .utf8)
    }
    #endif
  }

  /// Removes the picture first (so the next owner can take the render surface), then the panel.
  func close() {
    guard let panel else { return }
    save(panel.frame)
    panel.delegate = nil
    panel.onKey = nil; panel.onMoveEnded = nil
    panel.contentView = nil
    panel.orderOut(nil)
    self.panel = nil
  }

  func bringToFront() { panel?.orderFrontRegardless() }

  /// The video changed size (its stream became known, or the next item plays): the panel
  /// takes the new aspect ratio and keeps its size class and corner.
  func update(aspect: CGFloat) {
    guard let panel else { return }
    let ratio = Self.ratio(aspect)
    let current = panel.contentAspectRatio
    if current.height > 0, abs(current.width / current.height - ratio) < 0.01 { return }
    let frame = panel.frame
    let visible = Self.visibleFrame(containing: frame)
    lock(panel, ratio: ratio, screen: visible)
    let size = Self.size(ratio: ratio, boxWidth: MiniWindowSizing.boxWidth(width: frame.width, height: frame.height), screen: visible)
    // Keep the edge nearest the screen's corner in place, then snap as after a resize.
    let right = frame.midX >= visible.midX, top = frame.midY >= visible.midY
    let target = NSRect(x: right ? frame.maxX - size.width : frame.minX, y: top ? frame.maxY - size.height : frame.minY,
      width: size.width, height: size.height)
    panel.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    panel.invalidateShadow()
    if free { save(panel.frame) } else { snap(animated: false) }
  }

  // MARK: Placement

  private static func ratio(_ aspect: CGFloat) -> CGFloat {
    aspect.isFinite && aspect > 0 ? aspect : CGFloat(MiniWindowSizing.fallbackAspect)
  }
  /// The visible frame of the screen showing `frame` (the main screen when none does).
  private static func visibleFrame(containing frame: NSRect) -> NSRect {
    let center = NSPoint(x: frame.midX, y: frame.midY)
    let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens.first
    return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  }
  /// The window for `ratio` in a box `boxWidth` wide, no larger than the screen's visible area.
  private static func size(ratio: CGFloat, boxWidth: CGFloat, screen: NSRect) -> NSSize {
    let box = min(widths.upperBound, max(widths.lowerBound, boxWidth))
    let fitted = MiniWindowSizing.size(aspect: Double(ratio), boxWidth: Double(box),
      maxWidth: Double(screen.width - 2 * margin), maxHeight: Double(screen.height - 2 * margin))
    return NSSize(width: fitted.width, height: fitted.height)
  }
  /// Locks resizing to the video's own aspect ratio, between the smallest and largest boxes.
  private func lock(_ panel: NSPanel, ratio: CGFloat, screen: NSRect) {
    panel.contentAspectRatio = NSSize(width: ratio, height: 1)
    panel.contentMinSize = Self.size(ratio: ratio, boxWidth: Self.widths.lowerBound, screen: screen)
    panel.contentMaxSize = Self.size(ratio: ratio, boxWidth: Self.widths.upperBound, screen: screen)
  }

  private func initialFrame(ratio: CGFloat) -> NSRect {
    let defaults = PerformanceEnvironment.defaults
    free = defaults.bool(forKey: Self.freeKey)
    var box = Self.defaultWidth
    var origin: NSPoint?
    if let saved = defaults.string(forKey: Self.frameKey).map(NSRectFromString), saved.width > 0 {
      box = MiniWindowSizing.boxWidth(width: saved.width, height: saved.height)
      origin = saved.origin
    }
    if let origin {
      let screen = Self.visibleFrame(containing: NSRect(origin: origin, size: NSSize(width: 1, height: 1)))
      let size = Self.size(ratio: ratio, boxWidth: box, screen: screen)
      if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: origin, size: size)) }) {
        return NSRect(origin: origin, size: size)
      }
    }
    // First run (or the saved screen is gone): bottom-right corner of the main screen.
    free = false
    let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = Self.size(ratio: ratio, boxWidth: box, screen: visible)
    return NSRect(x: visible.maxX - Self.margin - size.width, y: visible.minY + Self.margin, width: size.width, height: size.height)
  }

  /// Moves the panel into the corner of its screen nearest to its centre, 16pt from the edges.
  private func snap(animated: Bool) {
    guard let panel else { return }
    let frame = panel.frame
    let center = NSPoint(x: frame.midX, y: frame.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? panel.screen ?? NSScreen.main else { return }
    let visible = screen.visibleFrame.insetBy(dx: Self.margin, dy: Self.margin)
    let target = NSRect(
      x: center.x < screen.visibleFrame.midX ? visible.minX : visible.maxX - frame.width,
      y: center.y < screen.visibleFrame.midY ? visible.minY : visible.maxY - frame.height,
      width: frame.width, height: frame.height)
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.setFrame(target, display: true)
    }
    save(target)
  }

  private func moveEnded(free: Bool) {
    self.free = free
    if free { if let panel { save(panel.frame) } } else { snap(animated: true) }
  }

  private func save(_ frame: NSRect) {
    PerformanceEnvironment.defaults.set(NSStringFromRect(frame), forKey: Self.frameKey)
    PerformanceEnvironment.defaults.set(free, forKey: Self.freeKey)
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    panel?.invalidateShadow()
    if free { if let panel { save(panel.frame) } } else { snap(animated: true) }
  }
  func windowDidResize(_ notification: Notification) { panel?.invalidateShadow() }
}

/// The panel itself: no title bar, floating, on every Space and beside full-screen apps, never
/// in the Dock or ⌘Tab. Clicking it does not activate the app, so it can sit over other work.
final class MiniPlayerPanel: NSPanel, DanmakuFitting {
  var onKey: ((MiniPlayerCoordinator.Key) -> Void)?
  var onMoveEnded: ((Bool) -> Void)?
  private var dragPoll: Timer?
  var danmakuFit: DanmakuFit { .miniPlayer }

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
      styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    title = "小窗"
    identifier = NSUserInterfaceItemIdentifier("io.github.pidean.manping.mini-player")
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isRestorable = false
    isExcludedFromWindowsMenu = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovable = true
    isMovableByWindowBackground = false
    acceptsMouseMovedEvents = true
    animationBehavior = .utilityWindow
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Space and ←/→ when the menu bar does not handle them (the app is not active).
  override func keyDown(with event: NSEvent) {
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let onKey else {
      super.keyDown(with: event); return
    }
    switch event.keyCode {
    case 49: onKey(.togglePause)
    case 123: onKey(.back)
    case 124: onKey(.forward)
    default: super.keyDown(with: event)
    }
  }

  /// Moves the panel with the pointer from `event` (a mouse-down), then reports where it was
  /// dropped; ⌥ held at the drop leaves it there instead of snapping.
  func drag(from event: NSEvent) {
    performDrag(with: event)
    finishDragWhenReleased()
  }

  private func finishDragWhenReleased() {
    dragPoll?.invalidate()
    guard NSEvent.pressedMouseButtons & 1 != 0 else {
      onMoveEnded?(NSEvent.modifierFlags.contains(.option)); return
    }
    // The drag runs on after `performDrag` returned: wait for the button to come up.
    let poll = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        self?.dragPoll?.invalidate()
        self?.dragPoll = nil
        self?.onMoveEnded?(NSEvent.modifierFlags.contains(.option))
      }
    }
    RunLoop.main.add(poll, forMode: .common)
    dragPoll = poll
  }
}

/// Rounds the panel's corners (16pt, continuous) around the hosted SwiftUI view.
private final class MiniPlayerContainer: NSView {
  init(content: NSView, radius: CGFloat) {
    super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
    wantsLayer = true
    layer?.cornerRadius = radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.borderWidth = 0.5
    layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    content.frame = bounds
    content.autoresizingMask = [.width, .height]
    addSubview(content)
  }
  required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Content

/// The mini window's content: the picture and danmaku, and on hover a 28% dimming with
/// 「关闭小窗」「回到主窗口」, the danmaku switch, 「−10 · 播放 · +10」 and a thin progress line.
/// The controls fade after 1.5 s without activity. Click pauses or resumes, double-click
/// returns to the main window, dragging anywhere moves the panel.
struct MiniPlayerContent: View {
  @ObservedObject var model: AppModel
  var body: some View {
    MiniPlayerStage(model: model, player: model.player).id(ObjectIdentifier(model.player))
      .environment(\.colorScheme, .dark)
      .tint(Theme.accent)
  }
}

private struct MiniPlayerStage: View {
  @ObservedObject var model: AppModel
  @ObservedObject var player: PlayerModel
  @StateObject private var chrome = PlayerChromeState(idleDelay: 1.5)

  private var live: LivePlaybackModel? { model.livePlayback }
  private var showsCover: Bool { model.usesUIFixtures && !PerformanceOptions.playsLocalMedia }
  private var cover: URL? {
    if let live { return live.room?.cover }
    return model.pgcPlayback?.episode?.cover ?? model.videoDetails?.video.cover ?? model.selected?.cover
  }
  private var duration: Double {
    if player.duration > 0 { return player.duration }
    if let episode = model.pgcPlayback?.episode { return Double(episode.duration) }
    return Double(model.videoDetails?.video.duration ?? 0)
  }
  private var shown: Bool { chrome.visible || MiniPlayerCoordinator.debugHover }

  var body: some View {
    ZStack {
      Color.black
      PlayerSurface(model: player)
      if showsCover {
        // In an overlay the filled cover cannot grow the stack past the panel (which would push
        // the top buttons and the progress line out of view).
        Color.clear.overlay { CachedImage(url: cover).aspectRatio(contentMode: .fill) }
          .clipped().allowsHitTesting(false)
      } else if player.audioOnly {
        AudioOnlyBackdrop(cover: cover, title: "")
      }
      MiniPlayerMouseArea(
        hover: { inside in inside ? chrome.activity() : chrome.pointerLeft() },
        moved: { chrome.activity() },
        click: { chrome.activity(); player.togglePause() },
        doubleClick: { leave { model.toggleCompactPlayer() } })
      controls.playerChromeFade(shown)
      // 「N 秒后播放下一个」 with 取消, under the top buttons and clear of the centre controls;
      // it stays visible while the controls fade, since it acts on its own.
      if let deadline = model.nextPlaybackDeadline {
        MiniNextPlaybackPrompt(deadline: deadline, cancel: model.cancelNextPlayback)
          .frame(maxHeight: .infinity, alignment: .top)
          .padding(.top, shown ? 46 : 10)
          .animation(.easeOut(duration: 0.2), value: shown)
          .transition(.opacity)
      }
    }
    .animation(.snappy(duration: 0.25), value: model.nextPlaybackDeadline == nil)
    .onAppear { chrome.activity() }
    .onChange(of: player.paused) { _, _ in chrome.activity() }
    .onChange(of: player.commentsEnabled) { _, _ in chrome.activity() }
  }

  private var controls: some View {
    ZStack {
      Color.black.opacity(0.28).allowsHitTesting(false)
      VStack(spacing: 0) {
        GlassEffectContainer(spacing: 6) {
          HStack(spacing: 6) {
            Button { leave { model.closePlayer() } } label: { Image(systemName: "xmark") }
              .buttonStyle(MiniGlassButtonStyle()).help("关闭小窗").accessibilityLabel("关闭小窗")
            Button { leave { model.toggleCompactPlayer() } } label: { Image(systemName: "pip.exit") }
              .buttonStyle(MiniGlassButtonStyle()).help("回到主窗口").accessibilityLabel("回到主窗口")
            if let live { LiveBadge(status: live.room?.status ?? .live).padding(.leading, 2) }
            Spacer(minLength: 0)
            Button { player.commentsEnabled.toggle() } label: {
              DanmakuSymbol().fill(.foreground).frame(width: 15, height: 15)
            }.buttonStyle(MiniGlassButtonStyle(active: player.commentsEnabled))
              .help(player.commentsEnabled ? "隐藏弹幕" : "显示弹幕").accessibilityLabel("弹幕")
              .accessibilityValue(player.commentsEnabled ? "显示" : "隐藏")
          }
        }
        Spacer(minLength: 4)
        HStack(spacing: 20) {
          if live == nil {
            Button { seek(by: -10) } label: { Image(systemName: "gobackward.10") }
              .buttonStyle(MiniGlassButtonStyle(size: 34)).help("后退 10 秒").accessibilityLabel("后退 10 秒")
          }
          PlayerPlayButton(paused: player.paused, size: 44) { player.togglePause() }
          if live == nil {
            Button { seek(by: 10) } label: { Image(systemName: "goforward.10") }
              .buttonStyle(MiniGlassButtonStyle(size: 34)).help("前进 10 秒").accessibilityLabel("前进 10 秒")
          }
        }
        Spacer(minLength: 4)
        if live == nil {
          VStack(alignment: .leading, spacing: 6) {
            PlayerTimeLabel(clock: player.clock, duration: duration)
            PlaybackProgressBar(clock: player.clock, duration: duration).clipShape(Capsule())
          }
        }
      }.padding(10)
    }
  }

  /// Actions that close the panel run on the next turn: tearing down the hosting view inside
  /// its own event handling would release it mid-call.
  private func leave(_ action: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { action() }
  }

  private func seek(by seconds: Double) {
    chrome.activity()
    player.seek(min(max(0, duration), max(0, player.time + seconds)))
  }
}

/// The mini window's countdown to the next item: a glass capsule with the seconds left and
/// 取消. Only this view redraws while it counts down.
private struct MiniNextPlaybackPrompt: View {
  let deadline: Date
  let cancel: () -> Void
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { context in
      let remaining = Int(ceil(max(0, deadline.timeIntervalSince(context.date))))
      HStack(spacing: 8) {
        Text("\(remaining) 秒后播放下一个").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.white)
        Button("取消", action: cancel).buttonStyle(.plain).font(Theme.Font.caption.weight(.semibold))
          .foregroundStyle(Theme.accentText(.dark)).accessibilityLabel("取消播放下一个")
      }
      .padding(.horizontal, 12).frame(height: 28)
      .glassEffect(.regular.tint(.black.opacity(0.25)), in: Capsule())
    }
  }
}

/// Small round Liquid Glass buttons on the mini window.
private struct MiniGlassButtonStyle: ButtonStyle {
  var size: CGFloat = 28
  var active = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(active ? Theme.onAccent : .white)
      .frame(width: size, height: size)
      // On: a solid accent disc like the main panel's switch (a tinted glass washes out to grey).
      .background { if active { Circle().fill(Theme.accent) } }
      .glassEffect(active ? .regular.interactive() : .regular.tint(.black.opacity(0.2)).interactive(), in: Circle())
      .contentShape(Circle())
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
  }
}

/// AppKit mouse handling under the mini window's controls: hover (in any app state), click,
/// double-click and dragging the panel by any point of the picture.
private struct MiniPlayerMouseArea: NSViewRepresentable {
  let hover: (Bool) -> Void
  let moved: () -> Void
  let click: () -> Void
  let doubleClick: () -> Void
  func makeNSView(context: Context) -> MiniPlayerMouseView { MiniPlayerMouseView() }
  func updateNSView(_ view: MiniPlayerMouseView, context: Context) {
    view.hover = hover; view.moved = moved; view.click = click; view.doubleClick = doubleClick
  }
}

private final class MiniPlayerMouseView: NSView {
  var hover: (Bool) -> Void = { _ in }
  var moved: () -> Void = {}
  var click: () -> Void = {}
  var doubleClick: () -> Void = {}
  private var pendingClick: DispatchWorkItem?
  private var tracking: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hover(true) }
  override func mouseExited(with event: NSEvent) { hover(false) }
  override func mouseMoved(with event: NSEvent) { moved() }

  override func mouseDown(with event: NSEvent) {
    moved()
    if event.clickCount >= 2 {
      pendingClick?.cancel(); pendingClick = nil
      doubleClick()
      return
    }
    guard let panel = window as? MiniPlayerPanel else { return }
    let start = event.locationInWindow
    // A click unless the pointer travels 3pt before the button comes up; then a window drag.
    while let next = panel.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      if next.type == .leftMouseUp {
        let work = DispatchWorkItem { [weak self] in self?.pendingClick = nil; self?.click() }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        return
      }
      let point = next.locationInWindow
      if hypot(point.x - start.x, point.y - start.y) >= 3 {
        panel.drag(from: event)
        return
      }
    }
  }
}
