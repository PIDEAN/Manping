import AppKit
import SwiftUI

/// Full screen for a window that can show the player (DesignSystem.md §11).
///
/// While the window shows the playback page, full screen is immersive: the shell drops its
/// sidebar and toolbar and the page its right column (`EnvironmentValues.immersivePlayback`),
/// leaving the picture, the danmaku and the glass control panel. The window then enters and
/// leaves full screen with its own animation: the layout switches first, then the window frame
/// moves to the screen (and back) step by step, so the picture and the danmaku render at their
/// real size on every frame. The system transition scales snapshots of the window instead: the
/// video stood still for half a second and the danmaku looked stretched, then snapped back.
/// Other pages keep the system transition. 减弱动态效果 makes the move instant.
///
/// Both ways the frame moves with the immersive layout (picture only), which costs one stage
/// layout per step; the toolbar and the right column change only at the windowed size: on the
/// way in before the window grows, on the way out after it has shrunk. Switching them back at
/// the start of the exit laid the whole page (comment list, recommendations) out at every step
/// of the shrink and showed the right column appear at screen size, then shrink with the window.
@MainActor final class PlayerFullScreenTransition {
  /// The window shows the playback page now.
  private let showsPlayer: () -> Bool
  /// The window is (or is about to be) in full screen; its layout follows before any frame change.
  private let setFullScreen: (Bool) -> Void
  /// The frame to return to, read before the window leaves it.
  private var windowedFrame: NSRect?
  private var entering = false
  private var exiting = false
  /// Bumped by every new transition, a failure and `reset`: a frame animation still running from
  /// an earlier one restores its window but no longer changes the layout.
  private var transition: UInt64 = 0
  private weak var movingWindow: NSWindow?
  private var savedLevel: NSWindow.Level?
  private var exitTarget: NSRect?

  private func finishMove(finalFrame: NSRect? = nil) {
    guard let window = movingWindow else { savedLevel = nil; exitTarget = nil; return }
    hold(window, false)
    if let level = savedLevel { window.level = level }
    if let finalFrame { window.setFrame(finalFrame, display: true) }
    movingWindow = nil
    savedLevel = nil
    exitTarget = nil
  }

  init(showsPlayer: @escaping () -> Bool, setFullScreen: @escaping (Bool) -> Void) {
    self.showsPlayer = showsPlayer
    self.setFullScreen = setFullScreen
  }

  // MARK: Entering

  /// `customWindowsToEnterFullScreen(for:)`: this window animates itself while it shows the player.
  func customWindowsToEnter(_ window: NSWindow) -> [NSWindow]? {
    beginEntering(window)
    return showsPlayer() ? [window] : nil
  }
  /// `windowWillEnterFullScreen(_:)`, for either transition.
  func willEnter(_ window: NSWindow) { beginEntering(window) }
  /// `window(_:startCustomAnimationToEnterFullScreenWithDuration:)`.
  func startEntering(_ window: NSWindow, duration: TimeInterval) {
    beginEntering(window)
    guard let screen = window.screen ?? NSScreen.main else { return }
    // The system places full-screen windows below the camera housing; so does this one.
    var target = screen.frame
    target.size.height -= screen.safeAreaInsets.top
    // Marking the window full screen first hides its title bar; marking it after the move made
    // the space flash black. The mark makes AppKit jump the window to the screen, so the size
    // stays pinned for that jump (`willUseFullScreenContentSize`: laying the page out once at
    // the screen size flashed an enlarged picture) and the window goes back to where it was.
    let start = window.frame
    hold(window, true)
    pinnedContentSize = window.contentRect(forFrameRect: start).size
    window.styleMask.insert(.fullScreen)
    pinnedContentSize = nil
    window.setFrame(start, display: false)
    move(window, to: target, duration: duration)
  }
  /// `window(_:willUseFullScreenContentSize:)`.
  func fullScreenContentSize(proposed: NSSize) -> NSSize { pinnedContentSize ?? proposed }
  private var pinnedContentSize: NSSize?
  func didEnter() { entering = false }
  func didFailToEnter() {
    entering = false
    transition &+= 1
    finishMove()
    setFullScreen(false)
  }
  private func beginEntering(_ window: NSWindow) {
    guard !entering else { return }
    finishMove()
    entering = true
    transition &+= 1
    exiting = false
    if !window.styleMask.contains(.fullScreen) { windowedFrame = window.frame }
    setFullScreen(true)
  }

  // MARK: Leaving

  /// `customWindowsToExitFullScreen(for:)`: the playback page returns to its windowed frame itself.
  func customWindowsToExit(_ window: NSWindow) -> [NSWindow]? {
    beginExiting()
    let animates = showsPlayer() && windowedFrame != nil
    // The system transition animates snapshots of the windowed layout: switch it now.
    if !animates { setFullScreen(false) }
    return animates ? [window] : nil
  }
  /// `windowWillExitFullScreen(_:)`, for either transition. The layout waits (see the type).
  func willExit() { beginExiting() }
  /// `window(_:startCustomAnimationToExitFullScreenWithDuration:)`.
  func startExiting(_ window: NSWindow, duration: TimeInterval) {
    beginExiting()
    guard let windowedFrame else {
      window.styleMask.remove(.fullScreen)
      setFullScreen(false)
      return
    }
    // Removing the mark brings the title bar back; AppKit may also move the window, which still
    // covers the screen, to fit under the menu bar. The move starts from the screen, as entering
    // does, and nothing constrains the frame until it is done.
    let start = window.frame
    let target = (window.screen ?? NSScreen.main).map {
      playerExitFrame(windowedFrame, screen: $0.frame, visible: $0.visibleFrame)
    } ?? windowedFrame
    hold(window, true)
    window.styleMask.remove(.fullScreen)
    if window.frame != start { window.setFrame(start, display: false) }
    move(window, to: target, duration: duration, isExit: true) { [weak self] in self?.setFullScreen(false) }
  }
  func didExit() {
    transition &+= 1
    finishMove(finalFrame: exitTarget)
    exiting = false
    setFullScreen(false)
  }
  func didFailToExit() {
    exiting = false
    transition &+= 1
    finishMove()
    setFullScreen(true)
  }
  private func beginExiting() {
    guard !exiting else { return }
    finishMove()
    exiting = true
    transition &+= 1
    entering = false
  }

  /// The window closed (the standalone window can close while in full screen).
  func reset() {
    entering = false
    exiting = false
    transition &+= 1
    finishMove()
    windowedFrame = nil
    setFullScreen(false)
  }

  // MARK: Animation

  /// Moves the window frame in steps on the main thread: every step lays the page out at that
  /// size, so the picture and the danmaku keep rendering live instead of being scaled.
  /// `completion` runs once the frame has arrived.
  private func move(_ window: NSWindow, to frame: NSRect, duration: TimeInterval,
    isExit: Bool = false, completion: (@MainActor @Sendable () -> Void)? = nil) {
    movingWindow = window
    exitTarget = isExit ? frame : nil
    // The layout switch (sidebar, toolbar, right column) lands at the current size first.
    window.contentView?.layoutSubtreeIfNeeded()
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || duration <= 0 {
      finishMove(finalFrame: frame)
      completion?()
      return
    }
    savedLevel = window.level
    // AppKit finishes its side of the transition `duration` after it asked for the animation;
    // the move ends just before, so no step lands after AppKit has placed the window.
    let deadline = CACurrentMediaTime() + duration - 0.04
    // Above the menu bar while the frame moves over it, as the system transition does.
    window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    // One main-loop turn lets SwiftUI apply the layout switch before the first step.
    let current = transition
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window, self.transition == current else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = max(0.1, deadline - CACurrentMediaTime())
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrame(frame, display: true)
      } completionHandler: { [weak self, weak window] in
        MainActor.assumeIsolated {
          guard let self, window != nil, self.transition == current else { return }
          self.finishMove(finalFrame: isExit ? frame : nil)
          completion?()
        }
      }
    }
  }

  /// While the transition moves the frame AppKit must leave it alone (`PlayerHostWindow`).
  private func hold(_ window: NSWindow, _ value: Bool) {
    (window as? PlayerHostWindow)?.holdsFrame = value
  }
}

/// Fits a saved window frame to the screen currently hosting full screen.
func playerExitFrame(_ saved: NSRect, screen: NSRect, visible: NSRect) -> NSRect {
  let width = min(max(0, saved.width), visible.width)
  let height = min(max(0, saved.height), visible.height)
  let overlap = saved.intersection(screen)
  let area = saved.width * saved.height
  if overlap.isNull || overlap.width * overlap.height < area / 2 {
    return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                  width: width, height: height)
  }
  return NSRect(x: min(max(saved.minX, visible.minX), visible.maxX - width),
                y: min(max(saved.minY, visible.minY), visible.maxY - height),
                width: width, height: height)
}

/// A window that can show the player. During a full-screen transition its frame is the
/// transition's: AppKit constrains a window to the screen's visible frame (below the menu bar)
/// when its level or style changes, and on the way out, with the full-screen mark already
/// removed, it pulled the window down and shortened it before and while the frame moved, so the
/// window changed size several times instead of once.
final class PlayerHostWindow: NSWindow {
  var holdsFrame = false
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    holdsFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }
}

private struct ImmersivePlaybackKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// The playback page fills a full-screen window: no right column, no toolbar.
  var immersivePlayback: Bool {
    get { self[ImmersivePlaybackKey.self] }
    set { self[ImmersivePlaybackKey.self] = newValue }
  }
}
