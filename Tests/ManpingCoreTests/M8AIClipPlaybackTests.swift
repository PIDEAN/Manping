import Foundation
import XCTest
@testable import ManpingCore

final class M8AIClipPlaybackTests: XCTestCase {
  private let media = "video:1:2"
  private let clips = [AITimeRange(start: 232, end: 250), AITimeRange(start: 618, end: 652)]

  /// Plays both clips: seek, land, run to the end, seek the next, land, run to the end, pause.
  func testPlaysClipsInOrderAndPausesAfterTheLast() {
    var machine = AIClipPlaybackMachine()
    XCTAssertEqual(machine.start(clips: clips.reversed(), media: media, position: 30, now: 0), [.seek(232), .play])
    XCTAssertEqual(machine.phase, .seeking(index: 0))
    // A stale sample from before the seek is ignored.
    XCTAssertEqual(machine.tick(time: 30.1, media: media, now: 0.1), [])
    XCTAssertEqual(machine.phase, .seeking(index: 0))
    XCTAssertEqual(machine.tick(time: 231.2, media: media, now: 0.4), [])
    XCTAssertEqual(machine.phase, .playing(index: 0))
    for time in stride(from: 231.5, to: 249.7, by: 0.3) { XCTAssertEqual(machine.tick(time: time, media: media, now: 1), []) }
    XCTAssertEqual(machine.tick(time: 249.8, media: media, now: 20), [.seek(618)])
    XCTAssertEqual(machine.phase, .seeking(index: 1))
    // Samples near the old clip's end arrive before the seek lands.
    XCTAssertEqual(machine.tick(time: 250, media: media, now: 20.1), [])
    XCTAssertEqual(machine.tick(time: 618, media: media, now: 20.3), [])
    XCTAssertEqual(machine.phase, .playing(index: 1))
    for time in stride(from: 618.3, to: 651.7, by: 0.3) { XCTAssertEqual(machine.tick(time: time, media: media, now: 30), []) }
    XCTAssertEqual(machine.tick(time: 651.8, media: media, now: 55), [.pause])
    XCTAssertFalse(machine.isActive)
    XCTAssertEqual(machine.lastExit, .finished)
  }

  func testUserJumpsAndMediaChangesEndTheMode() {
    var machine = AIClipPlaybackMachine()
    _ = machine.start(clips: clips, media: media, position: 0, now: 0)
    _ = machine.tick(time: 232, media: media, now: 0.5)
    _ = machine.tick(time: 233, media: media, now: 1.5)
    // Dragging back by more than 1.5 s is the user's jump.
    XCTAssertEqual(machine.tick(time: 230, media: media, now: 1.6), [])
    XCTAssertEqual(machine.lastExit, .userSeek)
    XCTAssertFalse(machine.isActive)

    _ = machine.start(clips: clips, media: media, position: 0, now: 10)
    _ = machine.tick(time: 232, media: media, now: 10.5)
    XCTAssertEqual(machine.tick(time: 400, media: media, now: 10.6), [])
    XCTAssertEqual(machine.lastExit, .userSeek)

    _ = machine.start(clips: clips, media: media, position: 0, now: 20)
    XCTAssertEqual(machine.tick(time: 232, media: "video:1:3", now: 20.5), [])
    XCTAssertEqual(machine.lastExit, .mediaChanged)
    XCTAssertEqual(machine.tick(time: 233, media: media, now: 21), [])
  }

  func testSeekTimeoutAndStopAndContiguousClips() {
    var machine = AIClipPlaybackMachine()
    _ = machine.start(clips: clips, media: media, position: 0, now: 0)
    machine.check(now: 5)
    XCTAssertTrue(machine.isActive)
    machine.check(now: AIClipPlaybackMachine.seekTimeout + 1)
    XCTAssertEqual(machine.lastExit, .seekFailed)

    _ = machine.start(clips: clips, media: media, position: 0, now: 0)
    machine.stop()
    XCTAssertEqual(machine.lastExit, .stopped)
    XCTAssertEqual(machine.tick(time: 232, media: media, now: 1), [])

    // Touching clips play straight through without another seek.
    let touching = [AITimeRange(start: 10, end: 30), AITimeRange(start: 30.2, end: 50)]
    _ = machine.start(clips: touching, media: media, position: 0, now: 0)
    _ = machine.tick(time: 10, media: media, now: 0.5)
    for time in stride(from: 10.3, to: 29.7, by: 0.3) { _ = machine.tick(time: time, media: media, now: 1) }
    XCTAssertEqual(machine.tick(time: 29.8, media: media, now: 2), [])
    XCTAssertEqual(machine.phase, .playing(index: 1))
    // Nothing usable: nothing starts.
    var empty = AIClipPlaybackMachine()
    XCTAssertEqual(empty.start(clips: [AITimeRange(start: 5, end: 5)], media: media, position: nil, now: 0), [])
    XCTAssertFalse(empty.isActive)
  }

  func testTimestampScannerAndMarkdownExport() {
    let text = "在 05:48 提到，1:02:03 也有；2026-10-18 12:30 不算日期外的 99:99，3.10:20 也不算"
    let found = AITimestampScanner.matches(in: text).map(\.seconds)
    XCTAssertEqual(found.prefix(2), [348, 3723])
    XCTAssertFalse(found.contains(where: { $0 > 4000 }))

    let chapters = AIChaptersResult(overview: "概述", chapters: [
      AIChapterItem(start: AITimestamp(seconds: 12, text: "00:12", seekable: true), end: AITimestamp(seconds: 24, text: "00:24", seekable: true),
        title: "出发", points: ["沿 318 国道往西"], highlight: false, evidence: ["c1"]),
      AIChapterItem(start: AITimestamp(seconds: 300, text: "05:00", seekable: false), end: nil, title: "无依据", points: [], highlight: false, evidence: [])],
      sources: [], insufficient: false)
    let content = AIAnswerContent.structured(.chapters(chapters))
    XCTAssertTrue(content.markdownText.contains("- **00:12–00:24 出发**：沿 318 国道往西"))
    XCTAssertEqual(content.citedTimes, [12])
    let thread = AIThread(sourceKey: media, title: "走进山野", turns: [
      AITurn(presetID: "chapters", presetName: "章节总结", question: nil, content: content, rawText: "{}", materials: [.subtitles],
        model: "m", provider: "p"),
      AITurn(presetID: "qa", presetName: "问答", question: "在哪里？", content: .markdown("观景台"), rawText: "观景台", materials: [], model: "m", provider: "p")])
    let markdown = thread.markdown(sourceTitle: "走进山野")
    XCTAssertTrue(markdown.hasPrefix("# 走进山野"))
    XCTAssertTrue(markdown.contains("## 章节总结"))
    XCTAssertTrue(markdown.contains("## 在哪里？"))
    XCTAssertTrue(markdown.contains("依据：字幕"))
  }

  func testClearThreadRemovesOnlyThatSource() async throws {
    let service = try AIConversationService.fixture()
    let first = AISource.video(AIVideoInfo(aid: 1, cid: 2, title: "走进山野", duration: 1104, uploaderMid: 2))
    let second = AISource.video(AIVideoInfo(aid: 1, cid: 3, title: "走进山野 P2", duration: 1104, uploaderMid: 2))
    let options = AIRunOptions(provider: .openAI, modelID: "fixture-model")
    for source in [first, second] {
      for await _ in await service.start(preset: AIBuiltInPresets.chapters, source: source, options: options).events {}
    }
    let saved = await service.thread(for: first)
    XCTAssertEqual(saved?.turns.count, 1)
    try await service.clearThread(for: first)
    let cleared = await service.thread(for: first)
    let kept = await service.thread(for: second)
    XCTAssertNil(cleared)
    XCTAssertEqual(kept?.turns.count, 1)
  }

  /// Small manual seeks inside a clip are invisible to the clock check; the reported seek ends the mode.
  func testReportedSeeksTellTheMachinesOwnFromTheUsers() {
    for offset in [2.0, -1.0] {
      var machine = AIClipPlaybackMachine()
      _ = machine.start(clips: clips, media: media, position: 0, now: 0)
      // The machine's own seek is reported back and recognised.
      XCTAssertFalse(machine.seekRequested(to: 232))
      XCTAssertTrue(machine.isActive)
      _ = machine.tick(time: 232, media: media, now: 0.5)
      _ = machine.tick(time: 236, media: media, now: 4.5)
      XCTAssertEqual(machine.phase, .playing(index: 0))
      // The same small jump through the clock alone would not end it.
      var clockOnly = machine
      XCTAssertEqual(clockOnly.tick(time: 236 + offset, media: media, now: 4.6), [])
      XCTAssertTrue(clockOnly.isActive)
      XCTAssertTrue(machine.seekRequested(to: 236 + offset))
      XCTAssertFalse(machine.isActive)
      XCTAssertEqual(machine.lastExit, .userSeek)
    }
    // The seek to the next clip is the machine's own too; a repeat of it is not.
    var machine = AIClipPlaybackMachine()
    _ = machine.start(clips: clips, media: media, position: 0, now: 0)
    XCTAssertFalse(machine.seekRequested(to: 232))
    _ = machine.tick(time: 232, media: media, now: 0.5)
    for time in stride(from: 232.5, to: 249.7, by: 0.5) { _ = machine.tick(time: time, media: media, now: 1) }
    XCTAssertEqual(machine.tick(time: 249.9, media: media, now: 18), [.seek(618)])
    XCTAssertFalse(machine.seekRequested(to: 618))
    XCTAssertTrue(machine.isActive)
    XCTAssertTrue(machine.seekRequested(to: 618))
    XCTAssertEqual(machine.lastExit, .userSeek)
    // Idle: nothing to end.
    XCTAssertFalse(machine.seekRequested(to: 10))
  }

}
