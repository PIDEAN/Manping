import AppKit
import XCTest
@testable import ManpingApp

final class PlayerFullScreenTests: XCTestCase {
  func testExitFramesFitCurrentVisibleScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = NSRect(x: 0, y: 25, width: 1440, height: 850)
    let cases: [(NSRect, NSRect)] = [
      (NSRect(x: 100, y: 100, width: 800, height: 600), NSRect(x: 100, y: 100, width: 800, height: 600)),
      (NSRect(x: 100, y: 300, width: 800, height: 600), NSRect(x: 100, y: 275, width: 800, height: 600)),
      (screen, visible),
      (NSRect(x: 2000, y: 100, width: 800, height: 600), NSRect(x: 320, y: 150, width: 800, height: 600)),
      (NSRect(x: 0, y: 0, width: 1600, height: 1000), visible),
      (NSRect(x: 1300, y: 100, width: 800, height: 600), NSRect(x: 320, y: 150, width: 800, height: 600)),
    ]
    for (saved, expected) in cases {
      let result = playerExitFrame(saved, screen: screen, visible: visible)
      XCTAssertEqual(result, expected)
      XCTAssertTrue(visible.contains(result), "\(result) outside \(visible)")
    }
  }
}
