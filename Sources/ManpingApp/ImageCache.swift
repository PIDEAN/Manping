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
actor ImageCache {
  static let shared = ImageCache()
  private struct Entry {
    let image: DecodedImage
    var accessed: Date
  }
  private var memory: [String: Entry] = [:]
  private var pending: [String: Task<DecodedImage, Error>] = [:]
  private var memoryCost = 0
  private var clearing = false
  private var generation: UInt64 = 0
  private let memoryLimit = 64 * 1024 * 1024
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
  func clear() async throws {
    guard !clearing else { return }
    clearing = true; generation &+= 1
    defer { clearing = false }
    let flights = Array(pending.values)
    for flight in flights { flight.cancel() }
    for flight in flights { _ = await flight.result }
    pending.removeAll(); memory.removeAll(); memoryCost = 0
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }
  fileprivate func image(for original: URL) async throws -> DecodedImage {
    guard !clearing else { throw CancellationError() }
    let revision = generation
    let url = Self.secured(original)
    let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }
      .joined()
    if var entry = memory[key] {
      entry.accessed = Date()
      memory[key] = entry
      return entry.image
    }
    if DebugUIFixtures.enabled, url.host == "fixture.invalid", url.pathComponents.contains("emote") {
      guard let image = Self.fixtureEmote(heart: url.lastPathComponent == "heart") else {
        throw URLError(.cannotDecodeContentData)
      }
      memory[key] = Entry(image: image, accessed: Date())
      memoryCost += image.cost
      return image
    }
    if let task = pending[key] {
      let image = try await task.value
      guard generation == revision, !clearing else { throw CancellationError() }
      return image
    }
    let directory = directory
    let diskLimit = diskLimit
    let task = Task.detached(priority: .utility) {
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
      memory[key] = Entry(image: image, accessed: Date())
      memoryCost += image.cost
      while memoryCost > memoryLimit,
        let oldest = memory.min(by: { $0.value.accessed < $1.value.accessed })
      {
        memoryCost -= oldest.value.image.cost
        memory[oldest.key] = nil
      }
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
  @State private var image: NSImage?
  @State private var failed = false
  var body: some View {
    ZStack {
      Rectangle().fill(.gray.opacity(0.12))
      if DebugUIFixtures.enabled, url?.host == "fixture.invalid" {
        if PerformanceOptions.requested, url?.pathComponents.contains("cover") == true,
          let cover = PerformanceArtwork.cover(Int(url?.lastPathComponent ?? "0") ?? 0) {
          Image(nsImage: cover).resizable().scaledToFill()
        } else {
          DebugFixtureImage(index: Int(url?.lastPathComponent ?? "0") ?? 0, avatar: url?.pathComponents.contains("avatar") == true)
        }
      } else if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").foregroundStyle(.tertiary)
      }

    }.clipped().task(id: url) {
      image = nil
      failed = false
      guard let url else { return }
      if DebugUIFixtures.enabled && url.host == "fixture.invalid" { return }
      do {
        let result = try await ImageCache.shared.image(for: url)
        try Task.checkCancellation()
        image = NSImage(cgImage: result.image, size: .zero)
      } catch is CancellationError {} catch { failed = true }
    }
  }
}
