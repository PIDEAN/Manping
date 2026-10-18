import XCTest
@testable import ManpingCore

final class AppleLocalModelTests: XCTestCase {
  func testLongPromptsKeepHeadAndTail() {
    let short = "总结这个视频"
    XCTAssertEqual(AppleLocalModel.fitted(short), short)
    let long = "指令开头" + String(repeating: "字", count: 10_000) + "问题结尾"
    let fitted = AppleLocalModel.fitted(long)
    XCTAssertTrue(fitted.hasPrefix("指令开头"))
    XCTAssertTrue(fitted.hasSuffix("问题结尾"))
    XCTAssertLessThan(fitted.count, AppleLocalModel.promptBudget + 40)
  }

  func testOnDeviceProviderIsNotAnUpstreamProviderAndNeedsNoKey() {
    XCTAssertFalse(AIProvider.sourceProviders.contains(.appleLocal))
    XCTAssertTrue(AIProvider.appleLocal.isOnDevice)
    XCTAssertEqual(AIProviderConfiguration().isConfigured(for: .appleLocal), AppleLocalModel.isAvailable)
  }
}
