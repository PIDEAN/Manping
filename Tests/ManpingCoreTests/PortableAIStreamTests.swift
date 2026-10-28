import Foundation
import XCTest
@testable import ManpingCore

final class PortableAIStreamTests: XCTestCase {
  func testEveryByteBoundaryPreservesUnicodeAndCRLF() throws {
    let data = Data(("\u{feff}: ping\r\ndata: {\r\ndata: \"choices\":[{\"delta\":{\"content\":\"你好🌟\"}}]}\r\n\r\n"
      + "data: [DONE]\r\n\r\n").utf8)
    for boundary in 0...data.count {
      var parser = AIStreamParser(family: .openAI)
      let first = try parser.append(Data(data.prefix(boundary)))
      let second = try parser.append(Data(data.dropFirst(boundary)))
      let last = try parser.finish()
      XCTAssertEqual((first + second + last).joined(), "你好🌟", "boundary \(boundary)")
    }
  }

  func testAllStreamingFamilies() throws {
    let samples: [(AIProtocolFamily, String)] = [
      (.openAI, "data: {\"choices\":[{\"delta\":{\"content\":\"native\"},\"finish_reason\":\"stop\"}]}\n\n"),
      (.anthropic, "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"native\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"),
      (.gemini, "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"native\"}]},\"finishReason\":\"STOP\"}]}\n\n"),
      (.ollama, "{\"message\":{\"content\":\"native\"},\"done\":false}\n{\"done\":true}"),
      (.responses, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"native\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"),
    ]
    for (family, stream) in samples {
      var parser = AIStreamParser(family: family)
      var text = ""
      for byte in stream.utf8 { text += try parser.append(Data([byte])).joined() }
      text += try parser.finish().joined()
      XCTAssertEqual(text, "native")
      XCTAssertTrue(parser.finished)
    }
  }

  func testTruncationAndEmptyStreamsRemainFailures() throws {
    var truncated = AIStreamParser(family: .openAI)
    _ = try truncated.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8))
    XCTAssertThrowsError(try truncated.finish()) { XCTAssertEqual($0 as? AIChatFailure, .truncatedStream) }
    var empty = AIStreamParser(family: .openAI)
    _ = try empty.append(Data("data: [DONE]\n\n".utf8))
    XCTAssertThrowsError(try empty.finish()) { XCTAssertEqual($0 as? AIChatFailure, .emptyResponse) }
  }

  func testCarriageReturnDispatchesWithoutWaitingForAnotherChunk() throws {
    var parser = AIStreamParser(family: .openAI)
    XCTAssertEqual(try parser.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"now\"}}]}\r\r".utf8)), ["now"])
    // LF following the last CR is the second half of CRLF, not a second empty line.
    XCTAssertEqual(try parser.append(Data("\ndata: [DONE]\r\r".utf8)), [])
    XCTAssertTrue(parser.finished)
    XCTAssertEqual(try parser.finish(), [])
  }

  func testCompleteOversizedLineCannotBypassLimit() {
    let text = String(repeating: "x", count: 1_048_576)
    let stream = Data(("data: {\"choices\":[{\"delta\":{\"content\":\"" + text + "\"}}]}\n\ndata: [DONE]\n\n").utf8)
    var parser = AIStreamParser(family: .openAI)
    XCTAssertThrowsError(try parser.append(stream)) { XCTAssertEqual($0 as? AIChatFailure, .invalidResponse) }
  }

  func testCompleteOversizedEventCannotBypassLimit() {
    let padding = String(repeating: " ", count: 270_000)
    let stream = Data(("data: {\n" + String(repeating: "data: " + padding + "\n", count: 4)
      + "data: \"choices\":[{\"delta\":{\"content\":\"fixture\"}}]}\n\ndata: [DONE]\n\n").utf8)
    var parser = AIStreamParser(family: .openAI)
    XCTAssertThrowsError(try parser.append(stream)) { XCTAssertEqual($0 as? AIChatFailure, .invalidResponse) }
  }

  func testEventLimitIncludesInsertedNewlines() {
    let line = "data: " + String(repeating: " ", count: 524_288) + "\n"
    var parser = AIStreamParser(family: .openAI)
    XCTAssertThrowsError(try parser.append(Data((line + line).utf8))) {
      XCTAssertEqual($0 as? AIChatFailure, .invalidResponse)
    }
  }

  func testExactLineLimitAndFragmentedOverflow() throws {
    var parser = AIStreamParser(family: .openAI)
    let prefix = "data: {\"choices\":[{\"delta\":{\"content\":\""
    let suffix = "\"}}]}"
    let text = String(repeating: "x", count: 1_048_576 - prefix.utf8.count - suffix.utf8.count)
    XCTAssertEqual(try parser.append(Data((prefix + text + suffix + "\n\ndata: [DONE]\n\n").utf8)), [text])
    XCTAssertNoThrow(try parser.finish())
    var oversized = AIStreamParser(family: .openAI)
    XCTAssertNoThrow(try oversized.append(Data(repeating: 120, count: 1_048_576)))
    XCTAssertThrowsError(try oversized.append(Data([120]))) { XCTAssertEqual($0 as? AIChatFailure, .invalidResponse) }
  }

  func testEventBudgetResetsAfterDispatch() throws {
    let text = String(repeating: "x", count: 600_000)
    let event = "data: {\"choices\":[{\"delta\":{\"content\":\"" + text + "\"}}]}\n\n"
    var parser = AIStreamParser(family: .openAI)
    XCTAssertEqual(try parser.append(Data((event + event + "data: [DONE]\n\n").utf8)), [text, text])
    XCTAssertNoThrow(try parser.finish())
  }

  func testPartialUTF8InvalidUTF8AndNonzeroDataIndices() throws {
    let stream = Data("data: {\"choices\":[{\"delta\":{\"content\":\"中文🌟\"}}]}\n\ndata: [DONE]\n\n".utf8)
    for chunkSize in [1, 2, 3, 7, 31] {
      var parser = AIStreamParser(family: .openAI)
      var output = ""
      for start in stride(from: 0, to: stream.count, by: chunkSize) {
        output += try parser.append(stream[start..<min(start + chunkSize, stream.count)]).joined()
      }
      output += try parser.finish().joined()
      XCTAssertEqual(output, "中文🌟")
    }
    var invalid = AIStreamParser(family: .openAI)
    XCTAssertThrowsError(try invalid.append(Data([0xff, 10]))) {
      XCTAssertEqual($0 as? AIChatFailure, .invalidResponse)
    }
  }

  func testResponsesRequiresCompletionAndPreservesProviderErrors() throws {
    var parser = AIStreamParser(family: .responses)
    _ = try parser.append(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\ndata: [DONE]\n\n".utf8))
    XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? AIChatFailure, .truncatedStream) }
    var limited = AIStreamParser(family: .openAI)
    XCTAssertThrowsError(try limited.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n".utf8))) {
      XCTAssertEqual($0 as? AIChatFailure, .outputLimit)
    }
    var refused = AIStreamParser(family: .anthropic)
    XCTAssertThrowsError(try refused.append(Data("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n\n".utf8))) {
      XCTAssertEqual($0 as? AIChatFailure, .refused)
    }
  }

  func testOllamaFinalLineWithoutDelimiterAndCarriageReturn() throws {
    for ending in ["", "\r", "\n", "\r\n"] {
      var parser = AIStreamParser(family: .ollama)
      let lines = try parser.append(Data(("{\"message\":{\"content\":\"last\"},\"done\":true}" + ending).utf8))
      XCTAssertEqual((lines + (try parser.finish())).joined(), "last")
    }
  }
}
