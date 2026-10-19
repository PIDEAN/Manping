import AppKit
import ManpingCore
import Combine
import CoreText
import ImageIO
import Metal
import QuartzCore
import os

private struct Glyph {
  let u: Float
  let v: Float
  /// Advance in device pixels at the raster's pixel font size.
  let advance: Float
}
/// Pixel geometry of one atlas generation. Glyphs are rasterized 1:1 at
/// `fontSize × backingScale`, so every field changes with the font size or the screen scale.
private struct GlyphRaster: Equatable {
  let pixelFontSize: Int
  let scale: CGFloat
  /// Transparent margin around the text box for the outline and the drop shadow.
  let pad: Int
  /// Square cell edge in pixels.
  let cell: Int
  /// Baseline distance from the cell top in pixels.
  let baseline: Int
  let atlasSize: Int
  var perRow: Int { atlasSize / cell }
  init(fontSize: Double, scale: CGFloat, atlasSize: Int) {
    let scale = max(1, scale)
    let pixels = max(8, Int((CGFloat(fontSize) * scale).rounded()))
    pixelFontSize = pixels
    self.scale = scale
    // Outline (half of 1pt outside), 1pt shadow offset and a 3pt blur.
    pad = Int((4.5 * scale).rounded(.up)) + 1
    // CJK ink sits within ~1.0em above and emoji/Latin descenders ~0.3em below the baseline.
    let box = Int((CGFloat(pixels) * 1.3).rounded(.up))
    cell = min(atlasSize / 4, box + 2 * pad)
    baseline = pad + pixels
    self.atlasSize = atlasSize
  }
}
private struct TextVertex {
  var position: SIMD2<Float>
  var uv: SIMD2<Float>
  var color: SIMD4<Float>
}
private struct GlyphCapture: @unchecked Sendable {
  let buffer: MTLBuffer
  let width: Int
  let height: Int
  let bytesPerRow: Int
  let path: String
  nonisolated func writePNG() {
    let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
  }
}
private struct GlyphPage: @unchecked Sendable {
  let texture: MTLTexture
  let glyphs: [Glyph]
}

/// Everything one frame needs from the main thread, published as an immutable value.
struct DanmakuScene: Sendable {
  var timeline: DanmakuTimeline
  var enabled: Bool
  var fontSize: Double
  var opacity: Double
  /// Danmaku crawl speed multiplier (the 速度 setting), not the playback speed.
  var speed: Double
  var area: Double
  var lineLimit: Int
  /// Points kept clear above the bottom edge (the player control panel).
  var bottomInset: Float
  /// View size in points and its backing scale.
  var size: CGSize
  var scale: CGFloat
  /// Highest refresh rate of the current screen.
  var maximumFPS: Int
  /// At most this many frames a second (弹幕帧率 or power saving), or nil for the screen's maximum.
  var frameCap: Int?
  var version: Int
}

/// Renders danmaku on its own thread, paced by a CAMetalDisplayLink.
///
/// Each frame asks the smooth media clock where playback will be at the frame's *presentation*
/// time and places every line there, so motion is uniform at whatever rate the display runs
/// (60 Hz, 120 Hz ProMotion, 144 Hz…) and independent of the video's own frame rate (24, 25,
/// 30, 50, 60…). The main thread only publishes scene values: SwiftUI work can no longer delay or
/// drop danmaku frames. While paused, hidden or disabled the link idles at 10 Hz, and so it does
/// during playback while no line is on screen or due within `wakeLead`. With nothing on screen
/// and an empty frame already presented, frames are neither cleared nor presented: the
/// transparent overlay stops changing, so the window server need not recomposite it every refresh.
/// Clock, lanes and placement are the same either way.
final class DanmakuEngine: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
  private struct Shared {
    var scene: DanmakuScene?
    var stopped = false
  }
  private let shared = OSAllocatedUnfairLock(initialState: Shared())
  private let statistics = OSAllocatedUnfairLock(initialState: [String: Int]())
  private let clock: DanmakuClock
  private let layer: CAMetalLayer
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let report: @Sendable (String) -> Void
  private let captureEnabled: Bool
  // Render-thread state.
  private var link: CAMetalDisplayLink?
  private var pages: [Int: GlyphPage] = [:]
  private var cache = GlyphCachePolicy()
  private var raster: GlyphRaster?
  private var drawnVersion = -1
  private var drawnClock: Double = -.infinity
  private var drawnEnabled = false
  /// The frame last presented had no line on it (true before the first present: nothing shows).
  private var drawnEmpty = true
  /// Host seconds of warning the link needs to be back at full rate before a line enters: one
  /// 10 Hz period for the rate change to land, plus margin.
  private let wakeLead = 0.35
  private var idleSkips = 0
  private var appliedRange: CAFrameRateRange?
  private var captured = false
  private var buffers: [MTLBuffer?] = [nil, nil, nil]
  private var capacities = [0, 0, 0]
  private var frameIndex = 0
  private let inFlight = DispatchSemaphore(value: 3)
  private var submits = 0, copiedGlyphs = 0, rasterized = 0
  private var peakHistoryPages = 0, peakFramePages = 0, peakResidentPages = 0
  private var lastGlyphCount = 0, lastVertexGlyphCount = 0
  private let retained = OSAllocatedUnfairLock(initialState: (pages: [ObjectIdentifier: Int](), outstanding: 0, peakOutstanding: 0, peakInFlightPages: 0))
  private let atlasSize = 1024
  /// Seconds of upcoming lines whose glyphs join the atlas plan before they enter.
  private let lookahead = 1.5
  /// Seconds of upcoming lines whose glyph bitmaps the background workshop renders ahead.
  private let prefetchWindow = 4.0
  private let workshop = GlyphWorkshop()
  private var prefetchedUntil = -Double.infinity
  private var prefetchVersion = -1

  init?(layer: CAMetalLayer, clock: DanmakuClock, capture: Bool, report: @escaping @Sendable (String) -> Void) {
    guard let device = layer.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      report("Metal device unavailable"); return nil
    }
    let shader = """
      #include <metal_stdlib>
      using namespace metal;
      struct Vertex {float2 position; float2 uv; float4 color;};
      struct Out {float4 position [[position]]; float2 uv; float4 color;};
      vertex Out glyphVertex(uint id [[vertex_id]],constant Vertex* vertices [[buffer(0)]]) {
          Out o; o.position=float4(vertices[id].position,0,1);o.uv=vertices[id].uv;o.color=vertices[id].color;return o;
      }
      fragment float4 glyphFragment(Out in [[stage_in]],texture2d<float> atlas [[texture(0)]]) {
          constexpr sampler s(filter::linear,address::clamp_to_edge);
          float4 pixel=atlas.sample(s,in.uv);return float4(pixel.rgb*in.color.rgb*in.color.a,pixel.a*in.color.a);
      }
      """
    do {
      let library = try device.makeLibrary(source: shader, options: nil)
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "glyphVertex")
      descriptor.fragmentFunction = library.makeFunction(name: "glyphFragment")
      let attachment = descriptor.colorAttachments[0]!
      attachment.pixelFormat = .bgra8Unorm
      attachment.isBlendingEnabled = true
      attachment.sourceRGBBlendFactor = .one
      attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      attachment.sourceAlphaBlendFactor = .one
      attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      report("Metal glyph pipeline: \(error.localizedDescription)"); return nil
    }
    layer.device = device
    self.layer = layer; self.device = device; self.commandQueue = queue; self.clock = clock
    self.report = report; self.captureEnabled = capture
    super.init()
  }

  /// Starts the render thread. The display link lives and fires on it.
  func start() {
    let thread = Thread { [self] in
      let link = CAMetalDisplayLink(metalLayer: layer)
      link.delegate = self
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 10, preferred: 10)
      link.add(to: .current, forMode: .default)
      self.link = link
      while !shared.withLock({ $0.stopped }) {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
      }
      link.invalidate()
      self.link = nil
    }
    thread.name = "io.github.pidean.manping.danmaku.render"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  func publish(_ scene: DanmakuScene) { shared.withLock { $0.scene = scene } }
  func stop() { shared.withLock { $0.stopped = true } }

  /// Peak frame cost since the previous call (per-second sampling in the debug report).
  func drainPeak() -> Int { statistics.withLock { stats in defer { stats["framePeakWindow"] = 0 }; return stats["framePeakWindow"] ?? 0 } }

  var evidence: [String: Int] {
    var values = statistics.withLock { $0 }
    let peaks = retained.withLock { ($0.peakOutstanding, $0.peakInFlightPages) }
    values["peakInFlight"] = peaks.0; values["peakInFlightPages"] = peaks.1
    values["bytesPerPage"] = atlasSize * atlasSize * 4
    return values
  }

  // MARK: Frame

  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    let (scene, stopped) = shared.withLock { ($0.scene, $0.stopped) }
    guard !stopped, let scene, scene.size.width > 0, scene.size.height > 0 else { return }
    let target = update.targetPresentationTimestamp
    let playing = clock.isRunning
    let media = clock.media(at: target) ?? drawnClock
    let enabled = scene.enabled && media.isFinite
    // Lines on screen now; otherwise whether one enters before the link could speed up again.
    let onScreen = enabled && scene.timeline.hasVisible(at: media, speed: scene.speed)
    var entering = false
    if enabled, playing, !onScreen, let ahead = clock.media(at: target + wakeLead), ahead > media {
      entering = scene.timeline.hasVisible(at: ahead, speed: scene.speed)
    }
    adaptRate(active: enabled && playing && (onScreen || entering), scene: scene)
    DanmakuMotionProbe.record(host: target, clock: media, speed: 1, playing: enabled && playing)
    // Nothing to show and the last presented frame is already empty: no clear, no present.
    // Glyphs for lines about to enter are still rendered ahead on the workshop.
    if !onScreen, drawnEmpty {
      if enabled { prefetch(scene: scene, media: media, raster: prepareRaster(scene)) }
      drawnVersion = scene.version; drawnClock = media; drawnEnabled = enabled
      if playing {
        idleSkips += 1
        let skips = idleSkips
        statistics.withLock { $0["idleSkips"] = skips }
      }
      return
    }
    // Nothing moved and nothing changed: keep the last frame on screen.
    // Lines waiting for workshop glyphs keep the frame live until they can be drawn.
    if scene.version == drawnVersion, enabled == drawnEnabled, !enabled || media == drawnClock, !pendingGlyphs { return }
    guard inFlight.wait(timeout: .now()) == .success else { return }
    let started = CACurrentMediaTime()
    if !render(scene: scene, media: media, enabled: enabled, drawable: update.drawable) { inFlight.signal(); return }
    let micros = Int((CACurrentMediaTime() - started) * 1_000_000)
    statistics.withLock { stats in
      stats["frameMicros"] = micros
      stats["frameMicrosPeak"] = max(stats["frameMicrosPeak"] ?? 0, micros)
      stats["framePeakWindow"] = max(stats["framePeakWindow"] ?? 0, micros)
      stats["frameMicrosTotal", default: 0] += micros; stats["frameCount", default: 0] += 1
    }
    drawnVersion = scene.version; drawnClock = media; drawnEnabled = enabled
  }

  /// Full display rate (or the cap) while lines move or are about to enter; 10 Hz otherwise.
  private func adaptRate(active: Bool, scene: DanmakuScene) {
    let top = Float(max(30, scene.maximumFPS))
    let range: CAFrameRateRange
    if !active { range = CAFrameRateRange(minimum: 10, maximum: 10, preferred: 10) }
    else if let cap = scene.frameCap {
      let ceiling = min(Float(max(30, cap)), top)
      range = CAFrameRateRange(minimum: 30, maximum: ceiling, preferred: ceiling)
    }
    else { range = CAFrameRateRange(minimum: 60, maximum: top, preferred: top) }
    guard appliedRange.map({ $0.minimum != range.minimum || $0.maximum != range.maximum || $0.preferred != range.preferred }) ?? true
    else { return }
    appliedRange = range
    link?.preferredFrameRateRange = range
    let hz = Int(range.preferred ?? range.maximum)
    statistics.withLock { stats in
      stats["linkHz"] = hz
      stats["linkRateChanges", default: 0] += 1
    }
  }

  /// Drops every atlas generation when the pixel font size or the scale changes. Frames already
  /// submitted keep their own textures alive until completion.
  private func prepareRaster(_ scene: DanmakuScene) -> GlyphRaster {
    let next = GlyphRaster(fontSize: scene.fontSize, scale: scene.scale, atlasSize: atlasSize)
    if let raster, raster == next { return raster }
    raster = next
    pages = [:]
    cache = GlyphCachePolicy(slotsPerPage: next.perRow * next.perRow, historyPages: cache.historyPages)
    return next
  }

  private func rasterize(_ character: Character, slot: Int, atlas: MTLTexture, raster: GlyphRaster) -> Glyph {
    let bitmap = workshop.bitmap(character, raster: raster) ?? {
      rasterized += 1
      return GlyphWorkshop.render(character, raster: raster)
    }()
    let x = (slot % raster.perRow) * raster.cell
    let y = (slot / raster.perRow) * raster.cell
    bitmap.pixels.withUnsafeBytes {
      atlas.replace(region: MTLRegionMake2D(x, y, raster.cell, raster.cell), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: raster.cell * 4)
    }
    return Glyph(u: Float(x) / Float(atlasSize), v: Float(y) / Float(atlasSize), advance: bitmap.advance)
  }

  /// Glyphs of one line laid out once, in line-local points; frames only translate them.
  private struct LineLayout {
    var width: Float
    /// (atlas page, x offset from the line start, u, v) per character.
    var glyphs: [(page: Int, dx: Float, u: Float, v: Float)]
  }
  private struct LineKey: Hashable {
    let time: Double
    let lane: Int
    let mode: Int
    let text: String
  }
  private var layouts: [LineKey: LineLayout] = [:]
  private var plannedPages: [Int: GlyphPage] = [:]
  private var plannedTextures: [ObjectIdentifier] = []
  private var planRaster: GlyphRaster?
  /// Characters present in the current atlas plan (usable without a workshop bitmap).
  private var atlasCharacters: Set<Character> = []
  /// Some visible lines are still waiting for glyphs.
  private var pendingGlyphs = false

  /// Forgets the atlas plan; the next frame rebuilds it (after a failed GPU submission).
  private func invalidatePlan() {
    if let raster { cache = GlyphCachePolicy(slotsPerPage: raster.perRow * raster.perRow, historyPages: cache.historyPages) }
    pages = [:]; plannedPages = [:]; plannedTextures = []; layouts = [:]
    planRaster = nil; atlasCharacters = []
  }

  /// Hands the workshop the glyphs of lines entering within the next few seconds, so their
  /// bitmaps are ready before any frame needs them. Re-runs every half second of media time.
  private func prefetch(scene: DanmakuScene, media: Double, raster: GlyphRaster) {
    guard scene.enabled, scene.version != prefetchVersion || media + prefetchWindow / 2 > prefetchedUntil || media < prefetchedUntil - prefetchWindow
    else { return }
    prefetchVersion = scene.version; prefetchedUntil = media + prefetchWindow
    let upcoming = scene.timeline.visible(at: media + prefetchWindow, speed: scene.speed).prefix(400)
    workshop.request(Set(upcoming.flatMap { Array($0.comment.text) }), raster: raster)
  }

  /// Plans the glyph atlas for the lines on screen and those about to enter. Runs only when a
  /// line appears that has no layout yet (a few times a second), not every frame.
  private func replan(_ lines: [PositionedComment], raster: GlyphRaster,
    blits: inout [(MTLTexture, MTLOrigin, MTLTexture, MTLOrigin)]) -> Bool {
    let characters = lines.flatMap { Array($0.comment.text) }
    let cell = raster.cell
    var nextCache = cache
    let plan = nextCache.prepare(characters)
    for (id, keys) in plan.created {
      let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: atlasSize, height: atlasSize, mipmapped: false)
      texture.storageMode = .shared
      texture.usage = .shaderRead
      // No clearing: every slot a frame samples is written whole (glyph plus its transparent
      // margin), and quads are inset so linear sampling never reaches past a slot.
      guard let atlas = device.makeTexture(descriptor: texture) else { report("Metal glyph atlas allocation failed"); return false }
      let glyphs = keys.enumerated().map { slot, character -> Glyph in
        guard let address = plan.copied[character], let source = pages[address.page] else {
          return rasterize(character, slot: slot, atlas: atlas, raster: raster)
        }
        copiedGlyphs += 1
        let x = (slot % raster.perRow) * cell
        let y = (slot / raster.perRow) * cell
        // Carried-over glyphs are copied on the GPU, ahead of this frame's draw.
        blits.append((source.texture, MTLOrigin(x: (address.slot % raster.perRow) * cell, y: (address.slot / raster.perRow) * cell, z: 0),
          atlas, MTLOrigin(x: x, y: y, z: 0)))
        return Glyph(u: Float(x) / Float(atlasSize), v: Float(y) / Float(atlasSize), advance: source.glyphs[address.slot].advance)
      }
      pages[id] = GlyphPage(texture: atlas, glyphs: glyphs)
    }
    cache = nextCache
    peakHistoryPages = max(peakHistoryPages, cache.cachedPageCount)
    // Snapshot all generations before producing any UVs. Commands retain their immutable textures.
    plannedPages = pages.filter { plan.pages.contains($0.key) }
    peakFramePages = max(peakFramePages, plannedPages.count)
    plannedTextures = plannedPages.values.map { ObjectIdentifier($0.texture) }
    peakResidentPages = max(peakResidentPages,
      retained.withLock { Set(pages.values.map { ObjectIdentifier($0.texture) }).union($0.pages.keys).count })
    pages = pages.filter { cache.cachedPages.contains($0.key) }
    // Addresses may move between plans: lay every line out again against this one.
    layouts.removeAll(keepingCapacity: true)
    let scale = Float(raster.scale)
    for line in lines {
      let key = LineKey(time: line.comment.time, lane: line.lane, mode: line.comment.mode, text: line.comment.text)
      guard layouts[key] == nil else { continue }
      var dx: Float = 0
      var glyphs: [(page: Int, dx: Float, u: Float, v: Float)] = []
      glyphs.reserveCapacity(line.comment.text.count)
      for character in line.comment.text {
        guard let address = plan.addresses[character], let page = plannedPages[address.page] else { continue }
        let glyph = page.glyphs[address.slot]
        glyphs.append((address.page, dx, glyph.u, glyph.v))
        // Whole-pixel advances keep glyphs of one line evenly spaced.
        dx += glyph.advance.rounded() / scale
      }
      layouts[key] = LineLayout(width: dx, glyphs: glyphs)
    }
    planRaster = raster
    atlasCharacters = Set(plan.addresses.keys)
    lastGlyphCount = characters.count
    return true
  }

  /// Encodes and presents one frame; false when nothing was submitted.
  private func render(scene: DanmakuScene, media: Double, enabled: Bool, drawable: CAMetalDrawable) -> Bool {
    guard let command = commandQueue.makeCommandBuffer() else { return false }
    let visible = enabled
      ? Array(scene.timeline.visible(at: media, speed: scene.speed).prefix(scene.lineLimit)) : []
    let raster = prepareRaster(scene)
    func key(_ line: PositionedComment) -> LineKey {
      LineKey(time: line.comment.time, lane: line.lane, mode: line.comment.mode, text: line.comment.text)
    }
    var blits: [(MTLTexture, MTLOrigin, MTLTexture, MTLOrigin)] = []
    // Re-plan when a line without a layout can now be laid out (its glyphs are ready), or
    // the raster changed. Lines still waiting for glyphs do not re-plan every frame.
    // A glyph is usable when it is already in the atlas or the workshop has its bitmap; an
    // evicted bitmap does not make a glyph that is still in the atlas unavailable.
    let atlasValid = planRaster == raster
    func usable(_ character: Character) -> Bool {
      (atlasValid && atlasCharacters.contains(character)) || workshop.bitmap(character, raster: raster) != nil
    }
    let waiting = visible.filter { layouts[key($0)] == nil }
    if !waiting.isEmpty { workshop.request(Set(waiting.flatMap { Array($0.comment.text) }), raster: raster) }
    if planRaster != raster || waiting.contains(where: { $0.comment.text.allSatisfy(usable) }) {
      // Upcoming lines join the plan early, so their rasterization lands on frames before
      // they enter instead of the frame they appear in.
      let upcoming = enabled
        ? scene.timeline.visible(at: media + lookahead, speed: scene.speed).prefix(scene.lineLimit)
          .filter { $0.comment.time > media } : []
      // Lines whose glyphs the workshop has not finished yet wait a few frames (a cold start
      // or a seek); rendering a screenful synchronously would stall this thread for ~80 ms.
      let candidates = visible + upcoming
      let ready = candidates.filter { $0.comment.text.allSatisfy(usable) }
      if ready.count < candidates.count {
        workshop.request(Set(candidates.flatMap { Array($0.comment.text) }), raster: raster)
      }
      guard replan(ready, raster: raster, blits: &blits) else { return false }
    }
    pendingGlyphs = visible.contains { layouts[key($0)] == nil }
    if !blits.isEmpty {
      // The plan above assumes these copies happen: without them, rebuild it next frame.
      guard let blit = command.makeBlitCommandEncoder() else { invalidatePlan(); return false }
      let size = MTLSize(width: raster.cell, height: raster.cell, depth: 1)
      for (source, from, target, to) in blits {
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: from, sourceSize: size,
          to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: to)
      }
      blit.endEncoding()
    }
    prefetch(scene: scene, media: media, raster: raster)
    let framePages = plannedPages
    let frameTextures = plannedTextures

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = drawable.texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
      // Copies encoded above are dropped with this command buffer.
      if !blits.isEmpty { invalidatePlan() }
      return false
    }
    retained.withLock { state in
      for texture in frameTextures { state.pages[texture, default: 0] += 1 }
      state.outstanding += 1
      state.peakOutstanding = max(state.peakOutstanding, state.outstanding)
      state.peakInFlightPages = max(state.peakInFlightPages, state.pages.count)
    }

    let scale = Float(raster.scale)
    // The drawable's own size, in points: while the window resizes (a full-screen transition)
    // the main thread may already have resized the layer for a scene published a moment later.
    // Placing lines in the drawable that is actually presented keeps glyphs 1:1 with pixels and
    // the lane area following the new height, never scaled.
    let width = Float(drawable.texture.width) / scale
    let height = Float(drawable.texture.height) / scale
    let fontSize = Float(scene.fontSize)
    let laneHeight = fontSize * 1.35
    // Device pixels to points: glyphs map 1:1 onto the drawable.
    let cellPoints = Float(raster.cell) / scale
    let padPoints = Float(raster.pad) / scale
    // CJK ink is centred about 0.37em above the baseline; centre it in the lane.
    let baselineInLane = laneHeight / 2 + fontSize * 0.37
    let baselineInCell = Float(raster.baseline) / scale
    // Scrolling and top comments stay inside the chosen area and above the control bar;
    // bottom comments stack up from the control bar. Tiny views fall back to the full height.
    let bottomEdge = height > scene.bottomInset + laneHeight * 2 ? height - scene.bottomInset : height
    let areaLimit = min(height * Float(scene.area), bottomEdge)
    let snap = { (value: Float) -> Float in (value * scale).rounded() / scale }
    let alpha = Float(min(1, max(0, scene.opacity)))
    let uvSize = Float(raster.cell) / Float(atlasSize)

    // Pass 1: place lines and count glyphs per atlas page.
    struct Placed { let layout: LineLayout; let x: Float; let y: Float; let color: SIMD4<Float>; let time: Double }
    var placed: [Placed] = []
    placed.reserveCapacity(visible.count)
    var perPage: [Int: Int] = [:]
    for item in visible {
      let laneTop: Float
      if item.comment.mode == 4 {
        laneTop = bottomEdge - Float(item.lane + 1) * laneHeight
        if laneTop < 0 { continue }
      } else {
        laneTop = Float(item.lane) * laneHeight
        if laneTop + laneHeight > areaLimit, item.lane > 0 { continue }
      }
      guard let layout = layouts[key(item)] else { continue }
      // Fixed lines sit on whole device pixels (1:1 texels); moving lines keep their sub-pixel
      // position, since rounding made the per-frame steps alternate.
      let x = item.comment.mode == 4 || item.comment.mode == 5
        ? snap((width - layout.width) / 2) : width - Float(item.progress) * (width + layout.width)
      // Entirely off screen (entering or leaving): nothing to draw.
      if x > width || x + layout.width < 0 { continue }
      let rgb = item.comment.color
      // Premultiplied in the shader: opacity scales fill, outline and shadow together.
      let color = SIMD4<Float>(Float((rgb >> 16) & 255) / 255, Float((rgb >> 8) & 255) / 255, Float(rgb & 255) / 255, alpha)
      placed.append(Placed(layout: layout, x: x, y: snap(laneTop + baselineInLane - baselineInCell), color: color,
        time: item.comment.time))
      for glyph in layout.glyphs { perPage[glyph.page, default: 0] += 1 }
    }
    // Pass 2: write the quads straight into this frame's buffer, grouped by page.
    var missingBuffer = false
    let order = perPage.keys.sorted()
    var cursor: [Int: Int] = [:]
    var total = 0
    for page in order { cursor[page] = total; total += perPage[page]! * 6 }
    lastVertexGlyphCount = total / 6
    if total > 0 {
      let length = total * MemoryLayout<TextVertex>.stride
      let slot = frameIndex % 3
      frameIndex += 1
      if buffers[slot] == nil || length > capacities[slot] {
        let capacity = max(length * 2, 256 * 1024)
        buffers[slot] = device.makeBuffer(length: capacity, options: .storageModeShared)
        capacities[slot] = buffers[slot] == nil ? 0 : capacity
      }
      if buffers[slot] == nil { missingBuffer = true }
      if let frameBuffer = buffers[slot] {
      let vertices = frameBuffer.contents().bindMemory(to: TextVertex.self, capacity: total)
      let sx = 2 / width, sy = 2 / height
      let inset = 1 / scale, texel = 1 / Float(atlasSize)
      for line in placed {
        // Quads and UVs are inset by one pixel / texel on every side: linear sampling at a
        // sub-pixel edge would otherwise reach into the neighbouring (maybe uninitialised)
        // cell. The cell margin is transparent, so nothing visible is lost.
        let top = 1 - (line.y + inset) * sy, bottom = 1 - (line.y + cellPoints - inset) * sy
        for glyph in line.layout.glyphs {
          let left = (line.x + glyph.dx - padPoints + inset) * sx - 1
          let right = left + (cellPoints - 2 * inset) * sx
          let u = glyph.u + texel, v = glyph.v + texel
          let index = cursor[glyph.page]!
          cursor[glyph.page] = index + 6
          let color = line.color, u2 = glyph.u + uvSize - texel, v2 = glyph.v + uvSize - texel
          // Two triangles, written in place: no per-glyph allocation at display rate.
          vertices[index] = TextVertex(position: SIMD2(left, top), uv: SIMD2(u, v), color: color)
          vertices[index + 1] = TextVertex(position: SIMD2(right, top), uv: SIMD2(u2, v), color: color)
          vertices[index + 2] = TextVertex(position: SIMD2(left, bottom), uv: SIMD2(u, v2), color: color)
          vertices[index + 3] = TextVertex(position: SIMD2(right, top), uv: SIMD2(u2, v), color: color)
          vertices[index + 4] = TextVertex(position: SIMD2(right, bottom), uv: SIMD2(u2, v2), color: color)
          vertices[index + 5] = TextVertex(position: SIMD2(left, bottom), uv: SIMD2(u, v2), color: color)
        }
      }
      encoder.setRenderPipelineState(pipeline)
      encoder.setVertexBuffer(frameBuffer, offset: 0, index: 0)
      var offset = 0
      for page in order {
        let count = perPage[page]! * 6
        guard let texture = framePages[page]?.texture else { offset += count; continue }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: offset, vertexCount: count)
        offset += count
      }
      }
    }
    encoder.endEncoding()
    var capture: GlyphCapture?
    if captureEnabled, !captured, media >= 4, let path = ProcessInfo.processInfo.environment["MANPING_GLYPH_CAPTURE_PATH"] {
      let texture = drawable.texture
      let bytesPerRow = (texture.width * 4 + 255) / 256 * 256
      if let buffer = device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared),
        let blit = command.makeBlitCommandEncoder() {
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
          to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
          destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        capture = GlyphCapture(buffer: buffer, width: texture.width, height: texture.height, bytesPerRow: bytesPerRow, path: path)
        captured = true
      }
    }
    let completion = inFlight
    let retained = self.retained
    command.addCompletedHandler { [framePages, frameTextures, capture] _ in
      withExtendedLifetime(framePages) {}
      capture?.writePNG()
      retained.withLock { state in
        state.outstanding -= 1
        for texture in frameTextures {
          let remaining = (state.pages[texture] ?? 1) - 1
          state.pages[texture] = remaining == 0 ? nil : remaining
        }
      }
      completion.signal()
    }
    // Without vertices this frame would be blank: keep the previous one and try again next frame.
    if missingBuffer { pendingGlyphs = true } else {
      command.present(drawable); drawnEmpty = placed.isEmpty
      noteEntries(placed.map(\.time), media: media)
    }
    command.commit()
    submits += 1
    let snapshot: [String: Int] = [
      "submits": submits, "rasterized": rasterized, "copiedGlyphs": copiedGlyphs,
      "cachedPages": cache.cachedPageCount, "activePages": cache.activePageCount,
      "peakFramePages": peakFramePages, "peakResidentPages": peakResidentPages, "peakHistoryPages": peakHistoryPages,
      "frameGlyphs": lastGlyphCount, "vertexGlyphs": lastVertexGlyphCount, "historyPageLimit": cache.historyPages,
      "entries": entries, "lateEntries": lateEntries, "entryLateMaxMicros": entryLateMaxMicros,
    ]
    statistics.withLock { $0.merge(snapshot) { _, new in new } }
    return true
  }

  /// Evidence that idling never costs an entry: how long after its start time each line was
  /// first presented. More than two frames at the current rate counts as a late entry. Lines
  /// already running when the first lines are drawn (danmaku loaded after playback started) are
  /// not entries.
  private var newestEntry = -Double.infinity
  private var entries = 0, lateEntries = 0, entryLateMaxMicros = 0
  private func noteEntries(_ times: [Double], media: Double) {
    if media < newestEntry { newestEntry = media }  // a seek backwards
    guard clock.isRunning, newestEntry > -.infinity else { newestEntry = max(newestEntry, times.max() ?? newestEntry); return }
    let frame = 1 / Double(appliedRange?.preferred ?? appliedRange?.maximum ?? 60)
    for time in times where time > newestEntry {
      entries += 1
      let late = media - time
      entryLateMaxMicros = max(entryLateMaxMicros, Int(late * 1_000_000))
      if late > 2 * frame { lateEntries += 1 }
    }
    newestEntry = max(newestEntry, times.max() ?? newestEntry)
  }
}

/// How the danmaku layer fits a small host window: the font follows the window height
/// (`size × height ÷ referenceHeight`, never below `minimumFontSize`), and the area and the
/// number of lines on screen are capped. Placement, clock and render thread are unchanged.
struct DanmakuFit: Equatable, Sendable {
  var referenceHeight: Double
  var minimumFontSize: Double
  var area: Double
  var lineLimit: Int
  var bottomInset: Float
  /// The main player keeps room for its control panel.
  static let regularBottomInset: Float = 120
  /// 小窗: upper half, at most 30 lines, 13pt or larger (DesignSystem.md §12).
  static let miniPlayer = DanmakuFit(referenceHeight: 720, minimumFontSize: 13, area: 0.5, lineLimit: 30, bottomInset: 0)

  /// Whole points, so resizing the window re-rasterizes glyphs only when the size really changes.
  func fontSize(_ base: Double, height: CGFloat) -> Double {
    max(minimumFontSize, (base * Double(height) / referenceHeight).rounded())
  }
}

/// A window that hosts the danmaku layer at a different scale (the mini window).
@MainActor protocol DanmakuFitting: NSWindow {
  var danmakuFit: DanmakuFit { get }
}

/// The danmaku layer over the video. Main-thread side: publishes scene values to the engine.
final class DanmakuView: NSView {
  private let model: PlayerModel
  private let metalLayer = CAMetalLayer()
  private var engine: DanmakuEngine?
  private var observations: [AnyCancellable] = []
  private var version = 0
  private var stopped = false
  private static weak var diagnosticEngine: DanmakuEngine?
  static var diagnosticEvidence: [String: Int] { diagnosticEngine?.evidence ?? [:] }
  static func drainFramePeak() -> Int { diagnosticEngine?.drainPeak() ?? 0 }

  init(model: PlayerModel) {
    self.model = model
    super.init(frame: .zero)
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.isOpaque = false
    metalLayer.framebufferOnly = !ProcessInfo.processInfo.arguments.contains("--glyph-probe")
    metalLayer.presentsWithTransaction = false
    wantsLayer = true
    // Until the next frame is drawn at a new size, the last one stays at its own pixel size,
    // pinned to the top edge where the lanes start: danmaku never look stretched or squeezed
    // while the window resizes. (AppKit derives the backing layer's gravity from this; the
    // default stretched the last frame to the new bounds.)
    layerContentsPlacement = .topLeft
    let report: @Sendable (String) -> Void = { [weak model] message in
      DispatchQueue.main.async { MainActor.assumeIsolated { model?.error = message } }
    }
    engine = DanmakuEngine(layer: metalLayer, clock: model.danmakuClock,
      capture: !metalLayer.framebufferOnly, report: report)
    Self.diagnosticEngine = engine
    engine?.start()
    observations.append(model.$commentsEnabled.sink { [weak self] _ in
      // @Published emits before storing the value; read it on the next main turn.
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish() } }
    })
    // The effective level and the 省电 switches both change the line limit and frame cap.
    observations.append(PowerState.shared.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish() } }
    })
    publish()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func makeBackingLayer() -> CALayer { metalLayer }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() {
    super.layout()
    resize()
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    resize()
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    resize()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    resize()
  }
  private func resize() {
    let scale = window?.backingScaleFactor ?? 2
    metalLayer.contentsScale = scale
    let pixels = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    if metalLayer.drawableSize != pixels { metalLayer.drawableSize = pixels }
    publish()
  }
  /// Settings, comments toggle, power state or the timeline changed.
  func refreshPreferences() { publish() }
  func timelineChanged() { publish() }
  private func publish() {
    guard !stopped, let engine else { return }
    version &+= 1
    // A host window may scale the layer down (the mini window); the main player uses it as is.
    let fit = (window as? DanmakuFitting)?.danmakuFit
    engine.publish(DanmakuScene(
      timeline: model.timeline, enabled: model.commentsEnabled,
      fontSize: fit?.fontSize(model.danmakuFontSize, height: bounds.height) ?? model.danmakuFontSize,
      opacity: model.danmakuOpacity, speed: model.danmakuSpeed,
      area: fit.map { min(model.danmakuArea, $0.area) } ?? model.danmakuArea,
      lineLimit: min(PowerState.shared.danmakuLineLimit, fit?.lineLimit ?? .max),
      bottomInset: fit?.bottomInset ?? DanmakuFit.regularBottomInset, size: bounds.size,
      scale: window?.backingScaleFactor ?? 2, maximumFPS: window?.screen?.maximumFramesPerSecond ?? 60,
      frameCap: PowerState.shared.danmakuFrameCap(setting: model.danmakuFrameRate), version: version))
  }
  func stop() {
    stopped = true
    observations.removeAll()
    engine?.stop()
  }
}

/// Renders glyph bitmaps on a background queue ahead of need. The render thread takes a ready
/// bitmap and only uploads it; a glyph that is not ready yet is rendered on the spot.
final class GlyphWorkshop: @unchecked Sendable {
  struct Bitmap: Sendable {
    let pixels: [UInt8]
    let advance: Float
  }
  private struct State {
    var raster: GlyphRaster?
    var ready: [Character: Bitmap] = [:]
    var queued: Set<Character> = []
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let queue = DispatchQueue(label: "io.github.pidean.manping.danmaku.glyphs", qos: .utility)
  /// Bitmaps kept per raster; about 27 KB each at 24 pt on Retina.
  private let capacity = 3_000

  fileprivate func bitmap(_ character: Character, raster: GlyphRaster) -> Bitmap? {
    state.withLock { $0.raster == raster ? $0.ready[character] : nil }
  }

  fileprivate func request(_ characters: Set<Character>, raster: GlyphRaster) {
    let work: [Character] = state.withLock { s in
      if s.raster != raster { s = State(raster: raster) }
      if s.ready.count > capacity { s.ready.removeAll(keepingCapacity: true) }
      let missing = characters.filter { s.ready[$0] == nil && !s.queued.contains($0) }
      s.queued.formUnion(missing)
      return Array(missing)
    }
    guard !work.isEmpty else { return }
    queue.async { [self] in
      for character in work {
        guard state.withLock({ $0.raster == raster }) else { return }
        let bitmap = Self.render(character, raster: raster)
        state.withLock { s in
          guard s.raster == raster else { return }
          s.ready[character] = bitmap; s.queued.remove(character)
        }
      }
    }
  }

  private static func font(size: CGFloat) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    let traits = [kCTFontWeightTrait: NSFont.Weight.semibold.rawValue] as CFDictionary
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base),
      [kCTFontTraitsAttribute: traits] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
  }

  /// One glyph cell: CoreText and CoreGraphics only, safe on any thread.
  fileprivate static func render(_ character: Character, raster: GlyphRaster) -> Bitmap {
    let cell = raster.cell
    let size = CGFloat(raster.pixelFontSize)
    // CJK glyphs are built from overlapping contours. Stroking on top of the fill would draw
    // every interior contour edge as a black seam, so the outline goes down first (a 2pt
    // stroke-only pass, about 8% at 24pt) and the white fill covers its inner half: what
    // remains is a clean 1pt outline outside the ink.
    let font = font(size: size)
    let black = CGColor(gray: 0, alpha: 1), white = CGColor(gray: 1, alpha: 1)
    let outline = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTStrokeColorAttributeName as String): black,
      NSAttributedString.Key(kCTStrokeWidthAttributeName as String): NSNumber(value: Double(2 * raster.scale / size) * 100),
    ]))
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
    ]))
    let width = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
    var pixels = [UInt8](repeating: 0, count: cell * cell * 4)
    pixels.withUnsafeMutableBytes { bytes in
      if let context = CGContext(
        data: bytes.baseAddress, width: cell, height: cell, bitsPerComponent: 8,
        bytesPerRow: cell * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      {
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.translateBy(x: 0, y: CGFloat(cell))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // Shadow offsets are in base space (y up), unaffected by the flip above: a negative
        // height moves the shadow down on screen. One shadow for fill and outline together.
        context.setShadow(offset: CGSize(width: 0, height: -raster.scale), blur: 3 * raster.scale,
          color: CGColor(gray: 0, alpha: 0.6))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineJoin(.round)
        context.textPosition = CGPoint(x: raster.pad, y: raster.baseline)
        CTLineDraw(outline, context)
        context.textPosition = CGPoint(x: raster.pad, y: raster.baseline)
        CTLineDraw(line, context)
        context.endTransparencyLayer()
      }
    }
    return Bitmap(pixels: pixels, advance: max(Float(raster.scale) * 3, width))
  }
}
