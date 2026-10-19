import XCTest
@testable import ManpingCore

final class AppleLocalModelTests: XCTestCase {
  /// Long prompts are no longer cut silently: every message reaches the model in full and the
  /// on-device budget comes from the SDK, so long material is segmented before it gets here.
  func testConversationIsPassedWholeAndBudgetComesFromTheSDK() {
    let middle = String(repeating: "字", count: 10_000)
    let single = AppleLocalModel.prompt(for: AIConversationRequest(system: "系统规则", messages: [.user("指令开头" + middle + "问题结尾")]))
    XCTAssertEqual(single.instructions, "系统规则")
    XCTAssertEqual(single.prompt, "指令开头" + middle + "问题结尾")
    let turns = AppleLocalModel.prompt(for: AIConversationRequest(system: nil, messages: [.user("一"), .assistant("二"), .user("三")]))
    XCTAssertEqual(turns.instructions, AppleLocalModel.defaultInstructions)
    XCTAssertEqual(turns.prompt, "用户：一\n\n助手：二\n\n用户：三")
    let budget = AppleLocalModel.requestBudget()
    XCTAssertTrue(budget.known)
    XCTAssertGreaterThanOrEqual(budget.contextTokens, 1024)
    XCTAssertLessThan(budget.inputLimit, budget.contextTokens)
  }

  func testOnDeviceProviderIsNotAnUpstreamProviderAndNeedsNoKey() {
    XCTAssertFalse(AIProvider.sourceProviders.contains(.appleLocal))
    XCTAssertEqual(AIProviderConfiguration().isConfigured(for: .appleLocal), AppleLocalModel.isAvailable)
  }
}
