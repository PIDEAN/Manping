import XCTest
@testable import ManpingCore

final class DanmakuFilterTests: XCTestCase {
  private func line(_ text: String, mode: Int = 1, color: UInt32 = 0xffffff, weight: Int? = nil, at time: Double = 1) -> DanmakuComment {
    DanmakuComment(time: time, mode: mode, color: color, text: text, weight: weight)
  }

  func testKeywordsAreCaseInsensitiveSubstrings() {
    let matcher = DanmakuFilter(rules: ["前方高能", "awsl"]).compiled()
    XCTAssertFalse(matcher.allows(line("前方高能预警")))
    XCTAssertFalse(matcher.allows(line("AWSL!!")))
    XCTAssertTrue(matcher.allows(line("这段配乐真好听")))
  }

  func testRegexRulesAndValidation() {
    let matcher = DanmakuFilter(rules: ["/^[0-9]+$/", "/哈{3,}/"]).compiled()
    XCTAssertFalse(matcher.allows(line("23333")))
    XCTAssertFalse(matcher.allows(line("哈哈哈哈")))
    XCTAssertTrue(matcher.allows(line("2333 好看")))
    XCTAssertEqual(DanmakuFilter.validate("  /a(b/  "), .failure(.invalidRegex))
    XCTAssertEqual(DanmakuFilter.validate("   "), .failure(.empty))
    XCTAssertEqual(DanmakuFilter.validate(String(repeating: "长", count: 201)), .failure(.tooLong))
    XCTAssertEqual(DanmakuFilter.validate(" /a+/ "), .success("/a+/"))
    // An invalid pattern stored earlier is skipped, not applied as a keyword.
    XCTAssertTrue(DanmakuFilter(rules: ["/a(b/"]).compiled().allows(line("/a(b/")))
  }

  func testTypesColorAndSmartLevel() {
    let matcher = DanmakuFilter(hideTop: true, hideBottom: true, hideColored: true, level: 5).compiled()
    XCTAssertFalse(matcher.allows(line("顶", mode: 5)))
    XCTAssertFalse(matcher.allows(line("底", mode: 4)))
    XCTAssertFalse(matcher.allows(line("彩", color: 0xff0000)))
    XCTAssertFalse(matcher.allows(line("低分", weight: 2)))
    XCTAssertTrue(matcher.allows(line("高分", weight: 8)))
    XCTAssertTrue(matcher.allows(line("无等级（直播）")))
    XCTAssertFalse(DanmakuFilter(hideScrolling: true).compiled().allows(line("滚")))
  }

  func testTimelineAppliesAndReappliesTheFilter() throws {
    let comments = try DanmakuParser.parse(Data(
      "<i><d p=\"1,1,25,16777215,0,0,abc,1,9\">好看</d><d p=\"1.5,1,25,16777215,0,0,abc,2,1\">刷屏</d><d p=\"2,1,25,16777215\">前方高能</d></i>".utf8))
    XCTAssertEqual(comments.map(\.weight), [9, 1, nil])
    var timeline = DanmakuTimeline(comments: comments, lanes: 4, duration: 8)
    XCTAssertEqual(timeline.count, 3)
    timeline.setFilter(DanmakuFilter(rules: ["前方"], level: 3))
    XCTAssertEqual(timeline.visible(at: 3).map(\.comment.text), ["好看"])
    // Live lines arriving later are shielded too.
    timeline.append(DanmakuComment(time: 4, text: "前方注意"))
    timeline.append(DanmakuComment(time: 4.1, text: "主播好"))
    XCTAssertEqual(timeline.visible(at: 5).map(\.comment.text), ["好看", "主播好"])
    timeline.setFilter(DanmakuFilter())
    XCTAssertEqual(timeline.visible(at: 5).count, 5)
  }

  func testFilterRoundTripsThroughJSON() throws {
    let filter = DanmakuFilter(rules: ["a", "/b+/"], hideTop: true, level: 4)
    let decoded = try JSONDecoder().decode(DanmakuFilter.self, from: JSONEncoder().encode(filter))
    XCTAssertEqual(decoded, filter)
  }

  func testDensityPeaksWhereCommentsCluster() {
    let comments = (0..<30).map { DanmakuComment(time: 50 + Double($0) * 0.1, text: "高能") }
      + (0..<5).map { DanmakuComment(time: 10 + Double($0), text: "前面") }
    let density = DanmakuTimeline(comments: comments).density(duration: 100, bins: 10)
    XCTAssertEqual(density.count, 10)
    XCTAssertTrue((4...6).contains(density.firstIndex(of: 1) ?? -1), "smoothing spreads the peak over its neighbours")
    XCTAssertLessThan(density[1], 0.5)
    XCTAssertTrue(DanmakuTimeline(comments: Array(comments.prefix(5))).density(duration: 100).isEmpty, "too few to draw")
    XCTAssertTrue(DanmakuTimeline(comments: comments).density(duration: 0).isEmpty)
  }

  func testCatastrophicPatternsAreRejectedAndBoundedAtRuntime() {
    XCTAssertEqual(DanmakuFilter.validate("/^(a+)+$/"), .failure(.tooComplex))
    XCTAssertEqual(DanmakuFilter.validate("/(哈|哈哈)+$/"), .failure(.tooComplex))
    XCTAssertEqual(DanmakuFilter.validate("/^[0-9]+$/"), .success("/^[0-9]+$/"))
    // A stored rule that predates validation: matching stays bounded and the rule switches off.
    let matcher = DanmakuFilter(rules: ["/^(a+)+$/", "刷屏"]).compiled()
    let started = Date()
    for _ in 0..<200 {
      XCTAssertTrue(matcher.allows(DanmakuComment(time: 1, text: String(repeating: "a", count: 160) + "!")))
    }
    XCTAssertFalse(matcher.allows(DanmakuComment(time: 1, text: "别刷屏了")))
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
  }

  func testAccountShieldParsesKeywordsPatternsAndUsers() throws {
    XCTAssertThrowsError(try DanmakuAccountShield.parse(["limit": 5000]))
    XCTAssertThrowsError(try DanmakuAccountShield.parse(["rule": "x"]))
    XCTAssertEqual(try DanmakuAccountShield.parse(["rule": NSNull()]).count, 0)
    let shield = try DanmakuAccountShield.parse(["rule": [
      ["id": 1, "type": 0, "filter": "剧透"], ["id": 2, "type": 1, "filter": "^哈+$"],
      ["id": 3, "type": 1, "filter": "^(a+)+$"], ["id": 4, "type": 2, "filter": "ABCDEF12"],
      ["id": 5, "type": 0, "filter": "剧透"], ["id": 6, "type": 9, "filter": "x"], ["id": 7, "type": 0, "filter": "  "],
    ] as [[String: Any]]])
    XCTAssertEqual(shield.keywords, ["剧透"])
    XCTAssertEqual(shield.patterns, ["^哈+$"])
    XCTAssertEqual(shield.users, ["abcdef12"])
    XCTAssertEqual(shield.skipped, 1)
    let comments = try DanmakuParser.parse(Data(
      "<i><d p=\"1,1,25,16777215,0,0,abcdef12,1,9\">普通内容</d><d p=\"1,1,25,16777215,0,0,99999999,2,9\">普通内容</d></i>".utf8))
    XCTAssertEqual(comments.map(\.userHash), ["abcdef12", "99999999"])
    var filter = DanmakuFilter(); filter.account = shield
    let matcher = filter.compiled()
    XCTAssertFalse(matcher.allows(comments[0]), "blocked user")
    XCTAssertTrue(matcher.allows(comments[1]))
    XCTAssertFalse(matcher.allows(DanmakuComment(time: 1, text: "前方剧透")))
    XCTAssertFalse(matcher.allows(DanmakuComment(time: 1, text: "哈哈哈")))
    filter.account?.enabled = false
    XCTAssertTrue(filter.compiled().allows(comments[0]), "off: account rules ignored")
  }
}
