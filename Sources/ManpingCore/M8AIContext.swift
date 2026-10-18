import Foundation

public enum AIContextSource: Equatable, Sendable {
  case video(aid: Int64, cid: Int64, title: String, description: String)
  case article(id: Int64, title: String, content: String)
  public var identifier: String {
    switch self {
    case .video(let aid, let cid, _, _): "video:\(aid):\(cid)"
    case .article(let id, _, _): "article:\(id)"
    }
  }
  public var title: String {
    switch self { case .video(_, _, let title, _), .article(_, let title, _): title }
  }
  public var isArticle: Bool { if case .article = self { return true }; return false }
  public static func article(_ detail: ArticleDetail) -> Self {
    let text = detail.blocks.compactMap { block -> String? in
      if case .text(let spans, _) = block { return spans.map(\.text).joined() }
      return nil
    }.joined(separator: " ")
    return .article(id: detail.article.id, title: detail.article.title, content: normalizedArticle(text))
  }
  public static func normalizedArticle(_ text: String) -> String {
    text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct AIPromptContext: Equatable, Sendable {
  public let values: [String: String]
  public init(source: AIContextSource, subtitle: String = "无字幕", comments: String = "无评论", question: String = "") {
    switch source {
    case .video(_, _, let title, let description):
      values = ["title": title, "description": description, "subtitle": subtitle, "comments": comments, "question": question]
    case .article(_, let title, let content):
      values = ["title": title, "content": AIContextSource.normalizedArticle(content), "comments": comments, "question": question]
    }
  }
  public static func subtitleText(_ cues: [DownloadSubtitleCue]) -> String {
    cues.map { "\(duration($0.start)) - \(duration($0.end)): \($0.text)" }.joined(separator: "\n")
  }
  public static func hotCommentText(_ texts: [String]) -> String {
    var result = ""
    for text in texts {
      let item = text + "\n------"
      // .NET string.Length counts UTF-16 code units. Preserve the source's whole-comment cap.
      if result.utf16.count + item.utf16.count > 800 { break }
      result += item
    }
    return result.isEmpty ? "无评论" : result
  }
  private static func duration(_ value: Double) -> String {
    guard value.isFinite, value >= 0, value < 86_400_000 else { return "00:00" }
    let seconds = Int(value)
    return seconds >= 3600
      ? String(format: "%02d:%02d:%02d", (seconds / 3600) % 24, (seconds / 60) % 60, seconds % 60)
      : String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

extension BiliService {
  public func aiPromptContext(source: AIContextSource, task: AIPromptTask, question: String = "",
    rpc: (any BiliRPCService)?, expectedIdentity: AuthSnapshot) async throws -> AIPromptContext {
    try checkRESTIdentity(expectedIdentity)
    guard source.isArticle == task.isArticle else { throw BiliError.invalidResponse("AI 上下文类型与提示词不匹配") }
    var subtitle = "无字幕", comments = "无评论"
    let oid: Int64, targetType: Int32
    switch source {
    case .video(let aid, let cid, _, _):
      guard aid > 0, cid > 0 else { throw BiliError.invalidResponse("AI 视频上下文缺少视频或分集标识") }
      oid = aid; targetType = 1
      let tracks = try await downloadSubtitleTracks(aid: aid, cid: cid, expectedIdentity: expectedIdentity)
      try Task.checkCancellation(); try checkRESTIdentity(expectedIdentity)
      if let track = tracks.first(where: { !$0.isAI }) ?? tracks.first {
        let cues = try await downloadSubtitleCues(track: track, expectedIdentity: expectedIdentity)
        try Task.checkCancellation(); try checkRESTIdentity(expectedIdentity)
        subtitle = cues.isEmpty ? "无字幕" : AIPromptContext.subtitleText(cues)
      }
    case .article(let id, _, let content):
      guard id > 0, !AIContextSource.normalizedArticle(content).isEmpty else { throw BiliError.invalidResponse("文章正文为空，无法生成 AI 响应") }
      oid = id; targetType = 12
    }
    if task.needsComments {
      guard let rpc else { throw BiliError.dependency("评论服务不可用，请稍后重试") }
      let page = try await rpc.comments(oid: oid, targetType: targetType, sort: .hot, next: 0)
      try Task.checkCancellation(); try checkRESTIdentity(expectedIdentity)
      comments = AIPromptContext.hotCommentText(page.comments.map(\.text))
    }
    try Task.checkCancellation(); try checkRESTIdentity(expectedIdentity)
    return AIPromptContext(source: source, subtitle: subtitle, comments: comments, question: question)
  }
}
