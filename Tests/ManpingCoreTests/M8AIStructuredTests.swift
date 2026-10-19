import Foundation
import XCTest
@testable import ManpingCore

final class M8AIStructuredTests: XCTestCase {
  private func evidence() -> AIEvidenceIndex {
    var index = AIEvidenceIndex()
    index.add("c1", start: 10, end: 40)
    index.add("c2", start: 100, end: 130)
    index.add("c3", start: 62.8, end: 3605.9)
    index.add("ch1", start: 0, end: 300)
    return index
  }

  func testChaptersKeepOnlySupportedTimestampsSeekable() throws {
    let validator = AIStructuredValidator(duration: 600, evidence: evidence(), danmaku: nil)
    let json = """
    ```json
    {"overview":"概述","chapters":[
      {"start":"00:10","end":"00:40","title":"开头","points":["要点"],"highlight":true,"evidence":["c1"]},
      {"start":"00:50","end":"01:00","title":"无依据","points":[],"evidence":["c2"]},
      {"start":"20:00","title":"超出时长","evidence":["ch1"]},
      {"start":"59:00","end":"60:05","title":"长字幕末尾","evidence":["c3"]},
      {"start":"bad","title":"丢弃"}
    ],"sources":["cc"],"insufficient":false}
    ```
    """
    guard case .structured(.chapters(let result)) = validator.validate(json, mode: .chaptersJSON) else { return XCTFail("Expected chapters") }
    XCTAssertEqual(result.chapters.map(\.title), ["开头", "无依据", "超出时长", "长字幕末尾"])
    XCTAssertEqual(result.chapters.map(\.start.seekable), [true, false, false, false])
    // No danmaku peak overlaps, so the claimed highlight is not kept.
    XCTAssertFalse(result.chapters[0].highlight)
    // Inside a long cue's original range, but past the 10-minute video: not seekable.
    XCTAssertEqual(result.chapters[3].start.seconds, 3540)
    let long = AIStructuredValidator(duration: 4000, evidence: evidence(), danmaku: nil)
    guard case .structured(.chapters(let longResult)) = long.validate(json, mode: .chaptersJSON) else { return XCTFail() }
    XCTAssertTrue(longResult.chapters[3].start.seekable)
    XCTAssertTrue(longResult.chapters[3].end?.seekable == true)
  }

  func testUnparseableStructuredOutputFallsBackWithReason() {
    let validator = AIStructuredValidator(duration: 600, evidence: evidence(), danmaku: nil)
    guard case .fallback(let text, let reason) = validator.validate("## 不是 JSON\n00:10 开头", mode: .chaptersJSON) else { return XCTFail() }
    XCTAssertEqual(text, "## 不是 JSON\n00:10 开头")
    XCTAssertFalse(reason.isEmpty)
    XCTAssertFalse(AIAnswerContent.fallback(text: text, reason: reason).isUsableResult)
    if case .fallback = validator.validate("{\"unrelated\":1}", mode: .clipsJSON) {} else { XCTFail("Missing clips is a fallback") }
    XCTAssertEqual(validator.validate("普通回答", mode: .markdown), .markdown("普通回答"))
  }

  func testClipsRulesForThreeMinutes() throws {
    let validator = AIStructuredValidator(duration: 600, evidence: evidence(), danmaku: nil)
    func clips(_ json: String) throws -> AIClipsResult {
      guard case .structured(.clips(let result)) = validator.validate(json, mode: .clipsJSON) else {
        XCTFail("Expected clips for \(json)"); throw AIChatFailure.invalidResponse
      }
      return result
    }
    let good = try clips(#"{"clips":[{"start":"01:40","end":"02:10","reason":"b","evidence":["c2"]},{"start":"00:10","end":"00:40","reason":"a","evidence":["c1"]}],"total_seconds":999}"#)
    XCTAssertTrue(good.valid, good.problems.joined())
    XCTAssertEqual(good.clips.map(\.start), [10, 100])
    XCTAssertEqual(good.totalSeconds, 60) // recomputed, the model's 999 is ignored
    XCTAssertEqual(good.limitSeconds, 180)
    XCTAssertTrue(AIAnswerContent.structured(.clips(good)).isUsableResult)
    let reversed = try clips(#"{"clips":[{"start":"00:40","end":"00:10","reason":"x","evidence":["c1"]}]}"#)
    XCTAssertFalse(reversed.valid)
    let overlap = try clips(#"{"clips":[{"start":"00:00","end":"02:00","reason":"x","evidence":["ch1"]},{"start":"01:50","end":"02:10","reason":"y","evidence":["c2"]}]}"#)
    XCTAssertFalse(overlap.valid)
    let tooShort = try clips(#"{"clips":[{"start":"00:10","end":"00:20","reason":"x","evidence":["c1"]}]}"#)
    XCTAssertFalse(tooShort.valid)
    let tooLong = try clips(#"{"clips":[{"start":"00:00","end":"04:00","reason":"x","evidence":["ch1"]}]}"#)
    XCTAssertFalse(tooLong.valid)
    let unsupported = try clips(#"{"clips":[{"start":"03:00","end":"03:30","reason":"x","evidence":["c1"]}]}"#)
    XCTAssertFalse(unsupported.valid)
    let notFinite = try clips(#"{"clips":[{"start":"abc","end":"00:30","reason":"x","evidence":["c1"]}]}"#)
    XCTAssertFalse(notFinite.valid)
    XCTAssertFalse(AIAnswerContent.structured(.clips(notFinite)).isUsableResult)
    // Short video: the limit is the video length and short clips are allowed.
    var short = AIEvidenceIndex(); short.add("c1", start: 0, end: 40)
    let shortValidator = AIStructuredValidator(duration: 40, evidence: short, danmaku: nil)
    guard case .structured(.clips(let shortResult)) = shortValidator.validate(#"{"clips":[{"start":"00:02","end":"00:08","reason":"x","evidence":["c1"]}]}"#, mode: .clipsJSON) else { return XCTFail() }
    XCTAssertTrue(shortResult.valid, shortResult.problems.joined())
    XCTAssertEqual(shortResult.limitSeconds, 40)
  }

  func testHighlightsQuotesComeFromDigestIDsAndPeaksMustExist() throws {
    let digest = try XCTUnwrap(AIDanmakuDigest.make(AIFixtureMaterialProvider.danmaku(), duration: 1104))
    let peak = try XCTUnwrap(digest.peaks.first)
    let quote = try XCTUnwrap(peak.quotes.first)
    var index = AIEvidenceIndex(); for item in digest.peaks { index.add(item.id, start: item.start, end: item.end) }
    let validator = AIStructuredValidator(duration: 1104, evidence: index, danmaku: digest)
    let mid = AITimecode.format(peak.start + 5)
    let json = """
    {"moments":[{"peak":"\(peak.id)","start":"\(mid)","end":"\(AITimecode.format(peak.end))","title":"t","why":"w","quotes":["\(quote.id)","编造的弹幕","q999"]},
    {"peak":"d99","start":"00:10","end":"00:20","title":"假峰","quotes":[]},
    {"peak":"\(peak.id)","start":"00:01","end":"00:05","title":"峰外","quotes":[]}]}
    """
    guard case .structured(.highlights(let result)) = validator.validate(json, mode: .highlightsJSON) else { return XCTFail() }
    XCTAssertEqual(result.moments.count, 2)
    let first = try XCTUnwrap(result.moments.first(where: { $0.title == "t" }))
    XCTAssertEqual(first.quotes, [quote])
    XCTAssertTrue(first.start.seekable)
    XCTAssertFalse(result.moments.first(where: { $0.title == "峰外" })?.start.seekable ?? true)
    XCTAssertFalse(result.density.isEmpty)
  }

  func testImplausibleTimesFallBackInsteadOfTrapping() throws {
    for duration in [600.0, nil] {
      let validator = AIStructuredValidator(duration: duration, evidence: evidence(), danmaku: nil)
      for value in ["1e20", "1e308", "-1e20", "\"99999999:00:00\""] {
        let chapters = #"{"overview":"x","chapters":[{"start":"# + value + #","title":"x","evidence":["c1"]}]}"#
        guard case .fallback(_, let reason) = validator.validate(chapters, mode: .chaptersJSON) else { return XCTFail("chapters \(value)") }
        XCTAssertTrue(reason.contains("超出"), reason)
        let clips = #"{"clips":[{"start":"00:10","end":"# + value + #","reason":"r","evidence":["c1"]}]}"#
        guard case .fallback = validator.validate(clips, mode: .clipsJSON) else { return XCTFail("clips \(value)") }
        let moments = #"{"moments":[{"peak":"p1","start":"# + value + #","end":"00:20"}]}"#
        guard case .fallback = validator.validate(moments, mode: .highlightsJSON) else { return XCTFail("moments \(value)") }
      }
    }
    // A media length past a day raises the ceiling with it; the sum of clips is still converted safely.
    let huge = AIStructuredValidator(duration: 1e300, evidence: evidence(), danmaku: nil)
    let json = #"{"clips":[{"start":0,"end":1e299,"evidence":["c1"]},{"start":2e299,"end":3e299,"evidence":["c1"]}]}"#
    guard case .structured(.clips(let result)) = huge.validate(json, mode: .clipsJSON) else { return XCTFail() }
    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.problems.contains { $0.hasPrefix("总时长") })
    XCTAssertEqual(AITimecode.wholeSeconds(.infinity), 0)
    XCTAssertEqual(AITimecode.wholeSeconds(-5), 0)
    XCTAssertEqual(AITimecode.wholeSeconds(1e308), 1_000_000_000_000)
    XCTAssertFalse(AITimecode.format(1e308).isEmpty)
    XCTAssertEqual(AITimecode.format(3725.9), "1:02:05")
    XCTAssertTrue(AIAnswerContent.structured(.clips(result)).markdownText.contains("共 1000000000000 秒"))
  }

}
