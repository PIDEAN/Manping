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

  func testInvalidTimestampsAreRemovedBeforeSorting() {
    let cues: [DownloadSubtitleCue] = [
      .init(start: 10, end: 11, text: "late"), .init(start: .nan, end: 2, text: "invalid"),
      .init(start: 0, end: 1, text: "early"), .init(start: .infinity, end: .infinity, text: "infinite"),
      .init(start: -1, end: 2, text: "negative"), .init(start: 2, end: 1, text: "reversed"),
    ]
    XCTAssertEqual(AITranscript.clean(cues, language: "en", isAI: false).cues, [
      .init(id: "c1", start: 0, end: 1, text: "early"), .init(id: "c2", start: 10, end: 11, text: "late"),
    ])
  }

  func testTimecodeArithmeticOverflowIsRejected() {
    XCTAssertNil(AITimecode.parse("1e308:00"))
    XCTAssertNil(AITimecode.parse("1e307:00:00"))
    XCTAssertEqual(AITimecode.parse("100:00:00"), 360_000)
  }

  func testWhitespaceNormalizationMatchesFoundationBehavior() {
    let samples = ["\tAlpha\r\nBeta\u{85}Gamma\u{2028}Delta\u{2029}Epsilon\u{00a0}Zeta\u{2003}End\t",
      "行一\n行二", "Cafe\u{301}\t☕️", "plain text", "\u{200B}零宽字符"]
    for text in samples {
      let expected = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let result = AITranscript.clean([.init(start: 0, end: 1, text: text)], language: "en", isAI: false)
      XCTAssertEqual(result.cues.first?.text, expected)
    }
  }
}
