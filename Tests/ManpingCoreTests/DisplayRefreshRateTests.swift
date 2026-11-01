import XCTest
@testable import ManpingCore

final class DisplayRefreshRateTests: XCTestCase {
  func testRationalPeriodsPreserveFractionalRates() {
    XCTAssertEqual(DisplayRefreshRate.hertz(periodValue: 1001, timeScale: 60000, fallback: 60), 60000.0 / 1001, accuracy: 1e-10)
    XCTAssertEqual(DisplayRefreshRate.hertz(periodValue: 1, timeScale: 60, fallback: 120), 60)
    XCTAssertEqual(DisplayRefreshRate.hertz(periodValue: 1, timeScale: 120, fallback: 60), 120)
  }
  func testUnknownOrInvalidPeriodUsesScreenThenSafeFallback() {
    for value: Int64 in [0, -1] {
      XCTAssertEqual(DisplayRefreshRate.hertz(periodValue: value, timeScale: 60000, fallback: 120), 120)
    }
    XCTAssertEqual(DisplayRefreshRate.hertz(periodValue: 1, timeScale: 0, fallback: 60), 60)
    XCTAssertEqual(DisplayRefreshRate.hertz(periodValue: 1, timeScale: 100000, fallback: 24), 24)
    XCTAssertEqual(DisplayRefreshRate.hertz(periodValue: 0, timeScale: 0, fallback: 0), 60)
  }
}
