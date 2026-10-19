import XCTest
@testable import ManpingCore

final class PlaybackNodePolicyTests: XCTestCase {
  func testRefreshKeepsVideoAndAudioAuthoritiesIndependent() throws {
    let video = URL(string: "http://127.0.0.1:12001/video?sig=old")!
    let audio = URL(string: "http://127.0.0.1:12002/audio?sig=old")!
    let newVideo = URL(string: "http://127.0.0.1:12001/video?sig=new")!
    let newAudio = URL(string: "http://127.0.0.1:12002/audio?sig=new")!
    let other = URL(string: "http://127.0.0.1:12003/backup")!
    let current = PlaybackURLCandidates.Candidate(video: video, audio: audio)
    for manual in [nil, "127.0.0.1"] {
      let result = try XCTUnwrap(PlaybackNodePolicy.refreshed(video: [other, newVideo],
        audio: [other, newAudio], current: current, manualHost: manual))
      XCTAssertEqual(result.video, newVideo)
      XCTAssertEqual(result.audio, newAudio)
      XCTAssertNil(PlaybackNodePolicy.refreshed(video: [other], audio: [newAudio], current: current, manualHost: manual))
      XCTAssertNil(PlaybackNodePolicy.refreshed(video: [newVideo], audio: [other], current: current, manualHost: manual))
    }
  }

  func testManualHostRewritesOnlyLegalSignedTemplates() throws {
    let source = URL(string: "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/a.m4s?sig=fixture")!
    let manual = "upos-sz-mirrorcos.bilivideo.com"
    let choice = try XCTUnwrap(PlaybackNodePolicy.restrictedURLs([source], current: nil, manualHost: manual).first)
    XCTAssertEqual(choice.host, manual)
    XCTAssertEqual(choice.path, source.path)
    XCTAssertEqual(choice.query, source.query)
    let overseas = URL(string: "https://overseas.example.invalid/a.m4s?sig=fixture")!
    XCTAssertTrue(PlaybackNodePolicy.restrictedURLs([overseas], current: nil, manualHost: manual).isEmpty)
    XCTAssertTrue(PlaybackNodePolicy.restrictedURLs([source], current: nil, manualHost: "127.0.0.1").isEmpty)
  }

  func testAuthorityRequiresHTTPHostAndEffectivePort() {
    let https = URL(string: "https://example.invalid/a")!
    XCTAssertTrue(PlaybackNodePolicy.sameAuthority(https, URL(string: "https://example.invalid:443/b")!))
    XCTAssertFalse(PlaybackNodePolicy.sameAuthority(https, URL(string: "https://example.invalid:444/b")!))
    XCTAssertFalse(PlaybackNodePolicy.sameAuthority(https, URL(string: "https://other.invalid/a")!))
    XCTAssertFalse(PlaybackNodePolicy.sameAuthority(URL(string: "file:///fixture/a")!, URL(string: "file:///fixture/b")!))
    XCTAssertFalse(PlaybackNodePolicy.sameAuthority(URL(string: "ftp://example.invalid/a")!, https))
  }
}
