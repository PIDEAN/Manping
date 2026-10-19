import Foundation
import Darwin
import XCTest
@testable import ManpingCore

final class M7DownloadTests: XCTestCase {
  func testLegacyPayloadAndOptionalPlanRoundTrip() throws {
    let old = Data(#"{"id":"old","bvid":"BVfixture","title":"Old","state":"downloading","progress":0.3,"output":"","error":""}"#.utf8)
    var record = try JSONDecoder().decode(DownloadRecord.self, from: old)
    XCTAssertNil(record.options)
    record.options = DownloadOptions(cid: 100, quality: 64, pages: [1, 3], directory: "/fixture")
    let decoded = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(record))
    XCTAssertEqual(decoded.options, record.options)
    XCTAssertEqual(decoded.id, "old")
    XCTAssertEqual(decoded.progress, 0.3)
  }
  func testResumeWithMatchingValidatorProducesIdenticalBytes() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let destination = fixture.folder.appendingPathComponent("video.m4s")
    try fixture.seed(destination, bytes: "abc", total: 10)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("resume"), to: destination)
    XCTAssertEqual(try Data(contentsOf: destination), Data("abcdefghij".utf8))
    let metadata = try Data(contentsOf: destination.appendingPathExtension("resume.json"))
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), Set(["etag", "totalBytes"]))
    XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("access_key"))
    XCTAssertEqual(try fixture.requests().first?["range"], "bytes=3-")
    XCTAssertEqual(try fixture.requests().first?["ifrange"], "\"fixture\"")
  }
  func testIgnoredRangeRestartsWithoutAppendingOldBytes() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("video.m4s")
    try fixture.seed(file, bytes: "old", total: 10)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("ignore"), to: file)
    XCTAssertEqual(try Data(contentsOf: file), Data("abcdefghij".utf8))
  }
  func testInvalid206DoesNotCorruptExistingPartial() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("video.m4s")
    try fixture.seed(file, bytes: "abc", total: 10)
    do {
      _ = try await DownloadWorker.resumeTransfer(request: fixture.request("bad-range"), to: file)
      XCTFail("A range starting after the saved bytes must fail")
    } catch DownloadFailure.invalidRange {}
    XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
  }
  func test416OnlyCompletesMatchingTotalOtherwiseRestartsOnce() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let complete = fixture.folder.appendingPathComponent("complete.m4s")
    try fixture.seed(complete, bytes: "abcdefghij", total: 10)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("complete"), to: complete)
    XCTAssertEqual(try Data(contentsOf: complete), Data("abcdefghij".utf8))
    let stale = fixture.folder.appendingPathComponent("stale.m4s")
    try fixture.seed(stale, bytes: "abc", total: 100)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("restart"), to: stale)
    XCTAssertEqual(try Data(contentsOf: stale), Data("abcdefghij".utf8))
    let requests = try fixture.requests()
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests.last?["range"], "")
  }
  func test416ChangedLastModifiedCannotCompleteEqualLengthPartial() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("dated.m4s")
    try fixture.seed(file, bytes: "oldoldold!", total: 10, etag: nil,
      lastModified: "Mon, 12 Oct 2026 00:00:00 GMT")
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("modified"), to: file)
    XCTAssertEqual(try Data(contentsOf: file), Data("abcdefghij".utf8))
    let requests = try fixture.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.first?["range"], "bytes=10-")
    XCTAssertEqual(requests.first?["ifrange"], "Mon, 12 Oct 2026 00:00:00 GMT")
    XCTAssertEqual(requests.last?["range"], "")
  }
  func test416MatchingLastModifiedCompletesWeakETagFallback() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("date-complete.m4s")
    try fixture.seed(file, bytes: "abcdefghij", total: 10, etag: "W/\"fixture\"",
      lastModified: "Tue, 13 Oct 2026 00:00:00 GMT")
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("date-complete"), to: file)
    XCTAssertEqual(try Data(contentsOf: file), Data("abcdefghij".utf8))
    let requests = try fixture.requests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?["ifrange"], "Tue, 13 Oct 2026 00:00:00 GMT")
  }
  func test416UsesStrongETagBeforeChangedLastModified() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("etag.m4s")
    try fixture.seed(file, bytes: "abcdefghij", total: 10,
      lastModified: "Mon, 12 Oct 2026 00:00:00 GMT")
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("complete"), to: file)
    XCTAssertEqual(try Data(contentsOf: file), Data("abcdefghij".utf8))
    let requests = try fixture.requests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?["ifrange"], "\"fixture\"")
  }
  func testMatchingIdentityResumes206ButChangedIdentityStartsWithoutOldRange() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("identity.m4s")
    let original = "aid:100:cid:200:quality:80:codec:7:bandwidth:1000"
    let replacement = "aid:100:cid:200:quality:64:codec:7:bandwidth:500"
    try fixture.seed(file, bytes: "abc", total: 10, identity: original)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("resume"), to: file, identity: original)
    XCTAssertEqual(try Data(contentsOf: file), Data("abcdefghij".utf8))
    // Same validator and equal-length fallback resource still cannot reuse another stream's bytes.
    try fixture.seed(file, bytes: "old", total: 10, identity: original)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("resume"), to: file, identity: replacement)
    XCTAssertEqual(try Data(contentsOf: file), Data("abcdefghij".utf8))
    let requests = try fixture.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.first?["range"], "bytes=3-")
    XCTAssertEqual(requests.last?["range"], "")
    XCTAssertEqual(requests.last?["ifrange"], "")
    let metadata = try JSONDecoder().decode(DownloadResumeMetadata.self,
      from: Data(contentsOf: file.appendingPathExtension("resume.json")))
    XCTAssertEqual(metadata.identity, replacement)
  }
  func testBoundDownloadSafelyResetsUnboundLegacyMetadata() async throws {
    let old = Data(#"{"etag":"\"fixture\"","totalBytes":10}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(DownloadResumeMetadata.self, from: old).identity)
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("legacy.m4s")
    try fixture.seed(file, bytes: "old", total: 10)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("resume"), to: file,
      identity: "aid:100:cid:200:quality:80:codec:7:bandwidth:1000")
    XCTAssertEqual(try fixture.requests().first?["range"], "")
    XCTAssertEqual(try Data(contentsOf: file), Data("abcdefghij".utf8))
  }
  func testInterruptedBodyCanResumeWithoutLosingReceivedBytes() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("short.m4s")
    let request = fixture.request("short")
    let task = Task { try await DownloadWorker.resumeTransfer(request: request, to: file) }
    defer { task.cancel() }
    // Do not close a tiny response before CFNetwork has delivered any delegate callbacks.
    // The server sends a realistic chunk and waits for acknowledgement of actual disk persistence.
    try await fixture.waitForPartial(file)
    XCTAssertEqual(try Data(contentsOf: file), fixture.initialChunk)
    try fixture.release("short")
    do { _ = try await task.value; XCTFail("Truncated response must not succeed") }
    catch {}
    XCTAssertEqual(try Data(contentsOf: file), fixture.initialChunk)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("short"), to: file)
    XCTAssertEqual(try Data(contentsOf: file), fixture.mediaPayload)
    let requests = try fixture.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.last?["range"], "bytes=262144-")
    XCTAssertEqual(requests.last?["ifrange"], "\"fixture\"")
  }
  func testCancellationRetainsPartialAndDoesNotComplete() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("slow.m4s")
    let request = fixture.request("slow")
    let task = Task { try await DownloadWorker.resumeTransfer(request: request, to: file) }
    defer { task.cancel() }
    try await fixture.waitForPartial(file)
    XCTAssertEqual(try Data(contentsOf: file), fixture.initialChunk)
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled transfer must fail") }
    catch is CancellationError {}
    XCTAssertEqual(try Data(contentsOf: file), fixture.initialChunk)
    try fixture.release("slow")
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("slow"), to: file)
    XCTAssertEqual(try Data(contentsOf: file), fixture.mediaPayload)
    let requests = try fixture.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.last?["range"], "bytes=262144-")
    XCTAssertEqual(requests.last?["ifrange"], "\"fixture\"")
  }
  func testDiskFailurePreservesExistingDirectory() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let directory = fixture.folder.appendingPathComponent("user-directory")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let userFile = directory.appendingPathComponent("important")
    try Data("keep".utf8).write(to: userFile)
    do {
      _ = try await DownloadWorker.resumeTransfer(request: fixture.request("resume"), to: directory)
      XCTFail("A directory cannot be a transfer output")
    } catch DownloadFailure.disk {}
    XCTAssertEqual(try Data(contentsOf: userFile), Data("keep".utf8))
  }
  func testMetadataDiskFailureDoesNotSucceedOrDeleteUserFiles() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("video.m4s")
    let marker = fixture.folder.appendingPathComponent("existing-marker")
    try Data("keep".utf8).write(to: marker)
    let invalidSidecar = marker.appendingPathComponent("resume.json")
    do {
      _ = try await DownloadWorker.resumeTransfer(request: fixture.request("resume"), to: file, metadataURL: invalidSidecar)
      XCTFail("A metadata write into a regular file must fail")
    } catch DownloadFailure.disk {}
    XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
  }
  func testNoValidatorNeverReusesUnverifiablePartial() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let file = fixture.folder.appendingPathComponent("no-validator.m4s")
    try Data("old".utf8).write(to: file)
    _ = try await DownloadWorker.resumeTransfer(request: fixture.request("resume"), to: file)
    XCTAssertEqual(try Data(contentsOf: file), Data("abcdefghij".utf8))
    XCTAssertEqual(try fixture.requests().first?["range"], "")
  }
  func testMergeFailureAndCancellationNeverReplaceUserOutput() async throws {
    let fixture = try DownloadHTTPFixture(); defer { fixture.stop() }
    let executable = fixture.folder.appendingPathComponent("fake-ffmpeg")
    try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let output = fixture.folder.appendingPathComponent("output.mp4")
    try Data("user-file".utf8).write(to: output)
    do {
      try await DownloadWorker.merge(video: output, audio: output, output: output, ffmpeg: executable)
      XCTFail("Existing output must be preserved")
    } catch DownloadFailure.outputExists {}
    XCTAssertEqual(try Data(contentsOf: output), Data("user-file".utf8))
    let cancelledOutput = fixture.folder.appendingPathComponent("cancelled.mp4")
    let task = Task { try await DownloadWorker.merge(video: output, audio: output, output: cancelledOutput, ffmpeg: executable) }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    do { try await task.value; XCTFail("Cancelled merger must fail") } catch is CancellationError {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledOutput.path))
    XCTAssertEqual(try Data(contentsOf: output), Data("user-file".utf8))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).contains(where: { $0.hasPrefix(".merge-") }))
    let failing = fixture.folder.appendingPathComponent("failing-ffmpeg")
    try Data("#!/bin/sh\nfor output; do :; done\nprintf partial > \"$output\"\nexit 9\n".utf8).write(to: failing)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failing.path)
    let failedOutput = fixture.folder.appendingPathComponent("failed.mp4")
    do {
      try await DownloadWorker.merge(video: output, audio: output, output: failedOutput, ffmpeg: failing)
      XCTFail("Failed merger must not leave a completed output")
    } catch BiliError.process(let code, _) { XCTAssertEqual(code, 9) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: failedOutput.path))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).contains(where: { $0.hasPrefix(".merge-") }))
  }
  func testOptionsAndExportsAreUsableAndCredentialFree() throws {
    XCTAssertEqual(try DownloadOptions.parsePages("1,3,5-7,3", count: 8), [1, 3, 5, 6, 7])
    XCTAssertThrowsError(try DownloadOptions.parsePages("1-99", count: 8))
    XCTAssertThrowsError(try DownloadOptions.parsePages("", count: 8))
    let options = DownloadOptions(quality: 80, codec: .hevc, pages: [1, 3], directory: "/tmp/a'b $(touch unsafe)", includeDanmaku: true)
    let command = try BBDownCommand.build(source: "BVfixture", options: options)
    XCTAssertTrue(command.contains("'--select-page' '1,3'"))
    XCTAssertTrue(command.contains("a'\"'\"'b $(touch unsafe)"))
    XCTAssertFalse(command.contains("--cookie")); XCTAssertFalse(command.contains("-token"))
    XCTAssertThrowsError(try BBDownCommand.build(source: "https://www.bilibili.com/video/BVfixture?access_key=fixture-only", options: options))
    let cues = try DownloadExport.parseSubtitleJSON(Data(#"{"body":[{"from":1.25,"to":2.5,"content":"中文"}]}"#.utf8))
    XCTAssertTrue(String(decoding: DownloadExport.subtitleSRT(cues), as: UTF8.self).contains("00:00:01,250 --> 00:00:02,500\n中文"))
  }
}

private final class DownloadHTTPFixture: @unchecked Sendable {
  let folder: URL
  private let process: Process
  private let exitLatch = DispatchSemaphore(value: 0)
  private let port: Int
  init() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("Bili-download-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", "-c", Self.server, folder.path]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    // Async XCTest can resume on another executor thread; do not wait on Process's creation runloop.
    let latch = exitLatch
    process.terminationHandler = { _ in latch.signal() }
    do {
      try process.run()
      var bytes = Data()
      while true {
        let byte = pipe.fileHandleForReading.readData(ofLength: 1)
        if byte.isEmpty || byte == Data([10]) { break }
        bytes.append(byte)
      }
      guard let value = Int(String(decoding: bytes, as: UTF8.self)) else { throw BiliError.dependency("Fixture HTTP server failed") }
      port = value
    } catch {
      if process.processIdentifier > 0 { Self.stop(process, exitLatch: exitLatch) }
      try? FileManager.default.removeItem(at: folder); throw error
    }
  }
  func stop() {
    Self.stop(process, exitLatch: exitLatch)
    try? FileManager.default.removeItem(at: folder)
  }
  private static func stop(_ process: Process, exitLatch: DispatchSemaphore) {
    if process.isRunning { process.terminate() }
    if exitLatch.wait(timeout: .now() + 1) == .timedOut {
      if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
      _ = exitLatch.wait(timeout: .now() + 1)
    }
  }
  var mediaPayload: Data { Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) }) }
  var initialChunk: Data { mediaPayload.prefix(256 * 1024) }
  func waitForPartial(_ file: URL) async throws {
    for _ in 0..<500 {
      let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
      if (attributes?[.size] as? NSNumber)?.intValue == 256 * 1024 { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw BiliError.invalidResponse("Fixture did not persist the first 256 KiB before timeout")
  }
  func release(_ path: String) throws {
    try Data().write(to: folder.appendingPathComponent("release-" + path))
  }
  func request(_ path: String) -> URLRequest {
    URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)?access_key=fixture-only")!)
  }
  func seed(_ destination: URL, bytes: String, total: Int64, etag: String? = "\"fixture\"",
            lastModified: String? = nil, identity: String? = nil) throws {
    try Data(bytes.utf8).write(to: destination)
    try JSONEncoder().encode(DownloadResumeMetadata(etag: etag, lastModified: lastModified, totalBytes: total, identity: identity))
      .write(to: destination.appendingPathExtension("resume.json"))
  }
  func requests() throws -> [[String: String]] {
    let log = try String(contentsOf: folder.appendingPathComponent("requests.jsonl"), encoding: .utf8)
    return try log.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]) }
  }
  private static let server = #"""
import http.server, sys, json, os, time
folder=sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_GET(self):
        path=self.path.split('?')[0]
        value=self.headers.get('Range','')
        with open(os.path.join(folder,'requests.jsonl'),'a') as f:
            f.write(json.dumps({'range':value,'ifrange':self.headers.get('If-Range','')})+'\n')
        data=bytes(range(256))*4096 if path in ['/short','/slow'] else b'abcdefghij'
        if path in ['/complete','/restart','/modified','/date-complete'] and value:
            self.send_response(416); self.send_header('Content-Range','bytes */10')
            if path not in ['/modified','/date-complete']: self.send_header('ETag','"fixture"')
            self.send_header('Last-Modified','Tue, 13 Oct 2026 00:00:00 GMT')
            self.send_header('Content-Length','0'); self.end_headers(); return
        if value and path != '/ignore':
            start=int(value[6:-1])
            if path == '/bad-range': start+=1
            body=data[start:]
            self.send_response(206); self.send_header('Content-Range',f'bytes {start}-{len(data)-1}/{len(data)}')
        else:
            body=data; self.send_response(200)
        self.send_header('ETag','"fixture"'); self.send_header('Content-Length',str(len(body))); self.end_headers()
        self.wfile.flush()
        if path in ['/short','/slow'] and not value:
            chunk=256*1024
            self.wfile.write(body[:chunk]); self.wfile.flush()
            marker=os.path.join(folder,'release-'+path[1:])
            for _ in range(1000):
                if os.path.exists(marker): break
                time.sleep(0.01)
            if path == '/short':
                self.close_connection=True; return
            try: self.wfile.write(body[chunk:]); self.wfile.flush()
            except (BrokenPipeError,ConnectionResetError): pass
            return
        self.wfile.write(body); self.wfile.flush()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
server.daemon_threads=True
print(server.server_port,flush=True)
server.serve_forever()
"""#
}
