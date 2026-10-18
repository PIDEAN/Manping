import XCTest
@testable import ManpingCore

final class BiliLinkParserTests: XCTestCase {
  func testWebLinks() {
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/video/BV1fK4y1t7hj/?spm_id_from=333&p=2"), .video(bvid: "BV1fK4y1t7hj"))
    XCTAssertEqual(BiliLinkParser.parse("https://m.bilibili.com/video/av170001"), .archive(aid: 170001))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/bangumi/play/ep837204"), .episode(837204))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/bangumi/play/ss12345?from=x"), .season(12345))
    XCTAssertEqual(BiliLinkParser.parse("https://live.bilibili.com/24530995?visit_id=1"), .live(24530995))
    XCTAssertEqual(BiliLinkParser.parse("https://live.bilibili.com/h5/7734200"), .live(7734200))
    XCTAssertEqual(BiliLinkParser.parse("https://space.bilibili.com/2/dynamic"), .space(2))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/read/cv123456/"), .article(123456))
    XCTAssertEqual(BiliLinkParser.parse("https://b23.tv/AbC123"), .short(URL(string: "https://b23.tv/AbC123")!))
  }

  func testShareTextIdentifiersAndAppScheme() {
    XCTAssertEqual(BiliLinkParser.parse("【4K 120FPS】你的设备顶得住吗？ https://b23.tv/xyz 复制打开"), .short(URL(string: "https://b23.tv/xyz")!))
    XCTAssertEqual(BiliLinkParser.parse("  bv1fK4y1t7hj "), .video(bvid: "BV1fK4y1t7hj"))
    XCTAssertEqual(BiliLinkParser.parse("AV170001"), .archive(aid: 170001))
    XCTAssertEqual(BiliLinkParser.parse("ss456"), .season(456))
    XCTAssertEqual(BiliLinkParser.parse("manping://video/BV1fK4y1t7hj"), .video(bvid: "BV1fK4y1t7hj"))
    XCTAssertEqual(BiliLinkParser.parse("manping://live/24530995"), .live(24530995))
    XCTAssertEqual(BiliLinkParser.parse("manping://article/cv42"), .article(42))
  }

  func testRejectsForeignAndMalformedLinks() {
    for text in ["https://evil.example/video/BV1fK4y1t7hj", "https://www.bilibili.com.evil.example/video/BV1fK4y1t7hj",
      "https://user:pass@www.bilibili.com/video/BV1fK4y1t7hj", "ftp://www.bilibili.com/video/BV1fK4y1t7hj",
      "https://www.bilibili.com/video/BV1short", "av0", "ep-1", "manping://video/../../etc", "manping://unknown/1",
      "https://b23.tv/a/b", "随便一段文字", "", String(repeating: "a", count: 3000)] {
      XCTAssertNil(BiliLinkParser.parse(text), text)
    }
    XCTAssertTrue(BiliLinkParser.isBilibili(URL(string: "https://www.bilibili.com/video/BV1fK4y1t7hj")!))
    XCTAssertFalse(BiliLinkParser.isBilibili(URL(string: "https://bilibili.com.evil.example/")!))
    XCTAssertFalse(BiliLinkParser.isBilibili(URL(string: "http://notbilibili.com/")!))
  }
}
