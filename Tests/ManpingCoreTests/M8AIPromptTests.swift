import Foundation
import XCTest
@testable import ManpingCore

final class M8AIPromptTests: XCTestCase, @unchecked Sendable {
  func testAllSourceTemplatesRenderOnePromptAndPreserveContextBraces() throws {
    for task in AIPromptTask.allCases {
      let tokens = ["title"] + (task.isArticle ? ["content"] : ["description", "subtitle"])
        + (task.needsComments ? ["comments"] : []) + (task.isQuestion ? ["question"] : [])
      let values = Dictionary(uniqueKeysWithValues: tokens.map { ($0, "fixture-" + $0) })
      let rendered = try AIPromptRenderer.render(template: task.defaultTemplate, values: values)
      for token in tokens {
        XCTAssertTrue(rendered.contains("fixture-" + token), "Missing \(token) in \(task)")
        XCTAssertFalse(rendered.contains("{" + token + "}"))
      }
      XCTAssertTrue(rendered.contains("以下是"))
    }
    XCTAssertEqual(try AIPromptRenderer.render(template: "{title} | {question}", values: ["title": "literal {question}", "question": "actual"]),
      "literal {question} | actual")
    XCTAssertThrowsError(try AIPromptRenderer.render(template: "  ", values: [:]))
    XCTAssertThrowsError(try AIPromptRenderer.render(template: String(repeating: "x", count: 128 * 1024 + 1), values: [:]))
  }
  func testArticleWhitespaceNormalization() {
    XCTAssertEqual(AIArticleInfo.normalizedArticle("  first\n\nsecond\tthird "), "first second third")
  }
  @MainActor func testPromptPersistenceAndFixtureIsolation() throws {
    let suite = "fixture.ai.prompts." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let persisted = AIPromptStore(defaults: defaults)
    XCTAssertTrue(persisted.streaming)
    persisted.streaming = false
    let restored = AIPromptStore(defaults: defaults)
    XCTAssertFalse(restored.streaming)
    let fixture = AIPromptStore(fixtures: true, defaults: defaults)
    XCTAssertTrue(fixture.streaming)
    fixture.streaming = false
    fixture.streaming = true
    XCTAssertFalse(restored.streaming)
    XCTAssertFalse(AIPromptStore(defaults: defaults).streaming)
    restored.streaming = true
    XCTAssertTrue(AIPromptStore(defaults: defaults).streaming)
  }
}
