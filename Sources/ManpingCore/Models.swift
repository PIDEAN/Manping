import Foundation

public struct Video: Codable, Identifiable, Equatable, Sendable {
  public var id: String { aid.map { "av\($0)" } ?? bvid }
  public let bvid: String
  public let aid: Int64?
  public let authorID: Int64?
  public let avatar: URL?
  public let title: String
  public let cover: URL?
  public let author: String
  public let duration: Int
  public let views: Int
  public let cid: Int64?
  public let description: String?
  public let publishedAt: Int64?
  public let subtitle: String?
  public let recommendationReason: String?
  public let viewsText: String?
  public init(
    bvid: String, title: String, cover: URL? = nil, author: String = "", duration: Int = 0,
    views: Int = 0, cid: Int64? = nil, description: String? = nil,
    aid: Int64? = nil, authorID: Int64? = nil, avatar: URL? = nil,
    publishedAt: Int64? = nil, subtitle: String? = nil, recommendationReason: String? = nil,
    viewsText: String? = nil
  ) {
    self.aid = aid
    self.authorID = authorID
    self.avatar = avatar
    self.bvid = bvid
    self.title = title
    self.cover = cover
    self.author = author
    self.duration = duration
    self.views = views
    self.cid = cid
    self.description = description
    self.publishedAt = publishedAt
    self.subtitle = subtitle
    self.recommendationReason = recommendationReason
    self.viewsText = viewsText
  }
  public static func parse(_ object: [String: Any]) throws -> Video {
    let bvid = object["bvid"] as? String ?? ""
    let aid = JSONValue.int64(object["aid"])
    guard !bvid.isEmpty || (aid ?? 0) > 0, let title = object["title"] as? String
    else { throw BiliError.invalidResponse("Missing video identifier/title") }
    let owner = object["owner"] as? [String: Any]
    let stat = object["stat"] as? [String: Any]
    let rawCover = (object["pic"] as? String) ?? ""
    return Video(
      bvid: bvid,
      title: title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
      cover: URL(string: rawCover.hasPrefix("//") ? "https:" + rawCover : rawCover),
      author: (owner?["name"] as? String) ?? (object["author"] as? String) ?? "",
      duration: (object["duration"] as? Int) ?? 0,
      views: (stat?["view"] as? Int) ?? (object["play"] as? Int) ?? 0,
      cid: JSONValue.int64(object["cid"]), description: object["desc"] as? String,
      aid: aid, authorID: JSONValue.int64(owner?["mid"]), avatar: JSONValue.url(owner?["face"]),
      publishedAt: JSONValue.int64(object["pubdate"] ?? object["ctime"]),
      subtitle: object["subtitle"] as? String ?? object["pubdate_text"] as? String,
      recommendationReason: (object["rcmd_reason"] as? [String: Any])?["content"] as? String
        ?? (object["rcmd_reason_style"] as? [String: Any])?["text"] as? String
        ?? object["rcmd_reason"] as? String)
  }
}
public enum BiliError: LocalizedError {
  case http(Int)
  case api(Int, String)
  case invalidResponse(String)
  case dependency(String)
  case process(Int32, String)
  public var errorDescription: String? {
    switch self {
    case .http(let code): return "服务器返回错误（HTTP \(code)）"
    case .api(let code, let message): return "哔哩哔哩 \(code)：\(message)"
    case .invalidResponse(let message), .dependency(let message): return Self.forPeople(message)
    case .process(let code, let message): return "FFmpeg 出错（\(code)）：\(message)"
    }
  }
  /// Messages the app wrote for people (Chinese text) are shown as they are; English parse diagnostics become one sentence.
  private static func forPeople(_ message: String) -> String {
    message.range(of: "\\p{Han}", options: .regularExpression) != nil ? message : "服务返回了无法识别的数据，请稍后重试。"
  }
}

// JSON identifiers can be encoded as either numbers or decimal strings by App endpoints.
enum JSONValue {
  static func int64(_ value: Any?) -> Int64? {
    if let string = value as? String { return Int64(string) }
    return (value as? NSNumber)?.int64Value
  }
  static func int(_ value: Any?) -> Int { Int(int64(value) ?? 0) }
  static func url(_ value: Any?) -> URL? {
    guard let raw = value as? String, !raw.isEmpty,
      let url = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw),
      ["https", "http"].contains(url.scheme ?? ""), url.host != nil
    else { return nil }
    return url
  }
}
