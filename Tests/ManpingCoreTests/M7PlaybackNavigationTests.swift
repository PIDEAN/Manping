import XCTest
@testable import ManpingCore

final class M7PlaybackNavigationTests: XCTestCase {
  private let before = Video(bvid: "BV1fixture000", title: "Before", cid: 1, aid: 10)
  private let current = Video(bvid: "BV1fixture001", title: "Current", cid: 11, aid: 100)
  private let after = Video(bvid: "BV1fixture002", title: "After", cid: 31, aid: 200)
  private let recommendation = Video(bvid: "BV1fixture003", title: "Related", cid: 41, aid: 300)
  private let parts = [VideoPart(cid: 11, page: 1, title: "First", duration: 30),
    VideoPart(cid: 22, page: 2, title: "Second", duration: 30)]
  private func details(parts: [VideoPart] = [], collections: [VideoCollectionSection] = [], related: [Video] = []) -> VideoDetails {
    VideoDetails(video: current, parts: parts, collections: collections, tags: [], related: related,
      stats: VideoStats(), uploader: VideoUploader(mid: 123, name: "Fixture"))
  }
  func testPartNavigationPrecedesQueueAndPlaylistBoundarySetting() {
    let detail = details(parts: parts, related: [recommendation])
    let secondPart = Video(bvid: current.bvid, title: current.title, cid: 22, aid: current.aid)
    for endWithPlaylist in [true, false] {
      XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: [current], playlistIndex: 0,
        endWithPlaylist: endWithPlaylist, autoNextRelated: true), .part(parts[1]))
      XCTAssertEqual(PlaybackNavigation.previous(details: detail, current: secondPart, playlist: [current], playlistIndex: 0,
        endWithPlaylist: endWithPlaylist, autoNextRelated: true), .part(parts[0]))
    }
  }
  func testQueueMovementDoesNotDependOnEndWithPlaylistAndPrecedesCollections() {
    let detail = details(collections: [.init(title: "Collection", episodes: [before, current, recommendation])])
    for endWithPlaylist in [true, false] {
      XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: [before, current, after], playlistIndex: 1,
        endWithPlaylist: endWithPlaylist, autoNextRelated: true), .playlistNext)
      XCTAssertEqual(PlaybackNavigation.previous(details: detail, current: current, playlist: [before, current, after], playlistIndex: 1,
        endWithPlaylist: endWithPlaylist, autoNextRelated: false), .playlistPrevious)
    }
  }
  func testPlaylistSettingOnlyBlocksEscapeAtQueueBoundary() {
    let detail = details(collections: [.init(title: "Collection", episodes: [before, current, after])], related: [recommendation])
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: [current], playlistIndex: 0,
      endWithPlaylist: true, autoNextRelated: true), .none)
    XCTAssertEqual(PlaybackNavigation.previous(details: detail, current: current, playlist: [current], playlistIndex: 0,
      endWithPlaylist: true, autoNextRelated: false), .none)
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: [current], playlistIndex: 0,
      endWithPlaylist: false, autoNextRelated: true), .video(after))
    XCTAssertEqual(PlaybackNavigation.previous(details: detail, current: current, playlist: [current], playlistIndex: 0,
      endWithPlaylist: false, autoNextRelated: false), .video(before))
    for endWithPlaylist in [true, false] {
      XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: nil, playlistIndex: nil,
        endWithPlaylist: endWithPlaylist, autoNextRelated: false), .video(after))
      XCTAssertEqual(PlaybackNavigation.previous(details: detail, current: current, playlist: nil, playlistIndex: nil,
        endWithPlaylist: endWithPlaylist, autoNextRelated: false), .video(before))
    }
  }
  func testRecommendRequiresPreferenceAndNeverParticipatesInPreviousNavigation() {
    let detail = details(related: [recommendation, after])
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: nil, playlistIndex: nil,
      endWithPlaylist: true, autoNextRelated: false), .none)
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: nil, playlistIndex: nil,
      endWithPlaylist: true, autoNextRelated: true), .video(recommendation))
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: [current], playlistIndex: 0,
      endWithPlaylist: true, autoNextRelated: true), .none)
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: [current], playlistIndex: 0,
      endWithPlaylist: false, autoNextRelated: true), .video(recommendation))
    XCTAssertEqual(PlaybackNavigation.previous(details: detail, current: current, playlist: nil, playlistIndex: nil,
      endWithPlaylist: false, autoNextRelated: true), .none)
  }
  func testCollectionsStayWithinSelectedGroupAndInvalidQueueIndexCannotMove() {
    let detail = details(collections: [.init(title: "First group", episodes: [before, current]),
      .init(title: "Second group", episodes: [after])], related: [recommendation])
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: nil, playlistIndex: nil,
      endWithPlaylist: false, autoNextRelated: false), .none)
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: nil, playlistIndex: nil,
      endWithPlaylist: false, autoNextRelated: true), .video(recommendation))
    XCTAssertEqual(PlaybackNavigation.previous(details: detail, current: current, playlist: [current, after], playlistIndex: 99,
      endWithPlaylist: false, autoNextRelated: false), .none)
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: after, playlist: [current, after], playlistIndex: 1,
      endWithPlaylist: false, autoNextRelated: true), .none)
    XCTAssertEqual(PlaybackNavigation.next(details: detail, current: current, playlist: [before, current, after], playlistIndex: nil,
      endWithPlaylist: false, autoNextRelated: false), .playlistNext)
  }
}
