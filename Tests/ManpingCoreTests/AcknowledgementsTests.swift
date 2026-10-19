import Foundation
import XCTest

@testable import ManpingCore

final class AcknowledgementsTests: XCTestCase {
  func testNamesAreUniqueAndLinksAreHTTPS() {
    let names = Acknowledgements.all.map(\.name)
    XCTAssertEqual(Set(names).count, names.count, "duplicate names")
    for entry in Acknowledgements.all {
      XCTAssertTrue(entry.url.hasPrefix("https://"), "\(entry.name): \(entry.url)")
      XCTAssertNotNil(URL(string: entry.url), "\(entry.name): \(entry.url)")
      XCTAssertFalse(entry.contribution.isEmpty, entry.name)
    }
  }

  func testOriginalProjectComesFirst() throws {
    let first = try XCTUnwrap(Acknowledgements.all.first)
    XCTAssertEqual(first.name, "Bili.Copilot")
    XCTAssertEqual(first.group, .original)
  }

  func testGroupsAppearInDeclaredOrder() {
    let order = Acknowledgement.Group.allCases
    let indices = Acknowledgements.all.map { order.firstIndex(of: $0.group)! }
    XCTAssertEqual(indices, indices.sorted())
  }

  func testReadmeAcknowledgementsListEveryProject() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
    let heading = try XCTUnwrap(readme.range(of: "## 致谢"), "README has no 「## 致谢」 section")
    var section = String(readme[heading.upperBound...])
    if let next = section.range(of: "\n## ") { section = String(section[..<next.lowerBound]) }
    let missing = Acknowledgements.all.map(\.name).filter { !section.contains($0) }
    XCTAssertTrue(missing.isEmpty, "README 「致谢」 is missing: \(missing.joined(separator: " | "))")
  }
}
