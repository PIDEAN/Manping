import Foundation

public struct PlaybackChapter: Identifiable, Equatable, Sendable {
  public let index: Int
  public let title: String
  public let time: Double
  public var id: Int { index }
  public init(index: Int, title: String, time: Double) {
    self.index = index; self.title = title.isEmpty ? "章节 \(index + 1)" : title; self.time = time
  }
  /// The source reads chapters from the playback engine, not a guessed REST endpoint.
  public static func parse(_ data: Data) throws -> [Self] {
    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw BiliError.invalidResponse("Invalid chapter list")
    }
    return rows.enumerated().compactMap { index, row in
      guard let time = row["time"] as? Double, time.isFinite, time >= 0 else { return nil }
      return Self(index: index, title: row["title"] as? String ?? "", time: time)
    }.sorted { $0.time < $1.time }
  }
}

public struct VideoDanmakuDraft: Equatable, Sendable {
  public let aid: Int64
  public let cid: Int64
  public let text: String
  public let progressMilliseconds: Int64
  public let color: UInt32
  public let standardSize: Bool
  public let mode: Int
  public init(aid: Int64, cid: Int64, text: String, seconds: Double, color: UInt32 = 0xffffff,
    standardSize: Bool = true, mode: Int = 1) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard aid > 0, cid > 0, !trimmed.isEmpty, trimmed.count <= 100,
      seconds.isFinite, seconds >= 0, seconds <= 86_400_000,
      color <= 0xffffff, [1, 4, 5].contains(mode),
      !trimmed.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 }) else {
      throw BiliError.invalidResponse("弹幕正文、播放位置或样式无效")
    }
    self.aid = aid; self.cid = cid; self.text = trimmed
    // The original view model truncates seconds before the SDK multiplies by 1000.
    progressMilliseconds = Int64(seconds) * 1000
    self.color = color; self.standardSize = standardSize; self.mode = mode
  }
  public func fields(timestampMilliseconds: Int64) -> [String: String] {
    ["aid": String(aid), "type": "1", "oid": String(cid), "msg": text,
      "progress": String(progressMilliseconds), "color": String(color),
      "fontsize": standardSize ? "25" : "18", "mode": String(mode), "rnd": String(timestampMilliseconds)]
  }
}

extension BiliService {
  public func sendVideoDanmaku(_ draft: VideoDanmakuDraft, expectedIdentity: AuthSnapshot) async throws {
    try checkRESTIdentity(expectedIdentity)
    guard expectedIdentity.state == .appAuthorized, expectedIdentity.token != nil else { throw AuthFailure.needsLogin }
    _ = try await appREST(.danmakuSend, fields: draft.fields(timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1000)),
      expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
  }
}
