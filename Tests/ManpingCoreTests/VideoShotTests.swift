import XCTest
@testable import ManpingCore

final class VideoShotTests: XCTestCase {
  private func payload(index: [Any] = [0, 0, 5, 10, 15], images: [String] = ["//i0.hdslb.com/bfs/videoshot/1.jpg"]) -> [String: Any] {
    ["img_x_len": 2, "img_y_len": 2, "img_x_size": 160, "img_y_size": 90, "image": images, "index": index]
  }

  func testParsesSheetsDropsPlaceholderAndPicksFrames() throws {
    let shot = try XCTUnwrap(VideoShot.parse(payload(index: [0, 0, 5, 10, 15, 20],
      images: ["//i0.hdslb.com/bfs/videoshot/1.jpg", "http://i0.hdslb.com/bfs/videoshot/2.jpg"])))
    XCTAssertEqual(shot.times, [0, 5, 10, 15, 20])
    XCTAssertEqual(shot.sheets.map(\.absoluteString), ["https://i0.hdslb.com/bfs/videoshot/1.jpg", "https://i0.hdslb.com/bfs/videoshot/2.jpg"])
    XCTAssertEqual(shot.frame(at: 0)?.x, 0)
    XCTAssertEqual(shot.frame(at: 7), VideoShot.Frame(sheet: shot.sheets[0], x: 160, y: 0, width: 160, height: 90))
    XCTAssertEqual(shot.frame(at: 12), VideoShot.Frame(sheet: shot.sheets[0], x: 0, y: 90, width: 160, height: 90))
    // Frame 4 is the first slot of the second sheet.
    XCTAssertEqual(shot.frame(at: 99), VideoShot.Frame(sheet: shot.sheets[1], x: 0, y: 0, width: 160, height: 90))
    XCTAssertNil(shot.frame(at: .nan))
  }

  func testRejectsForeignHostsAndBadPayloads() {
    XCTAssertNil(VideoShot.parse(payload(images: ["https://evil.example/a.jpg"])))
    XCTAssertNil(VideoShot.parse(payload(index: [10, 5])))
    var huge = payload(); huge["img_x_len"] = 500
    XCTAssertNil(VideoShot.parse(huge))
    XCTAssertNil(VideoShot.parse([:]))
    // More times than the sheets can hold are cut off.
    XCTAssertEqual(VideoShot.parse(payload(index: Array(0..<10).map { $0 * 5 }))?.times.count, 4)
  }
}
