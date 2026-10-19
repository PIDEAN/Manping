import AppKit
import ManpingCore
import CMpv
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import SwiftUI

/// Explicit developer diagnostics are available in optimized Release builds.
/// Invalid performance arguments still force fixture isolation before AppModel initializes.
enum PerformanceOptions {
  enum Mode { case scroll(String), playback(URL), stability(URL), memoryStress(URL), network(URL), anonymous(AnonymousPlaybackTarget) }
  static let arguments = ProcessInfo.processInfo.arguments
  static var requested: Bool { arguments.contains { $0.hasPrefix("--perf-") } }
  private static func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
  static var anonymousRequested: Bool { arguments.contains("--perf-anonymous-bvid") || arguments.contains("--perf-anonymous-live") }
  static var anonymousSeconds: Double { Double(value("--perf-anonymous-seconds") ?? "300") ?? 0 }
  static var audioTuning: DiagnosticAudioTuning? { try? DiagnosticAudioTuning(arguments: arguments) }
  @MainActor static func configureAudio(_ player: PlayerModel) {
    if requested, let driver = audioTuning?.driver, driver != .default { player.set("ao", driver.rawValue) }
  }
  @MainActor static func configurePlaybackTuning(_ player: PlayerModel) {
    guard requested, let tuning = audioTuning else { return }
    if let seconds = tuning.audioBufferSeconds { player.set("audio-buffer", String(seconds)) }
    if let wait = tuning.pauseWaitSeconds { player.set("cache-pause-wait", String(wait)) }
  }
  static var networkSeconds: Double { Double(value("--perf-network-seconds") ?? "60") ?? 0 }
  static var networkHideSeconds: Double { Double(value("--perf-network-hide-seconds") ?? "0") ?? -1 }
  static var networkHiddenReloadAt: Double? { value("--perf-network-hidden-reload-at").flatMap(Double.init) }
  static var networkNodePolicy: String { value("--perf-network-node-policy") ?? "auto" }
  /// Deliberately narrower than a proxy: no remote host, credentials, signatures or arbitrary endpoint.
  static func networkURL(_ raw: String, backup: Bool = false) -> URL? {
    guard raw.hasPrefix(backup ? "http://[::1]:" : "http://127.0.0.1:"),
      let parts = URLComponents(string: raw), parts.scheme == "http", (backup ? ["::1", "[::1]"].contains(parts.host ?? "") : parts.host == "127.0.0.1"),
      let port = parts.port, (1024...65535).contains(port), parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil, parts.path == (backup ? "/backup/media.mp4" : "/primary/media.mp4") else { return nil }
    return parts.url
  }
  static var networkDirect: Bool { arguments.contains("--perf-network-direct") }
  static var networkCancelRefresh: Bool { arguments.contains("--perf-network-cancel-refresh") }
  static var networkThird: URL? { value("--perf-network-third").flatMap { networkURL($0, backup: true) ?? networkURL($0) } }
  static var networkRefreshBackup: URL? { value("--perf-network-refresh-backup").flatMap { networkURL($0, backup: true) ?? networkURL($0) } }
  static var networkRefresh: URL? { value("--perf-network-refresh").flatMap { networkURL($0, backup: true) ?? networkURL($0) } }
  static var networkBackup: URL? { value("--perf-network-backup").flatMap { networkURL($0, backup: true) ?? networkURL($0) } }
  static var memoryIterations: Int { Int(value("--perf-memory-iterations") ?? "300") ?? 0 }
  static var memoryAcknowledgementDirectory: URL? {
    value("--perf-memory-ack-dir").map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
  }
  static var scrollPage: String? { value("--perf-scroll") }
  /// `--perf-danmaku empty|bursty`: playback with the danmaku layer on, over an empty timeline
  /// or one that alternates 10 s of lines (two a second) with 10 s without.
  static var danmakuPattern: String? { value("--perf-danmaku") }
  /// `--perf-source-fps N`: the local file's frame rate, for the drop percentage (default 60).
  static var sourceFPS: Double { value("--perf-source-fps").flatMap(Double.init) ?? 60 }
  /// Scroll run shape. Defaults keep the historical 60 Hz / 30 s / 2400 pt/s / cached-bitmap run.
  static var scrollHz: Int { Int(value("--perf-scroll-hz") ?? "60") ?? 0 }
  static var scrollSeconds: Double { Double(value("--perf-scroll-seconds") ?? "30") ?? 0 }
  static var scrollSpeed: Double { Double(value("--perf-scroll-speed") ?? "2400") ?? 0 }
  /// `pipeline` serves fixture covers through ImageCache and CachedImage's production path
  /// (off-main JPEG decode, memory tier, async hand-off) instead of one shared bitmap.
  static var coverPipeline: Bool { requested && value("--perf-covers") == "pipeline" }
  /// `over` places the (click-through) window so the resting pointer is over the grid, the
  /// usual situation when scrolling with a trackpad; the pointer itself is never moved. The
  /// programmatic scroll has no gesture phase, so card grids are told a gesture is in progress
  /// for the whole run, as a trackpad or wheel scroll would report.
  static let pointerOver = requested && value("--perf-pointer") == "over"
  /// `hover` places the window under the pointer like `over` but without the emulated gesture,
  /// so card hover runs as cards pass under the pointer (a scroll the grid did not see start).
  /// `away` places the window so the resting pointer is outside it when the screen allows.
  static let pointerMode = requested ? value("--perf-pointer") ?? "any" : "any"
  private static let scrollShapeOptions = ["--perf-scroll-hz", "--perf-scroll-seconds", "--perf-scroll-speed", "--perf-covers", "--perf-pointer"]
  static var playsLocalMedia: Bool {
    #if DEBUG
    // The README demo (DemoDirector) plays its local file over the offline samples.
    if DemoConfig.playsLocalMedia { return true }
    #endif
    return requested && (arguments.contains("--perf-play-local") || arguments.contains("--perf-stability") || arguments.contains("--perf-memory-stress") || arguments.contains("--perf-network") || anonymousRequested)
  }
  static func parse() throws -> Mode? {
    guard requested else { return nil }
    guard arguments.contains("--perf-fixture") else { throw Failure.arguments }
    _ = try DiagnosticAudioTuning(arguments: arguments)
    let count = ["--perf-anonymous-bvid", "--perf-anonymous-live", "--perf-scroll", "--perf-play-local", "--perf-stability", "--perf-memory-stress", "--perf-network"].filter(arguments.contains).count
    guard count == 1 else { throw Failure.arguments }
    if ["--perf-network-seconds", "--perf-network-backup", "--perf-network-refresh", "--perf-network-direct", "--perf-network-third", "--perf-network-refresh-backup", "--perf-network-cancel-refresh", "--perf-network-hide-seconds", "--perf-network-hidden-reload-at", "--perf-network-node-policy"].contains(where: arguments.contains), !arguments.contains("--perf-network") { throw Failure.arguments }
    if arguments.contains("--perf-anonymous-seconds"), !anonymousRequested { throw Failure.arguments }
    if anonymousRequested {
      guard arguments.contains("--skip-auth"), anonymousSeconds.isFinite, (300...600).contains(anonymousSeconds),
        ["--perf-anonymous-bvid", "--perf-anonymous-live", "--perf-anonymous-seconds"].allSatisfy({ name in arguments.filter { $0 == name }.count <= 1 }),
        let target = AnonymousPlaybackTarget(bvid: value("--perf-anonymous-bvid"), live: value("--perf-anonymous-live")),
        !arguments.contains("--perf-media"), !arguments.contains("--perf-danmaku"),
        !arguments.contains("--perf-source-fps"), !arguments.contains("--perf-memory-iterations"),
        !arguments.contains("--perf-memory-ack-dir"), !scrollShapeOptions.contains(where: arguments.contains)
      else { throw Failure.arguments }
      return .anonymous(target)
    }
    if arguments.contains("--perf-network") {
      guard let raw = value("--perf-network"), let url = networkURL(raw),
        (!arguments.contains("--perf-network-backup") || networkBackup != nil),
        (!arguments.contains("--perf-network-refresh") || networkRefresh != nil),
        (!arguments.contains("--perf-network-third") || networkThird != nil),
        (!arguments.contains("--perf-network-refresh-backup") || (networkRefreshBackup != nil && networkRefresh != nil)),
        (!networkCancelRefresh || networkRefresh != nil),
        networkSeconds.isFinite, (30...120).contains(networkSeconds),
        networkHideSeconds.isFinite, networkHideSeconds >= 0, networkHideSeconds <= networkSeconds - 10,
        ["auto", "manual", "no-switch"].contains(networkNodePolicy),
        (!arguments.contains("--perf-network-hidden-reload-at") || networkHiddenReloadAt.map {
          $0.isFinite && $0 > 0 && $0 < networkHideSeconds
        } == true),
        !arguments.contains("--perf-media"), !arguments.contains("--perf-danmaku"),
        !arguments.contains("--perf-source-fps"), !arguments.contains("--perf-memory-iterations"),
        !arguments.contains("--perf-memory-ack-dir"), !scrollShapeOptions.contains(where: arguments.contains)
      else { throw Failure.arguments }
      return .network(url)
    }
    if arguments.contains("--perf-memory-iterations") || arguments.contains("--perf-memory-ack-dir") {
      guard arguments.contains("--perf-memory-stress") else { throw Failure.arguments }
    }
    if arguments.contains("--perf-memory-stress") {
      guard (25...300).contains(memoryIterations), memoryIterations % 25 == 0 else { throw Failure.arguments }
      if arguments.contains("--perf-memory-ack-dir") {
        guard let raw = value("--perf-memory-ack-dir"), raw.hasPrefix("/"), !raw.contains("://"),
          let directory = memoryAcknowledgementDirectory else { throw Failure.arguments }
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
          .appendingPathComponent(".build", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard directory.path.hasPrefix(build.path + "/"),
          (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw Failure.arguments }
      }
    }
    if arguments.contains("--perf-danmaku") || arguments.contains("--perf-source-fps") {
      guard arguments.contains("--perf-play-local") else { throw Failure.arguments }
      if arguments.contains("--perf-danmaku") {
        guard ["empty", "bursty"].contains(danmakuPattern ?? "") else { throw Failure.arguments }
      }
      if arguments.contains("--perf-source-fps") {
        guard let fps = value("--perf-source-fps").flatMap(Double.init), (1...240).contains(fps) else { throw Failure.arguments }
      }
    }
    if scrollShapeOptions.contains(where: arguments.contains) {
      guard scrollPage != nil, [60, 120].contains(scrollHz), (5...120).contains(scrollSeconds),
        (200...6000).contains(scrollSpeed), ["bitmap", "pipeline"].contains(value("--perf-covers") ?? "bitmap"),
        ["any", "over", "hover", "away"].contains(value("--perf-pointer") ?? "any")
      else { throw Failure.arguments }
    }
    if let page = scrollPage {
      guard ["recommended", "popular", "search"].contains(page), !arguments.contains("--perf-media") else { throw Failure.arguments }
      return .scroll(page)
    }
    let stability = arguments.contains("--perf-stability")
    let memoryStress = arguments.contains("--perf-memory-stress")
    guard let path = value(stability || memoryStress ? "--perf-media" : "--perf-play-local"), !path.hasPrefix("--"),
      !path.contains("://") else { throw Failure.arguments }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else { throw Failure.arguments }
    if memoryStress { return .memoryStress(url) }
    return stability ? .stability(url) : .playback(url)
  }
  static func validate() throws { _ = try parse() }
  enum Failure: Error { case arguments, timedOut, playbackUnavailable, countersUnavailable }
}

@MainActor enum PerformanceEnvironment {
  static let suite = "io.github.pidean.manping.performance.\(ProcessInfo.processInfo.processIdentifier)"
  static let defaults: UserDefaults = {
    guard PerformanceOptions.requested else { return .standard }
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }()
  static func cleanUp() {
    if PerformanceOptions.requested { defaults.removePersistentDomain(forName: suite) }
  }
}

enum PerformanceFixtures {
  static let videos: [Video] = (0..<600).map { index in
    Video(bvid: "BVperf\(index)", title: "\(DebugUIFixtures.titles[index % DebugUIFixtures.titles.count]) · \(index + 1)",
      cover: URL(string: "https://fixture.invalid/cover/\(index)"), author:"本地性能样本 \(index % 8)",
      duration: 180 + index, views: 120_000 + index * 1249, cid: Int64(1000 + index),
      aid: Int64(100 + index), publishedAt: 1_760_000_000 - Int64(index * 3000),
      subtitle: "昨天 18:00", recommendationReason: index % 4 == 0 ? "很多人点赞" : nil)
  }
}

@MainActor enum PerformanceArtwork {
  // Production covers are cached bitmaps. Rasterize the synthetic artwork once
  // so this test does not add a GeometryReader/gradient/text tree to every cover.
  static let covers: [NSImage?] = (0..<8).map { index in
    let renderer = ImageRenderer(content: DebugFixtureImage(index: index).frame(width: 512, height: 288))
    renderer.scale = 1
    return renderer.nsImage
  }
  static func cover(_ index: Int) -> NSImage? { covers[abs(index) % covers.count] }
}

/// Encoded 1280×720 JPEG covers for `--perf-covers pipeline`: every fixture video has its own URL,
/// so ImageCache decodes, caches and evicts them like real covers (no network, no disk writes).
enum PerformanceCoverData {
  private static let jpegs: [Data] = (0..<8).compactMap(render)
  static func data(for url: URL) -> Data? {
    guard PerformanceOptions.coverPipeline, url.host == "fixture.invalid", url.pathComponents.contains("cover"),
      !jpegs.isEmpty else { return nil }
    return jpegs[abs(Int(url.lastPathComponent) ?? 0) % jpegs.count]
  }
  private static func render(_ index: Int) -> Data? {
    let width = 1280, height = 720
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let hue = Double(index) / 8
    let colors = [NSColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor,
      NSColor(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.35, alpha: 1).cgColor]
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
      context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    }
    // Deterministic detail so the JPEG carries photo-like entropy rather than a flat gradient.
    var seed = UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15
    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    for _ in 0..<600 {
      context.setFillColor(red: next(), green: next(), blue: next(), alpha: 0.35 + next() * 0.5)
      context.fillEllipse(in: CGRect(x: next() * Double(width), y: next() * Double(height), width: 8 + next() * 120, height: 8 + next() * 120))
    }
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}

/// Card hover state gathered only in scroll diagnostics runs (a constant check otherwise).
@MainActor enum PerformanceCounters {
  static let enabled = PerformanceOptions.scrollPage != nil && PerformanceOptions.requested
  /// Pointer events on card grids, and the times a card lifted under the pointer.
  static var cardHoverEvents = 0
  static var cardHoverLifts = 0
  /// Whether a card is lifted now, and whether the pointer rests on a card's frame.
  static var cardLifted = false
  static var pointerOnCard = false
  static func reset() { cardHoverEvents = 0; cardHoverLifts = 0 }
}

@MainActor final class PerformanceRun {
  static let shared = PerformanceRun()
  private var complete = false
  private var scrollStarted = false
  private var scrollOrigin = 0.0
  private var scrollLastArrival: Double?
  private var scrollIntervals: [Double] = []
  private var scrollActualY = 0.0
  private var scrollMinimumY = Double.infinity
  private var scrollMaximumY = -Double.infinity
  private var scrollExtent = 0.0
  private var scrollGeometryChanges = 0
  private var scrollReversals = 0
  private var previousActualY: Double?
  private var previousDirection = 0
  private var scrollEnvironment: [String: Any] = [:]
  /// Display-link frame timestamps (the vsync each callback belongs to) and the nominal period.
  private var scrollVsyncDeltas: [Double] = []
  private var scrollNominalPeriods: [Double] = []
  private var scrollLastVsync: Double?
  /// Main run-loop busy spans (wake to sleep, after Core Animation's commit) while scrolling.
  private var mainBusySpans: [Double] = []
  private var mainBusyStart: Double?
  private var mainObserver: CFRunLoopObserver?
  /// Ticks with the real pointer over the window: hover tracking then runs as cards pass under it,
  /// so runs are only comparable when this share matches (normally 0).
  private var pointerInsideTicks = 0

  static func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
  }
  private func delay(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
  private func wait(seconds: Double = 12, until predicate: () -> Bool) async throws {
    let deadline = CACurrentMediaTime() + seconds
    while !predicate() {
      guard CACurrentMediaTime() < deadline else { throw PerformanceOptions.Failure.timedOut }
      await delay(0.05)
    }
  }
  func run(model: AppModel, window: NSWindow) async {
    do {
      guard let mode = try PerformanceOptions.parse() else { return }
      let screen = window.screen ?? NSScreen.main
      var refresh = 0.0
      if let screen, let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
        let mode = CGDisplayCopyDisplayMode(display.uint32Value) { refresh = mode.refreshRate }
      Self.log("PERF environment pid=\(ProcessInfo.processInfo.processIdentifier) window=\(Int(window.frame.width))x\(Int(window.frame.height)) scale=\(window.backingScaleFactor) screen_max_hz=\(screen?.maximumFramesPerSecond ?? 0) display_mode_hz=\(refresh) config=isolated fixture_unique_ids=\(Set(PerformanceFixtures.videos.map(\.id)).count)")
      switch mode {
      case .scroll(let page):
        Self.log("PERF scroll START page=\(page) items=600 warmup_s=2 duration_s=\(PerformanceOptions.scrollSeconds) speed_pt_s=\(PerformanceOptions.scrollSpeed) requested_hz=\(PerformanceOptions.scrollHz) cover_mode=\(PerformanceOptions.coverPipeline ? "pipeline" : "cached_bitmap") measurement=actual_displaylink_callback_arrival")
        // Clicks pass through to whatever the user is doing. Hover still follows the real pointer,
        // so each run records how long the pointer was over the window (pointer_inside_pct).
        window.ignoresMouseEvents = true
        if ["over", "hover"].contains(PerformanceOptions.pointerMode), let visible = screen?.visibleFrame {
          // Put the resting pointer over the grid (right of the sidebar, mid-height).
          let pointer = NSEvent.mouseLocation, size = window.frame.size
          let x = min(max(pointer.x - size.width * 0.6, visible.minX), visible.maxX - size.width)
          let y = min(max(pointer.y - size.height * 0.5, visible.minY), visible.maxY - size.height)
          window.setFrameOrigin(NSPoint(x: x, y: y))
        } else if PerformanceOptions.pointerMode == "away", let visible = screen?.visibleFrame {
          // The on-screen corner farthest from the pointer; the window keeps its size.
          let pointer = NSEvent.mouseLocation, size = window.frame.size
          let x = pointer.x - visible.minX > visible.maxX - pointer.x ? visible.minX : visible.maxX - size.width
          let y = pointer.y - visible.minY > visible.maxY - pointer.y ? visible.minY : visible.maxY - size.height
          window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        scrollEnvironment = ["pid": Int(ProcessInfo.processInfo.processIdentifier),
          "window_pt": [Int(window.frame.width), Int(window.frame.height)], "backing_scale": window.backingScaleFactor,
          "screen_max_hz": screen?.maximumFramesPerSecond ?? 0, "display_mode_hz": refresh,
          "screen_name": screen?.localizedName ?? "unknown"]
        try await wait(seconds: PerformanceOptions.scrollSeconds + 15) { complete }
      case .playback(let file): try await playback(file: file, model: model)
      case .stability(let file): try await stability(file: file, model: model)
      case .memoryStress(let file): try await memoryStress(file: file, model: model)
      case .network(let url): try await network(url: url, model: model)
      case .anonymous(let target): try await anonymous(target: target, model: model)
      }
      Self.log("PERF complete")
    } catch {
      Self.log("PERF FAIL reason=\(String(describing: error))")
    }
    model.shutdown()
    PerformanceEnvironment.cleanUp()
    NSApp.terminate(nil)
  }
  func updateScroll(actualY: Double, extent: Double) {
    scrollActualY = actualY; scrollExtent = max(0, extent)
    guard scrollStarted else { return }
    scrollMinimumY = min(scrollMinimumY, actualY); scrollMaximumY = max(scrollMaximumY, actualY)
    if let previousActualY, abs(actualY - previousActualY) > 0.1 {
      scrollGeometryChanges += 1
      let direction = actualY > previousActualY ? 1 : -1
      if previousDirection != 0 && direction != previousDirection { scrollReversals += 1 }
      previousDirection = direction
    }
    previousActualY = actualY
  }
  func scrollTick(arrival: Double, vsync: Double, target: Double, pointerInside: Bool, move: (Double) -> Void) -> Bool {
    guard !complete else { return false }
    if !scrollStarted {
      guard scrollExtent > 1 else { return true }
      scrollStarted = true; scrollOrigin = arrival; scrollLastArrival = arrival; scrollLastVsync = vsync
      scrollMinimumY = scrollActualY; scrollMaximumY = scrollActualY
      startMainBusyObserver()
      PerformanceCounters.reset()
      return true
    }
    let elapsed = arrival - scrollOrigin
    if let previous = scrollLastArrival { scrollIntervals.append((arrival - previous) * 1000) }
    scrollLastArrival = arrival
    if let previous = scrollLastVsync, vsync > previous { scrollVsyncDeltas.append((vsync - previous) * 1000) }
    scrollLastVsync = vsync
    if target > vsync { scrollNominalPeriods.append((target - vsync) * 1000) }
    if pointerInside { pointerInsideTicks += 1 }
    if elapsed >= PerformanceOptions.scrollSeconds {
      stopMainBusyObserver()
      let sorted = scrollIntervals.sorted()
      func percentile(_ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
      }
      let slow = Double(sorted.filter { $0 > 25 }.count) / Double(max(1, sorted.count)) * 100
      let meaningful = scrollGeometryChanges > 100 && scrollMaximumY - scrollMinimumY > 1000 && scrollReversals > 0
      Self.log(String(format: "PERF scroll END page=%@ elapsed_s=%.3f samples=%d p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f over25_pct=%.4f actual_y_min=%.1f actual_y_max=%.1f content_extent=%.1f geometry_changes=%d reversals=%d actual_scroll=%@", PerformanceOptions.scrollPage ?? "", elapsed, sorted.count, percentile(0.50), percentile(0.95), percentile(0.99), slow, scrollMinimumY, scrollMaximumY, scrollExtent, scrollGeometryChanges, scrollReversals, meaningful ? "verified" : "FAIL"))
      guard PerformanceOptions.pointerMode == "hover" else {
        Self.log("PERF scroll JSON " + scrollReport(elapsed: elapsed, verified: meaningful))
        complete = true; return false
      }
      // With the lift live, hold still under the pointer: no card should have lifted while the
      // content moved, and the card under the pointer should lift once it settles. The app runs
      // inactive (it never takes focus), and an inactive window may get no hover until the
      // pointer moves; pointer_on_card false then means the grid never learned where it is.
      let liftsWhileScrolling = PerformanceCounters.cardHoverLifts
      Task { @MainActor in
        await delay(0.8)
        let settle: [String: Any] = ["lifts_while_scrolling": liftsWhileScrolling,
          "lifted_after_settle": PerformanceCounters.cardLifted, "pointer_on_card": PerformanceCounters.pointerOnCard]
        Self.log("PERF scroll JSON " + scrollReport(elapsed: elapsed, verified: meaningful, settle: settle))
        complete = true
      }
      return false
    }
    let distance = elapsed * PerformanceOptions.scrollSpeed
    let phase = distance.truncatingRemainder(dividingBy: scrollExtent * 2)
    move(phase <= scrollExtent ? phase : scrollExtent * 2 - phase)
    return true
  }
  private func startMainBusyObserver() {
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.afterWaiting, .beforeWaiting]).rawValue,
      true, CFIndex.max) { [weak self] _, activity in
      MainActor.assumeIsolated {
        guard let self else { return }
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
          self.mainBusyStart = now
        } else if let start = self.mainBusyStart {
          self.mainBusySpans.append((now - start) * 1000); self.mainBusyStart = nil
        }
      }
    }
    mainObserver = observer
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }
  private func stopMainBusyObserver() {
    if let mainObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), mainObserver, .commonModes) }
    mainObserver = nil
  }
  /// One JSON line: callback-arrival and vsync-timestamp frame pacing plus main-thread busy time.
  private func scrollReport(elapsed: Double, verified: Bool, settle: [String: Any]? = nil) -> String {
    func stats(_ values: [Double]) -> [String: Any] {
      let sorted = values.sorted()
      func percentile(_ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
      }
      func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
      return ["count": sorted.count, "mean": round3(sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)),
        "p50": round3(percentile(0.5)), "p95": round3(percentile(0.95)), "p99": round3(percentile(0.99)),
        "max": round3(sorted.last ?? 0)]
    }
    func share(_ values: [Double], over limit: Double) -> Double {
      (Double(values.filter { $0 > limit }.count) / Double(max(1, values.count)) * 1_000_000).rounded() / 10_000
    }
    let nominal = scrollNominalPeriods.sorted().dropFirst(scrollNominalPeriods.count / 2).first ?? 1000 / Double(PerformanceOptions.scrollHz)
    // A vsync delta of n periods means n - 1 refreshes passed without a callback (a dropped frame).
    let missed = scrollVsyncDeltas.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
    let hitch = scrollIntervals.reduce(0.0) { $0 + max(0, $1 - nominal * 1.5) }
    let busy = mainBusySpans.reduce(0, +)
    var report: [String: Any] = [
      "page": PerformanceOptions.scrollPage ?? "", "requested_hz": PerformanceOptions.scrollHz,
      "duration_s": PerformanceOptions.scrollSeconds, "speed_pt_s": PerformanceOptions.scrollSpeed,
      "cover_mode": PerformanceOptions.coverPipeline ? "pipeline" : "cached_bitmap",
      "environment": scrollEnvironment, "elapsed_s": elapsed, "nominal_period_ms": (nominal * 1000).rounded() / 1000,
      "pointer_mode": PerformanceOptions.pointerOver ? "over_with_emulated_scroll_gesture" : PerformanceOptions.pointerMode,
      "nominal_period_over_10ms_pct": share(scrollNominalPeriods, over: 10),
      "card_hover_events_per_s": (Double(PerformanceCounters.cardHoverEvents) / elapsed * 100).rounded() / 100,
      "card_hover_lifts_per_s": (Double(PerformanceCounters.cardHoverLifts) / elapsed * 100).rounded() / 100,
      "pointer_inside_pct":(Double(pointerInsideTicks) / Double(max(1, scrollIntervals.count)) * 10_000).rounded() / 100,
      "callbacks": scrollIntervals.count, "effective_fps": (Double(scrollIntervals.count) / elapsed * 100).rounded() / 100,
      "arrival_interval_ms": stats(scrollIntervals),
      "arrival_over_pct": ["8.33": share(scrollIntervals, over: 1000 / 120.0), "12.5": share(scrollIntervals, over: 12.5),
        "16.7": share(scrollIntervals, over: 1000 / 60.0), "25": share(scrollIntervals, over: 25)],
      "vsync_interval_ms": stats(scrollVsyncDeltas), "missed_vsyncs": missed,
      "missed_vsync_pct": (Double(missed) / Double(max(1, scrollVsyncDeltas.count + missed)) * 1_000_000).rounded() / 10_000,
      "hitch_ms_per_s": (hitch / elapsed * 1000).rounded() / 1000,
      "main_busy_ms": stats(mainBusySpans), "main_busy_pct": (busy / (elapsed * 1000) * 1_000_000).rounded() / 10_000,
      "main_busy_over_pct": ["4": share(mainBusySpans, over: 4), "8.33": share(mainBusySpans, over: 1000 / 120.0)],
      "scroll": ["actual_y_min": scrollMinimumY, "actual_y_max": scrollMaximumY, "content_extent": scrollExtent,
        "geometry_changes": scrollGeometryChanges, "reversals": scrollReversals, "verified": verified],
    ]
    if let settle { report["hover_settle"] = settle }
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
  private func renderFrames(_ player: PlayerModel) -> Int {
    let text = player.surface?.renderEvidence ?? ""
    let first = text.split(separator: " ").first ?? ""
    return first.hasPrefix("frames=") ? Int(first.dropFirst(7)) ?? 0 : 0
  }
  private func openLocal(file: URL, model: AppModel, checkDelayedLoad: Bool = false) async throws {
    model.open(Video(bvid: DebugUIFixtures.bvid, title: "4K60 本地性能测试", aid: 100))
    try await wait { model.videoDetails != nil && model.player.surface != nil }
    guard model.player.mediaIsolationVerified else { throw PerformanceOptions.Failure.playbackUnavailable }
    model.player.commentsEnabled = false
    model.player.set("volume", "0")
    if checkDelayedLoad { try await delayedNavigationLoad(file: file, model: model, phase: "initial", start: 0) }
    else { model.player.load(video: file, audio: nil) }
    try await wait {
      model.player.duration > 0 && model.player.time > 0.1 && model.player.engine != nil &&
        renderFrames(model.player) > 0
    }
    guard model.player.error == nil else { throw PerformanceOptions.Failure.playbackUnavailable }
  }
  /// Synthetic danmaku for `--perf-danmaku`: none, or 10 s of lines (two a second, every tenth
  /// one a top line) followed by 10 s without, repeated.
  private static func danmakuTimeline(_ pattern: String, duration: Double) -> DanmakuTimeline {
    guard pattern == "bursty" else { return DanmakuTimeline(comments: []) }
    let times = Array(stride(from: 0.5, to: max(1, duration), by: 0.5))
    let comments = times.enumerated().compactMap { index, time -> DanmakuComment? in
      guard time.truncatingRemainder(dividingBy: 20) < 10 else { return nil }
      return DanmakuComment(time: time, mode: index % 10 == 9 ? 5 : 1, text: "本地性能样本弹幕 \(index) · 满屏")
    }
    return DanmakuTimeline(comments: comments)
  }
  private func danmakuSubmits() -> Int { DanmakuView.diagnosticEvidence["submits"] ?? 0 }
  private func playback(file: URL, model: AppModel) async throws {
    let fps = PerformanceOptions.sourceFPS
    let navigationCheck = ProcessInfo.processInfo.environment["MANPING_NAVIGATION_CHECK"] == "1"
    Self.log("PERF playback START file=\(file.lastPathComponent) warmup_s=5 source_fps=\(fps) danmaku=\(PerformanceOptions.danmakuPattern ?? "off") profile=\(MacSettings.load(from: PerformanceEnvironment.defaults).text(.mpvProfile)) hwdec_request=videotoolbox")
    try await openLocal(file: file, model: model, checkDelayedLoad: navigationCheck)
    if let pattern = PerformanceOptions.danmakuPattern {
      model.player.commentsEnabled = true
      model.player.timeline = Self.danmakuTimeline(pattern, duration: model.player.duration)
    }
    try await wait { model.player.time >= 5 }
    if navigationCheck {
      try await pausedBrowsing(model: model)
      try await delayedNavigationLoad(file: file, model: model, phase: "reload", start: model.player.time)
      try await delayedNavigationLoad(file: file, model: model, phase: "user-pause", start: model.player.time, browsing: false)
      return
    }
    let player = model.player
    let startTime = player.time
    let startRenderFrames = renderFrames(player)
    let startSubmits = danmakuSubmits(), startHost = CACurrentMediaTime()
    guard let startVO = player.metrics["frame-drop-count"], let startDecoder = player.metrics["decoder-frame-drop-count"] else { throw PerformanceOptions.Failure.countersUnavailable }
    Self.log("PERF playback WARM media_s=\(startTime) hwdec_current=\(player.hardware) vo_drop=\(startVO) decoder_drop=\(startDecoder) danmaku_lines=\(player.timeline.count) comments_enabled=\(player.commentsEnabled) engine_profile=\(player.engineProfile) power=\(PowerState.shared.level) source_transfer=\(player.videoGamma)")
    try await wait(seconds: max(70, player.duration + 15)) { player.eofReached || player.time >= player.duration }
    let elapsed = CACurrentMediaTime() - startHost
    let submits = danmakuSubmits() - startSubmits
    Self.log(String(format: "PERF playback DANMAKU submits_delta=%d elapsed_s=%.3f presents_per_s=%.2f lines=%d enabled=%@ evidence=%@", submits, elapsed,
      Double(submits) / max(0.001, elapsed), player.timeline.count, player.commentsEnabled ? "yes" : "no",
      DanmakuView.diagnosticEvidence.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")))
    Self.log("PERF playback DISPLAY \(player.surface?.displayEvidence ?? "unavailable")")
    await delay(0.15)
    guard let endVO = player.metrics["frame-drop-count"], let endDecoder = player.metrics["decoder-frame-drop-count"], player.time > startTime else { throw PerformanceOptions.Failure.countersUnavailable }
    let expectedFrames = (player.time - startTime) * fps
    let vo = max(0, endVO - startVO), decoder = max(0, endDecoder - startDecoder)
    let dropPercent = (vo + decoder) / expectedFrames * 100
    let hardwarePass = player.hardware.hasPrefix("videotoolbox")
    Self.log("PERF playback render_frames_delta=\(renderFrames(player) - startRenderFrames) render_evidence=\(player.surface?.renderEvidence ?? "unavailable")")
    Self.log(String(format: "PERF playback END file=%@ start_s=%.3f end_s=%.3f expected_cfr_frames=%.1f vo_drop_delta=%.0f decoder_drop_delta=%.0f total_drop_pct=%.6f hwdec_current=%@ estimated_vf_fps=%@ threshold_pct=0.1 result=%@", file.lastPathComponent, startTime, player.time, expectedFrames, vo, decoder, dropPercent, player.hardware, player.metrics["estimated-vf-fps"].map { String(format: "%.3f", $0) } ?? "unavailable", dropPercent < 0.1 && hardwarePass ? "PASS" : "FAIL"))
  }
  private func waitForLoad(_ player: PlayerModel, until predicate: (PlayerModel.DiagnosticLoadSample) -> Bool) async throws -> PlayerModel.DiagnosticLoadSample {
    let deadline = CACurrentMediaTime() + 12
    while CACurrentMediaTime() < deadline {
      if let sample = await player.diagnosticLoadSample(), predicate(sample) { return sample }
      await delay(0.05)
    }
    if let sample = await player.diagnosticLoadSample() {
      Self.log("PERF navigation LOAD_TIMEOUT held=\(sample.held) loaded=\(sample.loadedFiles) pause=\(sample.paused) time=\(String(describing: sample.time)) audio_pts=\(String(describing: sample.audioTime)) audio_selected=\(sample.audioSelected) ao=\(sample.audioOutput)")
    }
    throw PerformanceOptions.Failure.timedOut
  }
  /// Pause after loadfile returned, but before mpv applies its captured pause=no.
  /// The production on_load hook must repair that stale option before audio starts.
  private func delayedNavigationLoad(file: URL, model: AppModel, phase: String, start: Double, browsing: Bool = true) async throws {
    let player = model.player
    guard let counter = player.surface?.diagnosticFrameCounter(),
      let before = await player.diagnosticLoadSample(),
      await player.diagnosticHoldNextLoad() else { throw PerformanceOptions.Failure.playbackUnavailable }
    player.load(video: file, audio: nil, start: start, paused: false)
    let held = try await waitForLoad(player) { $0.held }
    Self.log("PERF navigation LOAD_BARRIER phase=\(phase) held=\(held.held) loaded_before=\(before.loadedFiles) raw_pause=\(held.paused)")
    guard held.loadedFiles == before.loadedFiles else { throw PerformanceOptions.Failure.countersUnavailable }
    if browsing {
      model.openOverlay(.userSpace(946974))
      try await wait { player.surface == nil && player.browsingSuspended && player.paused }
    } else { player.set("pause", "yes") }
    let entered = await player.diagnosticLoadSample()
    await player.diagnosticReleaseLoad()
    Self.log("PERF navigation LOAD_RELEASE phase=\(phase) entered_pause=\(String(describing: entered?.paused))")
    _ = try await waitForLoad(player) {
      !$0.held && $0.loadedFiles > before.loadedFiles && $0.time != nil
    }
    await delay(0.4)
    guard let first = await player.diagnosticLoadSample(), let firstTime = first.time else {
      throw PerformanceOptions.Failure.countersUnavailable
    }
    let frames = counter(), submits = danmakuSubmits()
    await delay(1.5)
    guard let last = await player.diagnosticLoadSample(), let lastTime = last.time else {
      throw PerformanceOptions.Failure.countersUnavailable
    }
    let drift = abs(lastTime - firstTime)
    let audioDrift = first.audioTime.flatMap { first in last.audioTime.map { abs($0 - first) } }
    // mpv exposes audio-pts only from STATUS_PLAYING onward (command.c). A paused
    // initial/replacement file can have an initialized AO without ever starting it.
    let audioNeverStarted = first.audioTime == nil && last.audioTime == nil && !first.eof && !last.eof
    func seconds(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "unavailable" }
    let renderDelta = counter() - frames, danmakuDelta = danmakuSubmits() - submits
    let passed = entered?.paused == true && first.paused && last.paused && first.audioSelected && last.audioSelected &&
      ["coreaudio", "avfoundation"].contains(first.audioOutput) && first.audioOutput == last.audioOutput && drift < 0.05 &&
      (audioNeverStarted || (audioDrift.map { $0 < 0.05 } ?? false)) &&
      renderDelta == 0 && danmakuDelta == 0 && !player.powerAssertionHeld
    Self.log(String(format: "PERF navigation DELAYED_LOAD phase=%@ captured_pause=no before_start_held=%@ loaded_before=%d loaded_after=%d entered_pause=%@ raw_pause=%@ audio_selected=%@ ao=%@ observation_s=1.5 time_start_s=%.6f time_end_s=%.6f drift_s=%.6f audio_start_s=%@ audio_end_s=%@ audio_drift_s=%@ audio_state=%@ render_delta=%d danmaku_delta=%d power=%@ result=%@",
      phase, held.held ? "yes" : "no", before.loadedFiles, last.loadedFiles, entered?.paused == true ? "yes" : "no",
      last.paused ? "yes" : "no", last.audioSelected ? "yes" : "no", last.audioOutput,
      firstTime, lastTime, drift, seconds(first.audioTime), seconds(last.audioTime), seconds(audioDrift),
      audioNeverStarted ? "not-started" : "frozen", renderDelta, danmakuDelta,
      player.powerAssertionHeld ? "held" : "released", passed ? "PASS" : "FAIL"))
    guard passed else { throw PerformanceOptions.Failure.countersUnavailable }
    if browsing { model.goBack() } else { player.requestPlay() }
    try await wait { player.surface != nil && !player.paused && player.time > lastTime + 0.3 }
    guard await player.diagnosticPauseFlag() == false else { throw PerformanceOptions.Failure.playbackUnavailable }
    let resumed = try await waitForLoad(player) { $0.audioTime != nil }
    await delay(0.4)
    guard let resumedEnd = await player.diagnosticLoadSample(), let audioStart = resumed.audioTime,
      let audioEnd = resumedEnd.audioTime, audioEnd > audioStart + 0.1 else { throw PerformanceOptions.Failure.countersUnavailable }
    Self.log(String(format: "PERF navigation DELAYED_RESUME phase=%@ raw_pause=no resumed_s=%.6f audio_start_s=%.6f audio_end_s=%.6f audio_advance_s=%.6f result=PASS",
      phase, player.time, audioStart, audioEnd, audioEnd - audioStart))
  }
  /// Opt-in with the existing local-media command; never opens, activates or moves a window.
  private func pausedBrowsing(model: AppModel) async throws {
    let player = model.player
    guard let counter = player.surface?.diagnosticFrameCounter(), player.engine != nil else {
      throw PerformanceOptions.Failure.playbackUnavailable
    }
    let heldBefore = player.powerAssertionHeld
    let originalPosition = player.time
    model.openOverlay(.userSpace(946974))
    try await wait { player.surface == nil && player.paused && !player.powerAssertionHeld }
    await delay(0.4)
    let rawPause = await player.diagnosticPauseFlag()
    let pausedPosition = (await player.diagnosticNetworkEngineSample()).time ?? -.infinity
    let frames = counter(), submits = danmakuSubmits()
    await delay(1.5)
    let pausedEnd = (await player.diagnosticNetworkEngineSample()).time ?? .infinity
    let rendered = counter() - frames, danmaku = danmakuSubmits() - submits
    let delta = abs(pausedEnd - pausedPosition)
    let suspended = rawPause == true && !player.powerAssertionHeld && rendered == 0 && danmaku == 0 && delta < 0.05
    Self.log(String(format: "PERF navigation PAUSE raw_pause=%@ power_before=%@ power_after=%@ surface_owners=%d render_delta=%d danmaku_delta=%d enter_s=%.3f paused_s=%.3f paused_end_s=%.3f drift_s=%.6f result=%@",
      rawPause == true ? "yes" : "no", heldBefore ? "held" : "released", player.powerAssertionHeld ? "held" : "released",
      player.surface == nil ? 0 : 1, rendered, danmaku, originalPosition, pausedPosition, pausedEnd, delta, suspended ? "PASS" : "FAIL"))
    guard suspended else { throw PerformanceOptions.Failure.countersUnavailable }
    model.goBack()
    let returnPosition = player.time
    try await wait { player.surface != nil && !player.paused && player.time > pausedPosition + 0.3 }
    let rawResumed = await player.diagnosticPauseFlag()
    let resumed = rawResumed == false && player.powerAssertionHeld && abs(returnPosition - pausedPosition) < 0.1
    Self.log(String(format: "PERF navigation RESUME raw_pause=%@ power=%@ surface_owners=%d paused_s=%.3f return_s=%.3f resumed_s=%.3f position_error_s=%.6f result=%@",
      rawResumed == true ? "yes" : "no", player.powerAssertionHeld ? "held" : "released", player.surface == nil ? 0 : 1,
      pausedPosition, returnPosition, player.time, abs(returnPosition - pausedPosition), resumed ? "PASS" : "FAIL"))
    guard resumed else { throw PerformanceOptions.Failure.playbackUnavailable }
    var settings = MacSettings.load(from: PerformanceEnvironment.defaults)
    _ = settings.set(.liveText, .bool(true), capabilities: [.liveText])
    player.configureRuntime(settings: settings)
    let analyses = player.liveTextPauseAnalyses, clears = player.liveTextResumeClears
    player.set("pause", "yes")
    try await wait { player.liveTextPauseAnalyses > analyses }
    if player.liveText.isSupported { try await wait(seconds: 12) { player.liveText.analysis != nil } }
    let obtainedAnalysis = player.liveText.analysis != nil
    player.requestPlay()
    try await wait { player.liveTextResumeClears > clears && !player.paused }
    let cleared = player.liveText.analysis == nil
    Self.log("PERF navigation LIVETEXT pause_analyses=\(player.liveTextPauseAnalyses - analyses) resume_clears=\(player.liveTextResumeClears - clears) supported=\(player.liveText.isSupported) analysis_obtained=\(obtainedAnalysis) analysis_cleared=\(cleared) result=\(cleared ? "PASS" : "FAIL")")
    guard cleared else { throw PerformanceOptions.Failure.playbackUnavailable }
  }
  /// Loads through the production CDN prepare/attach/relay path. Only the origins and cache
  /// budget are diagnostic; no recovery, seek, retry or quality switch is triggered by this loop.
  private func network(url: URL, model: AppModel) async throws {
    let start = CACurrentMediaTime()
    let records = [try await networkSession(url: url, model: model)]
    model.closePlayer()
    memory(phase: "network_closed", iteration: 1, start: start)
    await delay(5)
    memory(phase: "network_settled", iteration: 1, start: start)
    lifetimes(records, current: model.player, iteration: 1)
    // Drain only after observing the production pool's retained render layer.
    MpvEnginePool.shared.drain()
    await delay(2)
    memory(phase: "network_drained", iteration: 1, start: start)
    lifetimes(records, current: model.player, iteration: 2)
  }
  private func networkSession(url: URL, model: AppModel) async throws -> WeakPlaybackRecord {
    Self.log("PERF network SETUP duration_s=\(PerformanceOptions.networkSeconds) route=\(PerformanceOptions.networkDirect ? "direct" : "relay") origins=loopback backup=\(PerformanceOptions.networkBackup == nil ? "off" : "on") auth=fixture cache_s=2")
    model.open(Video(bvid: DebugUIFixtures.bvid, title: "本地网络故障测试", aid: 100))
    try await wait { model.videoDetails != nil && model.player.surface != nil }
    let player = model.player
    guard player.mediaIsolationVerified else { throw PerformanceOptions.Failure.playbackUnavailable }
    player.commentsEnabled = false
    player.set("volume", "0")
    var settings = MacSettings.load(from: PerformanceEnvironment.defaults)
    settings.set(.cdnAuto, .bool(false), capabilities: [.cdnAuto])
    settings.set(.smartCache, .bool(false), capabilities: [.smartCache])
    settings.set(.cdnMultiSource, .bool(!PerformanceOptions.networkDirect), capabilities: [.cdnMultiSource])
    if PerformanceOptions.networkNodePolicy == "no-switch" {
      settings.set(.cdnStallRecovery, .bool(false), capabilities: [.cdnStallRecovery])
    }
    model.cdn.apply(settings)
    if PerformanceOptions.networkNodePolicy == "manual" { model.cdn.select(host: url.host) }
    let stream = MediaStream(quality: 80, codec: "avc1", url: url, bandwidth: 8_000_000,
      label: "loopback", backupURLs: [PerformanceOptions.networkBackup, PerformanceOptions.networkThird].compactMap { $0 })
    guard let prepared = await model.cdn.prepare(video: stream, audio: nil, avoidP2P: false, allowProbe: false)
    else { throw PerformanceOptions.Failure.playbackUnavailable }
    let initialRenderFrames = renderFrames(player)
    let start = ProcessInfo.processInfo.systemUptime
    Self.log("PERF network START duration_s=\(PerformanceOptions.networkSeconds)")
    var diagnosticHidden = PerformanceOptions.networkHideSeconds > 0
    player.surface?.setDiagnosticPresentationHidden(diagnosticHidden)
    defer { player.surface?.setDiagnosticPresentationHidden(false) }
    func loadPrepared(_ prepared: CDNController.Prepared) async {
      player.load(video: prepared.video, audio: prepared.audio)
      if let replacement = PerformanceOptions.networkRefresh {
        model.cdn.attach(player: player, ticket: prepared.ticket, reload: { [weak player] video, audio in
          guard let player else { return }
          player.load(video: video, audio: audio, start: player.time, paused: player.paused)
        }, downgrade: { false }, refresh: {
          if PerformanceOptions.networkCancelRefresh { throw CancellationError() }
          return (MediaStream(quality: 80, codec: "avc1", url: replacement, bandwidth: 8_000_000, label: "loopback",
            backupURLs: PerformanceOptions.networkRefreshBackup.map { [$0] } ?? []), nil)
        })
      } else { await model.attachCDN(to: player, ticket: prepared.ticket) }
    }
    await loadPrepared(prepared)
    // Keep prefetch bounded so a temporary origin fault cannot hide behind a whole-file cache.
    player.set("cache", "yes")
    player.set("demuxer-max-bytes", "4194304")
    player.set("demuxer-max-back-bytes", "0")
    player.set("demuxer-readahead-secs", "2")
    player.set("cache-pause-wait", String(PerformanceOptions.audioTuning?.pauseWaitSeconds ?? 1))
    var previousTime = 0.0
    var previousRenderFrames = initialRenderFrames
    var previousEngineTime: Double?
    var firstFrame: Double?
    var freezeStart: Double?
    var longestFreeze = 0.0
    var bufferingSamples = 0
    var errorSamples = 0
    var terminalSettledElapsed: Double?
    var diagnosticSession = 1
    while ProcessInfo.processInfo.systemUptime - start < PerformanceOptions.networkSeconds {
      let beforeSample = ProcessInfo.processInfo.systemUptime - start
      if diagnosticHidden, beforeSample >= PerformanceOptions.networkHideSeconds {
        player.surface?.setDiagnosticPresentationHidden(false)
        diagnosticHidden = false
      }
      if let reloadAt = PerformanceOptions.networkHiddenReloadAt, diagnosticSession == 1, beforeSample >= reloadAt {
        guard let next = await model.cdn.prepare(video: stream, audio: nil, avoidP2P: false, allowProbe: false)
        else { throw PerformanceOptions.Failure.playbackUnavailable }
        await loadPrepared(next)
        diagnosticSession += 1
        previousTime = 0
        previousRenderFrames = renderFrames(player)
        previousEngineTime = nil
      }
      let engine = await player.diagnosticNetworkEngineSample()
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      let rawEngineAdvancing: String
      if let time = engine.time, let previousEngineTime {
        rawEngineAdvancing = time > previousEngineTime + 0.05 ? "1" : "0"
      } else { rawEngineAdvancing = engine.idle == true ? "0" : "unknown" }
      let terminal = model.cdn.recoveryTerminal && player.terminalFailure
      let terminalAt = model.cdn.recoveryTerminalAt.flatMap { policyAt in
        player.terminalFailureAt.map { max(policyAt, $0) }
      }
      let rawAdvancing = player.time > previousTime + 0.05
      let currentRenderFrames = renderFrames(player)
      let rawRenderAdvancing = currentRenderFrames > previousRenderFrames
      // EOF/stop can publish a final position. Keep raw evidence for the terminal gate.
      let advancing = !terminal && !player.eofReached && rawAdvancing
      if advancing {
        if firstFrame == nil, renderFrames(player) > initialRenderFrames { firstFrame = elapsed }
        if let since = freezeStart { longestFreeze = max(longestFreeze, elapsed - since) }
        freezeStart = nil
      } else if player.eofReached {
        freezeStart = nil
      } else if freezeStart == nil { freezeStart = elapsed }
      if player.buffering { bufferingSamples += 1 }
      if player.error != nil { errorSamples += 1 }
      let snapshot = model.cdn.snapshot
      let inflight = snapshot.hosts.reduce(0) { $0 + $1.inflight }
      if terminal, terminalAt != nil, terminalSettledElapsed == nil,
        player.error != nil, !player.buffering, !rawAdvancing, !rawRenderAdvancing,
        engine.idle == true, rawEngineAdvancing == "0",
        snapshot.activeConnections == 0, inflight == 0 {
        terminalSettledElapsed = elapsed
      }
      // Never print Player.error/status or CDN event text: production messages may contain URLs.
      Self.log(String(format: "PERF network SAMPLE elapsed_s=%.3f media_s=%.3f advancing=%d raw_advancing=%d raw_render_advancing=%d buffering=%d error=%@ eof=%d terminal=%d terminal_elapsed_s=%.3f terminal_settled_elapsed_s=%.3f buffer_s=%.3f stalls=%d events=%d recovery_attempts=%d refresh_attempts=%d automatic_reloads=%d expired_status=%d relay_connections=%d relay_inflight=%d relay_retries=%d relay_hedges=%d relay_bytes=%d rss_bytes=%llu", elapsed, player.time, advancing ? 1 : 0, rawAdvancing ? 1 : 0, rawRenderAdvancing ? 1 : 0, player.buffering ? 1 : 0, player.error == nil ? "none" : "present", player.eofReached ? 1 : 0, terminal ? 1 : 0, terminalAt.map { $0 - start } ?? -1, terminalSettledElapsed ?? -1, player.bufferedAhead, model.cdn.stalls, model.cdn.events.count, model.cdn.recoveryAttempts, model.cdn.refreshAttempts, model.cdn.automaticReloads, model.cdn.expiredStatus, snapshot.activeConnections, inflight, snapshot.retries, snapshot.hedgedRequests, snapshot.totalBytes, bili_process_resident_bytes()) + Self.audioFields(player) + " engine_idle=\(engine.idle.map { $0 ? "1" : "0" } ?? "unknown") raw_engine_advancing=\(rawEngineAdvancing)")
      Self.log("PERF network PRESENTATION elapsed_s=\(String(format: "%.3f", elapsed)) hidden=\(diagnosticHidden ? 1 : 0) expected=\(player.presentationExpected ? 1 : 0) frames=\(currentRenderFrames) session=\(diagnosticSession)")
      previousTime = player.time
      previousRenderFrames = currentRenderFrames
      previousEngineTime = engine.time
      await delay(1)
    }
    if let since = freezeStart { longestFreeze = max(longestFreeze, ProcessInfo.processInfo.systemUptime - start - since) }
    Self.log(String(format: "PERF network END first_frame_s=%.3f media_s=%.3f longest_freeze_s=%.3f buffering_samples=%d error_samples=%d stalls=%d final_error=%@", firstFrame ?? -1, player.time, longestFreeze, bufferingSamples, errorSamples, model.cdn.stalls, player.error == nil ? "none" : "present"))
    return WeakPlaybackRecord(player)
  }

  private static func audioFields(_ player: PlayerModel) -> String {
    func scalar(_ key: String) -> String {
      guard let value = player.metrics[key], value.isFinite else { return "unavailable" }
      return String(format: "%.6f", value)
    }
    return " actual_ao=\(player.mediaEvidence["current-ao"] ?? "unavailable") audio_present=\(scalar("audio-present")) audio_pts_s=\(scalar("audio-pts")) avsync_s=\(scalar("avsync")) total_avsync_change_s=\(scalar("total-avsync-change")) audio_rate_hz=\(scalar("audio-out-params/samplerate")) audio_channels=\(scalar("audio-out-params/channel-count")) audio_input_channels=\(scalar("audio-params/channel-count"))"
  }
  private static func anonymousUnchanged(_ service: BiliService, expected: AuthSnapshot) async -> Bool {
    let current = await service.authSnapshot()
    let mid = await service.accountMid()
    return current.state == .needsLogin && current.token == nil &&
      current.epoch == expected.epoch && current.identityRevision == expected.identityRevision &&
      mid == nil
  }
  private enum AnonymousFailure: String, Error { case boundary, shortMedia, noLiveRoom, incompletePlayback }
  /// Real public GETs use an independent service; AppModel remains the fixture-only surface.
  /// No identity restore, progress reporter, watch activity, chat or heartbeat is started here.
  private func anonymous(target: AnonymousPlaybackTarget, model: AppModel) async throws {
    let credentials = DenyCredentialStore()
    let transport = GETOnlyAuditedTransport(base: IsolatedAuthTransport(diagnosticLogging: false))
    let service = BiliService(transport: transport, credentials: credentials, webDeviceCookies: true)
    let expected = await service.authSnapshot()
    let startBoundary = await Self.anonymousUnchanged(service, expected: expected)
    let started = CACurrentMediaTime()
    var live: LivePlaybackModel?
    var record: WeakPlaybackRecord?
    var failure: String?
    var failureCode: Int?
    func audit(_ phase: String, valid: Bool) {
      let counts = transport.audit
      Self.log("PERF anonymous AUDIT phase=\(phase) auth_check=\(valid ? "pass" : "fail") credential_calls=\(credentials.callCount) allowed_gets=\(counts.sent) rejected=\(counts.rejected) non_get=\(counts.nonGET) last_rejection=\(counts.lastRejection.map { "\"\($0)\"" } ?? "none")")
    }
    audit("start", valid: startBoundary)
    // Cleanup is also guaranteed if future diagnostic code adds an early throwing return.
    defer { live?.shutdown(); model.cdn.detach(); model.closePlayer() }
    do {
      guard startBoundary, credentials.callCount == 0, transport.audit.nonGET == 0, transport.audit.rejected == 0 else { throw AnonymousFailure.boundary }
      // LivePlaybackModel re-applies session preferences after each reconnect. Keep this
      // diagnostic child silent without changing output negotiation or system volume.
      PlayerModel.sessionVolume = 0; PlayerModel.sessionComments = false
      model.open(Video(bvid: DebugUIFixtures.bvid, title: "匿名播放诊断", aid: 100))
      try await wait { model.videoDetails != nil && model.player.surface != nil }
      let player = model.player
      Self.log("PERF anonymous MEDIA isolation=\(player.mediaIsolationVerified ? "pass" : "fail")")
      guard player.mediaIsolationVerified else { throw AnonymousFailure.boundary }
      player.commentsEnabled = false
      player.set("volume", "0")
      record = WeakPlaybackRecord(player)
      let initialFrames = renderFrames(player)
      var duration = 0.0
      var mode = "video"
      switch target {
      case .video(let bvid):
        let video = try await service.detail(bvid, expectedIdentity: expected)
        let manifest = try await service.playback(video, expectedIdentity: expected)
        duration = manifest.duration
        Self.log(String(format: "PERF anonymous SETUP mode=video bvid=%@ requested_s=%.0f duration_s=%.3f", bvid, PerformanceOptions.anonymousSeconds, duration))
        guard duration >= PerformanceOptions.anonymousSeconds + 5 else { throw AnonymousFailure.shortMedia }
        let choice = try PlaybackSelector.select(manifest)
        guard await Self.anonymousUnchanged(service, expected: expected), model.player === player,
          let prepared = await model.cdn.prepare(video: choice.video, audio: choice.audio, avoidP2P: true),
          await Self.anonymousUnchanged(service, expected: expected), model.player === player else { throw AnonymousFailure.boundary }
        player.load(video: prepared.video, audio: prepared.audio)
        model.cdn.attach(player: player, ticket: prepared.ticket, reload: { [weak player, weak model] video, audio in
          guard let player, let model, model.player === player else { return }
          player.load(video: video, audio: audio, start: player.time, paused: player.paused)
        }, downgrade: { false }, refresh: { [weak player, weak model] in
          guard let player, let model, model.player === player,
            await Self.anonymousUnchanged(service, expected: expected) else { throw AnonymousFailure.boundary }
          let freshVideo = try await service.detail(bvid, expectedIdentity: expected)
          let freshManifest = try await service.playback(freshVideo, expectedIdentity: expected)
          guard model.player === player, await Self.anonymousUnchanged(service, expected: expected) else { throw AnonymousFailure.boundary }
          let fresh = try PlaybackSelector.select(freshManifest)
          return (fresh.video, fresh.audio)
        })
        PerformanceOptions.configurePlaybackTuning(player)
      case .live(let requested):
        mode = "live"
        let roomID: Int64
        if let requested { roomID = requested }
        else {
          let feed = try await service.liveFeed(page: 1, expectedIdentity: expected)
          var selected: Int64?
          for candidate in feed.rooms.prefix(5) {
            guard await Self.anonymousUnchanged(service, expected: expected) else { throw AnonymousFailure.boundary }
            guard let room = try? await service.liveRoom(candidate.id), room.status == .live,
              let playback = try? await service.livePlayback(roomID: room.roomID), playback.status == .live,
              !LiveStreamSelector.ranked(playback, preferHEVC: true, avoidPeerAssisted: true).isEmpty else { continue }
            selected = room.roomID; break
          }
          guard let selected else { throw AnonymousFailure.noLiveRoom }
          roomID = selected
        }
        guard await Self.anonymousUnchanged(service, expected: expected) else { throw AnonymousFailure.boundary }
        live = LivePlaybackModel(roomID: roomID, service: service, player: player,
          preferHEVC: true, avoidPeerAssisted: true, usesFixtures: true)
        Self.log(String(format: "PERF anonymous SETUP mode=live room_id=%lld requested_s=%.0f duration_s=0", roomID, PerformanceOptions.anonymousSeconds))
        live?.start()
      }
      let start = CACurrentMediaTime()
      Self.log("PERF anonymous START mode=\(mode) duration_s=\(PerformanceOptions.anonymousSeconds)")
      var previous = 0.0, firstFrame: Double?, stallStart: Double?
      var stalls = 0, stallSeconds = 0.0, progressSamples = 0, audioSamples = 0
      while CACurrentMediaTime() - start < PerformanceOptions.anonymousSeconds {
        let elapsed = CACurrentMediaTime() - start
        let advancing = player.time > previous + 0.05
        if firstFrame == nil, advancing, renderFrames(player) > initialFrames { firstFrame = elapsed }
        if advancing {
          progressSamples += 1
          if let since = stallStart { stallSeconds += elapsed - since }
          stallStart = nil
        } else if firstFrame != nil, stallStart == nil { stallStart = elapsed; stalls += 1 }
        let ao = player.mediaEvidence["current-ao"] ?? "unavailable"
        if advancing, !player.buffering, player.metrics["audio-present"] == 1,
          !["unavailable", "null"].contains(ao), (player.metrics["audio-out-params/channel-count"] ?? 0) > 0,
          (player.metrics["audio-out-params/samplerate"] ?? 0) > 0 { audioSamples += 1 }
        Self.log(String(format: "PERF anonymous SAMPLE elapsed_s=%.3f media_s=%.3f advancing=%d buffering=%d error=%@ eof=%d first_frame_s=%.3f stalls=%d stall_s=%.3f reconnects=%d rss_bytes=%llu", elapsed, player.time, advancing ? 1 : 0,
          player.buffering ? 1 : 0, player.error == nil && live?.error == nil ? "none" : "present", player.eofReached ? 1 : 0,
          firstFrame ?? -1, stalls, stallSeconds + (stallStart.map { elapsed - $0 } ?? 0), live?.reconnects ?? model.cdn.automaticReloads,
          bili_process_resident_bytes()) + Self.audioFields(player))
        if player.eofReached || live?.ended == true { throw AnonymousFailure.incompletePlayback }
        guard await Self.anonymousUnchanged(service, expected: expected), credentials.callCount == 0,
          transport.audit.nonGET == 0, transport.audit.rejected == 0 else { throw AnonymousFailure.boundary }
        previous = player.time
        await delay(1)
      }
      guard firstFrame != nil, progressSamples >= Int(PerformanceOptions.anonymousSeconds * 0.8), audioSamples >= 3,
        player.error == nil, live?.error == nil, !player.buffering else { throw AnonymousFailure.incompletePlayback }
      Self.log(String(format: "PERF anonymous END elapsed_s=%.3f first_frame_s=%.3f progress_samples=%d audio_samples=%d stalls=%d stall_s=%.3f result=PASS", CACurrentMediaTime() - start, firstFrame ?? -1, progressSamples, audioSamples, stalls, stallSeconds))
    } catch let value as AnonymousFailure { failure = value.rawValue }
    catch is CancellationError { failure = "cancelled" }
    catch let value as GETOnlyAuditedTransport.Failure {
      switch value {
      case .transport: failure = "transport"
      case .rejected, .response: failure = "transport_policy"
      }
    }
    catch BiliError.http(let code) { failure = "http"; failureCode = code }
    catch BiliError.api(let code, _) { failure = "api"; failureCode = code }
    catch BiliError.invalidResponse { failure = "decode" }
    catch { failure = "playback_unavailable" }
    // Fixed categories only: never format an Error, request, URL, header or body.
    live?.shutdown(); live = nil
    model.cdn.detach(); model.closePlayer()
    let endBoundary = await Self.anonymousUnchanged(service, expected: expected)
    audit("end", valid: endBoundary)
    if !endBoundary || credentials.callCount != 0 || transport.audit.nonGET != 0 || transport.audit.rejected != 0 { failure = "boundary" }
    memory(phase: "anonymous_closed", iteration: 1, start: started)
    await delay(5)
    if let record { lifetimes([record], current: model.player, iteration: 1) }
    memory(phase: "anonymous_settled", iteration: 1, start: started)
    MpvEnginePool.shared.drain()
    await delay(2)
    if let record { lifetimes([record], current: model.player, iteration: 2) }
    memory(phase: "anonymous_drained", iteration: 1, start: started)
    if let failure {
      Self.log("PERF anonymous FAIL category=\(failure) code=\(failureCode.map(String.init) ?? "unavailable")")
      throw PerformanceOptions.Failure.playbackUnavailable
    }
  }

  private func memory(phase: String, iteration: Int, start: Double) {
    Self.log(String(format: "PERF memory phase=%@ iteration=%d elapsed_s=%.3f rss_bytes=%llu", phase, iteration, CACurrentMediaTime() - start, bili_process_resident_bytes()))
    Self.log("PERF browse_lifetime iteration=\(iteration) live_feeds=\(BrowseFeedModel.diagnosticLiveCount)")
  }
  @MainActor private final class WeakPlaybackRecord {
    weak var player: PlayerModel?
    weak var surface: VideoSurface?
    weak var videoLayer: CALayer?
    init(_ player: PlayerModel) {
      self.player = player
      surface = player.surface
      videoLayer = player.surface?.layer?.sublayers?.first { $0 is VideoLayer }
    }
  }
  private func lifetimes(_ records: [WeakPlaybackRecord], current: PlayerModel, iteration: Int) {
    let oldPlayers = records.filter { $0.player != nil && $0.player !== current }.count
    let surfaces = records.filter { $0.surface != nil }.count
    let layers = records.filter { $0.videoLayer != nil }.count
    Self.log("PERF lifetime iteration=\(iteration) retained_old_players=\(oldPlayers) retained_surfaces=\(surfaces) retained_video_layers=\(layers) current_engine=\(current.engine == nil ? "closed" : "active") pool_reuses=\(MpvEnginePool.shared.reuses)")
  }
  private func stability(file: URL, model: AppModel) async throws {
    let start = CACurrentMediaTime()
    var records: [WeakPlaybackRecord] = []
    memory(phase: "player", iteration: 0, start: start)
    for cycle in 1...50 {
      try await openLocal(file: file, model: model)
      await delay(0.25)
      records.append(WeakPlaybackRecord(model.player))
      model.closePlayer()
      // shutdown() synchronously joins the mpv command queue; allow SwiftUI to
      // detach and release the NSView before sampling/reopening.
      await delay(0.25)
      guard model.player.engine == nil else { throw PerformanceOptions.Failure.playbackUnavailable }
      if cycle % 10 == 0 {
        memory(phase: "player", iteration: cycle, start: start)
        lifetimes(records, current: model.player, iteration: cycle)
      }
    }
    memory(phase: "navigation", iteration: 0, start: start)
    for cycle in 1...200 {
      switch cycle % 5 {
      case 0: model.navigate(to: .popular); model.selectPopularTab(.recommended)
      case 1: model.navigate(to: .popular); model.selectPopularTab(.popular)
      case 2: model.openOverlay(.search("性能样本"))
      default: model.navigate(to: .downloads)
      }
      await delay(0.15)
      if cycle % 10 == 0 { memory(phase: "navigation", iteration: cycle, start: start) }
    }
    await delay(2)
    memory(phase: "idle", iteration: 200, start: start)
    lifetimes(records, current: model.player, iteration: 200)
    Self.log("PERF stability END player_open_close=50 actual_engines=50 navigation_switches=200")
  }
  private func memoryCheckpoint(iteration: Int, final: Bool, model: AppModel) async throws {
    guard model.player.engine == nil else { throw PerformanceOptions.Failure.playbackUnavailable }
    guard let directory = PerformanceOptions.memoryAcknowledgementDirectory else {
      Self.log("PERF memory_stress \(final ? "IDLE" : "MARK") iteration=\(iteration) hold_s=\(final ? 20 : 5)")
      await delay(final ? 20 : 5)
      return
    }
    let acknowledgement = directory.appendingPathComponent(final ? "idle.resume" : "checkpoint-\(iteration).resume")
    // Stale acknowledgements cannot unblock a later diagnostic run.
    if FileManager.default.fileExists(atPath: acknowledgement.path) { try FileManager.default.removeItem(at: acknowledgement) }
    let timeout = final || iteration == 25 || iteration == 150 ? 90.0 : 60.0
    Self.log("PERF memory_stress \(final ? "IDLE" : "MARK") iteration=\(iteration) wait_ack=\(acknowledgement.lastPathComponent) timeout_s=\(Int(timeout)) engine=closed")
    let deadline = CACurrentMediaTime() + timeout
    while !FileManager.default.fileExists(atPath: acknowledgement.path) {
      try Task.checkCancellation()
      guard CACurrentMediaTime() < deadline else {
        Self.log("PERF memory_stress ACK_TIMEOUT iteration=\(iteration)")
        throw PerformanceOptions.Failure.timedOut
      }
      await delay(0.05)
    }
    try FileManager.default.removeItem(at: acknowledgement)
    guard model.player.engine == nil else { throw PerformanceOptions.Failure.playbackUnavailable }
    Self.log("PERF memory_stress ACK iteration=\(iteration) phase=\(final ? "idle" : "checkpoint") engine=closed")
  }
  private func memoryStress(file: URL, model: AppModel) async throws {
    let start = CACurrentMediaTime()
    let iterations = PerformanceOptions.memoryIterations
    // A bounded diagnostic session must not keep a local player alive indefinitely.
    let watchdog = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(900)) } catch { return }
      Self.log("PERF FAIL reason=memory_stress_900s_deadline")
      model.shutdown()
      PerformanceEnvironment.cleanUp()
      NSApp.terminate(nil)
    }
    defer { watchdog.cancel() }
    var records: [WeakPlaybackRecord] = []
    Self.log("PERF memory_stress START iterations=\(iterations) marker_every=25 sampling=\(PerformanceOptions.memoryAcknowledgementDirectory == nil ? "fixed_hold" : "collector_ack") media=\(file.lastPathComponent)")
    memory(phase: "memory_stress", iteration: 0, start: start)
    lifetimes(records, current: model.player, iteration: 0)
    try await memoryCheckpoint(iteration: 0, final: false, model: model)
    for cycle in 1...iterations {
      guard CACurrentMediaTime() - start < 850 else { throw PerformanceOptions.Failure.timedOut }
      try await openLocal(file: file, model: model)
      // openLocal verifies a positive decoded timestamp and actual rendered frames.
      await delay(0.25)
      records.append(WeakPlaybackRecord(model.player))
      model.closePlayer()
      await delay(0.25)
      guard model.player.engine == nil else { throw PerformanceOptions.Failure.playbackUnavailable }
      if cycle % 25 == 0 {
        memory(phase: "memory_stress", iteration: cycle, start: start)
        lifetimes(records, current: model.player, iteration: cycle)
        try await memoryCheckpoint(iteration: cycle, final: false, model: model)
      }
    }
    await delay(2)
    memory(phase: "memory_stress_idle", iteration: iterations, start: start)
    lifetimes(records, current: model.player, iteration: iterations)
    try await memoryCheckpoint(iteration: iterations, final: true, model: model)
    Self.log("PERF memory_stress END player_open_close=\(iterations) actual_engines=\(iterations)")
  }

}

private struct PerformanceScrollModifier: ViewModifier {
  let page: String
  @State private var position = ScrollPosition(y: 0)
  func body(content: Content) -> some View {
    if PerformanceOptions.requested && PerformanceOptions.scrollPage == page {
      content.scrollPosition($position)
        .onScrollGeometryChange(for: PerformanceGeometry.self) { geometry in
          PerformanceGeometry(offset: geometry.contentOffset.y,
            extent: max(0, geometry.contentSize.height - geometry.containerSize.height))
        } action: { _, geometry in
          PerformanceRun.shared.updateScroll(actualY: geometry.offset, extent: geometry.extent)
        }
        .background(PerformanceFrameView { y in position.scrollTo(y: y) })
    } else { content }
  }
}
private struct PerformanceGeometry: Equatable { let offset: Double; let extent: Double }
private struct PerformanceFrameView: NSViewRepresentable {
  let move: (Double) -> Void
  func makeNSView(context: Context) -> PerformanceFrameProbe { PerformanceFrameProbe(move: move) }
  func updateNSView(_ nsView: PerformanceFrameProbe, context: Context) { nsView.move = move }
}
@MainActor private final class PerformanceFrameProbe: NSView {
  var move: (Double) -> Void
  private var link: CADisplayLink?
  private var startTask: Task<Void, Never>?
  private weak var nativeScroll: NSScrollView?
  private var identifiedDriver = false
  init(move: @escaping (Double) -> Void) { self.move = move; super.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { startTask?.cancel(); startTask = nil; link?.invalidate(); link = nil; return }
    guard link == nil, startTask == nil else { return }
    startTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, !Task.isCancelled, self.window != nil else { return }
      let link = self.displayLink(target: self, selector: #selector(tick(_:)))
      let hz = Float(PerformanceOptions.scrollHz)
      link.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
      self.link = link; link.add(to: .main, forMode: .common)
    }
  }
  @objc private func tick(_ link: CADisplayLink) {
    if !identifiedDriver, let content = window?.contentView {
      var candidates: [NSScrollView] = []
      func visit(_ view: NSView) {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 1000 {
          candidates.append(scroll)
        }
        view.subviews.forEach(visit)
      }
      visit(content)
      // Overlay content is later in the view tree than its covered browse page.
      nativeScroll = candidates.last
      identifiedDriver = true
      PerformanceRun.log("PERF scroll driver=\(nativeScroll == nil ? "SwiftUI.ScrollPosition" : "NSClipView") cover_mode=\(PerformanceOptions.coverPipeline ? "pipeline" : "cached_bitmap")")
    }
    let scroll = nativeScroll
    let pointerInside = window.map { $0.frame.contains(NSEvent.mouseLocation) } ?? false
    if !PerformanceRun.shared.scrollTick(arrival: CACurrentMediaTime(), vsync: link.timestamp, target: link.targetTimestamp,
      pointerInside: pointerInside, move: { [move] y in
      if let scroll {
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
      } else { move(y) }
    }) {
      link.invalidate(); self.link = nil
    }
  }
}
extension View {
  func performanceScrollProbe(page: String) -> some View { modifier(PerformanceScrollModifier(page: page)) }
}
