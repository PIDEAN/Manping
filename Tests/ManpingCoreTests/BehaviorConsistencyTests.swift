import Foundation
import XCTest
@testable import ManpingCore

/// The pure rules behind the UI state fixes: one settings source, panels that commit only
/// what was edited, merged shield edits, collected playlists, skip ranges and mini window size.
final class BehaviorConsistencyTests: XCTestCase {
  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "Manping.BehaviorFixture." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  // MARK: Settings (F15)

  func testCommittingOneFieldKeepsValuesSavedElsewhereMeanwhile() throws {
    try withDefaults { defaults in
      let all = Set(MacSettingKey.allCases)
      let stale = MacSettings.load(from: defaults)
      XCTAssertEqual(stale.text(.codec), "h264")
      // The player's quality menu stores another codec while the settings model is open.
      defaults.set("hevc", forKey: MacSettingKey.codec.rawValue)
      let merged = try XCTUnwrap(MacSettings.committing(.danmakuSpeed, .number(1.5), capabilities: all, to: defaults))
      XCTAssertEqual(merged.text(.codec), "hevc")
      XCTAssertEqual(merged.number(.danmakuSpeed), 1.5)
      XCTAssertEqual(defaults.string(forKey: MacSettingKey.codec.rawValue), "hevc")
      XCTAssertEqual(defaults.double(forKey: MacSettingKey.danmakuSpeed.rawValue), 1.5)
      XCTAssertNil(MacSettings.committing(.codec, .text("vp9"), capabilities: all, to: defaults))
      XCTAssertEqual(defaults.string(forKey: MacSettingKey.codec.rawValue), "hevc")
    }
  }

  // MARK: Danmaku panel (F13)

  func testDanmakuPanelRangesMatchTheSettingsWindow() throws {
    let font = try XCTUnwrap(MacSettingsCatalog.descriptor(.danmakuFontSize).numberRange)
    XCTAssertEqual(font.range, 12...48)
    let speed = try XCTUnwrap(MacSettingsCatalog.descriptor(.danmakuSpeed).numberRange)
    XCTAssertEqual(speed.range, 0.5...2)
    XCTAssertNil(MacSettingsCatalog.descriptor(.codec).numberRange)
  }

  func testPanelCommitsOnlyEditedFields() {
    var stored = MacSettings()
    let all = Set(MacSettingKey.allCases)
    XCTAssertTrue(stored.set(.danmakuFontSize, .number(48), capabilities: all))
    XCTAssertTrue(stored.set(.danmakuSpeed, .number(2), capabilities: all))
    var edits = MacSettingsEdits()
    // Opening and closing without touching anything writes nothing.
    XCTAssertTrue(edits.changes(from: stored).isEmpty)
    // Dragging the opacity slider commits opacity only; 48 and 2 stay as they were.
    edits.record(.danmakuOpacity, .number(0.6))
    let changes = edits.changes(from: stored)
    XCTAssertEqual(changes.map(\.key), [.danmakuOpacity])
    XCTAssertEqual(changes.first?.value, .number(0.6))
    // Moving a slider away and back to the stored value is not a change.
    edits.record(.danmakuFontSize, .number(48))
    XCTAssertEqual(edits.changes(from: stored).map(\.key), [.danmakuOpacity])
    edits.removeAll()
    XCTAssertTrue(edits.isEmpty)
  }

  // MARK: Shield (F14)

  func testShieldEditsMergeIntoTheLatestRules() {
    let stored = DanmakuFilter(rules: ["剧透"])
    // The settings window still holds `stored`; the player panel adds a rule meanwhile.
    let afterPanel = stored.applying(.addRule("/前方高能/"))
    // A type switch in the settings window is applied to the latest rules, not its old copy.
    let afterWindow = afterPanel.applying(.hide(.top, true))
    XCTAssertEqual(afterWindow.rules, ["剧透", "/前方高能/"])
    XCTAssertTrue(afterWindow.hideTop)
    XCTAssertTrue(afterWindow.hides(.top))
    XCTAssertFalse(afterWindow.hides(.bottom))
    XCTAssertEqual(afterWindow.applying(.addRule("剧透")).rules.count, 2)
    XCTAssertEqual(afterWindow.applying(.removeRule("剧透")).rules, ["/前方高能/"])
    XCTAssertEqual(afterWindow.applying(.level(12)).level, 10)
    let full = DanmakuFilter(rules: (0..<DanmakuFilter.maximumRules).map { "r\($0)" })
    XCTAssertEqual(full.applying(.addRule("new")).rules.count, DanmakuFilter.maximumRules)
  }

  // MARK: 全部播放 (F4)

  private func page(_ ids: [Int], hasMore: Bool) -> LibraryPage<LibraryEntry> {
    LibraryPage(items: ids.map { id in
      LibraryEntry(id: "v\(id)", title: "\(id)", destination: id < 0 ? .unavailable : .video(Video(bvid: "BV\(id)", title: "\(id)")))
    }, hasMore: hasMore)
  }

  func testCollectorReadsEveryPageAndSkipsRepeatsAndUnplayable() {
    var collector = PlaylistCollector()
    XCTAssertEqual(collector.nextPage, 1)
    collector.add(page([1, 2, -1], hasMore: true))
    XCTAssertFalse(collector.finished)
    XCTAssertEqual(collector.nextPage, 2)
    // Offset pages can repeat a row after a removal.
    collector.add(page([2, 3], hasMore: false))
    XCTAssertTrue(collector.finished)
    XCTAssertEqual(collector.videos.map(\.bvid), ["BV1", "BV2", "BV3"])
    collector.add(page([4], hasMore: false))
    XCTAssertEqual(collector.videos.count, 3)
  }

  func testCollectorStopsAtTheLimitAndOnAnEmptyPage() {
    var limited = PlaylistCollector(limit: 3)
    limited.add(page([1, 2], hasMore: true))
    limited.add(page([3, 4, 5], hasMore: true))
    XCTAssertTrue(limited.finished)
    XCTAssertEqual(limited.videos.map(\.bvid), ["BV1", "BV2", "BV3"])
    var empty = PlaylistCollector()
    empty.add(page([], hasMore: true))
    XCTAssertTrue(empty.finished)
    XCTAssertEqual(PlaylistCollector.defaultLimit, 1000)
  }

  func testCollectorTellsACutShortListFromOneThatEndsAtTheLimit() {
    // One more playable video than the limit on the same page.
    var midPage = PlaylistCollector(limit: 3)
    midPage.add(page([1, 2, 3, 4], hasMore: false))
    XCTAssertTrue(midPage.finished)
    XCTAssertTrue(midPage.truncated)
    XCTAssertEqual(midPage.videos.count, 3)
    // The limit is reached at a page boundary: reading goes on until a new video turns up.
    var boundary = PlaylistCollector(limit: 3)
    boundary.add(page([1, 2, 3], hasMore: true))
    XCTAssertFalse(boundary.finished)
    boundary.add(page([3, -1, 5], hasMore: true))
    XCTAssertTrue(boundary.finished)
    XCTAssertTrue(boundary.truncated)
    XCTAssertEqual(boundary.videos.map(\.bvid), ["BV1", "BV2", "BV3"])
    // Exactly the limit, then only repeats and unplayable rows: complete, not cut short.
    var exact = PlaylistCollector(limit: 3)
    exact.add(page([1, 2, 3], hasMore: true))
    exact.add(page([2, -1], hasMore: false))
    XCTAssertTrue(exact.finished)
    XCTAssertFalse(exact.truncated)
    var short = PlaylistCollector(limit: 3)
    short.add(page([1, 2], hasMore: false))
    XCTAssertFalse(short.truncated)
  }

  func testPlayAllResultBelongsOnlyToTheListAndAccountItWasReadFrom() {
    let account = AuthSnapshot(epoch: 1, identityRevision: 2, state: .needsLogin, token: nil)
    let folderA = PlaylistContext(list: "folder:1", identity: account)
    // Switching folders, or the account changing under the same folder, invalidates it.
    XCTAssertEqual(folderA, PlaylistContext(list: "folder:1", identity: account))
    XCTAssertNotEqual(folderA, PlaylistContext(list: "folder:2", identity: account))
    XCTAssertNotEqual(folderA, PlaylistContext(list: "later", identity: account))
    XCTAssertNotEqual(folderA, PlaylistContext(list: "folder:1",
      identity: AuthSnapshot(epoch: 1, identityRevision: 3, state: .needsLogin, token: nil)))
    XCTAssertNotEqual(folderA, PlaylistContext(list: "folder:1",
      identity: AuthSnapshot(epoch: 2, identityRevision: 2, state: .needsLogin, token: nil)))
  }

  func testCutShortListSaysSoOnlyWhenItWasCut() {
    var long = PlaylistCollector(limit: 2)
    long.add(page([1, 2, 3], hasMore: true))
    XCTAssertTrue(long.truncated)
    XCTAssertEqual(long.truncationNotice, "列表超过 2 个视频，已播放前 2 个。")
    var exact = PlaylistCollector(limit: 2)
    exact.add(page([1, 2], hasMore: false))
    XCTAssertNil(exact.truncationNotice)
  }

  /// The hand-off is judged when it is confirmed (after the last wait, before the queue
  /// changes), not when the list was read: a read replaced meanwhile, a list switched or an
  /// account changed in between all stop it.
  @MainActor func testPlaylistHandoffIsConfirmedAgainstTheListAtTheLastMoment() {
    let account = AuthSnapshot(epoch: 1, identityRevision: 2, state: .needsLogin, token: nil)
    let state = HandoffListState()
    let revision = state.generation
    let context = PlaylistContext(list: "folder:1", identity: account)
    let handoff = PlaylistHandoff(videos: [Video(bvid: "BV1", title: "1")], identity: account,
      notice: "cut") {
      state.generation == revision && PlaylistContext(list: state.list, identity: account) == context
    }
    XCTAssertNoThrow(try handoff.confirm(current: account))
    XCTAssertEqual(handoff.notice, "cut")
    // The account changed while the identity was being read.
    XCTAssertThrowsError(try handoff.confirm(current:
      AuthSnapshot(epoch: 1, identityRevision: 3, state: .needsLogin, token: nil))) { XCTAssertTrue($0 is CancellationError) }
    // Another folder was picked: the list context no longer matches.
    state.list = "folder:2"
    XCTAssertThrowsError(try handoff.confirm(current: account)) { XCTAssertTrue($0 is CancellationError) }
    state.list = "folder:1"
    XCTAssertNoThrow(try handoff.confirm(current: account))
    // The read was replaced or cancelled (its generation moved on), even for the same list.
    state.generation = UUID()
    XCTAssertThrowsError(try handoff.confirm(current: account)) { XCTAssertTrue($0 is CancellationError) }
  }

  @MainActor func testPlaylistHandoffStopsInACancelledTask() async {
    let account = AuthSnapshot(epoch: 1, identityRevision: 2, state: .needsLogin, token: nil)
    let handoff = PlaylistHandoff(videos: [], identity: account) { true }
    let task = Task { @MainActor () -> Bool in
      while !Task.isCancelled { await Task.yield() }
      do { try handoff.confirm(current: account); return false } catch { return error is CancellationError }
    }
    task.cancel()
    let stopped = await task.value
    XCTAssertTrue(stopped)
  }

  // MARK: Skip ranges (F8)

  func testAutomaticSkipCoversStartInsideSettingChangeAndOncePerRange() {
    let skips = [PlaybackSkip(kind: .opening, start: 0, end: 90), PlaybackSkip(kind: .ending, start: 1300, end: 1400)]
    var tracker = PlaybackSkipTracker(episode: 7)
    // Playback starts inside the opening.
    XCTAssertEqual(tracker.target(skips, at: 0, automatic: true), 90)
    // Seeking back into it later leaves the viewer there.
    XCTAssertNil(tracker.target(skips, at: 10, automatic: true))
    // Automatic skipping off: nothing happens; turned on while the ending plays: it skips.
    XCTAssertNil(tracker.target(skips, at: 1310, automatic: false))
    XCTAssertEqual(tracker.target(skips, at: 1320, automatic: true), 1400)
    // A new episode starts over.
    tracker.reset(episode: 8)
    XCTAssertEqual(tracker.episode, 8)
    XCTAssertEqual(tracker.target(skips, at: 5, automatic: true), 90)
    // A range skipped by hand is not skipped again automatically.
    var manual = PlaybackSkipTracker(episode: 9)
    manual.markHandled(skips[0])
    XCTAssertNil(manual.target(skips, at: 5, automatic: true))
    XCTAssertNil(manual.target(skips, at: .nan, automatic: true))
  }

  // MARK: Mini window (F17)

  func testMiniWindowKeepsTheVideoAspectInsideTheClampedBox() {
    let wide = MiniWindowSizing.size(aspect: 16.0 / 9, boxWidth: 480)
    XCTAssertEqual(wide.width, 480); XCTAssertEqual(wide.height, 270)
    // Portrait: a 9:16 window in a square box, not stretched to 1:1.
    let portrait = MiniWindowSizing.size(aspect: 9.0 / 16, boxWidth: 480)
    XCTAssertEqual(portrait.height, 480); XCTAssertEqual(portrait.width, 270)
    // Ultra-wide: the full box width, the video's own height.
    let ultra = MiniWindowSizing.size(aspect: 3, boxWidth: 480)
    XCTAssertEqual(ultra.width, 480); XCTAssertEqual(ultra.height, 160)
    // Bounded by the screen, keeping the aspect.
    let bounded = MiniWindowSizing.size(aspect: 9.0 / 16, boxWidth: 960, maxHeight: 600)
    XCTAssertEqual(bounded.height, 600); XCTAssertEqual(bounded.width, 338)
    XCTAssertEqual(MiniWindowSizing.aspect(width: 0, height: 1080), 16.0 / 9)
    XCTAssertEqual(MiniWindowSizing.aspect(width: 1080, height: 1920), 0.5625)
    // A window's box width survives an aspect change.
    XCTAssertEqual(MiniWindowSizing.boxWidth(width: 270, height: 480), 480)
    XCTAssertEqual(MiniWindowSizing.boxWidth(width: 480, height: 160), 480)
    XCTAssertEqual(MiniWindowSizing.boxWidth(width: 480, height: 270), 480, accuracy: 0.5)
  }
}

/// The page side of a hand-off: which read is current and which list is shown.
@MainActor private final class HandoffListState {
  var generation = UUID()
  var list = "folder:1"
}
