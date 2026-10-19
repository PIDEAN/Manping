import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// CGImage is immutable; decoding and all disk work stay off the main actor.
private struct DecodedImage: @unchecked Sendable {
  let image: CGImage
  var cost: Int { image.bytesPerRow * image.height }
}
/// The decoded-image memory tier. It is lock-protected rather than actor-isolated so a view can
/// read it synchronously: a cover that is already decoded draws in a cell's first frame instead of
/// a placeholder frame followed by an asynchronous swap and a second render.
private final class DecodedImageMemory: @unchecked Sendable {
  private struct Entry {
    let image: DecodedImage
    var tick: UInt64
  }
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var cost = 0
  private var tick: UInt64 = 0
  private let limit: Int
  init(limit: Int) { self.limit = limit }

  func image(for key: String) -> DecodedImage? {
    lock.lock(); defer { lock.unlock() }
    guard var entry = entries[key] else { return nil }
    tick &+= 1; entry.tick = tick; entries[key] = entry
    return entry.image
  }
  /// Least recently used entries go first once the tier exceeds its byte limit.
  func insert(_ image: DecodedImage, for key: String) {
    lock.lock(); defer { lock.unlock() }
    if let old = entries[key] { cost -= old.image.cost }
    tick &+= 1
    entries[key] = Entry(image: image, tick: tick)
    cost += image.cost
    while cost > limit, entries.count > 1, let oldest = entries.min(by: { $0.value.tick < $1.value.tick }) {
      cost -= oldest.value.image.cost
      entries[oldest.key] = nil
    }
  }
  func removeAll() {
    lock.lock(); defer { lock.unlock() }
    entries.removeAll(); cost = 0
  }
}

actor ImageCache {
  static let shared = ImageCache()
  private var pending: [String: Task<DecodedImage, Error>] = [:]
  private var clearing = false
  private var generation: UInt64 = 0
  /// Keyed by the secured URL string so the synchronous lookup needs no hashing.
  private nonisolated let memory = DecodedImageMemory(limit: 64 * 1024 * 1024)
  private let diskLimit = 200 * 1024 * 1024
  private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Manping/Images", isDirectory: true)

  /// Bilibili APIs return many covers as plain `http://` (e.g. `http://i1.hdslb.com/...`), which ATS
  /// blocks. The image CDN serves the same paths over HTTPS, so upgrade instead of relaxing ATS.
  nonisolated static func secured(_ url: URL) -> URL {
    guard url.scheme?.lowercased() == "http",
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    components.scheme = "https"
    return components.url ?? url
  }

  func imageForReader(for url: URL) async throws -> CGImage { try await image(for: url).image }
  /// An already decoded image, without waiting; nil when it must be loaded or decoded.
  nonisolated func cachedImage(for url: URL) -> CGImage? {
    memory.image(for: Self.secured(url).absoluteString)?.image
  }
  func clear() async throws {
    guard !clearing else { return }
    clearing = true; generation &+= 1
    defer { clearing = false }
    let flights = Array(pending.values)
    for flight in flights { flight.cancel() }
    for flight in flights { _ = await flight.result }
    pending.removeAll(); memory.removeAll()
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }
  fileprivate func image(for original: URL) async throws -> DecodedImage {
    guard !clearing else { throw CancellationError() }
    let revision = generation
    let url = Self.secured(original)
    let memoryKey = url.absoluteString
    if let image = memory.image(for: memoryKey) { return image }
    let key = SHA256.hash(data: Data(memoryKey.utf8)).map { String(format: "%02x", $0) }
      .joined()
    if DebugUIFixtures.enabled, url.host == "fixture.invalid", url.pathComponents.contains("emote") {
      guard let image = Self.fixtureEmote(heart: url.lastPathComponent == "heart") else {
        throw URLError(.cannotDecodeContentData)
      }
      memory.insert(image, for: memoryKey)
      return image
    }
    if let task = pending[key] {
      let image = try await task.value
      guard generation == revision, !clearing else { throw CancellationError() }
      return image
    }
    let directory = directory
    let diskLimit = diskLimit
    let fixtureCover = PerformanceCoverData.data(for: url)
    let task = Task.detached(priority: .utility) {
      // Scroll diagnostics: decode like a disk hit, never touch the shared cache directory.
      if let fixtureCover {
        guard let image = Self.decode(fixtureCover) else { throw URLError(.cannotDecodeContentData) }
        return image
      }
      let file = directory.appendingPathComponent(key)
      if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return image
      }
      var request = URLRequest(url: url)
      request.timeoutInterval = 25
      request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
        data.count <= 10 * 1024 * 1024, let image = Self.decode(data)
      else { throw URLError(.cannotDecodeContentData) }
      try Task.checkCancellation()
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? data.write(to: file, options: .atomic)
      Self.trimDisk(directory, limit: diskLimit)
      return image
    }
    pending[key] = task
    do {
      let image = try await task.value
      guard generation == revision, !clearing else { throw CancellationError() }
      pending[key] = nil
      memory.insert(image, for: memoryKey)
      return image
    } catch {
      if generation == revision { pending[key] = nil }
      throw error
    }
  }
  private nonisolated static func decode(_ data: Data) -> DecodedImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 960,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { return nil }
    return DecodedImage(image: image)
  }
  private nonisolated static func fixtureEmote(heart: Bool) -> DecodedImage? {
    guard let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    if heart {
      context.setFillColor(red: 1, green: 0.25, blue: 0.4, alpha: 1)
      context.move(to: CGPoint(x: 20, y: 4))
      context.addCurve(to: CGPoint(x: 4, y: 28), control1: CGPoint(x: 1, y: 19), control2: CGPoint(x: 1, y: 22))
      context.addCurve(to: CGPoint(x: 20, y: 30), control1: CGPoint(x: 8, y: 39), control2: CGPoint(x: 18, y: 38))
      context.addCurve(to: CGPoint(x: 36, y: 28), control1: CGPoint(x: 22, y: 38), control2: CGPoint(x: 32, y: 39))
      context.addCurve(to: CGPoint(x: 20, y: 4), control1: CGPoint(x: 39, y: 22), control2: CGPoint(x: 39, y: 19))
      context.fillPath()
    } else {
      context.setFillColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)
      context.fillEllipse(in: CGRect(x: 2, y: 2, width: 36, height: 36))
      context.setFillColor(red: 0.15, green: 0.12, blue: 0.1, alpha: 1)
      for x in [12, 25] { context.fillEllipse(in: CGRect(x: x, y: 23, width: 4, height: 5)) }
      context.setStrokeColor(red: 0.15, green: 0.12, blue: 0.1, alpha: 1); context.setLineWidth(2.5)
      context.move(to: CGPoint(x: 11, y: 16))
      context.addCurve(to: CGPoint(x: 29, y: 16), control1: CGPoint(x: 15, y: 7), control2: CGPoint(x: 25, y: 7))
      context.strokePath()
    }
    return context.makeImage().map { DecodedImage(image: $0) }
  }
  private nonisolated static func trimDisk(_ directory: URL, limit: Int) {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
    else { return }
    let entries = files.compactMap { url -> (URL, Int, Date)? in
      guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
      return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
    }.sorted { $0.2 < $1.2 }
    var total = entries.reduce(0) { $0 + $1.1 }
    for entry in entries where total > limit {
      if (try? FileManager.default.removeItem(at: entry.0)) != nil { total -= entry.1 }
    }
  }
}
struct CachedImage: View {
  let url: URL?
  @State private var image: CGImage?
  @State private var failed = false
  /// The placeholder glyph appears only when a load is actually slow (network), so memory and
  /// disk hits do not draw and then replace a symbol for a frame or two while a grid scrolls.
  @State private var waiting = false

  init(url: URL?) {
    self.url = url
    // Used only when the view's identity is created: an already decoded image draws at once.
    _image = State(initialValue: url.flatMap { ImageCache.shared.cachedImage(for: $0) })
  }

  var body: some View {
    ZStack {
      // An opaque photo covers the tint completely; skipping it saves a layer per grid cell.
      if !(image.map(Self.isOpaque) ?? false) { Rectangle().fill(.gray.opacity(0.12)) }
      if DebugUIFixtures.enabled, url?.host == "fixture.invalid", !Self.pipelineFixture(url) {
        if PerformanceOptions.requested, url?.pathComponents.contains("cover") == true,
          let cover = PerformanceArtwork.cover(Int(url?.lastPathComponent ?? "0") ?? 0) {
          Image(nsImage: cover).resizable().scaledToFill()
        } else {
          DebugFixtureImage(index: Int(url?.lastPathComponent ?? "0") ?? 0, avatar: url?.pathComponents.contains("avatar") == true)
        }
      } else if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFill()
      } else if failed || waiting {
        Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").foregroundStyle(.tertiary)
      }

    }.clipped().task(id: url) {
      guard let url else { image = nil; failed = false; waiting = false; return }
      if DebugUIFixtures.enabled && url.host == "fixture.invalid" && !Self.pipelineFixture(url) { return }
      if let cached = ImageCache.shared.cachedImage(for: url) {
        // Write only on change: an unchanged state write would still re-render the view.
        if image !== cached { image = cached }
        if failed { failed = false }
        if waiting { waiting = false }
        return
      }
      if image != nil { image = nil }
      if failed { failed = false }
      let reveal = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(250))
        if !Task.isCancelled { waiting = true }
      }
      defer { reveal.cancel() }
      do {
        let result = try await ImageCache.shared.image(for: url)
        try Task.checkCancellation()
        reveal.cancel()
        image = result.image
        if waiting { waiting = false }
      } catch is CancellationError {} catch {
        reveal.cancel()
        failed = true
        if waiting { waiting = false }
      }
    }
  }
  private static func isOpaque(_ image: CGImage) -> Bool {
    [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
  }
  /// `--perf-covers pipeline` sends fixture covers through the production loading path.
  private static func pipelineFixture(_ url: URL?) -> Bool {
    PerformanceOptions.coverPipeline && url?.pathComponents.contains("cover") == true
  }
}
