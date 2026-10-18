import Foundation

public enum DownloadContent: String, Codable, CaseIterable, Sendable {
  case video, audio, cover, danmaku, subtitle
  public var title: String {
    switch self {
    case .video: return "下载视频"
    case .audio: return "仅下载音频"
    case .cover: return "下载封面"
    case .danmaku: return "下载弹幕"
    case .subtitle: return "下载字幕"
    }
  }
}
public enum DownloadCodec: String, Codable, CaseIterable, Sendable {
  case avc, hevc, av1
}
/// A resumable task plan contains media identifiers and preferences, never a signed URL or credentials.
public struct DownloadOptions: Codable, Equatable, Sendable {
  public var cid: Int64?
  public var episodeID: Int64?
  public var quality: Int
  public var codec: DownloadCodec
  public var content: DownloadContent
  public var pages: [Int]
  public var allPages: Bool
  public var directory: String
  public var includeDanmaku: Bool
  public var filterAISubtitle: Bool
  public var subtitleID: String?
  public var subtitleLanguage: String?
  public init(cid: Int64? = nil, episodeID: Int64? = nil, quality: Int = 80,
              codec: DownloadCodec = .avc, content: DownloadContent = .video,
              pages: [Int] = [], allPages: Bool = false, directory: String = "",
              includeDanmaku: Bool = false, filterAISubtitle: Bool = true,
              subtitleID: String? = nil, subtitleLanguage: String? = nil) {
    self.cid = cid; self.episodeID = episodeID; self.quality = quality; self.codec = codec
    self.content = content; self.pages = pages; self.allPages = allPages; self.directory = directory
    self.includeDanmaku = includeDanmaku; self.filterAISubtitle = filterAISubtitle
    self.subtitleID = subtitleID; self.subtitleLanguage = subtitleLanguage
  }
  /// Original selection syntax accepts comma-separated page numbers and inclusive ranges.
  public static func parsePages(_ text: String, count: Int) throws -> [Int] {
    guard count > 0, count <= 100_000 else { throw BiliError.invalidResponse("没有可下载的分集") }
    var pages = Set<Int>()
    for item in text.split(separator: ",", omittingEmptySubsequences: false) {
      let bounds = item.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "-", omittingEmptySubsequences: false)
      guard (1...2).contains(bounds.count), let start = Int(bounds[0]), start > 0,
        let end = Int(bounds.last!), end >= start, end <= count
      else { throw BiliError.invalidResponse("分集格式应为 1,3,5-8，序号不能超过分集数量") }
      pages.formUnion(start...end)
    }
    guard !pages.isEmpty else { throw BiliError.invalidResponse("请选择分集") }
    return pages.sorted()
  }
}
/// A copyable command only: never launches a process or reads login state.
public enum BBDownCommand {
  public static func build(source: String, options: DownloadOptions, executable: String = "BBDown",
                           ffmpeg: String? = nil, qualityDescription: String? = nil) throws -> String {
    let canonical: String
    if source.range(of: "^BV[0-9A-Za-z]+$", options: .regularExpression) != nil {
      canonical = "https://www.bilibili.com/video/" + source
    } else if source.range(of: "^(av|ep|ss)[0-9]+$", options: .regularExpression) != nil {
      canonical = "https://www.bilibili.com/" + (source.hasPrefix("av") ? "video/" : "bangumi/play/") + source
    } else if let url = URL(string: source), url.scheme == "https", url.host == "www.bilibili.com",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.range(of: "^/(video/(BV[0-9A-Za-z]+|av[0-9]+)|bangumi/play/(ep|ss)[0-9]+)/?$", options: .regularExpression) != nil {
      canonical = url.absoluteString
    } else { throw BiliError.invalidResponse("下载命令需要公开 BV、av、ep 或 ss 标识，不接受带凭据的 URL") }
    var arguments = [executable, "-e", options.codec.rawValue]
    if !options.directory.isEmpty { arguments += ["--work-dir", options.directory] }
    if let ffmpeg, !ffmpeg.isEmpty { arguments += ["--ffmpeg-path", ffmpeg] }
    switch options.content {
    case .video: arguments += ["-q", qualityDescription ?? String(options.quality)]
    case .audio: arguments += ["--audio-only"]
    case .cover: arguments += ["--cover-only"]
    case .danmaku: arguments += ["--danmaku-only"]
    case .subtitle:
      arguments += ["--sub-only"]
      if !options.filterAISubtitle { arguments += ["--skip-ai", "False"] }
    }
    if options.allPages { arguments += ["--select-page", "ALL"] }
    else if !options.pages.isEmpty {
      guard options.pages.allSatisfy({ $0 > 0 }) else { throw BiliError.invalidResponse("分集序号必须大于零") }
      arguments += ["--select-page", options.pages.map(String.init).joined(separator: ",")]
    }
    if options.content == .video, options.includeDanmaku { arguments += ["-dd"] }
    arguments.append(canonical)
    return arguments.map(shellQuote).joined(separator: " ")
  }
  public static func shellQuote(_ argument: String) -> String {
    "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
}
