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
}
