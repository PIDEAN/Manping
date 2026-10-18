import Foundation

/// Subtitle metadata stays in memory; persisted task options contain only subtitle ID/language.
public struct DownloadSubtitleTrack: Identifiable, Equatable, Sendable {
  public let id: String
  public let language: String
  public let title: String
  public let isAI: Bool
  public let url: URL
  public init(id: String, language: String, title: String, isAI: Bool = false, url: URL) throws {
    guard !id.isEmpty, id.allSatisfy(\.isNumber), !language.isEmpty else {
      throw BiliError.invalidResponse("字幕标识或语言无效")
    }
    self.id = id; self.language = language; self.title = title; self.isAI = isAI
    self.url = try Self.safeURL(url.absoluteString)
  }
  /// Only subtitle paths on the image/AI subtitle CDNs used by Bilibili are accepted.
  /// HTTP is upgraded for these trusted hosts; arbitrary URL schemes, hosts and ports are rejected.
  public static func safeURL(_ raw: String) throws -> URL {
    let value = raw.hasPrefix("//") ? "https:" + raw : raw
    guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.user == nil, parts.password == nil,
      parts.fragment == nil,
      host == "aisubtitle.hdslb.com" || host.range(of: "^i[0-9]+\\.hdslb\\.com$", options: .regularExpression) != nil,
      parts.port == nil || parts.port == (parts.scheme?.lowercased() == "http" ? 80 : 443),
      parts.path.hasPrefix("/bfs/subtitle/") || parts.path.hasPrefix("/bfs/ai_subtitle/"),
      !parts.path.split(separator: "/").contains(".."),
      !(parts.queryItems ?? []).contains(where: { ["access_key", "access_token", "cookie", "sessdata"].contains($0.name.lowercased()) })
    else { throw BiliError.invalidResponse("字幕地址不属于受信的字幕节点") }
    parts.scheme = "https"; parts.host = host; parts.port = nil
    guard let result = parts.url else { throw BiliError.invalidResponse("字幕地址无效") }
    return result
  }
  static func parse(_ object: [String: Any]) throws -> [Self] {
    guard let subtitle = object["subtitle"] as? [String: Any],
      let rows = subtitle["subtitles"] as? [[String: Any]] else {
      throw BiliError.invalidResponse("字幕索引格式无效")
    }
    var result: [Self] = []
    var ids = Set<String>()
    for row in rows {
      let id = row["id_str"] as? String ?? JSONValue.int64(row["id"]).map(String.init) ?? ""
      let language = row["lan"] as? String ?? ""
      guard let url = row["subtitle_url"] as? String else { throw BiliError.invalidResponse("字幕地址缺失") }
      let track = try Self(id: id, language: language, title: row["lan_doc"] as? String ?? language,
        isAI: JSONValue.int(row["ai_type"]) > 0 || language.lowercased().hasPrefix("ai-"), url: safeURL(url))
      if ids.insert(track.id).inserted { result.append(track) }
    }
    return result
  }
  public static func filtered(_ tracks: [Self], filterAI: Bool) -> [Self] {
    filterAI ? tracks.filter { !$0.isAI } : tracks
  }
}

extension BiliService {
  public func downloadSubtitleTracks(aid: Int64, cid: Int64, expectedIdentity: AuthSnapshot) async throws -> [DownloadSubtitleTrack] {
    guard aid > 0, cid > 0 else { throw BiliError.invalidResponse("读取字幕需要有效的视频与分集标识") }
    try checkRESTIdentity(expectedIdentity)
    let object = try await subtitleMetadataObject(aid: aid, cid: cid, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    return try DownloadSubtitleTrack.parse(object)
  }
  public func downloadSubtitleCues(track: DownloadSubtitleTrack, expectedIdentity: AuthSnapshot) async throws -> [DownloadSubtitleCue] {
    try checkRESTIdentity(expectedIdentity)
    let url = try DownloadSubtitleTrack.safeURL(track.url.absoluteString)
    let body = try await subtitleBodyData(url, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    return try DownloadExport.parseSubtitleJSON(body)
  }
}
