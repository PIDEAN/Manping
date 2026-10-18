import XCTest

@testable import ManpingCore

final class MediaPolicyTests: XCTestCase {
  func testDiagnosticURLsPreserveSignedAudioAndLocalPaths() throws {
    let signed = "https://example.org/audio.m4s?signature=a%2Fb&x=one,two"
    let args = try DiagnosticArguments(["app", "--diagnose", "/tmp/a b.mp4", "--audio", signed])
    XCTAssertEqual(args.audio?.absoluteString, signed)
    XCTAssertEqual(args.video?.path, "/tmp/a b.mp4")
    XCTAssertEqual(try DiagnosticArguments.mediaURL("file:///tmp/a%20b.mp4").path, "/tmp/a b.mp4")
  }
  func testDiagnosticInvalidArgumentsAreRejectedWithoutEchoingInput() {
    for args in [
      ["--audio"], ["--seconds"], ["--diagnose", ""], ["--audio", "ftp://secret/a"],
      ["--diagnose", "https:///missing"], ["--diagnose", "https://"],
      ["--seconds", "nan"], ["--seconds", "-1"], ["--hwdec-mode", "auto"],
      ["--diagnose", "--audio"], ["--diagnose-bvid", "bad"],
    ] {
      XCTAssertThrowsError(try DiagnosticArguments(["app"] + args), "\(args.first ?? "")")
    }
  }
  func testFixedPixelGeometry() {
    for scale in [1.0, 2.0, 1.5] {
      let points = DiagnosticArguments.viewportPoints(scale: scale)
      XCTAssertEqual(points.width * scale, 1280)
      XCTAssertEqual(points.height * scale, 720)
    }
  }
  func testDiagnosticSigmoidControlIsExplicitAndValidated() throws {
    let baseline = try DiagnosticArguments(["app", "--diagnose", "/tmp/static.mp4"])
    XCTAssertNil(baseline.values["--sigmoid-upscaling"])
    for value in ["yes", "no"] {
      let args = try DiagnosticArguments([
        "app", "--diagnose", "/tmp/static.mp4", "--sigmoid-upscaling", value,
      ])
      XCTAssertEqual(args.values["--sigmoid-upscaling"], value)
      XCTAssertTrue(args.requested)
    }
    for control in [[], ["true"], ["NO"], ["auto"], ["no", "--sigmoid-upscaling", "yes"]] {
      XCTAssertThrowsError(
        try DiagnosticArguments(["app", "--sigmoid-upscaling"] + control))
    }
  }
  func testMoreThan1024GlyphsAndOldGlyphReappearance() {
    let keys = (0..<3072).map { Character(UnicodeScalar(0x4e00 + $0)!) }
    var policy = GlyphCachePolicy(slotsPerPage: 256, historyPages: 4)
    var frames: [GlyphCachePolicy.Frame] = []
    for start in stride(from: 0, to: keys.count, by: 512) {
      let frame = policy.prepare(Array(keys[start..<start + 512]))
      XCTAssertEqual(frame.addresses.count, 512)
      XCTAssertLessThanOrEqual(policy.cachedPageCount, 4)
      frames.append(frame)
    }
    let revisited = policy.prepare(Array(keys.prefix(512)) + Array(keys.suffix(512)))
    XCTAssertEqual(revisited.addresses.count, 1024)
    XCTAssertNotEqual(revisited.addresses[keys[0]]?.page, frames[0].addresses[keys[0]]?.page)
    XCTAssertEqual(frames[0].created.values.flatMap { $0 }.count, 512)
  }
  func testActiveFrameLargerThanHistoryAndInflightGenerationProtection() {
    let keys = (0..<3072).map { Character(UnicodeScalar(0x4e00 + $0)!) }
    var policy = GlyphCachePolicy(slotsPerPage: 256, historyPages: 2)
    let inFlight = policy.prepare(keys)
    XCTAssertEqual(inFlight.pages.count, 12)
    XCTAssertEqual(inFlight.addresses.count, keys.count)
    XCTAssertEqual(policy.cachedPageCount, 0)
    XCTAssertEqual(policy.activePageCount, 12)
    XCTAssertTrue(policy.prepare(keys).created.isEmpty)
    let next = policy.prepare(Array(keys.prefix(1024)))
    XCTAssertTrue(inFlight.pages.isDisjoint(with: next.created.keys))
    XCTAssertTrue(next.created.isEmpty)
    // Evicting history never changes the old frame's immutable slot pairing.
    XCTAssertEqual(inFlight.created[inFlight.addresses[keys[0]]!.page]?.first, keys[0])
    let cached = policy.prepare(Array(keys.prefix(1024)).suffix(512).map { $0 })
    XCTAssertTrue(cached.created.isEmpty)
  }
  func testSparseActivePagesCompactWithoutRerasterizingCachedGlyphs() {
    var policy = GlyphCachePolicy(slotsPerPage: 4, historyPages: 2)
    var keys: [Character] = []
    var copied = 0
    for index in 0..<40 {
      keys.append(Character(UnicodeScalar(0x4e00 + index)!))
      let frame = policy.prepare(keys)
      XCTAssertEqual(frame.addresses.count, keys.count)
      XCTAssertLessThanOrEqual(frame.pages.count, (keys.count + 3) / 4 + 2)
      copied += frame.copied.count
    }
    XCTAssertGreaterThan(copied, 0)
    XCTAssertTrue(policy.prepare(keys).created.isEmpty)
  }

}
