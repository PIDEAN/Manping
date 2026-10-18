import AppKit

/// Hosts one playback page after the root removes its previous SwiftUI owner.
/// It never creates a PlayerModel or a second render surface.
@MainActor final class M7PlaybackWindowCoordinator: NSObject, NSWindowDelegate {
  private(set) var window: NSWindow?
  private weak var mainWindow: NSWindow?
  private var restoreMain = false
  private var onClose: (@MainActor () -> Void)?
  /// The window's own full-screen button moved the picture; a pending open placement must yield.
  var onUserPlaced: (@MainActor () -> Void)?
  private var closing = false
  /// Shows `content` in the window. `displayMode` (default, fullscreen or compact) is applied
  /// when the caller opens something there; nil keeps the window's current state.
  func present(content: NSView, mainWindow: NSWindow?, hideMain: Bool, displayMode: String?,
    onClose: @escaping @MainActor () -> Void) {
    self.mainWindow = mainWindow
    self.onClose = onClose
    if window == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.title = "满屏 · 播放"
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.backgroundColor = Theme.backdropNSColor
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.minSize = NSSize(width: 760, height: 480)
      window.delegate = self
      window.center()
      // Reopens where the user last left it (center() is only the first-run default).
      window.setFrameAutosaveName("PlaybackWindow")
      self.window = window
    }
    guard let window else { return }
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    if hideMain, mainWindow?.isVisible == true {
      restoreMain = true
      mainWindow?.orderOut(nil)
    }
    if let displayMode { applyDisplayMode(displayMode) }
  }
  func applyDisplayMode(_ displayMode: String) {
    guard let window else { return }
    let fullScreen = window.styleMask.contains(.fullScreen)
    if displayMode == "fullscreen" {
      if !fullScreen { window.toggleFullScreen(nil) }
    } else {
      if fullScreen { window.toggleFullScreen(nil) }
      window.level = displayMode == "compact" ? .floating : .normal
      window.collectionBehavior = displayMode == "compact" ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
      if displayMode == "compact" {
        window.setContentSize(NSSize(width: 800, height: 500))
      }
    }
  }
  func close(showMain: Bool = true) {
    guard let window, !closing else { return }
    closing = true
    let callback = onClose
    onClose = nil
    window.delegate = nil
    window.contentView = nil
    window.close()
    self.window = nil
    if showMain || restoreMain { mainWindow?.makeKeyAndOrderFront(nil) }
    restoreMain = false
    closing = false
    callback?()
  }
  func windowWillClose(_ notification: Notification) { close(showMain: true) }
  func windowWillEnterFullScreen(_ notification: Notification) { onUserPlaced?() }
  func windowWillExitFullScreen(_ notification: Notification) { onUserPlaced?() }
}
