import XCTest

@testable import ManpingCore

final class CoreTests: XCTestCase {
  func testWBIKnownVector() throws {
    let image = "7cd084941338484aae1ad9425b84077c"
    let sub = "4932caff0ff746eab6f01bf08b70ac45"
    XCTAssertEqual(
      try WBI.mixinKey(imageKey: image, subKey: sub), "ea1db124af3c7062474693fa704f4ff8")
    XCTAssertEqual(
      try WBI.sign(
        ["foo": "114", "bar": "514", "zab": "1919810"], imageKey: image, subKey: sub,
        timestamp: 1_702_204_169),
      "bar=514&foo=114&wts=1702204169&zab=1919810&w_rid=8f6f2b5b3d485fe1886cec6a0be8c5d4")
    XCTAssertEqual(WBI.md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
    XCTAssertThrowsError(try WBI.mixinKey(imageKey: "short", subKey: "key"))
  }
  func testWBIFiltersAndEncodes() throws {
    let signed = try WBI.sign(
      ["keyword": "中文!'()* /"], imageKey: String(repeating: "a", count: 32),
      subKey: String(repeating: "b", count: 32), timestamp: 1)
    XCTAssertTrue(signed.hasPrefix("keyword=%E4%B8%AD%E6%96%87%20%2F&wts=1&w_rid="))
  }
  func testDanmakuMediaClockSeekAndPause() throws {
    let comments = try DanmakuParser.parse(
      Data(
        "<i><d p=\"1,1,25,16777215,0\">hello &amp; 中文</d><d p=\"5,5,25,65280,0\">fixed</d><d p=\"nan,1,25,1\">bad</d></i>"
          .utf8))
    XCTAssertEqual(comments.count, 2)
    let timeline = DanmakuTimeline(comments: comments, lanes: 2, duration: 8)
    XCTAssertEqual(timeline.visible(at: 0).count, 0)
    XCTAssertEqual(timeline.visible(at: 3).first?.comment.text, "hello & 中文")
    XCTAssertEqual(timeline.visible(at: 3).first!.progress, 0.25, accuracy: 0.001)
    XCTAssertEqual(timeline.visible(at: 3).first!.progress, timeline.visible(at: 3).first!.progress)
    XCTAssertEqual(timeline.visible(at: 15).count, 0)
    XCTAssertEqual(timeline.visible(at: 3).count, 1)
    XCTAssertTrue(timeline.visible(at: .nan).isEmpty)
  }
  func testDanmakuLanesNeverOverlapAtAnySpeed() {
    // Dense mixed lines: short, long, ASCII and CJK, every 0.15 s.
    let texts = ["前方高能", "这段配乐太好听了，单曲循环一整天", "QAQ", "RTX2080S无所畏惧", "awsl", "白色背景上依然清楚"]
    let comments = (0..<400).map { DanmakuComment(time: Double($0) * 0.15, text: texts[$0 % texts.count]) }
    for speed in [0.5, 1, 2] {
      var timeline = DanmakuTimeline(comments: comments, lanes: 12, duration: 8)
      timeline.setSpeed(speed)
      XCTAssertGreaterThan(timeline.count, 40)
      // Render with the assumed width in ems: same-lane lines never touch.
      let width = 28.0
      for clock in stride(from: 0.0, through: 60, by: 0.25) {
        let visible = timeline.visible(at: clock, speed: speed)
        for lane in Set(visible.map(\.lane)) {
          let spans = visible.filter { $0.lane == lane }.map { item -> (Double, Double) in
            let length = DanmakuTimeline.estimatedLength(item.comment.text)
            let x = width - item.progress * (width + length)
            return (x, x + length)
          }.sorted { $0.0 < $1.0 }
          for (left, right) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(left.1, right.0 + 1e-6, "speed \(speed) lane \(lane) at \(clock)")
          }
        }
      }
    }
  }
  func testDanmakuTopAndBottomLinesKeepTheirOwnSpace() {
    let timeline = DanmakuTimeline(
      comments: [
        DanmakuComment(time: 0, text: "滚动"), DanmakuComment(time: 0.1, mode: 5, text: "顶部"),
        DanmakuComment(time: 0.2, mode: 4, text: "底部"), DanmakuComment(time: 0.3, mode: 4, text: "底部二"),
      ], lanes: 4, duration: 8)
    let visible = timeline.visible(at: 1)
    let scrolling = visible.first { $0.comment.mode == 1 }!
    let top = visible.first { $0.comment.mode == 5 }!
    XCTAssertNotEqual(scrolling.lane, top.lane, "a top line never sits on a lane a scrolling line is using")
    XCTAssertEqual(visible.filter { $0.comment.mode == 4 }.map(\.lane), [0, 1])
  }
  func testAPIParsingRejectsInvalidAndAcceptsDASH() throws {
    XCTAssertThrowsError(try Video.parse(["title": "missing bvid"]))
    XCTAssertThrowsError(try PlaybackManifest.parse([:]))
    let stream: [String: Any] = [
      "id": 80, "codecs": "avc1.640032", "baseUrl": "https://example.com/video", "bandwidth": 1000,
    ]
    let audio: [String: Any] = ["id": 30280, "base_url": "https://example.com/audio"]
    let parsed = try PlaybackManifest.parse([
      "dash": ["video": [stream], "audio": [audio], "duration": 12.5], "accept_quality": [80],
      "accept_description": ["1080P"],
    ])
    XCTAssertEqual(parsed.video.first?.label, "1080P")
    XCTAssertEqual(parsed.audio.count, 1)
    XCTAssertEqual(parsed.duration, 12.5)
  }
  func testPersistenceRecoversInterruptedTasks() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
      let store = try DownloadStore(url: folder.appendingPathComponent("tasks.sqlite"))
      try store.save(
        DownloadRecord(
          id: "test", bvid: "BV-test", title: "test", state: "downloading", progress: 0.4))
    }
    let recovered = try DownloadStore(url: folder.appendingPathComponent("tasks.sqlite"))
    XCTAssertEqual(try recovered.records().first?.state, "interrupted")
    XCTAssertEqual(try recovered.records().first?.progress, 0.4)
  }
  func testServiceHTTPFailureAndMissingFFmpeg() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailureProtocol.self]
    // Download delegates do not use a custom supplied session; test the actual HTTP failure via a localhost server in integration checks.
    let service = BiliService(session: URLSession(configuration: config))
    do {
      _ = try await service.data(URL(string: "https://example.com/failure")!)
      XCTFail("Expected HTTP error")
    } catch BiliError.http(let code) { XCTAssertEqual(code, 403) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      try await DownloadWorker.merge(video: folder, audio: folder, output: folder, ffmpeg: folder)
      XCTFail("Missing FFmpeg must fail")
    } catch BiliError.dependency {}
  }
  func testActualDownloadDelegateRejectsHTTPFailure() async throws {
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = [
      "-u", "-c",
      "import http.server; s=http.server.HTTPServer(('127.0.0.1',0),http.server.BaseHTTPRequestHandler); print(s.server_port,flush=True); s.serve_forever()",
    ]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer { server.terminate() }
    var bytes = Data()
    while true {
      let byte = pipe.fileHandleForReading.readData(ofLength: 1)
      if byte.isEmpty || byte == Data([10]) { break }
      bytes.append(byte)
    }
    let port = try XCTUnwrap(Int(String(decoding: bytes, as: UTF8.self)))
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    do {
      _ = try await DownloadWorker.resumeTransfer(
        request: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/missing")!), to: destination)
      XCTFail("The HTTP error page must not become a downloaded file")
    } catch BiliError.http(let code) { XCTAssertEqual(code, 501) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }
  func testDiagnosticRedaction() {
    XCTAssertEqual(
      DiagnosticRedactor.sanitize("HTTP failed https://cdn.example.com/media?token=private"),
      "HTTP failed [URL redacted]")
    XCTAssertEqual(
      DiagnosticRedactor.sanitize("Cookie: SESSDATA=private"),
      "[credential-bearing diagnostic redacted]")
    XCTAssertEqual(
      DiagnosticRedactor.sanitize("Authorization: Bearer private"),
      "[credential-bearing diagnostic redacted]")
    XCTAssertEqual(
      DiagnosticRedactor.sanitize("qrcode_key=private"), "[credential-bearing diagnostic redacted]")
  }

  func testActualFFmpegMerge() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let ffmpeg = environment["MANPING_FFMPEG"], let video = environment["MANPING_MERGE_VIDEO"],
      let audio = environment["MANPING_MERGE_AUDIO"]
    else {
      throw XCTSkip(
        "Set MANPING_FFMPEG/MANPING_MERGE_VIDEO/MANPING_MERGE_AUDIO for real merger verification")
    }
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    try await DownloadWorker.merge(
      video: URL(fileURLWithPath: video), audio: URL(fileURLWithPath: audio), output: output,
      ffmpeg: URL(fileURLWithPath: ffmpeg))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    let verify = Process()
    verify.executableURL = URL(fileURLWithPath: ffmpeg)
    verify.arguments = [
      "-nostdin", "-v", "error", "-i", output.path, "-map", "0:v:0", "-map", "0:a:0", "-frames:v",
      "1", "-f", "null", "-",
    ]
    verify.standardOutput = FileHandle.nullDevice
    verify.standardError = FileHandle.nullDevice
    try verify.run()
    verify.waitUntilExit()
    XCTAssertEqual(verify.terminationStatus, 0)
  }

  func testLivePublicAPI() async throws {
    guard ProcessInfo.processInfo.environment["MANPING_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set MANPING_LIVE_TESTS=1 for actual Bilibili requests")
    }
    let service = BiliService()
    print("LIVE_STAGE wbi")
    try await service.refreshKeys()
    print("LIVE_STAGE popular")
    let popular = try await service.popular()
    XCTAssertFalse(popular.isEmpty)
    print("LIVE_STAGE qr-generate")
    let qr = try await service.beginQR()
    XCTAssertEqual(qr.url.scheme, "https")
    guard let first = popular.first else { return }
    print("LIVE_STAGE detail")
    let detail = try await service.detail(first.bvid)
    XCTAssertNotNil(detail.cid)
    print("LIVE_STAGE playurl")
    let manifest = try await service.playback(detail)
    XCTAssertFalse(manifest.video.isEmpty)
    XCTAssertFalse(manifest.audio.isEmpty)
    // Signed URLs and QR secrets are deliberately not printed.
  }
}
private final class FailureProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("denied".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
