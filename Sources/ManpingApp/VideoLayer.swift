import AppKit
import Combine
import ManpingCore
import CMpv
import OpenGL.GL3
import QuartzCore
import SwiftUI


// CA may enter drawing callbacks with the CGL context already locked. Always acquire
// CGL before gate when both are needed; mpv's update callback only sets a C atomic.
private final class WeakVideoLayer: @unchecked Sendable {
  weak var layer: VideoLayer?
  init(_ layer: VideoLayer) { self.layer = layer }
}
final class VideoLayer: CAOpenGLLayer, @unchecked Sendable {
  private let gate = NSRecursiveLock()
  private var engine: OpaquePointer?
  private let context: CGLContextObj
  private let pixel: CGLPixelFormatObj
  let floating: Bool
  private let renderQueue = DispatchQueue(
    label: "io.github.pidean.manping.video.render", qos: .userInteractive)
  private var displaySource: DispatchSourceTimer?
  /// During playback frames are pumped on the display's vsync (a CVDisplayLink thread), so a
  /// 120 fps stream on a 120 Hz panel is not phase-drifting against a fixed 8 ms poll.
  private var link: CVDisplayLink?
  private var linkDisplay: CGDirectDisplayID = CGMainDisplayID()
  /// Guards only `pumpQueued`. The display link callback must never take `gate`: stopping the
  /// link while holding `gate` waits for an in-flight callback.
  private let pumpLock = NSLock()
  private var pumpQueued = false
  private var force = true
  private var visible = true
  private var playbackActive = false
  private var smoothMotion = false
  private var vsyncDraw = false
  private var swapPending = false
  private static let blockVsync: UInt64 = 1 << 3
  private struct CaptureRequest: Sendable {
    let width: Int
    let height: Int
    let completion: @Sendable (CGImage?) -> Void
  }
  private var pendingCaptures: [CaptureRequest] = []
  init(engine: OpaquePointer) throws {
    var chosen: CGLPixelFormatObj?
    var count: GLint = 0
    let base: [CGLPixelFormatAttribute] = [
      kCGLPFAOpenGLProfile,
      CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue), kCGLPFAAccelerated,
      kCGLPFADoubleBuffer,
    ]
    let hdr =
      base + [
        kCGLPFAColorSize, CGLPixelFormatAttribute(64), kCGLPFAColorFloat,
        CGLPixelFormatAttribute(0),
      ]
    let result = CGLChoosePixelFormat(hdr, &chosen, &count)
    floating = result == kCGLNoError && chosen != nil
    if !floating {
      CGLChoosePixelFormat(
        base + [kCGLPFAColorSize, CGLPixelFormatAttribute(24), CGLPixelFormatAttribute(0)], &chosen,
        &count)
    }
    guard let chosen else { throw NSError(domain: "CGL pixel format", code: Int(result.rawValue)) }
    pixel = chosen
    var ctx: CGLContextObj?
    let status = CGLCreateContext(chosen, nil, &ctx)
    guard let ctx else {
      CGLReleasePixelFormat(chosen)
      throw NSError(domain: "CGL context", code: Int(status.rawValue))
    }
    context = ctx
    self.engine = engine
    super.init()
    contentsFormat = floating ? .RGBA16Float : .RGBA8Uint
    isOpaque = true
    CGLSetCurrentContext(context)
    let render = bili_mpv_render_create(engine)
    CGLSetCurrentContext(nil)
    guard render >= 0 else {
      self.engine = nil
      throw NSError(domain: "mpv render", code: Int(render))
    }
    isAsynchronous = false
    let timer = DispatchSource.makeTimerSource(queue: renderQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(10))
    // A Sendable weak box: the optimizer rejects `[weak self]` of this layer in a @Sendable closure.
    let target = WeakVideoLayer(self)
    timer.setEventHandler { @Sendable in target.layer?.pump() }
    displaySource = timer
    timer.resume()
  }
  /// Presents a frame if mpv has one (or a redraw was forced). Always runs on `renderQueue`.
  fileprivate func pump(isVsync: Bool = false) {
    pumpLock.withLock { pumpQueued = false }
    CGLLockContext(context)
    gate.lock()
    guard let engine, visible else {
      gate.unlock()
      CGLUnlockContext(context)
      return
    }
    CGLSetCurrentContext(context)
    let pending = bili_mpv_render_pending(engine) != 0
    let blocks = bili_mpv_render_frame_flags(engine) & Self.blockVsync != 0
    let paced = playbackActive && (smoothMotion || blocks)
    if swapPending, isVsync || !playbackActive {
      bili_mpv_report_swap(engine)
      swapPending = false
    }
    // Display-sync repeats/interpolates even without a fresh source frame. A timer or a CA
    // layout redraw must not consume BLOCK_VSYNC frames between display-link ticks.
    let display = paced ? isVsync : (pending || force)
    vsyncDraw = display && isVsync
    if display { force = true }
    gate.unlock()
    CGLUnlockContext(context)
    // Never hold either render lock while acquiring Core Animation's transaction lock.
    if display {
      setNeedsDisplay()
      self.display()
      CATransaction.flush()
    }
    gate.lock(); vsyncDraw = false; gate.unlock()
  }
  /// Called on the display link thread once per refresh; coalesces into one queued pump.
  private func vsync() {
    let queue = pumpLock.withLock { () -> Bool in
      guard !pumpQueued else { return false }
      pumpQueued = true
      return true
    }
    if queue { renderQueue.async { [weak self] in self?.pump(isVsync: true) } }
  }
  /// Call with `gate` held; querying the period must not briefly start an idle display link.
  private func ensureLink() {
    guard link == nil else { return }
    var created: CVDisplayLink?
    guard CVDisplayLinkCreateWithCGDisplay(linkDisplay, &created) == kCVReturnSuccess, let created else { return }
    CVDisplayLinkSetOutputHandler(created) { [weak self] _, _, _, _, _ in
      self?.vsync()
      return kCVReturnSuccess
    }
    link = created
  }
  /// Call with `gate` held.
  private func updateLink(running: Bool) {
    if running {
      ensureLink()
      if let link, !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
    } else if let link, CVDisplayLinkIsRunning(link) {
      CVDisplayLinkStop(link)
    }
  }
  /// Follows the window to another screen so vsync matches the panel showing the video.
  func setDisplay(_ id: CGDirectDisplayID, fallbackFPS: Int) -> Double {
    gate.lock()
    defer { gate.unlock() }
    if id != linkDisplay {
      linkDisplay = id
      if let link { CVDisplayLinkSetCurrentCGDisplay(link, id) }
    }
    // Create the link even while paused so the first refresh override is not a guessed 60.
    ensureLink()
    let period = link.map(CVDisplayLinkGetNominalOutputVideoRefreshPeriod)
    return DisplayRefreshRate.hertz(periodValue: period?.timeValue ?? 0,
      timeScale: period?.timeScale ?? 0, fallback: fallbackFPS)
  }
  func setSmoothMotion(_ value: Bool) {
    gate.lock()
    smoothMotion = value
    force = true
    gate.unlock()
  }
  override init(layer: Any) {
    let source = layer as! VideoLayer
    pixel = CGLRetainPixelFormat(source.pixel)
    context = CGLRetainContext(source.context)
    floating = source.floating
    // Presentation copies must not own or access the live mpv engine.
    super.init(layer: layer)
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit {
    if let link { CVDisplayLinkStop(link) }
    CGLReleaseContext(context)
    CGLReleasePixelFormat(pixel)
  }
  override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
    CGLRetainPixelFormat(pixel)
  }
  override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
    CGLRetainContext(context)
  }
  /// mpv's target is linear BT.2020 (EDR) rather than sRGB; captures convert accordingly.
  private var edrOutput = false
  /// The layer's backing store: half floats for EDR, HDR sources and diagnostics; 8-bit RGBA for
  /// SDR output. mpv still renders into the context's own framebuffer either way.
  func configureDisplay(edr: Bool, deep: Bool, scale: CGFloat) {
    let deep = floating && deep
    gate.lock(); edrOutput = edr; gate.unlock()
    invalidateFrame()
    contentsFormat = deep ? .RGBA16Float : .RGBA8Uint
    colorspace = CGColorSpace(name: edr ? CGColorSpace.extendedLinearITUR_2020 : CGColorSpace.sRGB)
    wantsExtendedDynamicRangeContent = edr
    contentsScale = scale
  }
  private func updatePacing() {
    let active = visible && playbackActive && engine != nil
    updateLink(running: active)
  }
  func setVisible(_ value: Bool) {
    gate.lock()
    let stopping = visible && !value
    visible = value
    if !value { cancelCaptures() }
    updatePacing()
    gate.unlock()
    if stopping { renderQueue.async { [weak self] in self?.finishSwap() } }
  }
  func setPlaybackActive(_ value: Bool) {
    gate.lock()
    let stopping = playbackActive && !value
    playbackActive = value
    if !value { cancelCaptures() }
    updatePacing()
    gate.unlock()
    if stopping { renderQueue.async { [weak self] in self?.finishSwap() } }
  }
  /// Drain the last rendered frame when pacing stops; otherwise mpv waits 200 ms for a
  /// swap whose next vsync was just cancelled. Never wait for the render queue on the UI thread.
  private func finishSwap() {
    CGLLockContext(context)
    defer { CGLUnlockContext(context) }
    gate.lock()
    defer { gate.unlock() }
    guard let engine, swapPending else { return }
    CGLSetCurrentContext(context)
    bili_mpv_report_swap(engine)
    swapPending = false
  }
  /// A hidden/stopped layer has no next draw to fulfill a deferred screenshot.
  private func cancelCaptures() {
    let captures = pendingCaptures
    pendingCaptures = []
    for capture in captures { capture.completion(nil) }
  }
  func invalidateFrame() {
    gate.lock()
    force = true
    gate.unlock()
  }
  override func canDraw(
    inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
    forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?
  ) -> Bool {
    CGLLockContext(context)
    defer { CGLUnlockContext(context) }
    gate.lock()
    defer { gate.unlock() }
    guard let engine, visible else { return false }
    CGLSetCurrentContext(context)
    let pending = bili_mpv_render_pending(engine) != 0
    let blocks = bili_mpv_render_frame_flags(engine) & Self.blockVsync != 0
    if playbackActive && (smoothMotion || blocks) { return vsyncDraw }
    return pending || force
  }
  override func draw(
    inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
    forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?
  ) {
    CGLLockContext(context)
    defer { CGLUnlockContext(context) }
    gate.lock()
    defer { gate.unlock() }
    guard let engine, visible else { return }
    CGLSetCurrentContext(context)
    let blocks = bili_mpv_render_frame_flags(engine) & Self.blockVsync != 0
    let paced = playbackActive && (smoothMotion || blocks)
    guard !paced || vsyncDraw else { return }
    vsyncDraw = false
    force = false
    // The framebuffer Core Animation hands us follows the pixel format (half floats when
    // `floating`), whatever the layer's contentsFormat; tell mpv what it really draws into.
    let result = bili_mpv_render(engine, floating ? 1 : 0)
    let captures = pendingCaptures
    pendingCaptures = []
    for capture in captures {
      capture.completion(result > 0 ? captureImage(width: capture.width, height: capture.height, currentFrame: true) : nil)
    }
    super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    if result > 0 {
      if paced { swapPending = true } else { bili_mpv_report_swap(engine) }
    }
  }
  /// The current frame as mpv draws it (scaling, tone mapping, shaders), rendered offscreen at
  /// `width` x `height`. mpv's own screenshot cannot read VideoToolbox frames.
  func captureFrame(width: Int, height: Int, completion: @escaping @Sendable (CGImage?) -> Void) {
    // A Sendable weak box: the optimizer rejects capturing this layer in the queue closure.
    let target = WeakVideoLayer(self)
    renderQueue.async {
      guard let layer = target.layer else { completion(nil); return }
      let deferred = layer.gate.withLock {
        if layer.engine != nil, layer.visible, layer.playbackActive, layer.smoothMotion {
          layer.pendingCaptures.append(CaptureRequest(width: width, height: height, completion: completion))
          return true
        }
        return false
      }
      if !deferred { completion(layer.captureOnRenderQueue(width: width, height: height)) }
    }
  }
  /// Runs on `renderQueue` with the context and gate held.
  fileprivate func captureOnRenderQueue(width: Int, height: Int) -> CGImage? {
    CGLLockContext(context)
    defer { CGLUnlockContext(context) }
    gate.lock()
    defer { gate.unlock() }
    return captureImage(width: width, height: height, currentFrame: false)
  }
  /// Requires CGL → gate. In display-sync the draw callback owns the source FBO for the blit.
  private func captureImage(width: Int, height: Int, currentFrame: Bool) -> CGImage? {
    guard let engine, width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
    CGLSetCurrentContext(context)
    // EDR output is linear BT.2020 in half floats (target-prim/trc set for EDR): read it as
    // floats and colour-match to 8-bit sRGB; SDR output is already sRGB bytes.
    let image: CGImage?
    if floating && edrOutput {
      var pixels = [Float](repeating: 0, count: width * height * 4)
      guard bili_mpv_capture(engine, Int32(width), Int32(height), 1, currentFrame ? 1 : 0, &pixels) >= 0 else { return nil }
      image = Self.sRGBImage(fromLinear2020: pixels, width: width, height: height)
    } else {
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      guard bili_mpv_capture(engine, Int32(width), Int32(height), 0, currentFrame ? 1 : 0, &pixels) >= 0,
        let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
      image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    return image
  }
  private static func sRGBImage(fromLinear2020 pixels: [Float], width: Int, height: Int) -> CGImage? {
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let provider = CGDataProvider(data: data as CFData),
      let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
      let source = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
        bytesPerRow: width * 16, space: linear,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
          | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    // Highlights above SDR white clip, as in any SDR still.
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
  var isLive: Bool { gate.lock(); defer { gate.unlock() }; return engine != nil }
  func statistics() -> String {
    gate.lock()
    defer { gate.unlock() }
    guard let engine else { return "stopped" }
    var result = [CChar](repeating: 0, count: 512)
    bili_mpv_render_stats(engine, &result, result.count)
    return String(cString: result) + " pollMilliseconds=250"
  }
  func stop() {
    isAsynchronous = false
    CGLLockContext(context)
    defer { CGLUnlockContext(context) }
    gate.lock()
    defer { gate.unlock() }
    displaySource?.cancel()
    displaySource = nil
    cancelCaptures()
    if let link { CVDisplayLinkStop(link) }
    link = nil
    guard let engine else { return }
    CGLSetCurrentContext(context)
    bili_mpv_render_destroy(engine)
    CGLSetCurrentContext(nil)
    // Queued CA/timer callbacks acquire both locks and see nil before touching mpv.
    self.engine = nil
  }
}
