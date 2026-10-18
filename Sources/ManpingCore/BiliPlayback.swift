import Foundation

public struct MediaSegmentBase: Sendable, Equatable {
  public let initialization: String
  public let indexRange: String
  public init(initialization: String, indexRange: String) {
    self.initialization = initialization
    self.indexRange = indexRange
  }
}

public struct MediaStream: Identifiable, Equatable, Sendable {
  public var id: String { "\(quality)-\(codec)" }
  public let quality: Int
  public let codec: String
  public let url: URL
  public let bandwidth: Int
  public let label: String
  public let mimeType: String
  public let width: Int
  public let height: Int
  public let backupURLs: [URL]
  public let frameRate: String
  public let codecID: Int
  public let segmentBase: MediaSegmentBase?
  public init(
    quality: Int, codec: String, url: URL, bandwidth: Int, label: String,
    mimeType: String = "", width: Int = 0, height: Int = 0, backupURLs: [URL] = [],
    frameRate: String = "", codecID: Int = 0, segmentBase: MediaSegmentBase? = nil
  ) {
    self.quality = quality
    self.codec = codec
    self.url = url
    self.bandwidth = bandwidth
    self.label = label
    self.mimeType = mimeType
    self.width = width
    self.height = height
    self.backupURLs = backupURLs
    self.frameRate = frameRate
    self.codecID = codecID
    self.segmentBase = segmentBase
  }
}

public struct PlaybackFormat: Sendable, Equatable {
  public let quality: Int
  public let format: String
  public let description: String
}

public struct PlaybackManifest: Sendable {
  public let video: [MediaStream]
  public let audio: [MediaStream]
  public let duration: Double
  public let formats: [PlaybackFormat]
  /// Opening / ending ranges an episode marks for skipping (PGC only).
  public let skips: [PlaybackSkip]
  public init(
    video: [MediaStream], audio: [MediaStream], duration: Double,
    formats: [PlaybackFormat] = [], skips: [PlaybackSkip] = []
  ) {
    self.video = video
    self.audio = audio
    self.duration = duration
    self.formats = formats
    self.skips = skips
  }
  public static func parse(_ object: [String: Any]) throws -> PlaybackManifest {
    guard let dash = object["dash"] as? [String: Any] else {
      throw BiliError.invalidResponse("This video did not return DASH streams")
    }
    let ids = object["accept_quality"] as? [Int] ?? []
    let names = object["accept_description"] as? [String] ?? []
    var labels: [Int: String] = [:]
    for (index, id) in ids.enumerated() where index < names.count { labels[id] = names[index] }
    let formats = (object["support_formats"] as? [[String: Any]] ?? []).compactMap {
      item -> PlaybackFormat? in
      guard let quality = item["quality"] as? Int else { return nil }
      let name =
        item["new_description"] as? String ?? item["description"] as? String ?? labels[quality]
        ?? "\(quality)"
      labels[quality] = name
      return PlaybackFormat(
        quality: quality, format: item["format"] as? String ?? "", description: name)
    }
    func streams(_ key: String) -> [MediaStream] {
      (dash[key] as? [[String: Any]] ?? []).compactMap { item in
        guard let url = JSONValue.url(item["baseUrl"] ?? item["base_url"]),
          let id = item["id"] as? Int
        else { return nil }
        let base = (item["SegmentBase"] ?? item["segment_base"]) as? [String: Any]
        let segment = base.map {
          MediaSegmentBase(
            initialization: ($0["Initialization"] ?? $0["initialization"]) as? String ?? "",
            indexRange: ($0["indexRange"] ?? $0["index_range"]) as? String ?? "")
        }
        return MediaStream(
          quality: id, codec: item["codecs"] as? String ?? "", url: url,
          bandwidth: JSONValue.int(item["bandwidth"]), label: labels[id] ?? "\(id)",
          mimeType: (item["mimeType"] ?? item["mime_type"]) as? String ?? "",
          width: JSONValue.int(item["width"]), height: JSONValue.int(item["height"]),
          backupURLs: ((item["backupUrl"] ?? item["backup_url"]) as? [String] ?? []).compactMap(
            JSONValue.url),
          frameRate: (item["frameRate"] ?? item["frame_rate"]) as? String ?? "",
          codecID: JSONValue.int(item["codecid"]), segmentBase: segment)
      }.sorted {
        $0.quality > $1.quality || ($0.quality == $1.quality && $0.bandwidth > $1.bandwidth)
      }
    }
    let video = streams("video")
    let audio = streams("audio")
    guard !video.isEmpty, !audio.isEmpty else {
      throw BiliError.invalidResponse("DASH video/audio unavailable")
    }
    return PlaybackManifest(
      video: video, audio: audio,
      duration: (dash["duration"] as? NSNumber)?.doubleValue ?? 0, formats: formats,
      skips: PlaybackSkip.parse(object["clip_info_list"]))
  }
}

/// A range the episode marks as opening or ending, in seconds.
public struct PlaybackSkip: Sendable, Equatable {
  public enum Kind: Sendable, Equatable { case opening, ending }
  public let kind: Kind
  public let start: Double
  public let end: Double
  public init(kind: Kind, start: Double, end: Double) { self.kind = kind; self.start = start; self.end = end }
  public var title: String { kind == .opening ? "跳过片头" : "跳过片尾" }

  static func parse(_ raw: Any?) -> [PlaybackSkip] {
    (raw as? [[String: Any]] ?? []).compactMap { item in
      let kind: Kind
      switch item["clipType"] as? String {
      case "CLIP_TYPE_OP": kind = .opening
      case "CLIP_TYPE_ED": kind = .ending
      default: return nil
      }
      guard let start = (item["start"] as? NSNumber)?.doubleValue, let end = (item["end"] as? NSNumber)?.doubleValue,
        start.isFinite, end.isFinite, start >= 0, end - start >= 5, end - start <= 600 else { return nil }
      return PlaybackSkip(kind: kind, start: start, end: end)
    }.sorted { $0.start < $1.start }
  }

  /// The range playing at `time`, offered until a few seconds before it ends.
  public static func active(_ skips: [PlaybackSkip], at time: Double) -> PlaybackSkip? {
    skips.first { time >= $0.start && time < $0.end - 3 }
  }
}

/// Automatic skipping for one episode. Each marked range is skipped at most once, whether
/// playback starts inside it, automatic skipping is turned on while it plays, or the picture
/// moves to another window; seeking back into a range that was already skipped (or skipped by
/// hand) leaves the viewer there.
public struct PlaybackSkipTracker: Sendable, Equatable {
  public private(set) var episode: Int64?
  private var handled: Set<Double> = []
  public init(episode: Int64? = nil) { self.episode = episode }
  /// A new episode (or none): every range may be skipped again.
  public mutating func reset(episode: Int64?) { self.episode = episode; handled = [] }
  /// Where to seek now, or nil. Returning a target marks its range handled.
  public mutating func target(_ skips: [PlaybackSkip], at time: Double, automatic: Bool) -> Double? {
    guard automatic, time.isFinite, let range = PlaybackSkip.active(skips, at: time),
      !handled.contains(range.start) else { return nil }
    handled.insert(range.start)
    return range.end
  }
  /// The viewer pressed 「跳过」 for this range.
  public mutating func markHandled(_ skip: PlaybackSkip) { handled.insert(skip.start) }
}

public enum PlaybackCodec: String, CaseIterable, Sendable {
  case h264, hevc, av1
  func matches(_ stream: MediaStream) -> Bool {
    let codec = stream.codec.lowercased()
    switch self {
    case .h264: return stream.codecID == 7 || codec.hasPrefix("avc")
    case .hevc: return stream.codecID == 12 || codec.hasPrefix("hev") || codec.hasPrefix("hvc")
    case .av1: return stream.codecID == 13 || codec.hasPrefix("av01")
    }
  }
}

public struct PlaybackPreferences: Sendable, Equatable {
  public var codec: PlaybackCodec
  public var quality: Int?
  public var lastQuality: Int?
  public var avoidP2P: Bool
  public init(
    codec: PlaybackCodec = .h264, quality: Int? = nil,
    lastQuality: Int? = nil, avoidP2P: Bool = false
  ) {
    self.codec = codec
    self.quality = quality
    self.lastQuality = lastQuality
    self.avoidP2P = avoidP2P
  }
}

public struct PlaybackSelection: Sendable {
  public let video: MediaStream
  public let audio: MediaStream
  public let videoURL: URL
  public let audioURL: URL
}

public enum PlaybackSelector {
  public static let defaultQualityCeiling = 116
  public static func select(
    _ manifest: PlaybackManifest, preferences: PlaybackPreferences = .init(),
    supportsHardware: (PlaybackCodec) -> Bool = { $0 == .h264 }
  ) throws -> PlaybackSelection {
    // H.264 remains the compatibility baseline. Higher codecs require the caller's hardware verdict.
    let supported = manifest.video.filter { stream in
      PlaybackCodec.h264.matches(stream)
        || PlaybackCodec.allCases.contains {
          $0 != .h264 && $0.matches(stream) && supportsHardware($0)
        }
    }
    guard !supported.isEmpty,
      let audio = manifest.audio.max(by: {
        $0.quality < $1.quality || ($0.quality == $1.quality && $0.bandwidth < $1.bandwidth)
      })
    else { throw BiliError.invalidResponse("No compatible playback streams") }
    let qualities = Set(supported.map(\.quality)).sorted(by: >)
    // With no preference yet, start at 1080P 60 (116) rather than 8K / Dolby Vision: the
    // highest tiers start slowly and stall on ordinary networks. A request below every
    // available tier falls back to the lowest tier, not the highest.
    let requested = preferences.quality ?? preferences.lastQuality ?? PlaybackSelector.defaultQualityCeiling
    let quality = qualities.first(where: { $0 <= requested }) ?? qualities[qualities.count - 1]
    let candidates = supported.filter { $0.quality == quality }.sorted {
      $0.bandwidth > $1.bandwidth
    }
    let video =
      candidates.first(where: { preferences.codec.matches($0) })
      ?? candidates.first(where: { PlaybackCodec.h264.matches($0) }) ?? candidates[0]
    func selectedURL(_ stream: MediaStream) -> URL {
      guard preferences.avoidP2P else { return stream.url }
      return ([stream.url] + stream.backupURLs).first(where: { !isP2P($0) }) ?? stream.url
    }
    return PlaybackSelection(
      video: video, audio: audio,
      videoURL: selectedURL(video), audioURL: selectedURL(audio))
  }
  public static func isP2P(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return ["mcdn.bilivideo.cn", "mcdn.bilivideo.com", "szbdyd.com"].contains {
      host == $0 || host.hasSuffix("." + $0)
    }
  }
}
