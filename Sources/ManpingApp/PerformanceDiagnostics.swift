import AppKit
import ManpingCore
import CMpv
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI

/// Explicit developer diagnostics are available in optimized Release builds.
/// Invalid performance arguments still force fixture isolation before AppModel initializes.
enum PerformanceOptions {
  enum Mode { case scroll(String), playback(URL), stability(URL), memoryStress(URL) }
  static let arguments = ProcessInfo.processInfo.arguments
  static var requested: Bool { arguments.contains { $0.hasPrefix("--perf-") } }
  private static func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
  static var memoryIterations: Int { Int(value("--perf-memory-iterations") ?? "300") ?? 0 }
  static var memoryAcknowledgementDirectory: URL? {
    value("--perf-memory-ack-dir").map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
  }
  static var scrollPage: String? { value("--perf-scroll") }
  static var playsLocalMedia: Bool {
    requested && (arguments.contains("--perf-play-local") || arguments.contains("--perf-stability") || arguments.contains("--perf-memory-stress"))
  }
  static func parse() throws -> Mode? {
    guard requested else { return nil }
    guard arguments.contains("--perf-fixture") else { throw Failure.arguments }
    let count = ["--perf-scroll", "--perf-play-local", "--perf-stability", "--perf-memory-stress"].filter(arguments.contains).count
    guard count == 1 else { throw Failure.arguments }
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
      cover: URL(string: "https://fixture.invalid/cover/\(index % 8)"), author: "本地性能样本 \(index % 8)",
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
        Self.log("PERF scroll START page=\(page) items=600 warmup_s=2 duration_s=30 speed_pt_s=2400 requested_hz=60 measurement=actual_displaylink_callback_arrival")
        try await wait(seconds: 40) { complete }
      case .playback(let file): try await playback(file: file, model: model)
      case .stability(let file): try await stability(file: file, model: model)
      case .memoryStress(let file): try await memoryStress(file: file, model: model)
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
  func scrollTick(arrival: Double, move: (Double) -> Void) -> Bool {
    guard !complete else { return false }
    if !scrollStarted {
      guard scrollExtent > 1 else { return true }
      scrollStarted = true; scrollOrigin = arrival; scrollLastArrival = arrival
      scrollMinimumY = scrollActualY; scrollMaximumY = scrollActualY
      return true
    }
    let elapsed = arrival - scrollOrigin
    if let previous = scrollLastArrival { scrollIntervals.append((arrival - previous) * 1000) }
    scrollLastArrival = arrival
    if elapsed >= 30 {
      let sorted = scrollIntervals.sorted()
      func percentile(_ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
      }
      let slow = Double(sorted.filter { $0 > 25 }.count) / Double(max(1, sorted.count)) * 100
      let meaningful = scrollGeometryChanges > 100 && scrollMaximumY - scrollMinimumY > 1000 && scrollReversals > 0
      Self.log(String(format: "PERF scroll END page=%@ elapsed_s=%.3f samples=%d p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f over25_pct=%.4f actual_y_min=%.1f actual_y_max=%.1f content_extent=%.1f geometry_changes=%d reversals=%d actual_scroll=%@", PerformanceOptions.scrollPage ?? "", elapsed, sorted.count, percentile(0.50), percentile(0.95), percentile(0.99), slow, scrollMinimumY, scrollMaximumY, scrollExtent, scrollGeometryChanges, scrollReversals, meaningful ? "verified" : "FAIL"))
      complete = true; return false
    }
    let distance = elapsed * 2400
    let phase = distance.truncatingRemainder(dividingBy: scrollExtent * 2)
    move(phase <= scrollExtent ? phase : scrollExtent * 2 - phase)
    return true
  }
  private func renderFrames(_ player: PlayerModel) -> Int {
    let text = player.surface?.renderEvidence ?? ""
    let first = text.split(separator: " ").first ?? ""
    return first.hasPrefix("frames=") ? Int(first.dropFirst(7)) ?? 0 : 0
  }
  private func openLocal(file: URL, model: AppModel) async throws {
    model.open(Video(bvid: DebugUIFixtures.bvid, title: "4K60 本地性能测试", aid: 100))
    try await wait { model.videoDetails != nil && model.player.surface != nil }
    model.player.commentsEnabled = false
    model.player.set("volume", "0")
    model.player.load(video: file, audio: nil)
    try await wait {
      model.player.duration > 0 && model.player.time > 0.1 && model.player.engine != nil &&
        renderFrames(model.player) > 0
    }
    guard model.player.error == nil else { throw PerformanceOptions.Failure.playbackUnavailable }
  }
  private func playback(file: URL, model: AppModel) async throws {
    Self.log("PERF playback START file=\(file.lastPathComponent) warmup_s=5 source_fps=60 profile=high-quality hwdec_request=videotoolbox")
    try await openLocal(file: file, model: model)
    try await wait { model.player.time >= 5 }
    let player = model.player
    let startTime = player.time
    let startRenderFrames = renderFrames(player)
    guard let startVO = player.metrics["frame-drop-count"], let startDecoder = player.metrics["decoder-frame-drop-count"] else { throw PerformanceOptions.Failure.countersUnavailable }
    Self.log("PERF playback WARM media_s=\(startTime) hwdec_current=\(player.hardware) vo_drop=\(startVO) decoder_drop=\(startDecoder)")
    try await wait(seconds: max(70, player.duration + 15)) { player.eofReached || player.time >= player.duration }
    await delay(0.15)
    guard let endVO = player.metrics["frame-drop-count"], let endDecoder = player.metrics["decoder-frame-drop-count"], player.time > startTime else { throw PerformanceOptions.Failure.countersUnavailable }
    let expectedFrames = (player.time - startTime) * 60
    let vo = max(0, endVO - startVO), decoder = max(0, endDecoder - startDecoder)
    let dropPercent = (vo + decoder) / expectedFrames * 100
    let hardwarePass = player.hardware.hasPrefix("videotoolbox")
    Self.log("PERF playback render_frames_delta=\(renderFrames(player) - startRenderFrames) render_evidence=\(player.surface?.renderEvidence ?? "unavailable")")
    Self.log(String(format: "PERF playback END file=%@ start_s=%.3f end_s=%.3f expected_cfr_frames=%.1f vo_drop_delta=%.0f decoder_drop_delta=%.0f total_drop_pct=%.6f hwdec_current=%@ estimated_vf_fps=%@ threshold_pct=0.1 result=%@", file.lastPathComponent, startTime, player.time, expectedFrames, vo, decoder, dropPercent, player.hardware, player.metrics["estimated-vf-fps"].map { String(format: "%.3f", $0) } ?? "unavailable", dropPercent < 0.1 && hardwarePass ? "PASS" : "FAIL"))
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
      case 3: model.navigate(to: .downloads)
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
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
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
      PerformanceRun.log("PERF scroll driver=\(nativeScroll == nil ? "SwiftUI.ScrollPosition" : "NSClipView") cover_mode=cached_bitmap")
    }
    let scroll = nativeScroll
    if !PerformanceRun.shared.scrollTick(arrival: CACurrentMediaTime(), move: { [move] y in
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
