import Foundation
import XCTest

/// App preferences go through `PerformanceEnvironment.defaults`, so diagnostics, fixtures and
/// Debug scenes never read or write the user's real settings. Only the environment itself and
/// one launch-time registration may name `UserDefaults.standard`.
final class PreferenceIsolationTests: XCTestCase {
  func testAppCodeDoesNotBypassThePreferenceEnvironment() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let app = root.appendingPathComponent("Sources/ManpingApp")
    let allowed: Set<String> = ["PerformanceDiagnostics.swift", "Application.swift"]
    var offenders: [String] = []
    let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
    for name in files where !allowed.contains(name) {
      let text = try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
      if text.contains("UserDefaults.standard") { offenders.append(name) }
    }
    XCTAssertEqual(offenders.sorted(), [], "use PerformanceEnvironment.defaults instead")
  }
}
