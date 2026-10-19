import Foundation

/// A chapter from the player's `view_points` (or, in the UI, mpv's chapter list as a fallback).
public struct AIViewPoint: Sendable, Equatable, Codable {
  public let id: String
  public let start: Double
  public let end: Double
  public let title: String
  public init(id: String, start: Double, end: Double, title: String) { self.id = id; self.start = start; self.end = end; self.title = title }
}

/// One /x/player/wbi/v2 answer, parsed field by field: a malformed subtitle index does not hide
/// usable chapters and the reverse.
public struct PlayerMetadata: Sendable, Equatable {
  public let aid: Int64
  public let cid: Int64
  /// nil when the subtitle index was missing or malformed (`subtitleError` says why).
  public let subtitles: [DownloadSubtitleTrack]?
  public let subtitleError: String?
  public let viewPoints: [AIViewPoint]
  public init(aid: Int64, cid: Int64, subtitles: [DownloadSubtitleTrack]?, subtitleError: String? = nil, viewPoints: [AIViewPoint] = []) {
    self.aid = aid; self.cid = cid; self.subtitles = subtitles; self.subtitleError = subtitleError; self.viewPoints = viewPoints
  }
  /// `view_points` is an optional array of `{from, to, content}`; this shape follows external
  /// clients and is not verified against live responses here, so every element is optional.
  public static func parse(_ data: [String: Any], aid: Int64, cid: Int64) -> PlayerMetadata {
    var subtitles: [DownloadSubtitleTrack]?, subtitleError: String?
    do { subtitles = try DownloadSubtitleTrack.parse(data) } catch { subtitleError = error.localizedDescription }
    let raw = data["view_points"] as? [[String: Any]] ?? []
    let points = raw.compactMap { item -> (Double, Double, String)? in
      guard let from = AITimecode.parse(item["from"]), let to = AITimecode.parse(item["to"]), from >= 0, to > from,
        let content = (item["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
      return (from, to, String(content.prefix(80)))
    }.sorted { $0.0 < $1.0 }.prefix(200)
    let viewPoints = points.enumerated().map { AIViewPoint(id: "ch\($0.offset + 1)", start: $0.element.0, end: $0.element.1, title: $0.element.2) }
    return PlayerMetadata(aid: aid, cid: cid, subtitles: subtitles, subtitleError: subtitleError, viewPoints: viewPoints)
  }
}

/// Completed results and in-flight requests keyed by media and identity; lives on `BiliService`.
struct PlayerMetadataCache {
  var values: [String: (stored: Date, value: PlayerMetadata)] = [:]
  var flights: [String: Task<PlayerMetadata, Error>] = [:]
  static let lifetime: TimeInterval = 600
  static let capacity = 32
  static func key(aid: Int64, cid: Int64, identity: AuthSnapshot) -> String {
    "\(aid):\(cid):\(identity.epoch):\(identity.identityRevision)"
  }
  func value(_ key: String, now: Date) -> PlayerMetadata? {
    guard let entry = values[key], now.timeIntervalSince(entry.stored) < Self.lifetime else { return nil }
    return entry.value
  }
  mutating func store(_ value: PlayerMetadata, key: String, now: Date) {
    values[key] = (now, value)
    if values.count > Self.capacity, let oldest = values.min(by: { $0.value.stored < $1.value.stored })?.key {
      values.removeValue(forKey: oldest)
    }
  }
}

public struct AIOfficialOutlinePoint: Sendable, Equatable, Codable {
  public let id: String
  public let time: Double
  public let content: String
  public init(id: String, time: Double, content: String) { self.id = id; self.time = time; self.content = content }
}
public struct AIOfficialOutlineSection: Sendable, Equatable, Codable {
  public let id: String
  public let title: String
  public let start: Double
  public let points: [AIOfficialOutlinePoint]
  public init(id: String, title: String, start: Double, points: [AIOfficialOutlinePoint]) {
    self.id = id; self.title = title; self.start = start; self.points = points
  }
}

/// Bilibili's own AI summary. Three states, so “no summary” is never confused with “could not ask”.
public enum AIOfficialSummary: Sendable, Equatable {
  case available(summary: String, outline: [AIOfficialOutlineSection]?)
  case unavailable(reason: String)
  case retryableError(String)
  public var isAvailable: Bool { if case .available = self { return true }; return false }

  /// Candidate contract from external clients (not verified live in this repository): root
  /// `code` (-101 when signed out), `data.code` (0 ok, -1 unsupported, 1 none), nullable
  /// `data.model_result` with `result_type`, `summary` and a nullable `outline` of
  /// `{title, timestamp, part_outline: [{timestamp, content}]}`.
  public static func parse(_ root: [String: Any]) -> AIOfficialSummary {
    guard let code = (root["code"] as? NSNumber)?.intValue else { return .retryableError("官方总结返回了无法识别的数据。") }
    if code == -101 { return .unavailable(reason: "登录后才能读取官方 AI 总结。") }
    guard code == 0 else { return .retryableError("官方 AI 总结暂时无法读取（\(code)）。") }
    guard let data = root["data"] as? [String: Any] else { return .unavailable(reason: "该视频没有官方 AI 总结。") }
    switch (data["code"] as? NSNumber)?.intValue ?? 0 {
    case 0: break
    case -1: return .unavailable(reason: "该视频不支持官方 AI 总结。")
    default: return .unavailable(reason: "该视频没有官方 AI 总结。")
    }
    guard let result = data["model_result"] as? [String: Any] else { return .unavailable(reason: "该视频没有官方 AI 总结。") }
    let resultType = (result["result_type"] as? NSNumber)?.intValue ?? 0
    let summary = (result["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var sections: [AIOfficialOutlineSection] = []
    for (index, raw) in (result["outline"] as? [[String: Any]] ?? []).enumerated() {
      let title = (raw["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let parts = (raw["part_outline"] as? [[String: Any]] ?? []).enumerated().compactMap { offset, part -> AIOfficialOutlinePoint? in
        guard let time = AITimecode.parse(part["timestamp"]), time >= 0,
          let content = (part["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
        return AIOfficialOutlinePoint(id: "o\(index + 1).\(offset + 1)", time: time, content: content)
      }
      let start = AITimecode.parse(raw["timestamp"]) ?? parts.first?.time ?? 0
      guard !title.isEmpty || !parts.isEmpty, start >= 0 else { continue }
      sections.append(AIOfficialOutlineSection(id: "o\(index + 1)", title: title, start: start, points: parts))
    }
    guard resultType > 0, !summary.isEmpty || !sections.isEmpty else { return .unavailable(reason: "该视频没有官方 AI 总结。") }
    return .available(summary: summary, outline: sections.isEmpty ? nil : sections)
  }
  /// Body of `<official_summary>`.
  public func render() -> String? {
    guard case .available(let summary, let outline) = self else { return nil }
    var lines: [String] = summary.isEmpty ? [] : [summary]
    for section in outline ?? [] {
      lines.append("[\(section.id) \(AITimecode.format(section.start))] \(section.title)")
      for point in section.points { lines.append("  [\(point.id) \(AITimecode.format(point.time))] \(point.content)") }
    }
    return lines.joined(separator: "\n")
  }
}

extension BiliService {
  /// One request yields subtitles and chapters; repeated calls for the same media and identity
  /// (subtitle playback, AI) share the result for ten minutes and share an in-flight request.
  public func playerMetadata(aid: Int64, cid: Int64, expectedIdentity: AuthSnapshot) async throws -> PlayerMetadata {
    try checkRESTIdentity(expectedIdentity)
    guard aid > 0, cid > 0 else { throw BiliError.invalidResponse("读取字幕需要有效的视频与分集标识") }
    let key = PlayerMetadataCache.key(aid: aid, cid: cid, identity: expectedIdentity)
    if let cached = playerMetadataCache.value(key, now: Date()) { return cached }
    let flight: Task<PlayerMetadata, Error>
    if let existing = playerMetadataCache.flights[key] { flight = existing }
    else {
      flight = Task {
        let object = try await self.subtitleMetadataObject(aid: aid, cid: cid, expectedIdentity: expectedIdentity)
        return PlayerMetadata.parse(object, aid: aid, cid: cid)
      }
      playerMetadataCache.flights[key] = flight
    }
    do {
      let value = try await flight.value
      playerMetadataCache.flights.removeValue(forKey: key)
      try checkRESTIdentity(expectedIdentity)
      playerMetadataCache.store(value, key: key, now: Date())
      try Task.checkCancellation()
      return value
    } catch {
      playerMetadataCache.flights.removeValue(forKey: key)
      try checkRESTIdentity(expectedIdentity)
      throw error
    }
  }

  /// GET /x/web-interface/view/conclusion/get (WBI). Network failures are retryable; a signed-out
  /// answer is `unavailable`, never cached as “no summary” across identities by callers.
  public func officialSummary(aid: Int64, cid: Int64, bvid: String?, uploaderMid: Int64?, expectedIdentity: AuthSnapshot) async throws -> AIOfficialSummary {
    try checkRESTIdentity(expectedIdentity)
    guard aid > 0, cid > 0 else { throw BiliError.invalidResponse("官方总结需要有效的视频与分集标识") }
    var params = ["aid": String(aid), "cid": String(cid)]
    if let bvid, !bvid.isEmpty { params["bvid"] = bvid }
    if let uploaderMid, uploaderMid > 0 { params["up_mid"] = String(uploaderMid) }
    let body: Data
    do { body = try await wbiSignedBody("/x/web-interface/view/conclusion/get", params: params, expectedIdentity: expectedIdentity) }
    catch is CancellationError { throw CancellationError() }
    catch {
      try checkRESTIdentity(expectedIdentity); try Task.checkCancellation()
      return .retryableError("官方 AI 总结暂时无法读取，请稍后重试。")
    }
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
      return .retryableError("官方总结返回了无法识别的数据。")
    }
    return AIOfficialSummary.parse(root)
  }
}
