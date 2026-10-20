import AppKit
import Combine
import ManpingCore
import CMpv
import OpenGL.GL3
import QuartzCore
import SwiftUI


final class VideoSurface: NSView {
  let model: PlayerModel
  private var videoLayer: VideoLayer?
  private var metalView: DanmakuView!
  private var observers: [NSObjectProtocol] = []
  private var displayTimer: Timer?
  private var lastDisplay = ""
  private var lastLayerSignature = ""
  private var appliedPeak = 0.0
  private var appliedPeakAt = Date.distantPast
  private var appliedForHDR = false
  var renderReady = false
  var displayEvidence = ""
  var renderEvidence: String { videoLayer?.statistics() ?? "" }
  /// Retain the counter, not the surface, while navigation dismantles its NSView.
  func diagnosticFrameCounter() -> () -> Int {
    let layer = videoLayer
    return {
      let first = layer?.statistics().split(separator: " ").first ?? ""
      return first.hasPrefix("frames=") ? Int(first.dropFirst(7)) ?? 0 : 0
    }
  }
  /// Width / height of the picture on a playback stage (DesignSystem.md §11). The surface then
  /// fills the stage: the video layer is fitted to this shape and centred, the danmaku layer
  /// covers the whole stage, and the area around the picture stays clear so the stage backdrop
  /// shows. Nil (the mini window) keeps the video layer at the full bounds on black.
  var pictureAspect: CGFloat? {
    didSet {
      guard pictureAspect != oldValue else { return }
      layer?.backgroundColor = pictureAspect == nil ? NSColor.black.cgColor : NSColor.clear.cgColor
      needsLayout = true
    }
  }
  /// The shape mpv reports for the video being shown (`video-params/dw` ÷ `dh`). On a stage it
  /// wins over `pictureAspect`, which comes from the manifest (or 16:9 for a live room) and may
  /// not match: mpv would then letterbox inside the video layer, in black instead of the backdrop.
  var sourceAspect: CGFloat? {
    didSet {
      guard sourceAspect != oldValue, pictureAspect != nil else { return }
      needsLayout = true
    }
  }
  /// The video layer's frame: the largest rectangle of `pictureAspect` that fits, centred on
  /// whole points (the full bounds without an aspect).
  static func pictureFrame(in bounds: CGRect, aspect: CGFloat?) -> CGRect {
    guard let aspect, aspect.isFinite, aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    var size = CGSize(width: bounds.width, height: bounds.width / aspect)
    if size.height > bounds.height { size = CGSize(width: bounds.height * aspect, height: bounds.height) }
    let x = (bounds.minX + (bounds.width - size.width) / 2).rounded()
    let y = (bounds.minY + (bounds.height - size.height) / 2).rounded()
    return CGRect(x: x, y: y, width: size.width.rounded(), height: size.height.rounded())
  }
  init(model: PlayerModel) {
    self.model = model
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    model.surface?.stopRendering()
    model.surface = self
    model.start()
    if let engine = model.engine {
      do {
        let video: VideoLayer
        if let pooled = MpvEnginePool.shared.layer(for: engine), pooled.isLive {
          pooled.removeFromSuperlayer()
          video = pooled
        } else {
          video = try VideoLayer(engine: engine)
          MpvEnginePool.shared.adopt(video, for: engine)
        }
        videoLayer = video
        layer?.addSublayer(video)
        video.invalidateFrame()
        renderReady = true
      } catch { model.error = String(describing: error) }
    }
    metalView = DanmakuView(model: model)
    addSubview(metalView)
    for name in [
      NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
      NSApplication.didChangeScreenParametersNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.updateDisplay() }
        })
    }
    // Headroom changes with brightness even without a screen-change notification.
    displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateDisplay() }
    }
    model.renderStarted()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let picture = Self.pictureFrame(in: bounds, aspect: pictureAspect.map { sourceAspect ?? $0 })
    if videoLayer?.frame != picture {
      videoLayer?.frame = picture
      videoLayer?.invalidateFrame()
      // Draw the new size in this commit, with the layout around it: waiting for the next
      // render-queue pump left the previous size on screen for a few frames while the window
      // resized (full-screen transitions).
      videoLayer?.setNeedsDisplay()
    }
    CATransaction.commit()
    // The danmaku cover the whole surface (the whole stage), not only the picture.
    metalView.frame = bounds
    updateDisplay()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateDisplay()
  }
  private func updateDisplay() {
    guard let videoLayer else { return }
    let screen = window?.screen ?? NSScreen.main
    let potential = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
    let rawCurrent = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
    let arguments = ProcessInfo.processInfo.arguments
    let cap =
      arguments.firstIndex(of: "--headroom-cap").flatMap {
        arguments.count > $0 + 1 ? Double(arguments[$0 + 1]) : nil
      } ?? Double.greatestFiniteMagnitude
    let current = min(max(1, (rawCurrent * 10).rounded(.down) / 10), max(1, cap))
    // EDR only for HDR sources (PQ, HLG; Dolby Vision decodes to PQ). SDR sources render to
    // BT.709/sRGB exactly as on an SDR screen, shown from an 8-bit layer backing: no EDR
    // composition, no EDR headroom held for the display. A change of source type reconfigures
    // the layer once.
    // `--sdr` (the fixed sRGB golden path) is unchanged, and other `--diagnose` runs keep EDR for
    // every source as before unless `--edr-hdr-only` asks for the production choice.
    let forcedSDR = arguments.contains("--sdr")
    let hdrSource = model.hdrSource
    let everySourceEDR = PlayerModel.diagnosticMode && !arguments.contains("--edr-hdr-only")
    let edr = videoLayer.floating && potential > 1 && !forcedSDR && (hdrSource || everySourceEDR)
    let deep = videoLayer.floating && (edr || hdrSource || forcedSDR || everySourceEDR)
    let scale = window?.backingScaleFactor ?? 1
    let signature =
      "edr=\(edr) deep=\(deep) current=\((rawCurrent * 10).rounded() / 10) mappedHeadroom=\(current) potential=\(potential) scale=\(scale)"
    videoLayer.setVisible(
      window != nil && !isHiddenOrHasHiddenAncestor && !(window?.isMiniaturized ?? false))
    if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      videoLayer.setDisplay(CGDirectDisplayID(number.uint32Value))
    }
    guard signature != lastDisplay else { return }
    lastDisplay = signature
    displayEvidence = signature
    let peak = edr ? max(1, current) * 203 : 203
    // The layer and target space only change with EDR, surface depth or scale. Auto-brightness
    // moves the headroom every second or so; re-applying everything then rebuilt mpv's shaders
    // each time and dropped bursts of frames at 120 fps.
    let layerSignature = "edr=\(edr) deep=\(deep) scale=\(scale)"
    let layerChanged = layerSignature != lastLayerSignature
    if layerChanged {
      lastLayerSignature = layerSignature
      model.displayUpdates += 1
      videoLayer.configureDisplay(edr: edr, deep: deep, scale: scale)
      // Linear BT.2020 values are relative to SDR white; CA applies display color matching.
      model.set("target-prim", edr ? "bt.2020" : "bt.709")
      model.set("target-trc", edr ? "linear" : "srgb")
      model.set("tone-mapping", "bt.2390")
    }
    // Only HDR sources use the headroom; follow it with hysteresis and at most every 5 s.
    let drift = appliedPeak > 0 ? abs(peak - appliedPeak) / appliedPeak : 1
    let due = Date().timeIntervalSince(appliedPeakAt) >= 5 && drift >= 0.15
    if layerChanged || hdrSource != appliedForHDR || (hdrSource && due) {
      appliedPeak = peak; appliedPeakAt = Date(); appliedForHDR = hdrSource
      if !layerChanged { model.displayUpdates += 1 }
      model.set("target-peak", String(Int(peak)))
    }
  }
  private var renderingActive = false
  var presentationExpected: Bool {
    PlaybackPresentation.expected(hasWindow: window != nil, hidden: isHiddenOrHasHiddenAncestor,
      miniaturized: window?.isMiniaturized ?? false,
      occlusionVisible: window?.occlusionState.contains(.visible) ?? false,
      renderingActive: renderingActive && renderReady && videoLayer != nil)
  }
  /// Only the fixture's own surface is hidden; no window activation or renderer pacing changes.
  func setDiagnosticPresentationHidden(_ hidden: Bool) {
    guard PerformanceOptions.requested, PerformanceOptions.playsLocalMedia else { return }
    isHidden = hidden
    updateDisplay()
  }
  func setPlaybackActive(_ active: Bool) {
    renderingActive = active
    videoLayer?.setPlaybackActive(active)
  }
  /// The source's transfer became known or changed (SDR ↔ HDR): pick the output right away.
  func sourceTransferChanged() { updateDisplay() }
  func refreshDanmakuPreferences() { metalView?.refreshPreferences() }
  func danmakuTimelineChanged() { metalView?.timelineChanged() }
  func captureVideoFrame(width: Int, height: Int) async -> CGImage? {
    guard let videoLayer else { return nil }
    return await withCheckedContinuation { continuation in
      videoLayer.captureFrame(width: width, height: height) { continuation.resume(returning: $0) }
    }
  }
  func stopRendering() {
    renderingActive = false
    displayTimer?.invalidate()
    displayTimer = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    // The pool owns the render layer; park it hidden so the next surface can re-host it.
    videoLayer?.setVisible(false)
    videoLayer?.setPlaybackActive(false)
    videoLayer?.removeFromSuperlayer()
    videoLayer = nil
    metalView.stop()
    renderReady = false
    if model.surface === self { model.surface = nil }
  }
  /// Leaving a window only hides the picture; `viewDidMoveToWindow` shows it again. Real
  /// teardown happens in `PlayerSurface.dismantleNSView` or when a new surface takes over —
  /// stopping here left the player permanently black after a temporary removal.
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { videoLayer?.setVisible(false) }
    super.viewWillMove(toWindow: newWindow)
  }
}
