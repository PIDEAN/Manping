import AppKit
import Combine
import ManpingCore
import CMpv
import OpenGL.GL3
import QuartzCore
import SwiftUI

private final class EngineReference: @unchecked Sendable {
  let pointer: OpaquePointer
  var chapterGeneration = -2
  var chapterCount = -1
  var chapters: [PlaybackChapter] = []
  /// Poll ticks (10 Hz) and the load whose source transfer is known; only the poll queue uses them.
  var tick = 0
  var gammaGeneration = -2
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

// Tags public EOF property samples with the load that produced them.
private final class PlaybackEOFGeneration: @unchecked Sendable {
  private let lock = NSLock()
  private var generation = -1
  var value: Int { lock.withLock { generation } }
  func store(_ value: Int) { lock.withLock { generation = value } }
}

/// Keeps one closed mpv engine and its render layer (CGL context + mpv render context) for
/// the next player. Creating a render context per video made the system OpenGL-on-Metal
/// pipeline cache grow by ~0.27 MiB per open/close; reusing the pair avoids recompiling.
/// Only lifecycle changes here; rendering itself is untouched.
@MainActor final class MpvEnginePool {
  static let shared = MpvEnginePool()
  private struct Parked { let engine: OpaquePointer; let signature: String; let id: UUID }
  private var parked: Parked?
  /// A parked engine still holds its video-sized render buffers (around 230 MiB for 4K); release
  /// it if unused this long. Macs with 8 GB or less keep it only briefly.
  var idleLifetime: Duration = ProcessInfo.processInfo.environment["MANPING_MPV_POOL_IDLE_SECONDS"]
    .flatMap(Double.init).map { .milliseconds(Int(max(0.5, $0) * 1000)) }
    ?? (ProcessInfo.processInfo.physicalMemory <= 8 << 30 ? .seconds(20) : .seconds(90))
  private var eviction: Task<Void, Never>?
  /// The system asking for memory releases the idle engine at once.
  private let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
  private init() {
    memoryPressure.setEventHandler { MainActor.assumeIsolated { MpvEnginePool.shared.drain() } }
    memoryPressure.activate()
  }
  /// Render layers created for live or parked engines, so a new surface can re-host them.
  private var layers: [OpaquePointer: VideoLayer] = [:]
  private let queue = DispatchQueue(label: "io.github.pidean.manping.mpv.pool", qos: .userInitiated)
  private(set) var reuses = 0
  /// Returns the parked engine when it was created with the same library and profile.
  func checkout(signature: String) -> OpaquePointer? {
    guard let current = parked else { return nil }
    parked = nil; eviction?.cancel(); eviction = nil
    if current.signature == signature { reuses += 1; return current.engine }
    destroy(current.engine)
    return nil
  }
  func adopt(_ layer: VideoLayer, for engine: OpaquePointer) { layers[engine] = layer }
  func layer(for engine: OpaquePointer) -> VideoLayer? { layers[engine] }
  /// Called when a player closes. Keeps at most one idle engine; destroys the rest.
  func checkin(_ engine: OpaquePointer, signature: String, reusable: Bool) {
    if reusable, parked == nil {
      let reference = EngineReference(engine)
      // Stop decoding and network I/O; the next loadfile replaces the playlist entry.
      queue.sync {
        bili_mpv_release_load(reference.pointer)
        bili_mpv_pause_intent(reference.pointer, 0)
        let stop = strdup("stop")
        var args: [UnsafePointer<CChar>?] = [UnsafePointer(stop), nil]
        _ = args.withUnsafeMutableBufferPointer { bili_mpv_command(reference.pointer, $0.baseAddress) }
        free(stop)
        // Match a freshly created engine: no carried-over speed, shaders or subtitle choice.
        _ = bili_mpv_set(reference.pointer, "pause", "no")
        _ = bili_mpv_set(reference.pointer, "speed", "1")
        _ = bili_mpv_set(reference.pointer, "glsl-shaders", "")
        _ = bili_mpv_set(reference.pointer, "sid", "auto")
      }
      let id = UUID()
      parked = Parked(engine: engine, signature: signature, id: id)
      let lifetime = idleLifetime
      eviction = Task { @MainActor [weak self] in
        try? await Task.sleep(for: lifetime)
        guard !Task.isCancelled, let self, let current = self.parked, current.id == id else { return }
        self.parked = nil; self.destroy(current.engine)
      }
      return
    }
    destroy(engine)
  }
  /// Render context first (it needs the engine), then the engine.
  private func destroy(_ engine: OpaquePointer) {
    if let layer = layers.removeValue(forKey: engine) { layer.stop(); layer.removeFromSuperlayer() }
    let reference = EngineReference(engine)
    queue.sync { bili_mpv_destroy(reference.pointer) }
  }
  func drain() {
    eviction?.cancel(); eviction = nil
    if let current = parked { parked = nil; destroy(current.engine) }
  }
}

/// The playback position lives in its own object: only the timeline, progress bar and chapter
/// list observe it, so ten position updates a second no longer re-render the whole player page
/// (which also closed menus mid-click).
@MainActor final class PlaybackClock: ObservableObject {
  @Published var time: Double = 0
}

@MainActor final class PlayerModel: ObservableObject {
  let clock = PlaybackClock()
  /// Every seek asked of this player, sent before it is carried out (片段播放 tells its own apart).
  let seekRequests = PassthroughSubject<Double, Never>()
  var time: Double {
    get { clock.time }
    set { if clock.time != newValue { clock.time = newValue } }
  }
  @Published var duration: Double = 0
  /// mpv `paused-for-cache`: playback is waiting for network data.
  @Published private(set) var buffering = false
  /// Seconds of media buffered ahead of the playhead (`demuxer-cache-duration`).
  private(set) var bufferedAhead: Double = 0
  @Published private(set) var eofReached = false
  private var eofArmed = false
  private(set) var terminalFailure = false
  private(set) var terminalFailureAt: Double?
  var presentationExpected: Bool { surface?.presentationExpected ?? false }
  var onRecoverySeek: (() -> Void)?
  var presentedFrames: Int {
    let first = surface?.renderEvidence.split(separator: " ").first ?? ""
    return first.hasPrefix("frames=") ? Int(first.dropFirst(7)) ?? 0 : 0
  }
  private let eofGeneration = PlaybackEOFGeneration()
  @Published var paused = false
  private var confirmedEnginePause: Bool?
  private(set) var liveTextPauseAnalyses = 0
  private(set) var liveTextResumeClears = 0
  let playbackIdentity = UUID()
  private(set) var browsingSuspended = false
  private(set) var playbackIntended = true
  var powerAssertionHeld: Bool { sleepGuard.held }
  var onExplicitPlay: (() -> Void)?
  /// All loads and playback entry points obey the same gate, including delayed CDN loads.
  func suspendForBrowsing() {
    browsingSuspended = true
    set("pause", "yes")
    surface?.setPlaybackActive(false)
    sleepGuard.release()
  }
  func finishBrowsing(resume: Bool) {
    browsingSuspended = false
    set("pause", resume ? "no" : "yes")
  }
  func requestPlay() {
    if browsingSuspended { onExplicitPlay?() }
    set("pause", "no")
  }
  /// 仅播放声音: video decoding off for this session (music, podcasts, saving power).
  @Published private(set) var audioOnly = PlayerModel.sessionAudioOnly
  static var sessionAudioOnly = false
  /// Live rooms always show video: the session preference applies to videos and episodes.
  func suspendAudioOnly() { audioOnly = false }
  func setAudioOnly(_ on: Bool) {
    guard on != audioOnly else { return }
    audioOnly = on; Self.sessionAudioOnly = on
    if on { liveText.clear() }
    set("vid", on ? "no" : "auto")
  }
  /// The frame on screen at the video's display size (longest side at most 3840 px).
  func captureFrame() async -> CGImage? {
    guard let engine, external == nil else { return nil }
    let reference = EngineReference(engine)
    let size: (Double, Double) = await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: (bili_mpv_number(reference.pointer, "video-params/dw"),
          bili_mpv_number(reference.pointer, "video-params/dh")))
      }
    }
    guard size.0.isFinite, size.1.isFinite, size.0 >= 16, size.1 >= 16 else { return nil }
    let scale = min(1, 3840 / max(size.0, size.1))
    return await surface?.captureVideoFrame(width: Int(size.0 * scale), height: Int(size.1 * scale))
  }
  /// Live Text over the paused frame (设置 › 播放控制 › 暂停时识别画面文字).
  let liveText = LiveTextController()
  /// Live Text applies to the built-in player showing video, with the setting on.
  var liveTextEnabled: Bool { runtimeSettings.bool(.liveText) && !audioOnly && external == nil && !closing }
  /// Display-sleep assertion held only while frames are actually advancing.
  private let sleepGuard = PlaybackPowerAssertion()
  @Published var volume: Double = 80
  @Published var speed: Double = 1
  var status = "未加载"
  @Published var error: String?
  @Published var hardware = ""
  /// Volume and danmaku visibility chosen during this app session carry over to the next
  /// video or part instead of snapping back to the settings default.
  static var sessionVolume: Double?
  static var sessionComments: Bool?
  @Published var commentsEnabled = true { didSet { if oldValue != commentsEnabled { Self.sessionComments = commentsEnabled } } }
  @Published private(set) var chapters: [PlaybackChapter] = []
  @Published private(set) var usesExternalMpv = false
  var danmakuFontSize: Double = 24
  var danmakuOpacity: Double = 1
  var danmakuSpeed: Double = 1
  /// 弹幕帧率: `DanmakuFrameRate.display` or `.sixty`.
  var danmakuFrameRate = DanmakuFrameRate.display
  /// Fraction of the view height scrolling and top danmaku may use (1/4, 1/2 or 1). It is a
  /// player-local preference kept outside the settings catalog.
  var danmakuArea: Double = PlayerModel.storedDanmakuArea {
    didSet { if oldValue != danmakuArea { PerformanceEnvironment.defaults.set(danmakuArea, forKey: Self.danmakuAreaKey) } }
  }
  static let danmakuAreaKey = "Manping.danmakuArea"
  static let danmakuAreas: [Double] = [0.25, 0.5, 1]
  private static var storedDanmakuArea: Double {
    let value = PerformanceEnvironment.defaults.double(forKey: danmakuAreaKey)
    return danmakuAreas.contains(value) ? value : 1
  }
  /// The user's own rules plus the account's synced shield list. The user's rules have one
  /// source, `DanmakuFilterStore`, shared by every player and both editors.
  var effectiveDanmakuFilter: DanmakuFilter {
    var filter = DanmakuFilterStore.shared.filter
    filter.account = DanmakuShieldSync.shared.shield
    return filter
  }
  /// The user's rules or the account shield list changed (edited, synced, toggled, signed out).
  func refreshAccountShield() {
    timeline.setFilter(effectiveDanmakuFilter)
    surface?.refreshDanmakuPreferences()
  }
  private var runtimeSettings = MacSettings()
  private var temporaryOriginalSpeed: Double?
  /// The value the user just chose and until when poll samples that disagree are stale.
  private var userSpeed: (value: Double, until: Date)?
  private var userVolume: (value: Double, until: Date)?
  private var external: M7ExternalMpv?
  /// Lanes are laid out for the current danmaku speed, including timelines assigned later.
  var timeline = DanmakuTimeline(comments: []) {
    didSet {
      timeline.setFilter(effectiveDanmakuFilter); timeline.setSpeed(danmakuSpeed)
      // The render thread draws from a published copy.
      surface?.danmakuTimelineChanged()
    }
  }
  private let queue = DispatchQueue(label: "io.github.pidean.manping.mpv.commands", qos: .userInitiated)
  private var poll: DispatchSourceTimer?
  private(set) var mediaIsolationVerified = false
  private(set) var engine: OpaquePointer?
  private var engineSignature = ""
  private var enginePath = ""
  /// The built-in mpv profile this engine applied (「自动」 resolved when it was created).
  private(set) var engineProfile = ""
  /// The source's transfer (`video-params/gamma`), kept from the last video that reported one.
  /// `pq` and `hlg` select EDR output.
  private(set) var videoGamma = ""
  var hdrSource: Bool { ["pq", "hlg"].contains(videoGamma) }
  /// `--diagnose` runs: renderer evidence keeps its earlier, power-independent choices.
  static let diagnosticMode = ProcessInfo.processInfo.arguments.contains("--diagnose")
    || ProcessInfo.processInfo.arguments.contains("--diagnose-bvid")
  private var closing = false
  private var pending: (video: URL, audio: URL?, start: Double, paused: Bool)?
  private var generation = 0
  weak var surface: VideoSurface?
  var diagnosticEvents: [String] = []
  var shaderEvents: [String] = []
  var passes = ""
  var metrics: [String: Double] = [:]
  var metricSamples: [[String: Double]] = []
  var mediaEvidence: [String: String] = [:]
  /// Off for live streams, which have no fixed length.
  var tracksDuration = true
  /// Display reconfigurations (layer or tone-mapping target) since launch; diagnostics only.
  var displayUpdates = 0
  /// Smooth clock for danmaku, fed from the sampling thread (see DanmakuClock).
  nonisolated let danmakuClock = DanmakuClock()
  var mediaClock: Double { danmakuClock.media(at: CACurrentMediaTime()) ?? time }
  static var libraryPath: String {
    if let override = ProcessInfo.processInfo.environment["MANPING_MPV_LIBRARY"] { return override }
    let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libmpv.2.dylib")
      .path
    return FileManager.default.fileExists(atPath: bundled)
      ? bundled : "/opt/homebrew/lib/libmpv.2.dylib"
  }
  func start() {
    guard engine == nil, external == nil, !closing else { return }
    if DebugUIFixtures.enabled && !PerformanceOptions.playsLocalMedia { return }
    let executable = runtimeSettings.text(.customMpv)
    if !executable.isEmpty {
      usesExternalMpv = true
      let external = M7ExternalMpv { [weak self] sample in
        Task { @MainActor [weak self] in
          guard let self, !self.closing, !self.terminalFailure else { return }
          self.time = sample.time
          self.danmakuClock.update(.init(host: CACurrentMediaTime(), media: sample.time,
            playing: !sample.paused, speed: sample.speed))
          if self.duration != sample.duration { self.duration = sample.duration }
          if self.paused != sample.paused { self.paused = sample.paused }
          if self.speed != sample.speed && !self.isStale(sample.speed, against: self.userSpeed) { self.speed = sample.speed }
          if self.volume != sample.volume && !self.isStale(sample.volume, against: self.userVolume) { self.volume = sample.volume }
          if self.chapters != sample.chapters { self.chapters = sample.chapters }
          if !sample.eof && !sample.idle && sample.duration > 0 { self.eofArmed = true }
          if sample.eof && self.eofArmed { self.eofReached = true }
          if let error = sample.error, self.error != error { self.error = error }
          let status = sample.exited ? "外部 mpv 已退出" : "外部 mpv · 已连接"
          if self.status != status { self.status = status }
          if sample.exited { self.external = nil }
        }
      }
      self.external = external
      external.start(executable: executable)
      engineProfile = resolvedProfile()
      applyRuntime(previous: nil)
      return
    }
    var message = [CChar](repeating: 0, count: 2048)
    let customLibrary = runtimeSettings.text(.customLibMpv)
    let path = customLibrary.isEmpty ? Self.libraryPath : customLibrary
    // A profile switch needs a fresh engine (profiles set different option sets). 「自动」 is
    // resolved here, once per engine, from the power state.
    let profile = resolvedProfile()
    let signature = Self.signature(path: path, profile: profile)
    let isolated = PerformanceOptions.requested
    let reference: EngineReference?
    if let reused = MpvEnginePool.shared.checkout(signature: signature) {
      reference = EngineReference(reused)
    } else {
      reference = queue.sync { bili_mpv_create(path, isolated ? 1 : 0, &message, message.count).map(EngineReference.init) }
      if let handle = reference?.pointer, let ca = Bundle.main.url(forResource: "cacert", withExtension: "pem") {
        queue.sync { _ = bili_mpv_set(handle, "tls-ca-file", ca.path) }
      }
    }
    let handle = reference?.pointer
    guard let handle, let reference else {
      if isolated { PerformanceRun.log("PERF media_isolation requested=1 verified=0") }
      error = String(cString: message)
      return
    }
    // Process argv is immutable, so the engine pool cannot cross production/perf modes.
    let isolationMask = queue.sync { bili_mpv_isolation_mask(handle) }
    mediaIsolationVerified = isolated && isolationMask == 7
    if isolated {
      PerformanceRun.log("PERF media_isolation requested=1 verified=\(mediaIsolationVerified ? 1 : 0) ytdl=\(isolationMask & 1 != 0 ? "no" : "unverified") load_scripts=\(isolationMask & 2 != 0 ? "no" : "unverified") cookies=\(isolationMask & 4 != 0 ? "no" : "unverified")")
    }
    engine = handle
    bili_mpv_pause_intent(handle, paused ? 1 : 0)
    engineSignature = signature
    enginePath = path
    engineProfile = profile
    let diagnosticMode = Self.diagnosticMode
    // The playback report (debug builds) reads the media strings; it samples them once a second.
    let reportsMedia = diagnosticMode || ProcessInfo.processInfo.arguments.contains("--ui-playback-report") || PerformanceOptions.requested
    let eofGeneration = self.eofGeneration
    let danmakuClock = self.danmakuClock
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler { @Sendable [weak self] in
      let handle = reference.pointer
      let sampledGeneration = eofGeneration.value
      let reachedEnd = bili_mpv_flag(handle, "eof-reached") != 0
      var time: Double = 0
      // Unavailable while a file is opening; the clock then keeps the requested start position.
      let timeKnown = bili_mpv_number_checked(handle, "time-pos", &time) >= 0 && time.isFinite
      let duration = bili_mpv_number(handle, "duration")
      let paused = bili_mpv_flag(handle, "pause") != 0
      let waitingForCache = bili_mpv_flag(handle, "paused-for-cache") > 0
      let idle = bili_mpv_flag(handle, "idle-active") != 0
      let speed = bili_mpv_number(handle, "speed")
      // audio-pts follows the audio device sample by sample; time-pos steps once per video
      // frame. Read with this thread's host time, not when the main thread gets around to it.
      var audioTime: Double = 0
      let audioKnown = bili_mpv_number_checked(handle, "audio-pts", &audioTime) >= 0 && audioTime.isFinite && audioTime >= 0
      if timeKnown || audioKnown {
        danmakuClock.update(.init(host: CACurrentMediaTime(), media: audioKnown ? audioTime : time,
          playing: !paused && !waitingForCache && !idle && !reachedEnd, speed: speed))
      }
      let volume = bili_mpv_number(handle, "volume")
      let countValue = bili_mpv_number(handle, "chapter-list/count")
      let chapterCount = countValue.isFinite ? Int(min(1024, max(0, countValue))) : 0
      if reference.chapterGeneration != sampledGeneration || reference.chapterCount != chapterCount {
        reference.chapterGeneration = sampledGeneration; reference.chapterCount = chapterCount
        reference.chapters = (0..<chapterCount).compactMap { index in
          var seconds: Double = 0
          guard bili_mpv_number_checked(handle, "chapter-list/\(index)/time", &seconds) >= 0,
            seconds.isFinite, seconds >= 0 else { return nil }
          var title = [CChar](repeating: 0, count: 2048)
          _ = bili_mpv_string(handle, "chapter-list/\(index)/title", &title, title.count)
          let text = String(cString: title)
          return PlaybackChapter(index: index, title: text.isEmpty ? "章节 \(index + 1)" : text, time: seconds)
        }
      }
      let chapters = reference.chapters
      var cacheAhead: Double = 0
      let cacheKnown = bili_mpv_number_checked(handle, "demuxer-cache-duration", &cacheAhead) >= 0
      // Clock, state, buffer and events above and below run every tick (10 Hz). Decoder name,
      // frame counters and the source transfer once a second; vo-passes and the media strings
      // only for diagnostics. `--diagnose` keeps reading everything every tick, as before.
      reference.tick &+= 1
      let slow = diagnosticMode || reference.tick % 10 == 1
      var hardwareText: String?
      if reportsMedia && slow {
        var hardware = [CChar](repeating: 0, count: 128)
        _ = bili_mpv_string(handle, "hwdec-current", &hardware, hardware.count)
        hardwareText = String(cString: hardware)
      }
      // The source transfer picks EDR or SDR output: read it every tick until this load's video
      // reports one, then once a second. An empty value (no video yet) never replaces a known one.
      var gamma: String?
      // The picture's display size (`video-params/dw` × `dh`) is read with the transfer, so the
      // stage fits the video layer to the real shape soon after the first frame.
      var displayAspect: Double?
      if slow || reference.gammaGeneration != sampledGeneration {
        var width: Double = 0, height: Double = 0
        if bili_mpv_number_checked(handle, "video-params/dw", &width) >= 0,
          bili_mpv_number_checked(handle, "video-params/dh", &height) >= 0,
          width.isFinite, height.isFinite, width >= 16, height >= 16 {
          displayAspect = width / height
        }
        var buffer = [CChar](repeating: 0, count: 64)
        if bili_mpv_string(handle, "video-params/gamma", &buffer, buffer.count) >= 0, buffer[0] != 0 {
          gamma = String(cString: buffer)
          reference.gammaGeneration = sampledGeneration
        }
      }
      var passText: String?
      var media: [String: String]?
      if reportsMedia && slow {
        var passes = [CChar](repeating: 0, count: 32768)
        _ = bili_mpv_passes(handle, &passes, passes.count)
        passText = String(cString: passes)
        let names = [
          "audio-codec-name", "video-params/pixelformat", "video-params/hw-pixelformat",
          "video-params/primaries", "video-params/gamma", "video-params/colormatrix",
        ]
        media = Dictionary(
          uniqueKeysWithValues: names.map { name in
            var buffer = [CChar](repeating: 0, count: 256)
            _ = bili_mpv_string(handle, name, &buffer, buffer.count)
            return (name, String(cString: buffer))
          })
      }
      var logs: [String] = []
      for _ in 0..<64 {
        var message = [CChar](repeating: 0, count: 2048)
        let event = bili_mpv_event(handle, &message, message.count)
        if event == 0 { break }
        let line = DiagnosticRedactor.sanitize(String(cString: message))
        if !line.hasPrefix("event:") { logs.append(line) }
      }
      let events = logs
      var metrics: [String: Double]?
      if reportsMedia && slow {
        let properties = [
          "frame-drop-count", "decoder-frame-drop-count", "mistimed-frame-count",
          "demuxer-cache-duration", "demuxer-cache-state/fw-bytes", "video-params/sig-peak",
          "estimated-vf-fps", "estimated-frame-number", "estimated-frame-count",
          "display-fps", "vsync-jitter", "video-bitrate",
        ]
        var measured = Dictionary(
          uniqueKeysWithValues: properties.compactMap { name -> (String, Double)? in
            var value: Double = 0
            return bili_mpv_number_checked(handle, name, &value) >= 0 ? (name, value) : nil
          })
        if diagnosticMode { measured["residentBytes"] = Double(bili_process_resident_bytes()) }
        var ao = [CChar](repeating: 0, count: 64)
        _ = bili_mpv_string(handle, "current-ao", &ao, ao.count)
        media?["current-ao"] = DiagnosticAudioTuning.outputCategory(String(cString: ao))
        let count = bili_mpv_number(handle, "track-list/count")
        var hasAudio = false
        if count.isFinite, count > 0 {
          for index in 0..<Int(min(256, count)) {
            var kind = [CChar](repeating: 0, count: 32)
            _ = bili_mpv_string(handle, "track-list/\(index)/type", &kind, kind.count)
            if String(cString: kind) == "audio" { hasAudio = true; break }
          }
        }
        measured["audio-present"] = hasAudio ? 1 : 0
        if audioKnown { measured["audio-pts"] = audioTime }
        for name in ["avsync", "total-avsync-change", "audio-out-params/samplerate",
          "audio-params/channel-count", "audio-out-params/channel-count"] {
          var value: Double = 0
          if bili_mpv_number_checked(handle, name, &value) >= 0, value.isFinite { measured[name] = value }
        }
        metrics = measured
      }
      let sampledMetrics = metrics, sampledMedia = media, sampledPasses = passText
      let sampledHardware = hardwareText, sampledGamma = gamma, sampledAspect = displayAspect
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closing, !self.terminalFailure, self.generation == sampledGeneration else { return }
        if let sampledMedia { self.mediaEvidence = sampledMedia }
        if let sampledAspect { self.surface?.sourceAspect = CGFloat(sampledAspect) }
        if let sampledGamma, self.videoGamma != sampledGamma {
          self.videoGamma = sampledGamma
          self.surface?.sourceTransferChanged()
        }
        if let metrics = sampledMetrics {
          self.metrics = metrics
          if diagnosticMode && self.metricSamples.last?["mediaSecond"] != floor(time) {
            self.metricSamples.append(metrics.merging(["mediaSecond": floor(time)]) { _, new in new })
            self.metricSamples = Array(self.metricSamples.suffix(120))
          }
        }
        if self.generation == sampledGeneration, self.pending == nil {
          if !reachedEnd && !idle && duration > 0 { self.eofArmed = true }
          if reachedEnd && self.eofArmed { self.eofReached = true }
        }
        // Publish only real changes: every @Published write re-renders observing views.
        if timeKnown, self.generation == sampledGeneration, self.pending == nil {
          self.time = time
        }
        if let sampledPasses { self.passes = sampledPasses }
        // A live stream's "duration" grows every poll; publishing it re-rendered the page 10×/s.
        if self.tracksDuration, self.duration != duration { self.duration = duration }
        let effectivePause = paused || self.browsingSuspended
        if self.paused != effectivePause { self.paused = effectivePause }
        // UI intent is published immediately by set(); OCR follows the confirmed engine edge.
        if !idle, self.confirmedEnginePause != paused {
          self.confirmedEnginePause = paused
          if paused, self.liveTextEnabled, !idle, !self.browsingSuspended {
            self.liveTextPauseAnalyses += 1
            self.liveText.analyse(self)
          } else {
            self.liveTextResumeClears += 1
            self.liveText.clear()
          }
        }
        if speed.isFinite && speed > 0 && self.speed != speed && !self.isStale(speed, against: self.userSpeed) { self.speed = speed }
        if volume.isFinite && volume >= 0 && self.volume != volume && !self.isStale(volume, against: self.userVolume) { self.volume = volume }
        if self.chapters != chapters { self.chapters = chapters }
        if self.buffering != waitingForCache { self.buffering = waitingForCache }
        self.bufferedAhead = cacheKnown ? cacheAhead : 0
        self.surface?.setPlaybackActive(!self.browsingSuspended && !paused && !idle)
        self.sleepGuard.update(playing: !self.browsingSuspended && !paused && !idle && !reachedEnd)
        if let sampledHardware, self.hardware != sampledHardware { self.hardware = sampledHardware }
        // An error sampled before the newest loadfile belongs to the previous stream.
        if self.generation == sampledGeneration, self.pending == nil,
          let failure = events.last(where: { $0.hasPrefix("end-file:") && !$0.contains("success") }) {
          let reason = failure.dropFirst("end-file:".count).trimmingCharacters(in: .whitespaces)
          self.error = "没能加载视频流（\(reason)）。可在 更多 › 网络与节点 中换节点或重新测速后重试。"
        }
        if reportsMedia && !events.isEmpty {
          self.shaderEvents.append(
            contentsOf: events.filter {
              $0.localizedCaseInsensitiveContains("shader")
                || $0.localizedCaseInsensitiveContains("compute")
            })
          self.shaderEvents = Array(self.shaderEvents.suffix(512))
          self.diagnosticEvents.append(contentsOf: events)
          self.diagnosticEvents = Array(self.diagnosticEvents.suffix(128))
          if let error = events.last(where: {
            $0.contains("error") || $0.contains("failed") || $0.contains("Error")
          }), self.status != error {
            self.status = error
          }
        }
      }
    }
    poll = timer
    timer.resume()
    applyRuntime(previous: nil)
    PerformanceOptions.configureAudio(self)
  }
  func load(video: URL, audio: URL?, start: Double = 0, paused: Bool = false) {
    let paused = paused || browsingSuspended
    if !browsingSuspended { playbackIntended = !paused; self.paused = paused }
    self.start()
    if let engine { bili_mpv_pause_intent(engine, paused ? 1 : 0) }
    generation += 1
    terminalFailure = false
    terminalFailureAt = nil
    resetPlaybackEnd()
    confirmedEnginePause = nil
    chapters = []
    danmakuClock.reset()
    liveText.clear()
    // Until the new file reports its size, the stage uses the shape the page knows.
    surface?.sourceAspect = nil
    if let external {
      external.load(video: video, audio: audio, start: start, paused: paused)
      // External mpv keeps its own options; carry 仅播放声音 to it on every load as well.
      external.set("vid", audioOnly ? "no" : "auto")
      status = "外部 mpv · 正在加载"
      time = 0
      return
    }
    pending = (video, audio, start, paused)
    // A fresh engine starts with video on; carry 仅播放声音 into it.
    set("vid", audioOnly ? "no" : "auto")
    status = "正在加载分离音视频"
    error = nil
    // Report the start position until the new file plays, so a quality change or CDN reload
    // issued during loading resumes from here instead of from zero.
    time = start
    if duration != 0 { duration = 0 }
    if surface?.renderReady == true { renderStarted() }
  }
  func renderStarted() {
    guard let pending, let engine, !closing else { return }
    self.pending = nil
    let reference = EngineReference(engine)
    let loadGeneration = generation
    let eofGeneration = self.eofGeneration
    queue.async { [weak self] in
      let result = bili_mpv_load(
        reference.pointer, pending.video.absoluteString,
        pending.audio?.absoluteString, pending.start, pending.paused ? 1 : 0)
      eofGeneration.store(loadGeneration)
      if result < 0 { DispatchQueue.main.async {
        guard let self, self.generation == loadGeneration, !self.terminalFailure else { return }
        self.error = "mpv loadfile failed: \(result)"
      } }
    }
  }
  /// Terminal recovery failure: cancel the pending load and stop mpv before showing retry UI.
  func failPlayback(_ message: String) {
    generation += 1
    pending = nil
    terminalFailure = true
    terminalFailureAt = ProcessInfo.processInfo.systemUptime
    buffering = false
    error = message
    command(["stop"])
    surface?.setPlaybackActive(false)
    sleepGuard.release()
  }
  func resetPlaybackEnd() { eofReached = false; eofArmed = false }
  /// Network diagnostics read the engine even after terminal UI publication has stopped.
  /// Queue ordering puts this read after an already submitted stop command.
  func diagnosticNetworkEngineSample() async -> (idle: Bool?, time: Double?) {
    guard PerformanceOptions.requested, PerformanceOptions.playsLocalMedia,
      let engine, external == nil, !closing else { return (nil, nil) }
    let sampledGeneration = generation
    let reference = EngineReference(engine)
    let sample: (idle: Bool?, time: Double?) = await withCheckedContinuation { continuation in
      queue.async {
        let idle = bili_mpv_flag(reference.pointer, "idle-active") == 1
        var time = 0.0
        let known = bili_mpv_number_checked(reference.pointer, "time-pos", &time) >= 0 && time.isFinite
        continuation.resume(returning: (idle, known ? time : nil))
      }
    }
    guard generation == sampledGeneration, !closing else { return (nil, nil) }
    return sample
  }
  func diagnosticPauseFlag() async -> Bool? {
    guard PerformanceOptions.requested, let engine, !closing else { return nil }
    let reference = EngineReference(engine)
    return await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: bili_mpv_flag(reference.pointer, "pause") == 1) }
    }
  }
  /// A real mpv barrier, before captured loadfile options apply. Never blocks the worker.
  func diagnosticHoldNextLoad() async -> Bool {
    guard PerformanceOptions.requested, PerformanceOptions.playsLocalMedia,
      let engine, mediaIsolationVerified, !closing else { return false }
    let reference = EngineReference(engine)
    return await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: bili_mpv_hold_next_load(reference.pointer) >= 0) }
    }
  }
  func diagnosticReleaseLoad() async {
    guard let engine, PerformanceOptions.requested, !closing else { return }
    let reference = EngineReference(engine)
    await withCheckedContinuation { continuation in
      queue.async { bili_mpv_release_load(reference.pointer); continuation.resume() }
    }
  }
  struct DiagnosticLoadSample {
    let held: Bool, loadedFiles: Int, paused: Bool, audioSelected: Bool, eof: Bool
    let time: Double?, audioTime: Double?, audioOutput: String
  }
  func diagnosticLoadSample() async -> DiagnosticLoadSample? {
    guard PerformanceOptions.requested, PerformanceOptions.playsLocalMedia,
      let engine, !closing else { return nil }
    let reference = EngineReference(engine)
    return await withCheckedContinuation { continuation in
      queue.async {
        let engine = reference.pointer
        func number(_ name: String) -> Double? {
          var value = 0.0
          return bili_mpv_number_checked(engine, name, &value) >= 0 && value.isFinite ? value : nil
        }
        var output = [CChar](repeating: 0, count: 64)
        _ = bili_mpv_string(engine, "current-ao", &output, output.count)
        continuation.resume(returning: DiagnosticLoadSample(held: bili_mpv_load_held(engine) != 0,
          loadedFiles: Int(bili_mpv_loaded_files(engine)), paused: bili_mpv_flag(engine, "pause") != 0,
          audioSelected: (number("aid") ?? 0) > 0, eof: bili_mpv_flag(engine, "eof-reached") != 0, time: number("time-pos"),
          audioTime: number("audio-pts"), audioOutput: DiagnosticAudioTuning.outputCategory(String(cString: output))))
      }
    }
  }
  #if DEBUG
  func simulatePlaybackEnd() {
    guard DebugUIFixtures.enabled else { return }
    eofReached = true
  }
  #endif
  func command(_ args: [String]) {
    if args == ["cycle", "pause"] { togglePause(); return }
    if args.count >= 3, args[0] == "set", args[1] == "pause" { set("pause", args[2]); return }
    if let external, !closing { external.command(args); return }
    guard let engine, !closing else { return }
    let reference = EngineReference(engine)
    queue.async { [weak self] in
      let engine = reference.pointer
      let pointers = args.map { strdup($0) }
      defer { for pointer in pointers { free(pointer) } }
      var arguments = pointers.map { UnsafePointer<CChar>($0) } + [nil]
      let result = arguments.withUnsafeMutableBufferPointer {
        bili_mpv_command(engine, $0.baseAddress)
      }
      if result < 0 { DispatchQueue.main.async { self?.error = "mpv command failed: \(result)" } }
    }
  }
  func set(_ name: String, _ value: String) {
    if name == "pause" {
      if browsingSuspended && value != "yes" { return }
      playbackIntended = value == "no"
      paused = value == "yes"
      // Publish before queueing the property: an already submitted loadfile may be
      // applying its older file-local options on the engine thread right now.
      if let engine { bili_mpv_pause_intent(engine, paused ? 1 : 0) }
      if var next = pending { next.paused = paused; pending = next }
      if paused { surface?.setPlaybackActive(false); sleepGuard.release() }
      else { liveText.clear() }
    }
    if let external, !closing { external.set(name, value); return }
    guard let engine, !closing else { return }
    let reference = EngineReference(engine)
    queue.async { [weak self] in
      let engine = reference.pointer
      let result = bili_mpv_set(engine, name, value)
      if result < 0 { DispatchQueue.main.async { self?.error = "mpv property \(name): \(result)" } }
    }
  }
  func verboseLogs() {
    guard let engine else { return }
    let reference = EngineReference(engine)
    queue.async { bili_mpv_log_level(reference.pointer, "v") }
  }
  /// Danmaku look and speed only; safe to call while a settings control is being dragged.
  func applyDanmakuPreferences(_ settings: MacSettings) {
    danmakuFontSize = settings.number(.danmakuFontSize)
    danmakuOpacity = settings.number(.danmakuOpacity)
    danmakuSpeed = settings.number(.danmakuSpeed)
    danmakuFrameRate = settings.text(.danmakuFrameRate)
    timeline.setSpeed(danmakuSpeed)
    surface?.refreshDanmakuPreferences()
  }
  func setDanmakuArea(_ area: Double) {
    guard Self.danmakuAreas.contains(area), area != danmakuArea else { return }
    danmakuArea = area
    surface?.refreshDanmakuPreferences()
  }
  func configureRuntime(settings: MacSettings, previous: MacSettings? = nil) {
    let old = runtimeSettings
    runtimeSettings = settings
    if !settings.bool(.liveText) { liveText.clear() }
    applyDanmakuPreferences(settings)
    if engine != nil || external != nil {
      if old.text(.customLibMpv) != settings.text(.customLibMpv)
        || old.text(.customMpv) != settings.text(.customMpv)
        || old.text(.mpvProfile) != settings.text(.mpvProfile) {
        status = "播放器路径或画质配置已保存，下次新建播放器时生效"
      }
      applyRuntime(previous: previous ?? old)
    }
  }
  private func applyRuntime(previous: MacSettings?) {
    let old = previous.map { Dictionary(uniqueKeysWithValues: MpvRuntimePlan.properties($0)) }
    for (name, value) in MpvRuntimePlan.properties(runtimeSettings) where old?[name] != value {
      set(name, value)
    }
    // Profiles override different option sets; a fresh engine prevents a
    // fast -> high-quality transition from retaining fast-only options.
    if previous == nil {
      command(["apply-profile", engineProfile])
    }
    PerformanceOptions.configurePlaybackTuning(self)
    if previous?.text(.logLevel) != runtimeSettings.text(.logLevel) {
      let level = runtimeSettings.text(.logLevel)
      if let external { external.set("msg-level", "all=" + level) }
      else if let engine {
        let reference = EngineReference(engine)
        queue.async { bili_mpv_log_level(reference.pointer, level) }
      }
    }
  }
  /// The profile for a new engine: 画质配置, or `fast` while saving power with
  /// 「省电时降低画面处理质量」 on. Diagnostics never count as saving, so recorded evidence is
  /// reproducible.
  private func resolvedProfile() -> String {
    MpvRuntimePlan.profile(runtimeSettings, saving: Self.diagnosticMode ? .normal : PowerState.shared.level)
  }
  private static func signature(path: String, profile: String) -> String { path + "\u{0}" + profile }
  /// Options the built-in `fast` profile sets, for libraries whose `profile-list` cannot be read.
  private static let fastProfileOptions = [
    "scale", "dscale", "dither", "correct-downscaling", "linear-downscaling", "sigmoid-upscaling",
    "hdr-compute-peak", "allow-delayed-peak-detect",
  ]
  /// 画面增强 shaders were tuned on high-quality. When power saving gave this engine `fast`,
  /// put back exactly what a high-quality engine has before shaders run: every option `fast` set
  /// returns to its default, then `high-quality` is applied — the state a fresh high-quality engine
  /// starts in. An explicitly chosen 高性能 is left alone. Runs ahead of the shader change on the
  /// command queue.
  func prepareForShaders() {
    guard external == nil, let engine, !closing, engineProfile == "fast",
      runtimeSettings.text(.mpvProfile) != "fast" else { return }
    engineProfile = "high-quality"
    engineSignature = Self.signature(path: enginePath, profile: engineProfile)
    let reference = EngineReference(engine)
    let fallback = Self.fastProfileOptions
    queue.async {
      let handle = reference.pointer
      var list = [CChar](repeating: 0, count: 131_072)
      var keys = fallback
      if bili_mpv_string(handle, "profile-list", &list, list.count) >= 0,
        let profiles = (try? JSONSerialization.jsonObject(with: Data(String(cString: list).utf8))) as? [[String: Any]],
        let fast = profiles.first(where: { $0["name"] as? String == "fast" }),
        let options = fast["options"] as? [[String: Any]] {
        keys = options.compactMap { $0["key"] as? String }
      }
      for key in keys {
        var value = [CChar](repeating: 0, count: 1024)
        guard bili_mpv_string(handle, "option-info/\(key)/default-value", &value, value.count) >= 0 else { continue }
        _ = bili_mpv_set(handle, key, String(cString: value))
      }
      let words: [String] = ["apply-profile", "high-quality"]
      let copies = words.map { strdup($0) }
      defer { for copy in copies { free(copy) } }
      var pointers: [UnsafePointer<CChar>?] = copies.map { UnsafePointer<CChar>($0) } + [nil]
      _ = pointers.withUnsafeMutableBufferPointer { bili_mpv_command(handle, $0.baseAddress) }
    }
  }
  /// User-initiated speed change: applied to mpv at once, and later poll samples that still
  /// carry the old value are ignored for a moment so the choice does not snap back.
  func setSpeed(_ value: Double) {
    guard value.isFinite, value > 0 else { return }
    speed = value; userSpeed = (value, Date().addingTimeInterval(0.8))
    set("speed", String(value))
  }
  func setVolume(_ value: Double) {
    guard value.isFinite, value >= 0 else { return }
    volume = value; userVolume = (value, Date().addingTimeInterval(0.8)); Self.sessionVolume = value
    set("volume", String(value))
  }
  private func isStale(_ sample: Double, against user: (value: Double, until: Date)?) -> Bool {
    guard let user, Date() < user.until else { return false }
    return abs(sample - user.value) > 0.001
  }
  func beginTemporarySpeed() {
    guard temporaryOriginalSpeed == nil else { return }
    temporaryOriginalSpeed = speed
    speed = runtimeSettings.number(.temporarySpeed)
    set("speed", String(speed))
  }
  func endTemporarySpeed() {
    guard let original = temporaryOriginalSpeed else { return }
    temporaryOriginalSpeed = nil; speed = original
    set("speed", String(original))
  }
  func loadSubtitle(url: URL, title: String? = nil) {
    guard url.isFileURL else { error = "字幕必须先下载到本地文件"; return }
    command(["sub-add", url.path, "select", title ?? url.lastPathComponent])
  }
  func clearSubtitle() { set("sid", "no") }
  func seek(_ seconds: Double) {
    resetPlaybackEnd()
    onRecoverySeek?()
    seekRequests.send(seconds)
    // A deliberate jump: danmaku follow it (backwards too) instead of waiting.
    danmakuClock.seek(to: seconds, now: CACurrentMediaTime())
    // The frame changes: once the new one is decoded, analyse it if still paused.
    if paused, liveTextEnabled { liveText.analyse(self, afterSeekFrom: time) } else { liveText.clear() }
    if let args = MpvRuntimePlan.seek(seconds, precise: runtimeSettings.text(.preciseSeek) != "no") {
      command(args)
    }
  }
  func togglePause() {
    if browsingSuspended { requestPlay() }
    else { set("pause", paused ? "no" : "yes") }
  }
  func shutdown() {
    guard !closing else { return }
    closing = true
    sleepGuard.release()
    liveText.clear()
    // No callback points into UI. Stop both timers before freeing the render context.
    poll?.cancel()
    poll = nil
    external?.shutdown(); external = nil
    temporaryOriginalSpeed = nil
    surface?.stopRendering()
    if let engine {
      // Drain queued commands for this player before handing the engine on.
      let reference = EngineReference(engine)
      let inflight = queue.sync {
        bili_mpv_release_load(reference.pointer)
        return bili_mpv_load_inflight(reference.pointer) != 0
      }
      // A pending hook must not be parked without its event consumer. Destroying
      // that client releases its hooks; completed engines retain normal pooling.
      MpvEnginePool.shared.checkin(engine, signature: engineSignature, reusable: error == nil && !inflight)
    }
    engine = nil
  }
}
