#if DEBUG
import AppKit
import ManpingCore

/// Debug-only diagnosis of the full-screen exit (`MANPING_FS_PROBE=<json path>` with
/// `--ui-fixture`): opens the sample video, enters and leaves full screen, and records whether
/// the window is still on screen and the app still active afterwards (Stage Manager can move a
/// window into its strip).

@MainActor enum DebugFullScreenProbe {
  private static var started = false
  static func startIfRequested(model: AppModel) {
    guard !started, DebugUIFixtures.enabled,
      let path = ProcessInfo.processInfo.environment["MANPING_FS_PROBE"] else { return }
    started = true
    Task { await run(model: model, output: URL(fileURLWithPath: path)) }
  }

  private static func sample(_ window: NSWindow, _ label: String) -> [String: Any] {
    let screen = window.screen ?? NSScreen.main
    func values(_ rect: NSRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
    return [
      "label": label, "visible": window.isVisible, "miniaturized": window.isMiniaturized,
      "occlusionVisible": window.occlusionState.contains(.visible), "onActiveSpace": window.isOnActiveSpace,
      "key": window.isKeyWindow, "appActive": NSApp.isActive, "level": window.level.rawValue,
      "fullScreen": window.styleMask.contains(.fullScreen),
      "frame": values(window.frame),
      "screenFrame": screen.map { values($0.frame) } as Any? ?? NSNull(),
      "screenVisibleFrame": screen.map { values($0.visibleFrame) } as Any? ?? NSNull(),
      "holdsFrame": (window as? PlayerHostWindow)?.holdsFrame ?? false,
    ]
  }

  private static func run(model: AppModel, output: URL) async {
    var samples: [[String: Any]] = []
    func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() { if Date() > deadline { return false }; await pause(0.05) }
      return true
    }
    _ = await wait(20) { model.fixtureReady }
    guard let window = (NSApp.delegate as? AppDelegate)?.window else { return }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // `MANPING_FS_FRAME=x,y,w,h` (screen points, bottom-left origin): where the window starts.
    if let raw = ProcessInfo.processInfo.environment["MANPING_FS_FRAME"] {
      let v = raw.split(separator: ",").compactMap { Double($0) }
      if v.count == 4 { window.setFrame(NSRect(x: v[0], y: v[1], width: v[2], height: v[3]), display: true) }
      await pause(0.5)
    }
    model.open(Video(bvid: DebugUIFixtures.bvid, title: "全屏自检", aid: 100))
    await pause(3)
    // `MANPING_FS_MEDIA`: a local file playing in the real player, as an actual video would.
    if let media = ProcessInfo.processInfo.environment["MANPING_FS_MEDIA"] {
      model.player.load(video: URL(fileURLWithPath: media), audio: nil)
      model.player.set("loop-file", "inf")
      model.player.set("mute", "yes")
      _ = await wait(10) { model.player.time > 0.5 }
      await pause(1)
    }
    samples.append(sample(window, "before"))
    window.toggleFullScreen(nil)
    let entered = await wait(10) { window.styleMask.contains(.fullScreen) }
    await pause(2.5)
    samples.append(sample(window, entered ? "fullScreen" : "enterTimedOut"))
    window.toggleFullScreen(nil)
    let exited = await wait(10) { !window.styleMask.contains(.fullScreen) }
    for delay in [0.3, 1.0, 2.5] {
      await pause(delay)
      samples.append(sample(window, (exited ? "afterExit+" : "exitTimedOut+") + String(delay)))
    }
    let report: [String: Any] = ["samples": samples]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output)
    }
    NSApp.terminate(nil)
  }
}
#endif
