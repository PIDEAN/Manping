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
@MainActor final class PlayerFullScreenTransition {
  /// The window shows the playback page now.
  private let showsPlayer: () -> Bool
  /// The window is (or is about to be) in full screen; its layout follows before any frame change.
  private let setFullScreen: (Bool) -> Void
  /// The frame to return to, read before the window leaves it.
  private var windowedFrame: NSRect?
  private var entering = false
  private var exiting = false

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
    setFullScreen(false)
  }
  private func beginEntering(_ window: NSWindow) {
    guard !entering else { return }
    entering = true
    exiting = false
    if !window.styleMask.contains(.fullScreen) { windowedFrame = window.frame }
    setFullScreen(true)
  }

  // MARK: Leaving

  /// `customWindowsToExitFullScreen(for:)`: the playback page returns to its windowed frame itself.
  func customWindowsToExit(_ window: NSWindow) -> [NSWindow]? {
    beginExiting()
    return showsPlayer() && windowedFrame != nil ? [window] : nil
  }
  /// `windowWillExitFullScreen(_:)`, for either transition.
  func willExit() { beginExiting() }
  /// `window(_:startCustomAnimationToExitFullScreenWithDuration:)`.
  func startExiting(_ window: NSWindow, duration: TimeInterval) {
    beginExiting()
    window.styleMask.remove(.fullScreen)
    guard let windowedFrame else { return }
    move(window, to: windowedFrame, duration: duration)
  }
  func didExit() { exiting = false }
  func didFailToExit() {
    exiting = false
    setFullScreen(true)
  }
  private func beginExiting() {
    guard !exiting else { return }
    exiting = true
    entering = false
    setFullScreen(false)
  }

  /// The window closed (the standalone window can close while in full screen).
  func reset() {
    entering = false
    exiting = false
    windowedFrame = nil
    setFullScreen(false)
  }

  // MARK: Animation

  /// Moves the window frame in steps on the main thread: every step lays the page out at that
  /// size, so the picture and the danmaku keep rendering live instead of being scaled.
  private func move(_ window: NSWindow, to frame: NSRect, duration: TimeInterval) {
    // The layout switch (sidebar, toolbar, right column) lands at the current size first.
    window.contentView?.layoutSubtreeIfNeeded()
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || duration <= 0 {
      window.setFrame(frame, display: true)
      return
    }
    let level = window.level
    // AppKit finishes its side of the transition `duration` after it asked for the animation;
    // the move ends just before, so no step lands after AppKit has placed the window.
    let deadline = CACurrentMediaTime() + duration - 0.04
    // Above the menu bar while the frame moves over it, as the system transition does.
    window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    // One main-loop turn lets SwiftUI apply the layout switch before the first step.
    DispatchQueue.main.async { [weak window] in
      guard let window else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = max(0.1, deadline - CACurrentMediaTime())
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrame(frame, display: true)
      } completionHandler: { [weak window] in
        MainActor.assumeIsolated { window?.level = level }
      }
    }
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
