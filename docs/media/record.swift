// Records one README scene from the Debug build (docs/media/README.md).
//
//   swiftc -O docs/media/record.swift -o docs/media/.out/record
//   docs/media/.out/record --app ".build/ui/满屏 Debug.app" --scenes docs/media/scenes.json \
//     --out docs/media/.out [--media docs/media/.out/demo-media.mp4] hero
//
// It launches the app on its offline samples with `MANPING_DEMO_SCENE` (DemoDirector.swift), then records
// every window of that process with ScreenCaptureKit, one desktop-independent window stream each (so the
// windows need not be in front, and nothing else on screen is captured), at 30 fps as ProRes 4444 with the
// windows' transparent corners. The director plays the scene and writes events.json; when it is done the
// movies become 25 fps PNG sequences under .out/<scene>/ and the composition's timeline .out/<scene>.json
// (window frames, positions over time, stacking, and the director's pointer targets, clicks, zooms, keys and
// captions). Needs the Screen Recording permission for the terminal that runs it.
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct Failure: Error, CustomStringConvertible { let description: String }

// MARK: Options

var options: [String: String] = [:]
var positional: [String] = []
do {
  var args = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = args.next() {
    if arg.hasPrefix("--") { options[String(arg.dropFirst(2))] = args.next() ?? "" } else { positional.append(arg) }
  }
}
guard let appPath = options["app"], let scenesPath = options["scenes"], let outPath = options["out"], let sceneName = positional.first else {
  FileHandle.standardError.write(Data("usage: record --app <满屏 Debug.app> --scenes <scenes.json> --out <dir> [--media <file>] [--theme dark] <scene>\n".utf8))
  exit(2)
}
let out = URL(fileURLWithPath: outPath, isDirectory: true)
let scenes = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: scenesPath))) as? [String: [String: Any]] ?? [:]
guard let sceneConfig = scenes[sceneName] else { print("unknown scene \(sceneName)"); exit(2) }
let fps = 25.0

func log(_ text: String) { print("[\(sceneName)] \(text)"); fflush(stdout) }
func hostSeconds(_ machTime: UInt64) -> Double {
  var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
  return Double(machTime) * Double(info.numer) / Double(info.denom) / 1e9
}
func now() -> Double { hostSeconds(mach_absolute_time()) }

// MARK: Window capture

/// One window: a ScreenCaptureKit stream into ProRes 4444 movies. A new segment starts when the
/// window changes size (the stream's output size is fixed).
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  struct Segment { var url: URL; var start: Double; var size: CGSize; var scale: CGFloat }
  let id: CGWindowID
  let layer: Int
  let order: Int
  let directory: URL
  private(set) var segments: [Segment] = []
  private(set) var bounds: [(t: Double, rect: CGRect)] = []
  private(set) var firstSeen: Double
  private(set) var lastSeen: Double
  private let queue: DispatchQueue
  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var segmentStart: Double?
  private var scale: CGFloat = 2
  private var lastBuffer: CVPixelBuffer?
  private var lastTime = CMTime.zero
  private let lock = NSLock()

  init(window: SCWindow, layer: Int, order: Int, directory: URL, seen: Double) {
    id = window.windowID; self.layer = layer; self.order = order; self.directory = directory
    firstSeen = seen; lastSeen = seen
    queue = DispatchQueue(label: "record.window.\(window.windowID)")
  }

  func start(_ window: SCWindow) async throws {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    scale = CGFloat(filter.pointPixelScale)
    let stream = SCStream(filter: filter, configuration: configuration(size: window.frame.size), delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
  }

  private func configuration(size: CGSize) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.width = Int((size.width * scale).rounded())
    config.height = Int((size.height * scale).rounded())
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    config.showsCursor = false
    config.capturesAudio = false
    config.queueDepth = 8
    config.ignoreShadowsSingleWindow = true
    return config
  }

  /// A bounds sample from the window list; a size change starts a new segment.
  func observe(_ rect: CGRect, at time: Double) {
    lock.lock(); defer { lock.unlock() }
    lastSeen = time
    if let last = bounds.last?.rect, abs(last.minX - rect.minX) < 0.5, abs(last.minY - rect.minY) < 0.5,
      abs(last.width - rect.width) < 0.5, abs(last.height - rect.height) < 0.5 { return }
    let resized = bounds.last.map { abs($0.rect.width - rect.width) > 1 || abs($0.rect.height - rect.height) > 1 } ?? false
    bounds.append((time, rect))
    guard resized, let stream else { return }
    // The stream's output takes the new size; its first frame at that size starts a new movie.
    let id = id
    stream.updateConfiguration(configuration(size: rect.size)) { error in if let error { print("resize \(id): \(error)") } }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sample.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let info = attachments.first,
      let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
    let display = (info[.displayTime] as? UInt64).map(hostSeconds) ?? now()
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    // The first frame, or the first one after the window was resized, starts a movie.
    if writer == nil || segments.last?.size != size {
      finishSegment()
      startSegment(size: size, at: display)
    }
    guard let input, let adaptor, input.isReadyForMoreMediaData, let start = segmentStart else { return }
    let time = CMTime(seconds: max(0, display - start), preferredTimescale: 6000)
    guard time > lastTime else { return }
    // ProRes needs its own copy: the stream reuses its buffers.
    guard let copy = Self.copy(buffer, pool: adaptor.pixelBufferPool) else { return }
    if adaptor.append(copy, withPresentationTime: time) { lastBuffer = copy; lastTime = time }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    // A closed window (a popover, the mini window) ends its stream; keep what was recorded.
    queue.async { [weak self] in self?.finishSegment() }
  }

  private func startSegment(size: CGSize, at time: Double) {
    let url = directory.appendingPathComponent("w\(id)-\(segments.count).mov")
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
    ])
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    writer.add(input)
    guard writer.startWriting() else { return }
    writer.startSession(atSourceTime: .zero)
    self.writer = writer; self.input = input; self.adaptor = adaptor
    segmentStart = time; lastBuffer = nil; lastTime = CMTime(value: -1, timescale: 6000)
    segments.append(Segment(url: url, start: time, size: size, scale: scale))
  }

  /// Ends the current movie, holding its last frame until now so the movie lasts as long as the window did.
  private func finishSegment() {
    guard let writer, let input, let adaptor, let start = segmentStart else { return }
    let end = CMTime(seconds: max(0, now() - start), preferredTimescale: 6000)
    if let lastBuffer, end > lastTime, input.isReadyForMoreMediaData { adaptor.append(lastBuffer, withPresentationTime: end) }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.endSession(atSourceTime: end)
    writer.finishWriting { done.signal() }
    done.wait()
    self.writer = nil; self.input = nil; self.adaptor = nil; segmentStart = nil; lastBuffer = nil
  }

  func stop() async {
    if let stream { try? await stream.stopCapture() }
    stream = nil
    queue.sync { finishSegment() }
  }

  private static func copy(_ source: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
    var target: CVPixelBuffer?
    if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) }
    if target == nil {
      CVPixelBufferCreate(nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), kCVPixelFormatType_32BGRA, nil, &target)
    }
    guard let target else { return nil }
    CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(target, [])
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(target, []) }
    guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(target) else { return nil }
    let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(target))
    let fromStride = CVPixelBufferGetBytesPerRow(source), toStride = CVPixelBufferGetBytesPerRow(target)
    let bytes = min(fromStride, toStride)
    for row in 0..<rows { memcpy(to + row * toStride, from + row * fromStride, bytes) }
    return target
  }
}

// MARK: Scene

func waitFor(_ url: URL, seconds: Double, process: Process) async throws {
  let deadline = now() + seconds
  while !FileManager.default.fileExists(atPath: url.path) {
    guard process.isRunning else { throw Failure(description: "the app quit before \(url.lastPathComponent)") }
    guard now() < deadline else { throw Failure(description: "no \(url.lastPathComponent) after \(Int(seconds)) s") }
    try await Task.sleep(for: .milliseconds(50))
  }
}

/// The process's on-screen windows, front to back, with their layer and bounds (global points, top-left origin).
func windows(of pid: pid_t) -> [(id: CGWindowID, layer: Int, rect: CGRect, alpha: Double)] {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  return list.compactMap { info in
    guard (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
      let number = info[kCGWindowNumber as String] as? Int,
      let layer = info[kCGWindowLayer as String] as? Int,
      let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
    return (CGWindowID(number), layer, rect, info[kCGWindowAlpha as String] as? Double ?? 1)
  }
}

let sceneDir = out.appendingPathComponent(sceneName, isDirectory: true)
let director = sceneDir.appendingPathComponent("director", isDirectory: true)
let raw = sceneDir.appendingPathComponent("raw", isDirectory: true)
try? FileManager.default.removeItem(at: sceneDir)
for dir in [director, raw] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

let app = URL(fileURLWithPath: appPath)
let process = Process()
process.executableURL = app.appendingPathComponent("Contents/MacOS/Manping")
let size = sceneConfig["windowSize"] as? [Int] ?? [1280, 800]
process.arguments = ["--ui-fixture", "--skip-auth", "--ui-page", sceneConfig["page"] as? String ?? "popular",
  "--ui-theme", options["theme"] ?? "dark", "--ui-window-size", String(size[0]), String(size.count > 1 ? size[1] : 800)]
var environment = ProcessInfo.processInfo.environment
environment["MANPING_DEMO_SCENE"] = sceneName
environment["MANPING_DEMO_OUT"] = director.path
if let media = options["media"], sceneConfig["media"] as? Bool == true {
  environment["MANPING_DEMO_MEDIA"] = URL(fileURLWithPath: media).standardizedFileURL.path
}
process.environment = environment
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
try process.run()
log("app pid \(process.processIdentifier)")

var captures: [CGWindowID: WindowCapture] = [:]
var exitCode: Int32 = 0
do {
  try await waitFor(director.appendingPathComponent("ready.json"), seconds: 60, process: process)
  let pid = process.processIdentifier
  var appeared = 0
  /// Starts a stream for every new window of the app big enough to matter: the main and settings windows,
  /// the mini window (floating) and popovers. The status item and tooltips are too small or too high.
  func poll() async throws {
    let time = now()
    let listed = windows(of: pid).filter { $0.layer >= 0 && $0.layer < 200 && $0.alpha > 0.01 && $0.rect.width >= 60 && $0.rect.height >= 40 }
    for window in listed { captures[window.id]?.observe(window.rect, at: time) }
    let fresh = listed.filter { captures[$0.id] == nil }
    guard !fresh.isEmpty else { return }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    for window in fresh {
      guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { continue }
      let capture = WindowCapture(window: scWindow, layer: window.layer, order: appeared, directory: raw, seen: time)
      appeared += 1
      do {
        try await capture.start(scWindow)
        captures[window.id] = capture
        capture.observe(window.rect, at: time)
        log("recording window \(window.id) (layer \(window.layer), \(Int(window.rect.width))×\(Int(window.rect.height)))")
      } catch { log("window \(window.id): \(error)") }
    }
  }
  try await poll()
  guard !captures.isEmpty else { throw Failure(description: "no window to record (Screen Recording permission?)") }
  try await Task.sleep(for: .milliseconds(400))
  try Data().write(to: director.appendingPathComponent("go"))
  let done = director.appendingPathComponent("done")
  let deadline = now() + (sceneConfig["timeout"] as? Double ?? 60)
  while !FileManager.default.fileExists(atPath: done.path) {
    guard process.isRunning, now() < deadline else { throw Failure(description: "the scene did not finish") }
    try await poll()
    try await Task.sleep(for: .milliseconds(40))
  }
  try await poll()
} catch {
  log("FAIL \(error)")
  exitCode = 1
}
for capture in captures.values { await capture.stop() }
process.terminate()
for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
if process.isRunning { kill(process.processIdentifier, SIGKILL) }
guard exitCode == 0 else { exit(exitCode) }

// MARK: Timeline

let report = try JSONSerialization.jsonObject(with: Data(contentsOf: director.appendingPathComponent("events.json"))) as? [String: Any] ?? [:]
let origin = report["origin"] as? Double ?? 0
let duration = report["duration"] as? Double ?? 0
for note in report["notes"] as? [String] ?? [] { log("director: \(note)") }
let ms = { (time: Double) in ((time - origin) * 10000).rounded() / 10 }
var tracks: [[String: Any]] = []
for capture in captures.values.sorted(by: { $0.order < $1.order }) {
  var segments: [[String: Any]] = []
  for (index, segment) in capture.segments.enumerated() {
    let name = "w\(capture.id)-\(index)"
    let frames = sceneDir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    // Constant 25 fps from the segment's start: frame k is the window at start + k × 40 ms.
    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments = ["ffmpeg", "-v", "error", "-y", "-i", segment.url.path, "-vf", "fps=\(Int(fps))", "-pix_fmt", "rgba",
      "-start_number", "0", frames.appendingPathComponent("%05d.png").path]
    try ffmpeg.run(); ffmpeg.waitUntilExit()
    guard ffmpeg.terminationStatus == 0 else { throw Failure(description: "ffmpeg failed on \(segment.url.lastPathComponent)") }
    let count = (try? FileManager.default.contentsOfDirectory(atPath: frames.path).filter { $0.hasSuffix(".png") }.count) ?? 0
    segments.append(["start": ms(segment.start), "count": count, "dir": "\(sceneName)/\(name)", "digits": 5])
  }
  guard !segments.isEmpty else { continue }
  tracks.append([
    "id": "w\(capture.id)",
    "z": capture.layer * 1000 + capture.order,
    "from": max(0, ms(capture.firstSeen)),
    "to": min(duration, ms(capture.lastSeen)),
    "segments": segments,
    "bounds": capture.bounds.map { ["t": max(0, ms($0.t)), "x": $0.rect.minX, "y": $0.rect.minY, "w": $0.rect.width, "h": $0.rect.height] },
  ])
}
let timeline: [String: Any] = [
  "scene": sceneName,
  "title": sceneConfig["title"] as? String ?? sceneName,
  "duration": duration,
  "windows": tracks,
  "events": report["events"] as? [[String: Any]] ?? [],
]
try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("\(sceneName).json"))
if options["keep-raw"] == nil { try? FileManager.default.removeItem(at: raw) }
log("\(tracks.count) windows, \(Int(duration)) ms → \(out.appendingPathComponent("\(sceneName).json").path)")
