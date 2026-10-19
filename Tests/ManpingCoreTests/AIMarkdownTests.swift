import Foundation
import XCTest
@testable import ManpingCore

final class AIMarkdownTests: XCTestCase {
  func testParsesAnswerBlocksAndLinksOnlySupportedTimes() {
    let text = "# Title\n\nparagraph **bold**\n\n- first\n  - nested\n\n> quote\n\n```\nraw\n```\n\n| A | B |\n| --- | --- |\n| x | y |\n\n---"
    XCTAssertEqual(AIMarkdownBlock.parse(text), [
      .heading(1, "Title"), .paragraph("paragraph **bold**"),
      .list([.init(text: "first", depth: 0), .init(text: "nested", depth: 1)], ordered: false),
      .quote("quote"), .code("raw"), .table(["A", "B"], [["x", "y"]]), .rule,
    ])
    XCTAssertEqual(AIMarkdownBlock.linkTimes("00:10 `00:20` 02:00", duration: 30),
      "[00:10](manping-seek://10) `00:20` 02:00")
  }

  @MainActor func testRepeatedPanelUpdatesReuseAllParsingAndSeekInputsInvalidateInline() {
    let cache = AIMarkdownParseCache()
    let text = "## 认同\n**观点** 00:10\n## 分歧\n没有"
    for _ in 0..<100 {
      XCTAssertEqual(cache.blocks(text).count, 4)
      XCTAssertEqual(cache.comments(text)?.sections.count, 2)
      let attributed = cache.inline("**观点** 00:10", seekable: true, duration: 30)
      XCTAssertTrue(attributed.runs.contains { $0.link?.scheme == AIMarkdownBlock.seekScheme })
    }
    XCTAssertEqual(cache.blockParses, 1)
    XCTAssertEqual(cache.commentParses, 1)
    XCTAssertEqual(cache.inlineParses, 1)
    let disabled = cache.inline("**观点** 00:10", seekable: false, duration: 30)
    XCTAssertFalse(disabled.runs.contains { $0.link != nil })
    let shortened = cache.inline("**观点** 00:10", seekable: true, duration: 5)
    XCTAssertFalse(shortened.runs.contains { $0.link != nil })
    XCTAssertEqual(cache.inlineParses, 3)
    _ = cache.blocks(text + "!")
    _ = cache.comments(text + "!")
    XCTAssertEqual(cache.blockParses, 2)
    XCTAssertEqual(cache.commentParses, 2)
    // A rejected comment layout is cached as well.
    XCTAssertNil(cache.comments("plain")); XCTAssertNil(cache.comments("plain"))
    XCTAssertEqual(cache.commentParses, 3)
  }

  @MainActor func testCacheBoundsStreamingAndOversizedText() {
    let cache = AIMarkdownParseCache(maximumBytes: 64, maximumEntries: 2)
    for index in 0..<100 { _ = cache.inline("delta \(index)", seekable: false, duration: nil) }
    XCTAssertLessThanOrEqual(cache.inlineEntryCount, 2)
    let text = String(repeating: "x", count: 65)
    _ = cache.blocks(text); _ = cache.blocks(text)
    XCTAssertEqual(cache.blockParses, 2)
    _ = cache.inline(text, seekable: false, duration: nil)
    let parses = cache.inlineParses
    _ = cache.inline(text, seekable: false, duration: nil)
    XCTAssertEqual(cache.inlineParses, parses + 1)
  }
}
