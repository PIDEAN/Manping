import AppKit
import Combine
import CoreSpotlight
import ManpingCore
import CMpv
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
  var window: NSWindow!
  let model = AppModel()
  var diagnosticsTimer: Timer?
  var probes: [String: String] = [:]
  var representation: [String: Any] = [:]
  /// `manping://…` links and Bilibili web links handed to the app (Finder, `open`, other apps).
  func application(_ application: NSApplication, open urls: [URL]) {
    var opened = false
    for url in urls.prefix(1) where model.openLink(url.absoluteString) { opened = true }
    if opened { NSApp.activate(); window?.makeKeyAndOrderFront(nil) }
  }
  /// Dock menu: what is playing, pinned live rooms and the usual destinations.
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    fillQuickMenu(menu, statusItem: false)
    model.refreshFollowedLive()
    return menu
  }
  /// Shared by the Dock menu and the menu bar item. Picks there do not activate the app; the
  /// dispatcher brings the window forward for everything but play/pause and next.
  private func fillQuickMenu(_ menu: NSMenu, statusItem: Bool) {
    // Order (DesignSystem.md section 8): 正在播放 — 正在直播 ▸、固定的直播间 ▸ — 打开链接…、收藏、
    // 稍后再看、历史记录、消息 — 显示满屏、退出满屏 (the last group only in the menu bar item).
    menu.removeAllItems()
    @discardableResult
    func add(_ title: String, _ action: Selector, to target: NSMenu = menu, tag: Int = 0, image: String? = nil) -> NSMenuItem {
      let item = target.addItem(withTitle: title, action: #selector(performDockItem(_:)), keyEquivalent: "")
      item.target = self; item.tag = tag; item.representedObject = NSStringFromSelector(action)
      if statusItem, let image { item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
      return item
    }
    func header(_ title: String) {
      menu.addItem(.sectionHeader(title: title))
    }
    func submenu(_ title: String, image: String) -> NSMenu {
      let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
      if statusItem { item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
      let sub = NSMenu(title: title); item.submenu = sub
      return sub
    }
    let title = model.livePlayback?.room?.title ?? model.pgcPlayback?.episode?.title ?? model.selected?.title
    if let title, model.hasPlayback {
      header("正在播放")
      // The title itself brings the player forward.
      add(title.count > 40 ? String(title.prefix(39)) + "…" : title, #selector(showPlayer), image: "play.rectangle")
      add(activePlayer.paused ? "继续" : "暂停", #selector(togglePlayback), image: activePlayer.paused ? "play.fill" : "pause.fill")
      if model.canPlayNext { add("下一个", #selector(nextEpisode), image: "forward.end.fill") }
      menu.addItem(.separator())
    }
    var hasRooms = false
    if model.accountMID != nil {
      let live = model.followedLiveNow.prefix(10)
      let sub = submenu("正在直播", image: "dot.radiowaves.left.and.right")
      if live.isEmpty {
        sub.addItem(withTitle: "关注的主播都没有开播", action: nil, keyEquivalent: "").isEnabled = false
      }
      for room in live {
        add(room.author.isEmpty ? room.title : "\(room.author) · \(room.title)", #selector(openDockLiveRoom(_:)),
          to: sub, tag: Int(room.id))
      }
      hasRooms = true
    }
    let rooms = PinnedLiveStore.shared.rooms.prefix(8)
    if !rooms.isEmpty {
      let sub = submenu("固定的直播间", image: "pin")
      for room in rooms {
        add(room.title.isEmpty ? "直播间 \(room.id)" : room.title, #selector(openDockLiveRoom(_:)), to: sub, tag: Int(room.id))
      }
      hasRooms = true
    }
    if hasRooms { menu.addItem(.separator()) }
    add("打开链接…", #selector(openLinkFromClipboard), image: "link")
    add("收藏", #selector(openFavorites), image: "star")
    add("稍后再看", #selector(openLater), image: "clock")
    add("历史记录", #selector(openHistory), image: "clock.arrow.circlepath")
    add(model.unreadMessageCount > 0 ? "消息（\(model.unreadMessageCount)）" : "消息", #selector(openMessages), image: "bubble.left")
    if statusItem {
      menu.addItem(.separator())
      add("显示满屏", #selector(showMainWindow))
      let quit = menu.addItem(withTitle: "退出满屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
      quit.target = NSApp
    }
  }
  @objc private func showMainWindow() { window?.makeKeyAndOrderFront(nil) }
  @objc private func showPlayer() { model.showPlayer() }

  // MARK: Menu bar item

  private var statusItem: NSStatusItem?
  private var statusObservation: AnyCancellable?
  /// The playback page hides the sidebar (or ⌃⌘S floats it over the page): the window buttons follow.
  private var sidebarObservation: AnyCancellable?
  private var statusMenu: NSMenu?
  /// Shows or hides the menu bar item for 设置 › 在菜单栏显示.
  func updateStatusItem(visible: Bool) {
    if visible, statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      let icon = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        ?? NSImage(systemSymbolName: "play.tv", accessibilityDescription: nil)
      icon?.size = NSSize(width: 18, height: 18)
      icon?.isTemplate = true
      icon?.accessibilityDescription = "满屏"
      item.button?.image = icon
      let menu = NSMenu(); menu.delegate = self
      item.menu = menu
      statusItem = item; statusMenu = menu
      #if DEBUG
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        FileHandle.standardError.write(Data("status-item visible=\(item.isVisible) frame=\(item.button?.window?.frame ?? .zero)\n".utf8))
        // --ui-status-menu: open it for a screenshot check.
        if ProcessInfo.processInfo.arguments.contains("--ui-status-menu") { item.button?.performClick(nil) }
      }
      #endif
    } else if !visible, let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil; statusMenu = nil
    }
  }
  func menuNeedsUpdate(_ menu: NSMenu) {
    if menu === speedMenu { fillSpeedMenu(menu); return }
    if menu === subtitleMenu { fillSubtitleMenu(menu); return }
    if menu === qualityMenu { fillQualityMenu(menu); return }
    guard menu === statusMenu else { return }
    fillQuickMenu(menu, statusItem: true)
    // Refresh followed rooms in the background; the next open shows the new list.
    model.refreshFollowedLive()
  }
  @objc private func performDockItem(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    let action = NSSelectorFromString(name)
    if action != #selector(togglePlayback) && action != #selector(nextEpisode) {
      NSApp.activate(); window?.makeKeyAndOrderFront(nil)
    }
    NSApp.sendAction(action, to: self, from: sender)
  }
  @objc private func openDockLiveRoom(_ sender: NSMenuItem) { model.openLiveRoom(Int64(sender.tag)) }
  /// Spotlight results this app indexed reopen through their `manping://` identifier.
  func application(_ application: NSApplication, continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
    guard userActivity.activityType == CSSearchableItemActionType,
      let link = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
    NSApp.activate(); window?.makeKeyAndOrderFront(nil)
    return model.openLink(link)
  }
  @objc private func openLinkFromClipboard() {
    let pasted = NSPasteboard.general.string(forType: .string) ?? ""
    if BiliLinkParser.parse(pasted) != nil { model.openLink(pasted); return }
    let alert = NSAlert()
    alert.messageText = "打开哔哩哔哩链接"
    alert.informativeText = "粘贴视频、番剧、直播间、专栏或空间链接，也可以直接输入 BV、av、ep、ss、cv 编号。"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "https://www.bilibili.com/video/BV… 或 b23.tv/…"
    alert.accessoryView = field
    alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if !model.openLink(field.stringValue) { model.error = "没有识别出哔哩哔哩链接或编号。" }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Performance diagnostics run as an accessory (no Dock icon, never activated by launch) so they do
    // not take focus or keystrokes from the user's frontmost app. `.prohibited` stops the display
    // link from driving the window at all, so it cannot be used here.
    let args = ProcessInfo.processInfo.arguments
    var quietLaunch = PerformanceOptions.requested
    #if DEBUG
    quietLaunch = quietLaunch || args.contains("--ui-quiet")
    #endif
    NSApp.setActivationPolicy(quietLaunch ? .accessory : .regular)
    let options: DiagnosticArguments
    var diagnosticArgs = [args[0]]
    var skipAuthentication = false
    var launchPage: String?
    var launchTheme: AppTheme?
    var launchWindowSize: NSSize?
    #if DEBUG
    var modelChecks = false
    var runtimeChecks: String?
    var snapshotRequest: (URL, Double)?
    #endif
    var index = 1
    while index < args.count {
      if ["--perf-fixture", "--perf-stability", "--perf-memory-stress", "--perf-network-direct", "--perf-network-cancel-refresh"].contains(args[index]) ||
        (PerformanceOptions.requested && args[index] == "--skip-auth") {
        index += 1; continue
      }
      if ["--perf-anonymous-bvid", "--perf-anonymous-live", "--perf-anonymous-seconds", "--perf-audio-driver", "--perf-audio-buffer", "--perf-cache-pause-wait",
        "--perf-scroll", "--perf-play-local", "--perf-media", "--perf-memory-iterations", "--perf-memory-ack-dir",
        "--perf-danmaku", "--perf-source-fps", "--perf-network", "--perf-network-seconds", "--perf-network-backup", "--perf-network-refresh", "--perf-network-third", "--perf-network-refresh-backup",
        "--perf-network-hide-seconds", "--perf-network-hidden-reload-at", "--perf-network-node-policy",
        "--perf-scroll-hz", "--perf-scroll-seconds", "--perf-scroll-speed", "--perf-covers", "--perf-pointer"].contains(args[index]), index + 1 < args.count {
        index += 2; continue
      }
      #if DEBUG
        if args[index] == "--ui-runtime-checks", index + 1 < args.count {
          runtimeChecks = args[index + 1]; index += 2; continue
        }
        if args[index] == "--ui-model-checks" {
          modelChecks = true; index += 1; continue
        }
        if args[index] == "--ui-episodic" {
          index += 1; continue
        }
        if args[index] == "--ui-window-size", index + 2 < args.count {
          guard let width = Double(args[index + 1]), let height = Double(args[index + 2]),
            width.isFinite, height.isFinite, (720...3840).contains(width), (600...2160).contains(height)
          else {
            model.error = "Invalid diagnostic arguments"
            model.shutdown(); NSApp.terminate(nil); return
          }
          launchWindowSize = NSSize(width: width, height: height)
          index += 3; continue
        }
        if ["--ui-quiet", "--ui-space-fallback", "--ui-space-detail", "--ui-space-model-checks"].contains(args[index]) {
          index += 1; continue
        }
        if args[index] == "--ui-space-tab", index + 1 < args.count {
          guard ["主页", "投稿", "合集和系列", "动态"].contains(args[index + 1]) else {
            model.shutdown(); NSApp.terminate(nil); return
          }
          index += 2; continue
        }
        if args[index] == "--ui-fixture" {
          skipAuthentication = true
          index += 1
          continue
        }
        if args[index] == "--skip-auth" {
          skipAuthentication = true
          index += 1
          continue
        }
        if args[index] == "--ui-page", index + 1 < args.count {
          launchPage = args[index + 1]
          index += 2
          continue
        }
        if args[index] == "--ui-theme", index + 1 < args.count {
          launchTheme = AppTheme(rawValue: args[index + 1])
          if launchTheme == nil {
            launchTheme =
              args[index + 1] == "light"
              ? .light
              : args[index + 1] == "dark" ? .dark : nil
          }
          if launchTheme == nil {
            model.error = "Invalid diagnostic arguments"
            model.shutdown()
            NSApp.terminate(nil)
            return
          }
          index += 2
          continue
        }
        if args[index] == "--ui-video-tab", index + 1 < args.count {
          let tab = args[index + 1]
          guard ["info", "parts", "episodes", "seasons", "collections", "related", "comments", "ai"].contains(tab) else {
            model.shutdown()
            NSApp.terminate(nil)
            return
          }
          model.launchVideoTab = tab
          index += 2
          continue
        }
        if ["--ui-live-area", "--ui-live-sort", "--ui-live-scene"].contains(args[index]), index + 1 < args.count {
          index += 2; continue
        }
        if ["--ui-playback-report", "--ui-report-seconds", "--ui-report-actions"].contains(args[index]), index + 1 < args.count {
          index += 2; continue
        }
        if ["--ui-cdn-panel", "--ui-danmaku-panel", "--ui-danmaku-shield", "--ui-more-menu"].contains(args[index]) { index += 1; continue }
        if args[index] == "--ui-seek-preview", index + 1 < args.count { index += 2; continue }
        // Playback stage screenshot checks (PlayerStageDebug).
        if args[index] == "--ui-player-placement", index + 1 < args.count { index += 2; continue }
        // 设置 › 控制条 screenshot checks (PlayerBarStore, PlayerBarCustomizer).
        if ["--ui-player-bar", "--ui-bar-drag", "--ui-bar-width"].contains(args[index]), index + 1 < args.count { index += 2; continue }
        if args[index] == "--ui-status-menu" || args[index] == "--ui-translate" { index += 1; continue }
        if args[index] == "--ui-snapshot", index + 2 < args.count, let delay = Double(args[index + 2]), (1...120).contains(delay) {
          snapshotRequest = (URL(fileURLWithPath: args[index + 1]), delay); index += 3; continue
        }
        if args[index] == "--ui-spotlight-check" {
          DispatchQueue.main.asyncAfter(deadline: .now() + 12) { WatchActivity.debugReport() }
          index += 1; continue
        }
        if args[index] == "--ui-ai-preview" {
          guard DebugUIFixtures.enabled else { model.shutdown(); NSApp.terminate(nil); return }
          index += 1; continue
        }
        // AI panel screenshot scenes (fixture service only; nothing leaves the Mac).
        if args[index] == "--ui-ai-scene", index + 1 < args.count {
          guard DebugUIFixtures.enabled, ["intro", "chapters", "context", "highlights", "comments", "clips", "official", "settings"].contains(args[index + 1]) else {
            model.shutdown(); NSApp.terminate(nil); return
          }
          index += 2; continue
        }
        if args[index] == "--ui-ai-provider", index + 1 < args.count {
          guard DebugUIFixtures.enabled, AIProvider(rawValue: args[index + 1]) != nil else { model.shutdown(); NSApp.terminate(nil); return }
          index += 2; continue
        }
      #endif
      diagnosticArgs.append(args[index])
      index += 1
    }
    do {
      #if DEBUG
        if let scene = DebugUIFixtures.liveScene {
          guard LiveSessionFixture.scenes.contains(scene) else {
            throw DiagnosticArguments.Failure.invalid("--ui-live-scene")
          }
          if DebugUIFixtures.livePresentation?.opensLiveSettings == true {
            launchPage = "settings:live"
          }
        }
      #endif
      try PerformanceOptions.validate()
      if let page = PerformanceOptions.scrollPage { launchPage = page == "search" ? "search:性能样本" : page }
      if PerformanceOptions.requested { skipAuthentication = true; launchTheme = .dark }
      options = try DiagnosticArguments(diagnosticArgs)
      if let launchPage,
        !model.configureLaunchPage(launchPage == "settings:live" ? "settings" : launchPage)
      {
        throw DiagnosticArguments.Failure.invalid("--ui-page")
      }
      if launchPage == "settings:live" { model.launchSettingsGroup = .live }
    } catch {
      // Do not echo argv: media URLs may contain signatures.
      model.error = "Invalid diagnostic arguments"
      model.shutdown()
      NSApp.terminate(nil)
      return
    }

    #if DEBUG
      if args.contains("--ui-space-model-checks") {
        guard DebugUIFixtures.enabled else { print("FAIL space checks require --ui-fixture"); NSApp.terminate(nil); return }
        Task {
          let passed = await SpaceLibraryModelChecks.run()
          print(passed ? "PASS all space LibraryModel checks" : "FAIL space LibraryModel checks")
          model.shutdown(); NSApp.terminate(nil)
        }
        Task {
          try? await Task.sleep(for: .seconds(20))
          print("FAIL space LibraryModel checks timed out")
          NSApp.terminate(nil)
        }
        return
      }
      if let runtimeChecks {
        guard DebugUIFixtures.enabled else { print("FAIL runtime checks require --ui-fixture"); NSApp.terminate(nil); return }
        Task {
          let passed = await DebugM7RuntimeChecks.run(mockExecutable: runtimeChecks)
          print(passed ? "PASS all M7 runtime checks" : "FAIL M7 runtime checks")
          model.shutdown(); NSApp.terminate(nil)
        }
        return
      }
      if modelChecks {
        guard DebugUIFixtures.enabled else { print("FAIL model checks require --ui-fixture"); NSApp.terminate(nil); return }
        Task {
          let passed = await DebugUIModelChecks.run()
          print(passed ? "PASS all AppModel checks" : "FAIL AppModel checks")
          model.shutdown(); NSApp.terminate(nil)
        }
        return
      }
    #endif

    installMenus()
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = model.usesUIFixtures ? "满屏 · 本地样本" : "满屏"
    window.minSize = NSSize(width: 900, height: 600)
    window.titlebarAppearsTransparent = true
    if options.requested && options.flags.contains("--fixed-viewport") {
      let dimensions = DiagnosticArguments.viewportPoints(scale: window.backingScaleFactor)
      window.minSize = .zero
      window.setContentSize(NSSize(width: dimensions.width, height: dimensions.height))
      window.contentView = VideoSurface(model: model.player)
      representation["requestedPixelViewport"] = [1280, 720]
    } else {
      window.styleMask.insert(.fullSizeContentView)
      window.titleVisibility = .hidden
      window.isMovableByWindowBackground = true
      window.backgroundColor = Theme.backdropNSColor
      if let launchWindowSize { window.setContentSize(launchWindowSize) }
      window.contentView = NSHostingView(
        rootView: ContentView(model: model, diagnosticTheme: launchTheme)
          .persistentAppStorage())
    }
    window.delegate = self
    // AppKit crash-history restoration would block launch with a modal "reopen windows?" alert.
    // The original MainWindow only persists its bounds, so keep just the frame.
    window.isRestorable = false
    window.center()
    if !DebugUIFixtures.usesLiveSceneMemory, launchWindowSize == nil,
      !(options.requested && options.flags.contains("--fixed-viewport"))
    {
      window.setFrameAutosaveName("MainWindow")
    }
    // Performance diagnostics run beside whatever the user is doing: the window shows (it must be on
    // screen to draw) but the app never takes focus from the frontmost app.
    let quietDiagnostics = quietLaunch
    if quietDiagnostics { window.ignoresMouseEvents = true; window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }
    // 设置 › 在菜单栏显示, now and whenever it changes.
    updateStatusItem(visible: model.appSettings.bool(.menuBarItem))
    statusObservation = model.$appSettings.map { $0.bool(.menuBarItem) }.removeDuplicates().dropFirst()
      .sink { [weak self] visible in DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateStatusItem(visible: visible) } } }
    // A badge set while the app was still launching (before the regular activation policy) is dropped.
    DispatchQueue.main.async { [weak self] in self?.model.updateDockBadge() }
    alignTrafficLights()
    DispatchQueue.main.async { [weak self] in self?.alignTrafficLights() }
    sidebarObservation = ShellSidebarState.shared.objectWillChange
      .sink { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.alignTrafficLights() } } }
    if !quietDiagnostics { NSApp.activate(ignoringOtherApps: true) }
    SettingsWindowController.shared.diagnosticTheme = launchTheme
    // `--ui-page settings…` opens the settings window on that category; screenshots capture it.
    let settingsWindow: NSWindow? = model.launchSettingsGroup.flatMap { group in
      if model.launchSettingsPlayerBar { model.openPlayerBarSettings() } else { model.openSettings(group) }
      return SettingsWindowController.shared.window
    }
    #if DEBUG
    if DebugUIFixtures.liveScene?.hasPrefix("settings-") == true, let launchWindowSize {
      settingsWindow?.setContentSize(launchWindowSize)
    }
    #endif
    #if DEBUG
      if let index = args.firstIndex(of: "--ui-playback-report"), index + 1 < args.count {
        let seconds = args.firstIndex(of: "--ui-report-seconds").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 25
        let actions = args.firstIndex(of: "--ui-report-actions").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? ""
        DebugPlaybackReport.start(model: model, path: args[index + 1], seconds: seconds, actions: actions)
      }
      if skipAuthentication || launchPage != nil {
        let captured = settingsWindow ?? window!
        if let (destination, delay) = snapshotRequest {
          // Screen recording may be unavailable to the check script; the app renders its own window.
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak captured] in
            guard let view = captured?.contentView?.superview ?? captured?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
              FileHandle.standardError.write(Data("UI snapshot failed: window view unavailable\n".utf8)); return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
              FileHandle.standardError.write(Data("UI snapshot failed: PNG encoding unavailable\n".utf8)); return
            }
            do {
              // Publish only a complete PNG to the diagnostic driver's ready check.
              try data.write(to: destination, options: .atomic)
              FileHandle.standardOutput.write(Data("UI snapshot ready\n".utf8))
            } catch {
              FileHandle.standardError.write(Data("UI snapshot failed: PNG write error\n".utf8))
            }
          }
        }
        print("Debug window number: \(captured.windowNumber)")
        if Bundle.main.bundleURL.pathExtension == "app" {
          let windowFile = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(
            "window-id")
          try? String(captured.windowNumber).write(to: windowFile, atomically: true, encoding: .utf8)
          model.writeCaptureState()
        }
      }
    #endif
    if options.requested {
      model.selected = Video(bvid: "local-diagnostic", title: "媒体关键链路验证")
      model.player.timeline = DanmakuTimeline(
        comments: (0..<60).map {
          DanmakuComment(time: Double($0) / 3, text: "媒体时钟弹幕 \($0) · 原生 Metal")
        })
      if options.flags.contains("--glyph-probe") {
        // 2048 distinct CJK characters, revisited after eviction; all lines fit the parser's limit.
        let lines = (0..<16).map { row in
          String(
            (0..<128).compactMap { UnicodeScalar(0x4e00 + row * 128 + $0).map(Character.init) })
        }
        model.player.timeline = DanmakuTimeline(
          comments: (0..<48).map { index in
            DanmakuComment(time: Double(index / 8) * 1.5, mode: 5, text: lines[index % 16])
          }, lanes: 8, duration: 1.5)
      }
      let file = options.video
      let audio = options.audio
      model.player.start()
      model.player.set("mute", "yes")
      model.player.set("hwdec", options.values["--hwdec-mode"] ?? "videotoolbox")
      if let sigmoid = options.values["--sigmoid-upscaling"] {
        model.player.set("sigmoid-upscaling", sigmoid)
      }
      if options.flags.contains("--fixed-viewport") {
        model.player.commentsEnabled = false
        for (name, value) in [
          "video-unscaled": "no", "keepaspect": "yes", "panscan": "0",
          "target-prim": "bt.709", "target-trc": "srgb", "target-peak": "203",
          "tone-mapping": "bt.2390", "dither-depth": "no", "scale": "bilinear",
          "cscale": "bilinear", "dscale": "bilinear",
        ] { model.player.set(name, value) }
      }
      if let file { model.player.load(video: file, audio: audio) }
      if let bvid = options.values["--diagnose-bvid"] {
        Task {
          do {
            try await model.service.restoreCookies()
            let detail = try await model.service.detail(bvid)
            let streams = try await model.service.playback(detail)
            let video = streams.video.first { stream in
              (options.values["--codec"].map { stream.codec.hasPrefix($0) } ?? true)
                && (options.values["--quality"].flatMap(Int.init).map { stream.quality == $0 }
                  ?? true)
            }
            guard let video, let audio = streams.audio.first else {
              model.player.error = "Requested representation unavailable"
              return
            }
            representation["codec"] = video.codec
            representation["qn"] = video.quality
            representation["bandwidth"] = video.bandwidth
            representation["audioCodec"] = audio.codec
            // Public dimensions are not retained by MediaStream; obtain only the public metadata.
            if let cid = detail.cid {
              let dimensions = try await model.service.diagnosticDimensions(
                bvid: bvid, cid: cid, video: video)
              if dimensions.count == 2 {
                representation["width"] = dimensions[0]
                representation["height"] = dimensions[1]
              }
            }
            model.player.load(video: video.url, audio: audio.url)
          } catch {
            model.player.error = "Public playback diagnostic request failed"
          }
        }
      }
      if let shader = options.values["--shader"] {
        model.player.verboseLogs()
        model.player.set("glsl-shaders", shader)
      }
      if let preset = options.values["--preset"] {
        let parts = preset.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
          model.player.verboseLogs()
          model.shaderSelections = [parts[0]: parts[1]]
          model.applyShaders()
        }
      }
      if args.contains("--verbose") { model.player.verboseLogs() }
      if options.flags.contains("--danmaku-probe") {
        for (second, enabled) in [(2.0, false), (6.0, true)] {
          Timer.scheduledTimer(withTimeInterval: second, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.player.commentsEnabled = enabled }
          }
        }
        for second in [1.5, 3.0, 5.0, 7.5] {
          Timer.scheduledTimer(withTimeInterval: second, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
              self?.probes["danmakuAt\(second)"] = String(
                describing: DanmakuView.diagnosticEvidence)
            }
          }
        }
      }
      if args.contains("--pause-probe") {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated { self?.model.player.set("pause", "yes") }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.probes["pausedAt3"] = self?.model.player.surface?.renderEvidence
          }
        }
      }
      if args.contains("--stall-main") {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.probes["beforeMainStall"] = self.model.player.surface?.renderEvidence
            Thread.sleep(forTimeInterval: 2)
            self.probes["afterMainStall"] = self.model.player.surface?.renderEvidence
          }
        }
      }
      if args.contains("--stress"), let file {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.model.player.seek(5)
            self?.model.player.togglePause()
          }
        }
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated { self?.model.player.load(video: file, audio: audio, start: 3) }
        }
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.model.player.shutdown()
            self.model.player = PlayerModel()
            self.model.player.load(video: file, audio: audio, start: 4)
            self.model.player.set("mute", "yes")
            if !self.model.shaderSelections.isEmpty { self.model.applyShaders() }
          }
        }
        Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated { self?.model.player.seek(8) }
        }
      }
      let output = options.values["--report"] ?? "/tmp/manping-diagnostic.json"
      let seconds = options.seconds
      diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          let player = self.model.player
          let report: [String: Any] = [
            "time": player.time, "duration": player.duration, "hwdec": player.hardware,
            "error": player.error ?? "", "events": player.diagnosticEvents,
            "renderReady": player.surface?.renderReady ?? false,
            "shaderRequested": args.contains("--shader") || args.contains("--preset"),
            "display": player.surface?.displayEvidence ?? "",
            "render": player.surface?.renderEvidence ?? "",
            "passes": player.passes, "shaderEvents": player.shaderEvents,
            "media": player.mediaEvidence, "metrics": player.metrics,
            "metricSamples": player.metricSamples, "probes": self.probes,
            "windowNumber": self.window.windowNumber,
            "danmaku": DanmakuView.diagnosticEvidence, "representation": self.representation,
            "actualProperties": self.actualProperties(),
            "viewportPixels": [
              Int((player.surface?.bounds.width ?? 0) * self.window.backingScaleFactor),
              Int((player.surface?.bounds.height ?? 0) * self.window.backingScaleFactor),
            ],
          ]
          if let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          {
            try? data.write(to: URL(fileURLWithPath: output))
          }
          self.model.shutdown()
          NSApp.terminate(nil)
        }
      }
    } else if args.contains("--login") {
      Task {
        if !skipAuthentication { try? await model.service.restoreCookies() }
        model.showingLogin = true
      }
    } else {
      Task {
        await model.initialize(skipAuthentication: skipAuthentication)
        await model.resolveAccountLaunch()
        model.resolvePGCLaunch()
        if PerformanceOptions.requested {
          await PerformanceRun.shared.run(model: model, window: window)
        }
        #if DEBUG
        if model.launchCuratedPlaylist { model.playCuratedList() }
        #endif
      }
    }
  }

  /// The menu bar (DesignSystem.md section 8): 满屏 / 文件 / 编辑 / 显示 / 前往 / 播放 / 窗口 / 帮助.
  private func installMenus() {
    let menu = NSMenu()
    @discardableResult
    func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
      in target: NSMenu, own: Bool = true) -> NSMenuItem {
      let item = target.addItem(withTitle: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      if own { item.target = self }
      return item
    }
    func top(_ title: String) -> NSMenu {
      let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let submenu = NSMenu(title: title)
      holder.submenu = submenu
      menu.addItem(holder)
      return submenu
    }
    // 满屏
    let application = top("满屏")
    item("关于满屏", #selector(showAbout), in: application)
    application.addItem(.separator())
    item("设置…", #selector(openSettings), ",", in: application)
    application.addItem(.separator())
    item("隐藏满屏", #selector(NSApplication.hide(_:)), "h", in: application, own: false)
    item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], in: application, own: false)
    item("全部显示", #selector(NSApplication.unhideAllApplications(_:)), in: application, own: false)
    application.addItem(.separator())
    item("退出满屏", #selector(NSApplication.terminate(_:)), "q", in: application, own: false)
    // 文件
    let file = top("文件")
    item("打开链接…", #selector(openLinkFromClipboard), "l", in: file)
    file.addItem(.separator())
    item("关闭窗口", #selector(NSWindow.performClose(_:)), "w", in: file, own: false)
    // 编辑: undo, redo and the clipboard go through the responder chain.
    let edit = top("编辑")
    item("撤销", NSSelectorFromString("undo:"), "z", in: edit, own: false)
    item("重做", NSSelectorFromString("redo:"), "z", [.command, .shift], in: edit, own: false)
    edit.addItem(.separator())
    item("剪切", #selector(NSText.cut(_:)), "x", in: edit, own: false)
    item("拷贝", #selector(NSText.copy(_:)), "c", in: edit, own: false)
    item("粘贴", #selector(NSText.paste(_:)), "v", in: edit, own: false)
    item("全选", #selector(NSText.selectAll(_:)), "a", in: edit, own: false)
    edit.addItem(.separator())
    item("搜索…", #selector(focusSearch), "f", in: edit)
    item("热搜", #selector(showTrending), "k", in: edit)
    // 显示
    let view = top("显示")
    item("隐藏侧边栏", #selector(toggleSidebar), "s", [.command, .control], in: view)
    item("刷新", #selector(refreshPage), "r", in: view)
    view.addItem(.separator())
    item("进入全屏幕", #selector(toggleFullScreen), "f", [.command, .control], in: view)
    // 前往: hidden sidebar items stay reachable here.
    let go = top("前往")
    item("返回", #selector(goBack), "[", in: go)
    item("前进", #selector(goForward), "]", in: go)
    go.addItem(.separator())
    for (index, destination) in AppModel.Destination.discover.enumerated() {
      item(destination.title, #selector(goToDestination(_:)), String(index + 1), in: go).tag = index
    }
    go.addItem(.separator())
    for (index, destination) in AppModel.Destination.mine.enumerated() {
      item(destination.title, #selector(goToDestination(_:)), String(index + 1), [.command, .option], in: go).tag = 100 + index
    }
    // 播放
    let playback = top("播放")
    let none = NSEvent.ModifierFlags()
    item("播放 / 暂停", #selector(togglePlayback), " ", none, in: playback)
    item("快退", #selector(seekBackward), String(UnicodeScalar(NSLeftArrowFunctionKey)!), none, in: playback)
    item("快进", #selector(seekForward), String(UnicodeScalar(NSRightArrowFunctionKey)!), none, in: playback)
    playback.addItem(.separator())
    item("上一个", #selector(previousEpisode), "[", [.command, .shift], in: playback)
    item("下一个", #selector(nextEpisode), "]", [.command, .shift], in: playback)
    playback.addItem(.separator())
    speedMenu = dynamicSubmenu("倍速", in: playback)
    let danmaku = NSMenu(title: "弹幕")
    playback.addItem(withTitle: "弹幕", action: nil, keyEquivalent: "").submenu = danmaku
    item("显示弹幕", #selector(toggleDanmaku), "d", [.command, .shift], in: danmaku)
    item("弹幕设置…", #selector(openDanmakuSettings), in: danmaku)
    subtitleMenu = dynamicSubmenu("字幕", in: playback)
    qualityMenu = dynamicSubmenu("画质", in: playback)
    playback.addItem(.separator())
    item("截取画面", #selector(saveVideoScreenshot), "s", [.command, .shift], in: playback)
    item("小窗", #selector(toggleCompact), "p", [.command, .shift], in: playback)
    item("在独立窗口播放", #selector(toggleDetachedPlayback), "p", [.command, .option], in: playback)
    playback.addItem(.separator())
    item("发弹幕", #selector(composeLiveDanmaku), in: playback)
    item("送礼物", #selector(openLiveGifts), in: playback)
    item("点赞", #selector(likeLiveRoom), in: playback)
    // 窗口
    let windows = top("窗口")
    item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", in: windows, own: false)
    item("缩放", #selector(NSWindow.performZoom(_:)), in: windows, own: false)
    windows.addItem(.separator())
    item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:)), in: windows, own: false)
    // 帮助
    let help = top("帮助")
    item("满屏帮助", #selector(openHelp), in: help)
    item("反馈问题", #selector(openIssues), in: help)
    NSApp.windowsMenu = windows
    NSApp.helpMenu = help
    NSApp.mainMenu = menu
  }
  private var speedMenu: NSMenu?
  private var subtitleMenu: NSMenu?
  private var qualityMenu: NSMenu?
  /// A submenu filled when it opens (倍速, 字幕, 画质), from the player that is active then.
  private func dynamicSubmenu(_ title: String, in parent: NSMenu) -> NSMenu {
    let submenu = NSMenu(title: title)
    submenu.delegate = self
    parent.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
    return submenu
  }
  private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
  private func fillSpeedMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    for (index, speed) in Self.speeds.enumerated() {
      let entry = menu.addItem(withTitle: String(format: "%g×", speed), action: #selector(chooseSpeed(_:)), keyEquivalent: "")
      entry.target = self; entry.tag = index
      entry.state = abs(activePlayer.speed - speed) < 0.01 ? .on : .off
    }
  }
  private func fillSubtitleMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    let features = model.playbackFeatures
    let off = menu.addItem(withTitle: "关闭字幕", action: #selector(chooseSubtitle(_:)), keyEquivalent: "")
    off.target = self; off.state = features.selectedTrackID == nil ? .on : .off
    // The same list as the player's 字幕 menu (设置 › 隐藏 AI 字幕 applies here too); each item
    // carries its track id, so filtering never shifts which track an item selects.
    let visible = DownloadSubtitleTrack.filtered(features.tracks, filterAI: model.appSettings.bool(.filterAISubtitle))
    if let note = PlaybackSubtitleItems.emptyNote(features: features, visible: visible) {
      menu.addItem(withTitle: note, action: nil, keyEquivalent: "").isEnabled = false
    }
    for track in visible {
      let entry = menu.addItem(withTitle: track.title, action: #selector(chooseSubtitle(_:)), keyEquivalent: "")
      entry.target = self; entry.representedObject = track.id
      entry.state = features.selectedTrackID == track.id ? .on : .off
    }
  }
  /// One entry per quality of the open video, in the codec that is playing now.
  private var qualityChoices: [MediaStream] {
    guard model.pgcPlayback == nil, model.livePlayback == nil, let streams = model.manifest?.video else { return [] }
    let codec = model.selectedStream?.codec
    var seen = Set<Int>()
    return streams.filter { codec == nil || $0.codec == codec }.filter { seen.insert($0.quality).inserted }
  }
  private func fillQualityMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    let choices = qualityChoices
    if choices.isEmpty {
      menu.addItem(withTitle: "在播放器的画质菜单中选择", action: nil, keyEquivalent: "").isEnabled = false
    }
    for (index, stream) in choices.enumerated() {
      let entry = menu.addItem(withTitle: stream.label.isEmpty ? "\(stream.height)P" : stream.label,
        action: #selector(chooseQuality(_:)), keyEquivalent: "")
      entry.target = self; entry.tag = index
      entry.state = model.selectedStream?.quality == stream.quality ? .on : .off
    }
  }
  @objc private func chooseSpeed(_ sender: NSMenuItem) {
    guard Self.speeds.indices.contains(sender.tag) else { return }
    activePlayer.setSpeed(Self.speeds[sender.tag])
  }
  @objc private func chooseSubtitle(_ sender: NSMenuItem) {
    let features = model.playbackFeatures
    guard let id = sender.representedObject as? String else { features.selectSubtitle(nil, player: activePlayer); return }
    let visible = DownloadSubtitleTrack.filtered(features.tracks, filterAI: model.appSettings.bool(.filterAISubtitle))
    // The list changed since the menu opened (another video, or the track is now filtered out).
    guard let track = visible.first(where: { $0.id == id }) else { return }
    features.selectSubtitle(track, player: activePlayer)
  }
  @objc private func chooseQuality(_ sender: NSMenuItem) {
    let choices = qualityChoices
    guard choices.indices.contains(sender.tag) else { return }
    model.changeQuality(choices[sender.tag])
  }
  private var activePlayer: PlayerModel { model.livePlayback?.player ?? model.pgcPlayback?.player ?? model.player }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard let action = item.action else { return true }
    switch action {
    case #selector(toggleSidebar):
      item.title = sidebarShown ? "隐藏侧边栏" : "显示侧边栏"
      return true
    case #selector(toggleFullScreen):
      let full = (model.hasPlayback ? model.player.surface?.window : nil)?.styleMask.contains(.fullScreen)
        ?? window?.styleMask.contains(.fullScreen) ?? false
      item.title = full ? "退出全屏幕" : "进入全屏幕"
      return window != nil
    case #selector(composeLiveDanmaku), #selector(openLiveGifts), #selector(likeLiveRoom):
      guard let live = model.livePlayback, !model.compactPlayer else { return false }
      return action != #selector(openLiveGifts) || live.ui.settings.liveEffective.giftMessages
    case #selector(saveVideoScreenshot): return model.canTakeScreenshot
    case #selector(goBack): return model.canGoBack
    case #selector(goForward): return model.canGoForward
    case #selector(toggleDanmaku):
      item.state = activePlayer.commentsEnabled ? .on : .off
    default: break
    }
    let controls: [Selector] = [#selector(togglePlayback), #selector(seekBackward), #selector(seekForward),
      #selector(previousEpisode), #selector(nextEpisode), #selector(toggleDanmaku), #selector(toggleCompact),
      #selector(toggleDetachedPlayback), #selector(chooseSpeed(_:)),
      #selector(chooseSubtitle(_:)), #selector(chooseQuality(_:))]
    if controls.contains(action) {
      guard model.selected != nil || model.pgcPlayback?.episode != nil || model.livePlayback != nil else { return false }
      // A live stream has no timeline to step through.
      if model.livePlayback != nil, [#selector(seekBackward), #selector(seekForward)].contains(action) { return false }
      if (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true,
        item.keyEquivalentModifierMask.isEmpty, !item.keyEquivalent.isEmpty { return false }
      if action == #selector(previousEpisode) { return model.canPlayPrevious }
      if action == #selector(nextEpisode) { return model.canPlayNext }
    }
    return true
  }
  private var sidebarHidden: Bool { PerformanceEnvironment.defaults.bool(forKey: ShellPreferences.sidebarHiddenKey) }
  /// The sidebar is on screen: in the layout, or floating over the playback page.
  private var sidebarShown: Bool {
    let shell = ShellSidebarState.shared
    return shell.suppressed ? shell.peeking : !sidebarHidden
  }
  /// On the playback page the sidebar stays out of the layout; ⌃⌘S floats it over the page for a
  /// moment instead of changing the 隐藏侧边栏 preference.
  @objc private func toggleSidebar() {
    let shell = ShellSidebarState.shared
    if shell.suppressed {
      shell.peeking.toggle()
    } else {
      PerformanceEnvironment.defaults.set(!sidebarHidden, forKey: ShellPreferences.sidebarHiddenKey)
    }
    DispatchQueue.main.async { [weak self] in self?.alignTrafficLights() }
  }
  @objc private func goToDestination(_ sender: NSMenuItem) {
    let items = sender.tag >= 100 ? AppModel.Destination.mine : AppModel.Destination.discover
    let index = sender.tag % 100
    guard items.indices.contains(index) else { return }
    model.go(to: items[index])
  }
  @objc private func openFavorites() { model.go(to: .favorites) }
  @objc private func openLater() { model.go(to: .viewLater) }
  @objc private func openHistory() { model.go(to: .history) }
  @objc private func openMessages() { model.navigate(to: .message) }
  @objc private func saveVideoScreenshot() { model.takePlayerScreenshot() }
  @objc private func composeLiveDanmaku() {
    guard !model.compactPlayer else { return }
    model.livePlayback?.ui.requestCompose()
  }
  @objc private func openLiveGifts() {
    guard !model.compactPlayer, let live = model.livePlayback,
      live.ui.settings.liveEffective.giftMessages
    else { return }
    live.ui.panel = .gifts
  }
  @objc private func likeLiveRoom() {
    guard !model.compactPlayer else { return }
    model.livePlayback?.ui.like()
  }
  @objc private func togglePlayback() { activePlayer.togglePause() }
  @objc private func seekBackward() { activePlayer.seek(max(0, activePlayer.time - model.appSettings.number(.stepBackward))) }
  @objc private func seekForward() { activePlayer.seek(min(activePlayer.duration, activePlayer.time + model.appSettings.number(.stepForward))) }
  @objc private func previousEpisode() { model.playPrevious() }
  @objc private func nextEpisode() { model.playNext() }
  @objc private func toggleDanmaku() { activePlayer.commentsEnabled.toggle() }
  @objc private func openDanmakuSettings() { model.openSettings(.danmaku) }
  @objc private func toggleCompact() { model.toggleCompactPlayer() }
  @objc private func toggleDetachedPlayback() { model.togglePlaybackWindow() }
  /// 进入全屏幕: the player when something is playing, otherwise the main window.
  @objc private func toggleFullScreen() {
    if model.hasPlayback { model.togglePlayerFullScreen() } else { window?.toggleFullScreen(nil) }
  }
  @objc private func focusSearch() { model.showSearch() }
  @objc private func showTrending() { model.hotSearchRequest += 1 }
  @objc private func goBack() { model.goBack() }
  @objc private func goForward() { model.goForward() }
  @objc private func openSettings() { model.openSettings() }
  @objc private func refreshPage() { Task { await model.refresh() } }
  @objc private func openHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/PIDEAN/Manping#readme")!) }
  @objc private func openIssues() { NSWorkspace.shared.open(URL(string: "https://github.com/PIDEAN/Manping/issues")!) }
  /// 关于满屏: the standard panel with the app icon, name and version, plus credits to the
  /// upstream projects.
  @objc private func showAbout() {
    let credits = NSMutableAttributedString()
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
    func append(_ text: String, link: String? = nil) {
      var attributes = body
      if let link, let url = URL(string: link) { attributes[.link] = url }
      credits.append(NSAttributedString(string: text, attributes: attributes))
    }
    append("Manping · 原生 Apple Silicon 哔哩哔哩客户端\n")
    append("项目主页", link: "https://github.com/PIDEAN/Manping")
    append("\n\n致谢\n")
    for entry in Acknowledgements.entries(in: .original) {
      append(entry.name, link: entry.url)
      append("（\(entry.author)，\(entry.license)）\n")
    }
    append("完整致谢见 设置 › 致谢。")
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
    NSApp.activate()
    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "满屏", .credits: credits])
  }
  private func actualProperties() -> [String: String] {
    guard let engine = model.player.engine else { return [:] }
    let names = [
      "hwdec-current", "video-codec", "video-params/w", "video-params/h",
      "video-params/colormatrix", "video-params/colorlevels", "video-params/primaries",
      "video-params/gamma",
      "video-params/chroma-location",
      "video-out-params/w", "video-out-params/h", "video-out-params/colormatrix",
      "video-out-params/colorlevels",
      "video-out-params/chroma-location",
      "video-out-params/primaries", "video-out-params/gamma", "target-prim", "target-trc",
      "target-peak",
      "tone-mapping", "scale", "cscale", "dscale", "dither-depth", "icc-profile",
      "icc-profile-auto",
      "video-output-levels", "gamma-factor", "correct-downscaling", "linear-downscaling",
      "linear-upscaling", "sigmoid-upscaling", "vo-passes",
      "osd-dimensions",
    ]
    return Dictionary(
      uniqueKeysWithValues: names.map { name in
        var buffer = [CChar](repeating: 0, count: name == "vo-passes" ? 131_072 : 2048)
        let status = bili_mpv_string(engine, name, &buffer, buffer.count)
        let value = String(cString: buffer)
        return (
          name,
          status < 0
            ? "unavailable(\(status))"
            : (value.utf8.count == buffer.count - 1 ? "unavailable(truncated)" : value)
        )
      })
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
  private func alignTrafficLights() {
    guard window.styleMask.contains(.fullSizeContentView), !window.styleMask.contains(.fullScreen) else { return }
    // The standard buttons sit inside the sidebar's glass, level with the 60 pt toolbar (as far
    // as the titlebar view allows) and moved in from the window edge with the sidebar's inset.
    // An icon rail leaves less room, so the buttons move in less there.
    let rail = window.frame.width < Theme.sidebarCollapseWidth
    // Only the main window's own sidebar counts; 小窗 is a separate panel.
    // On the playback page the sidebar is out of the layout; floated over it with ⌃⌘S it is full width.
    let shell = ShellSidebarState.shared
    let inset: CGFloat = !sidebarShown ? 4 : shell.suppressed || !rail ? 10 : 2
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
      let base = trafficLightBaseX[type] ?? button.frame.origin.x
      trafficLightBaseX[type] = base
      let centre = parent.isFlipped ? Theme.toolbarHeight / 2 : parent.bounds.height - Theme.toolbarHeight / 2
      button.setFrameOrigin(NSPoint(x: base + inset, y: max(0, centre - button.frame.height / 2)))
    }
  }
  /// The buttons' standard x positions, read once, so repeated alignment never accumulates.
  private var trafficLightBaseX: [NSWindow.ButtonType: CGFloat] = [:]
  func windowDidResize(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in self?.alignTrafficLights() }
  }
  // Entering or leaving full screen from the window's own button moves the picture as much as
  // the menu does: an open still loading keeps it where the user put it.
  func windowWillEnterFullScreen(_ notification: Notification) {
    model.userPlacedPicture()
    fullScreen.willEnter(window)
  }
  func windowWillExitFullScreen(_ notification: Notification) {
    model.userPlacedPicture()
    fullScreen.willExit()
  }
  /// The playback page enters and leaves full screen with its own live animation; other pages
  /// keep the system transition.
  private lazy var fullScreen = PlayerFullScreenTransition(
    showsPlayer: { [unowned self] in model.showsPlayerInMainWindow },
    setFullScreen: { [unowned self] in model.setWindowFullScreen($0, detached: false) })
  func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? { fullScreen.customWindowsToEnter(window) }
  func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
    fullScreen.startEntering(window, duration: duration)
  }
  func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? { fullScreen.customWindowsToExit(window) }
  func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
    fullScreen.startExiting(window, duration: duration)
  }
  func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
    fullScreen.fullScreenContentSize(proposed: proposedSize)
  }
  func windowDidEnterFullScreen(_ notification: Notification) { fullScreen.didEnter() }
  func windowDidExitFullScreen(_ notification: Notification) { fullScreen.didExit() }
  func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreen.didFailToEnter() }
  func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreen.didFailToExit() }
  func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
  func windowWillClose(_ notification: Notification) {
    // The settings window belongs to this one; closing the main window quits.
    SettingsWindowController.shared.close()
    model.shutdown()
  }
}
@main struct ManpingApplication {
  @MainActor static func main() {
    if ProcessInfo.processInfo.arguments.contains("--diagnose")
      || ProcessInfo.processInfo.arguments.contains("--diagnose-bvid")
    {
      setenv("MANPING_RENDER_DIAGNOSTICS", "1", 1)
    }
    // Window state is never restored (see isRestorable below); without this AppKit still consults
    // its crash history during finishLaunching and blocks launch on a modal "reopen windows?" alert.
    UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
  }
}

// Convert non-Sendable API dictionaries inside the service actor; retain no signed URL.
extension BiliService {
  func diagnosticDimensions(bvid: String, cid: Int64, video: MediaStream) async throws -> [Int] {
    let payload = try await json(
      "/x/player/wbi/playurl",
      params: ["bvid": bvid, "cid": String(cid), "qn": "127", "fnval": "4048", "fourk": "1"],
      signed: true)
    let dash = payload["dash"] as? [String: Any]
    let raw = (dash?["video"] as? [[String: Any]])?.first {
      ($0["id"] as? Int) == video.quality && ($0["codecs"] as? String) == video.codec
        && ($0["bandwidth"] as? Int) == video.bandwidth
    }
    guard let width = raw?["width"] as? Int, let height = raw?["height"] as? Int else { return [] }
    return [width, height]
  }
}
