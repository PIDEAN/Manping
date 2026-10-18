import Foundation
import XCTest
@testable import ManpingCore

private final class ArticleTestStore: AuthCredentialStore, @unchecked Sendable {
  private var token: AppToken?
  private var cookies: [HTTPCookie]
  init(authorized: Bool, csrf: Bool = true) {
    token = authorized ? AppToken(mid: 500, accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: 10_000) : nil
    cookies = authorized && csrf ? [
      HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: "bili_jct", .value: "fixture-csrf"])!,
      HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: "SESSDATA", .value: "fixture-session"])!,
    ] : []
  }
  func save(_ value: [HTTPCookie]) { cookies = value }
  func load() -> [HTTPCookie] { cookies }
  func saveToken(_ value: AppToken?) { token = value }
  func loadToken() -> AppToken? { token }
  func clear() { token = nil; cookies = [] }
}

private actor ArticleTestTransport: AuthTransport {
  var requests: [URLRequest] = []
  let rejectViewinfo: Bool
  init(rejectViewinfo: Bool = false) { self.rejectViewinfo = rejectViewinfo }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let fields = articleFields(request)
    let url = request.url!
    let body = (rejectViewinfo && url.path == "/x/article/viewinfo" ? Data(#"{"code":-352,"message":"fixture rejection"}"#.utf8) : M6ArticleFixture.response(path: url.path, parameters: fields))
      ?? (url.path == "/x/v2/reply/add" || url.path == "/x/v2/reply/action" ? Data(#"{"code":0,"data":{}}"#.utf8) : nil)
    guard let body else { throw URLError(.unsupportedURL) }
    return AuthHTTPResponse(body: body, response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private func articleFields(_ request: URLRequest) -> [String: String] {
  let raw = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? request.url?.query ?? ""
  let components = URLComponents(string: "https://fixture.invalid/?" + raw.replacingOccurrences(of: "+", with: "%20"))!
  return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

final class M6ArticleTests: XCTestCase, @unchecked Sendable {
  private func service(_ transport: ArticleTestTransport, authorized: Bool = false, csrf: Bool = true) async throws -> BiliService {
    let service = BiliService(transport: transport, credentials: ArticleTestStore(authorized: authorized, csrf: csrf),
      now: { Date(timeIntervalSince1970: 1000) })
    try await service.restoreCookies()
    return service
  }
  func testCategoriesRankAndShortRecommendationPagesUseExactRoutes() async throws {
    let transport = ArticleTestTransport(); let service = try await service(transport)
    let identity = await service.authSnapshot()
    let categories = try await service.articlePartitions(expectedIdentity: identity)
    XCTAssertEqual(categories.first?.children.map(\.id), [11, 12])
    let hot = try await service.articleHotCategories(expectedIdentity: identity)
    XCTAssertEqual(hot.map(\.id), [1, 2])
    let ranks = try await service.articleRanking(categoryID: 1, expectedIdentity: identity)
    XCTAssertEqual(ranks.count, 5)
    let first = try await service.articleFeed(expectedIdentity: identity)
    XCTAssertEqual(first.items.count, 20); XCTAssertEqual(first.ranks.count, 1); XCTAssertTrue(first.hasMore)
    let second = try await service.articleFeed(page: 2, expectedIdentity: identity)
    XCTAssertEqual(second.items.count, 4); XCTAssertTrue(second.hasMore, "Live short pages do not imply exhaustion")
    let final = try await service.articleFeed(page: 3, expectedIdentity: identity)
    XCTAssertTrue(final.items.isEmpty); XCTAssertFalse(final.hasMore)
    _ = try await service.articleFeed(categoryID: 11, sort: .reads, expectedIdentity: identity)
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url!.path }, ["/x/article/categories", "/x/article/rank/categories", "/x/article/rank/list",
      "/x/article/recommends/plus", "/x/article/recommends/plus", "/x/article/recommends/plus", "/x/article/recommends"])
    XCTAssertEqual(articleFields(requests[3])["pn"], "1")
    XCTAssertEqual(articleFields(requests[4])["pn"], "2")
    XCTAssertEqual(articleFields(requests[6])["sort"], "5")
    XCTAssertEqual(articleFields(requests[6])["cid"], "11")
    XCTAssertNil(articleFields(requests[3])["mid"])
  }
  func testNativeWrapperMergesViewinfoAndDoesNotExecuteHTML() async throws {
    let transport = ArticleTestTransport(); let service = try await service(transport)
    let identity = await service.authSnapshot()
    let detail = try await service.articleDetail(id: 100, expectedIdentity: identity)
    XCTAssertEqual(detail.article.id, 100)
    XCTAssertEqual(detail.article.stats.reads, 126_800, "viewinfo supersedes INITIAL_STATE statistics")
    XCTAssertFalse(detail.isLiked); XCTAssertFalse(detail.isFavorited)
    XCTAssertEqual(detail.tags, ["摄影", "旅行"])
    XCTAssertTrue(detail.blocks.contains { if case .image = $0 { true } else { false } })
    XCTAssertTrue(detail.blocks.contains { if case .text(_, let heading) = $0 { heading == 2 } else { false } })
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url!.path }, ["/read/native", "/x/article/viewinfo"])
    XCTAssertEqual(requests[0].url?.host, "www.bilibili.com")
    XCTAssertEqual(articleFields(requests[0]), ["id": "100"])
    XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(articleFields(requests[1])["id"], "100")
  }
  func testBalancedInitialStateAndLegacyBodyDiscardActiveContent() throws {
    let read: [String: Any] = ["id": 100, "title": "A }; quoted \" brace {", "author": ["mid": 500, "name": "Synthetic"],
      "publish_time": 1700000000, "content": #"<h2>A &amp; B</h2><p>Hello <strong>bold</strong> &#x1F600; <a href="javascript:alert(1)">safe text</a></p><script>DO_NOT_SHOW</script><iframe src="https://untrusted.invalid">HIDDEN</iframe><img data-src="//fixture.invalid/cover/1" src="data:invalid"/><p><a href="https://www.bilibili.com/video/av123">Video</a></p>"#]
    let encoded = try JSONSerialization.data(withJSONObject: ["readInfo": read])
    let html = "<script>window.__INITIAL_STATE__ = " + String(decoding: encoded, as: UTF8.self) + "; window.NOT_EXECUTED();</script>"
    let state = try ArticleContentParser.initialState(html)
    let detail = try ArticleContentParser.detail(id: 100, state: state,
      view: ["like": 1, "favorite": true, "attention": true, "coin": 1, "stats": ["view": 9]])
    XCTAssertEqual(detail.article.title, "A }; quoted \" brace {")
    XCTAssertTrue(detail.isLiked); XCTAssertTrue(detail.isFavorited); XCTAssertTrue(detail.isFollowing)
    XCTAssertEqual(detail.contributedCoins, 1)
    let text = detail.blocks.compactMap { block -> String? in
      if case .text(let runs, _) = block { return runs.map(\.text).joined() }; return nil
    }.joined(separator: " ")
    XCTAssertTrue(text.contains("A & B")); XCTAssertTrue(text.contains("😀"))
    XCTAssertFalse(text.contains("DO_NOT_SHOW")); XCTAssertFalse(text.contains("HIDDEN"))
    XCTAssertTrue(detail.blocks.contains(.image(URL(string: "https://fixture.invalid/cover/1")!, caption: nil)))
    let links = detail.blocks.flatMap { block -> [URL] in
      if case .text(let runs, _) = block { return runs.compactMap(\.link) }; return []
    }
    XCTAssertEqual(links.map(\.scheme), ["https"])
    XCTAssertThrowsError(try ArticleContentParser.detail(id: 101, state: state, view: ["stats": [:]]))
    XCTAssertThrowsError(try ArticleContentParser.initialState("<script>window.__INITIAL_STATE__ = {\"readInfo\": {}"))
  }
  func testDeniedViewinfoPreservesNativeBodyWithoutAssumingInteractionState() async throws {
    let transport = ArticleTestTransport(rejectViewinfo: true); let service = try await service(transport)
    let identity = await service.authSnapshot()
    let detail = try await service.articleDetail(id: 100, expectedIdentity: identity)
    XCTAssertFalse(detail.blocks.isEmpty)
    XCTAssertEqual(detail.article.stats.reads, 136_800)
    XCTAssertFalse(detail.interactionStateAvailable)
    XCTAssertNotNil(detail.metadataWarning)
  }
  func testStructuredOpusAndCurrentNativeEmptyOpusFallback() throws {
    let opus: [String: Any] = ["content": ["paragraphs": [
      ["para_type": 1, "text": ["nodes": [["node_type": 1, "word": ["words": "Original opus", "style": ["bold": true]]]]]],
      ["para_type": 2, "pic": ["pics": [["url": "//fixture.invalid/cover/2", "width": 800, "height": 600]]]],
      ["para_type": 3, "line": [:]],
    ]]]
    var read: [String: Any] = ["id": 100, "title": "A", "opus": opus, "content": "<p>Legacy</p>"]
    let view: [String: Any] = ["stats": ["coin": 12, "view": 34], "like": 0, "favorite": false]
    let structured = try ArticleContentParser.detail(id: 100, state: ["readInfo": read], view: view)
    XCTAssertEqual(structured.blocks, [.text([ArticleInlineText("Original opus", bold: true)], heading: nil),
      .image(URL(string: "https://fixture.invalid/cover/2")!, caption: nil), .divider])
    // Projected live wrapper: opus paragraphs are present, but text objects contain no nodes.
    read["opus"] = ["content": ["paragraphs": [["para_type": 1, "format": ["align": 0], "text": [:]]]]]
    let native = try ArticleContentParser.detail(id: 100, state: ["readInfo": read, "readViewInfo": [:], "dynamicId": "synthetic"], view: view)
    XCTAssertEqual(native.blocks, [.text([ArticleInlineText("Legacy")], heading: nil)])
    XCTAssertEqual(native.article.stats.coins, 12)
  }
  func testArticleWritesUseCSRFAndArticleCommentTargetOnlyInFixture() async throws {
    let transport = ArticleTestTransport(); let service = try await service(transport, authorized: true)
    let identity = await service.authSnapshot()
    _ = try await service.articleFeed(expectedIdentity: identity)
    try await service.setArticleLiked(id: 100, liked: true, expectedIdentity: identity)
    try await service.setArticleLiked(id: 100, liked: false, expectedIdentity: identity)
    try await service.setArticleFavorited(id: 100, favorited: true, expectedIdentity: identity)
    try await service.setArticleFavorited(id: 100, favorited: false, expectedIdentity: identity)
    try await service.sendArticleComment(id: 100, message: "Fixture comment", expectedIdentity: identity)
    try await service.setArticleCommentLiked(id: 100, replyID: 200, liked: true, expectedIdentity: identity)
    let requests = await transport.requests
    XCTAssertEqual(articleFields(requests[0])["mid"], "500")
    XCTAssertEqual(requests[1].httpMethod, "POST")
    XCTAssertEqual(articleFields(requests[1])["type"], "1")
    XCTAssertEqual(articleFields(requests[2])["type"], "2")
    XCTAssertEqual(articleFields(requests[1])["csrf"], "fixture-csrf")
    XCTAssertTrue(requests[1].value(forHTTPHeaderField: "Cookie")?.contains("bili_jct=fixture-csrf") == true)
    XCTAssertEqual(requests[3].url?.path, "/x/article/favorites/add")
    XCTAssertEqual(requests[4].url?.path, "/x/article/favorites/del")
    XCTAssertEqual(articleFields(requests[5])["type"], "12")
    XCTAssertEqual(articleFields(requests[6])["oid"], "100")
    XCTAssertEqual(articleFields(requests[6])["type"], "12")
  }
  func testArticleMutationRejectsMissingCSRFAndStaleIdentityBeforeSending() async throws {
    let transport = ArticleTestTransport(); let service = try await service(transport, authorized: true, csrf: false)
    let identity = await service.authSnapshot()
    do { try await service.setArticleLiked(id: 100, liked: true, expectedIdentity: identity); XCTFail("Missing CSRF must fail") }
    catch AuthFailure.missingCSRF {}
    let before = await transport.requests
    XCTAssertTrue(before.isEmpty)
    try await service.logout()
    do { try await service.setArticleFavorited(id: 100, favorited: true, expectedIdentity: identity); XCTFail("Stale account must fail") }
    catch is CancellationError {}
    let after = await transport.requests
    XCTAssertTrue(after.isEmpty)
  }
}
