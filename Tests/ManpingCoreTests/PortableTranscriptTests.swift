import Foundation
import XCTest
@testable import ManpingCore

final class PortableTranscriptTests: XCTestCase {
  func testCleaningPreservesSourceRangesAndStableIDs() {
    let cues = [DownloadSubtitleCue(start: 0, end: 2, text: "大家好"),
      .init(start: 2.5, end: 4, text: "今天去爬山"), .init(start: 4.2, end: 5, text: "嗯"),
      .init(start: 10, end: 12, text: "出发"), .init(start: 12.1, end: 13, text: "出发"),
      .init(start: 62.8, end: 3605.9, text: "很长的一句"), .init(start: 3700, end: 3701, text: "。。。")]
    let result = AITranscript.clean(cues, language: "zh", isAI: false)
    XCTAssertEqual(result.cues, [
      .init(id: "c1", start: 0, end: 4, text: "大家好，今天去爬山"),
      .init(id: "c2", start: 10, end: 13, text: "出发"),
      .init(id: "c3", start: 62.8, end: 3605.9, text: "很长的一句"),
    ])
    XCTAssertEqual(AITranscript.render([result.cues[2]]), "[c3 01:02-1:00:05] 很长的一句")
  }

  func testFillerAndWhitespaceSemantics() {
    let inputs = ["嗯！", " U H ", "⚡️", "Hello\t\nworld", "你好\u{00a0}世界", "café", "e\u{301}"]
    let cues = inputs.enumerated().map { DownloadSubtitleCue(start: Double($0.offset) * 20,
      end: Double($0.offset) * 20 + 1, text: $0.element) }
    let result = AITranscript.clean(cues, language: "zh", isAI: false)
    XCTAssertEqual(result.cues.map(\.text), ["⚡️", "Hello world", "你好 世界", "café", "e\u{301}"])
  }

  func testOrdinaryTimecodesAndInvalidInputs() {
    XCTAssertEqual(AITimecode.parse("1:00:05"), 3605)
    XCTAssertEqual(AITimecode.parse("03:52.5"), 232.5)
    XCTAssertNil(AITimecode.parse("03:75"))
    XCTAssertNil(AITimecode.parse(true))
    XCTAssertNil(AITimecode.parse(Double.nan))
    XCTAssertEqual(AITimecode.format(3605.9), "1:00:05")
  }
}
