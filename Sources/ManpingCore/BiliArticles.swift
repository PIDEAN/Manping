import Foundation

extension BiliService {
  public func articlePartitions(expectedIdentity: AuthSnapshot) async throws -> [ArticlePartition] {
    guard let raw = try await appREST(.articleCategories, expectedIdentity: expectedIdentity) as? [[String: Any]],
      raw.count <= 200 else { throw BiliError.invalidResponse("Missing article partitions") }
    try checkRESTIdentity(expectedIdentity)
    return try raw.map { try ArticleParsing.partition($0) }
  }
  public func articleHotCategories(expectedIdentity: AuthSnapshot) async throws -> [ArticlePartition] {
    guard let raw = try await appREST(.articleHotCategories, expectedIdentity: expectedIdentity) as? [[String: Any]],
      raw.count <= 200 else { throw BiliError.invalidResponse("Missing article rank categories") }
    try checkRESTIdentity(expectedIdentity)
    return try raw.map { try ArticleParsing.partition($0) }
  }
  public func articleRanking(categoryID: Int64, expectedIdentity: AuthSnapshot) async throws -> [ArticleSummary] {
    guard categoryID >= 0 else { throw BiliError.invalidResponse("Invalid article category") }
    guard let raw = try await appREST(.articleRanking, fields: ["cid": String(categoryID)],
      expectedIdentity: expectedIdentity) as? [[String: Any]] else {
      throw BiliError.invalidResponse("Missing article ranking")
    }
    try checkRESTIdentity(expectedIdentity)
    return try ArticleParsing.summaries(raw)
  }
  public func articleFeed(categoryID: Int64? = nil, sort: ArticleSort = .recommended,
    page: Int = 1, expectedIdentity: AuthSnapshot) async throws -> ArticleFeedPage {
    guard (1...1_000_000).contains(page), categoryID.map({ $0 >= 0 }) ?? true else {
      throw BiliError.invalidResponse("Invalid article page/category")
    }
    var fields = ["cid": String(categoryID ?? 0), "pn": String(page), "ps": "20"]
    if categoryID != nil { fields["sort"] = String(sort.rawValue) }
    if let token = expectedIdentity.token { fields["mid"] = String(token.mid) }
    let data = try await appREST(categoryID == nil ? .articleRecommend : .articleList,
      fields: fields, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    let raw: [[String: Any]]
    let ranks: [[String: Any]]
    if categoryID == nil {
      guard let payload = data as? [String: Any], let articles = payload["articles"] as? [[String: Any]] else {
        throw BiliError.invalidResponse("Missing article recommendations")
      }
      raw = articles; ranks = payload["ranks"] as? [[String: Any]] ?? []
    } else {
      guard let articles = data as? [[String: Any]] else { throw BiliError.invalidResponse("Missing partition articles") }
      raw = articles; ranks = []
    }
    return ArticleFeedPage(items: try ArticleParsing.summaries(raw),
      // Live pages can contain fewer than ps=20 items before the feed is exhausted.
      ranks: try ArticleParsing.summaries(ranks), hasMore: !raw.isEmpty)
  }
  public func articleDetail(id: Int64, expectedIdentity: AuthSnapshot) async throws -> ArticleDetail {
    guard id > 0 else { throw BiliError.invalidResponse("Invalid article identifier") }
    let html = try await articleNativeHTML(id: id, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    let state = try ArticleContentParser.initialState(html)
    do {
      let view = try await appObject(.articleView, fields: ["id": String(id)], expectedIdentity: expectedIdentity)
      try checkRESTIdentity(expectedIdentity)
      return try ArticleContentParser.detail(id: id, state: state, view: view)
    } catch is CancellationError { throw CancellationError() }
    catch {
      try Task.checkCancellation()
      try checkRESTIdentity(expectedIdentity)
      // A denied/unavailable viewinfo must not discard the already retrieved public body.
      return try ArticleContentParser.detail(id: id, state: state, view: nil)
    }
  }
}

// Extract data only. Article HTML and INITIAL_STATE scripts are never executed.
enum ArticleContentParser {
  static func initialState(_ html: String) throws -> [String: Any] {
    guard html.utf8.count <= 8 * 1024 * 1024,
      let marker = html.range(of: "window.__INITIAL_STATE__") else {
      throw BiliError.invalidResponse("Missing article INITIAL_STATE")
    }
    let bytes = Array(html[marker.upperBound...].utf8)
    var index = 0
    func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
    while index < bytes.count && whitespace(bytes[index]) { index += 1 }
    guard index < bytes.count, bytes[index] == 61 else { throw BiliError.invalidResponse("Invalid article state assignment") }
    index += 1
    while index < bytes.count && whitespace(bytes[index]) { index += 1 }
    guard index < bytes.count, bytes[index] == 123 else { throw BiliError.invalidResponse("Invalid article state object") }
    let start = index
    var depth = 0; var quoted = false; var escaped = false
    while index < bytes.count {
      let byte = bytes[index]
      if quoted {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false }
      } else if byte == 34 { quoted = true }
      else if byte == 123 {
        depth += 1
        guard depth <= 128 else { throw BiliError.invalidResponse("Article state is too deeply nested") }
      } else if byte == 125 {
        depth -= 1
        if depth == 0 {
          guard let state = try JSONSerialization.jsonObject(with: Data(bytes[start...index])) as? [String: Any] else {
            throw BiliError.invalidResponse("Invalid article state JSON")
          }
          return state
        }
      }
      index += 1
    }
    throw BiliError.invalidResponse("Incomplete article INITIAL_STATE")
  }

  static func detail(id: Int64, state: [String: Any], view: [String: Any]?) throws -> ArticleDetail {
    guard var read = state["readInfo"] as? [String: Any], JSONValue.int64(read["id"]) == id else {
      throw BiliError.invalidResponse("Article content identifier mismatch")
    }
    // Viewinfo supplies current statistics and account state; INITIAL_STATE supplies the body.
    if let view {
      guard let stats = view["stats"] as? [String: Any] else { throw BiliError.invalidResponse("Missing article view statistics") }
      read["stats"] = stats
    }
    let article = try ArticleParsing.summary(read)
    let blocks: [ArticleBodyBlock]
    if let opus = read["opus"] as? [String: Any] {
      let decoded = try opusBlocks(opus)
      // Current native responses can expose empty opus text objects alongside full legacy HTML.
      blocks = decoded.isEmpty ? try htmlBlocks(read["content"] as? String ?? "") : decoded
    } else if let content = read["content"] as? String {
      blocks = try htmlBlocks(content)
    } else { throw BiliError.invalidResponse("Missing article body") }
    guard !blocks.isEmpty else { throw BiliError.invalidResponse("Article body is empty or unavailable") }
    let tags = (read["tags"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    let stateAvailable = JSONValue.int64(view?["like"]) != nil && view?["favorite"] is Bool
    return ArticleDetail(article: article, blocks: blocks, tags: Array(tags.prefix(100)),
      isLiked: JSONValue.int(view?["like"]) > 0, isFavorited: view?["favorite"] as? Bool ?? false,
      isFollowing: view?["attention"] as? Bool ?? false, contributedCoins: max(0, JSONValue.int(view?["coin"])),
      interactionStateAvailable: stateAvailable,
      metadataWarning: !stateAvailable ? (view == nil ? "互动状态暂时无法获取；统计来自文章正文，点赞和收藏暂不可用。" : "互动状态不完整；点赞和收藏暂不可用。") : nil)
  }

  static func opusBlocks(_ opus: [String: Any]) throws -> [ArticleBodyBlock] {
    guard let content = opus["content"] as? [String: Any],
      let paragraphs = content["paragraphs"] as? [[String: Any]], paragraphs.count <= 4000 else {
      throw BiliError.invalidResponse("Invalid article opus paragraphs")
    }
    var blocks: [ArticleBodyBlock] = []
    for paragraph in paragraphs {
      switch JSONValue.int(paragraph["para_type"]) {
      case 1:
        let text = paragraph["text"] as? [String: Any] ?? [:]
        let nodes = text["nodes"] as? [[String: Any]] ?? []
        guard nodes.count <= 4000 else { throw BiliError.invalidResponse("Too many article text nodes") }
        let runs = nodes.compactMap { node -> ArticleInlineText? in
          guard let word = node["word"] as? [String: Any], let words = word["words"] as? String,
            words != "\\n", !words.isEmpty else { return nil }
          let style = word["style"] as? [String: Any] ?? [:]
          return ArticleInlineText(words, bold: style["bold"] as? Bool ?? false)
        }
        if !runs.isEmpty { blocks.append(.text(runs, heading: nil)) }
      case 2:
        let pic = paragraph["pic"] as? [String: Any] ?? [:]
        let pictures = pic["pics"] as? [[String: Any]] ?? []
        guard pictures.count <= 1000 else { throw BiliError.invalidResponse("Too many article pictures") }
        for picture in pictures {
          if let url = JSONValue.url(picture["url"]) { blocks.append(.image(url, caption: nil)) }
        }
      case 3:
        let line = paragraph["line"] as? [String: Any] ?? [:]
        let pic = line["pic"] as? [String: Any] ?? [:]
        if let url = JSONValue.url(pic["url"]) { blocks.append(.image(url, caption: nil)) }
        else { blocks.append(.divider) }
      default: continue
      }
      guard blocks.count <= 4000 else { throw BiliError.invalidResponse("Too many article body blocks") }
    }
    return blocks
  }

  static func htmlBlocks(_ html: String) throws -> [ArticleBodyBlock] {
    guard html.utf8.count <= 8 * 1024 * 1024 else { throw BiliError.invalidResponse("Article body is too large") }
    let clean = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    let tokenizer = try NSRegularExpression(pattern: #"<(?:(?:"[^"]*")|(?:'[^']*')|[^'">])*>|[^<]+"#)
    let tokens = tokenizer.matches(in: clean, range: NSRange(clean.startIndex..., in: clean))
    guard tokens.count <= 100_000 else { throw BiliError.invalidResponse("Too many article HTML tokens") }
    var blocks: [ArticleBodyBlock] = []; var runs: [ArticleInlineText] = []
    var bold = 0; var italic = 0; var heading: Int?
    var links: [URL?] = []; var blocked: String?
    let blockTags: Set<String> = ["p", "div", "section", "article", "blockquote", "ul", "ol", "li", "pre", "figure", "figcaption", "h1", "h2", "h3", "h4", "h5", "h6"]
    let hiddenTags: Set<String> = ["script", "style", "iframe", "object", "embed", "svg", "head", "noscript"]
    func flush() {
      if !runs.isEmpty, runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
        blocks.append(.text(runs, heading: heading))
      }
      runs = []
    }
    for match in tokens {
      guard let range = Range(match.range, in: clean) else { continue }
      let token = String(clean[range])
      if token.hasPrefix("<") {
        let closing = token.hasPrefix("</")
        let inner = token.dropFirst(closing ? 2 : 1).dropLast()
        let tag = inner.prefix { $0.isLetter || $0.isNumber }.lowercased()
        if let hidden = blocked {
          if closing && tag == hidden { blocked = nil }
          continue
        }
        if hiddenTags.contains(tag) { if !closing && !token.hasSuffix("/>") { blocked = tag }; continue }
        if blockTags.contains(tag) {
          flush()
          if tag.hasPrefix("h"), let level = Int(tag.dropFirst()), (1...6).contains(level) { heading = closing ? nil : level }
          if tag == "li" && !closing { runs.append(ArticleInlineText("• ")) }
        } else if tag == "br" { runs.append(ArticleInlineText("\n")) }
        else if tag == "hr" { flush(); blocks.append(.divider) }
        else if tag == "img" && !closing {
          flush()
          if let raw = attribute("data-src", in: token) ?? attribute("src", in: token), let url = JSONValue.url(raw) {
            blocks.append(.image(url, caption: attribute("alt", in: token).flatMap { $0.isEmpty ? nil : $0 }))
          }
        } else if ["strong", "b"].contains(tag) { bold = max(0, bold + (closing ? -1 : 1)) }
        else if ["em", "i"].contains(tag) { italic = max(0, italic + (closing ? -1 : 1)) }
        else if tag == "a" {
          if closing { if !links.isEmpty { links.removeLast() } }
          else { links.append(attribute("href", in: token).flatMap(safeLink)) }
        }
      } else if blocked == nil {
        let text = decodeEntities(token).replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
        if !text.isEmpty { runs.append(ArticleInlineText(text, bold: bold > 0, italic: italic > 0, link: links.last ?? nil)) }
      }
      guard blocks.count <= 4000 else { throw BiliError.invalidResponse("Too many article body blocks") }
    }
    flush()
    return blocks
  }
  private static func attribute(_ name: String, in token: String) -> String? {
    let pattern = #"(?i)(?:\s)"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) else { return nil }
    for index in 1...3 {
      if let range = Range(match.range(at: index), in: token) { return decodeEntities(String(token[range])) }
    }
    return nil
  }
  private static func safeLink(_ raw: String) -> URL? {
    let value = raw.hasPrefix("//") ? "https:" + raw : raw
    guard let url = URL(string: value), ["http", "https", "bilibili"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil else { return nil }
    return url
  }
  private static func decodeEntities(_ text: String) -> String {
    let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
      "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "\u{201C}", "rdquo": "\u{201D}"]
    guard let expression = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) else { return text }
    var result = text
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: result), let keyRange = Range(match.range(at: 1), in: text) else { continue }
      let key = String(text[keyRange]); let replacement: String?
      if key.hasPrefix("#x") { replacement = UInt32(key.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init) }
      else if key.hasPrefix("#") { replacement = UInt32(key.dropFirst()).flatMap(UnicodeScalar.init).map(String.init) }
      else { replacement = named[key] }
      if let replacement { result.replaceSubrange(range, with: replacement) }
    }
    return result
  }
}
