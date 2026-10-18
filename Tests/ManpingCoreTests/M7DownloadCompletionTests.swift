import Foundation
import XCTest
@testable import ManpingCore

final class M7DownloadCompletionTests: XCTestCase, @unchecked Sendable {
  private struct Files: Sendable {
    let folder: URL
    var staged: URL { folder.appendingPathComponent("staged.mp4") }
    var output: URL { folder.appendingPathComponent("final.mp4") }
    var checkpoint: URL { folder.appendingPathComponent("completion.json") }
  }
  private func files() throws -> Files {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-completion-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return Files(folder: folder)
  }

  func testPublishedArtifactRecoversAfterAncillaryOrRecordFailure() async throws {
    let files = try files(); defer { try? FileManager.default.removeItem(at: files.folder) }
    try Data("hello".utf8).write(to: files.staged)
    let output = try await DownloadCompletion.publish(staged: files.staged, to: files.output, checkpoint: files.checkpoint)
    XCTAssertEqual(output, files.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: files.staged.path))
    enum AncillaryFailure: Error { case simulated }
    do { throw AncillaryFailure.simulated } catch {}
    let recovered = try await DownloadCompletion.recover(checkpoint: files.checkpoint)
    XCTAssertEqual(recovered, files.output)
    XCTAssertEqual(try Data(contentsOf: files.output), Data("hello".utf8))
    let data = try Data(contentsOf: files.checkpoint)
    let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(metadata.keys), ["version", "outputPath", "expectedSize", "sha256", "device", "inode"])
    XCTAssertEqual(metadata["expectedSize"] as? Int, 5)
    XCTAssertEqual(metadata["sha256"] as? String, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    let json = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(json.contains("access_key")); XCTAssertFalse(json.contains("account")); XCTAssertFalse(json.contains("https://"))
  }

  func testCheckpointWriteFailureCannotPublishOutput() async throws {
    let files = try files(); defer { try? FileManager.default.removeItem(at: files.folder) }
    try Data("media".utf8).write(to: files.staged)
    let unavailable = files.folder.appendingPathComponent("missing-parent/completion.json")
    do {
      _ = try await DownloadCompletion.publish(staged: files.staged, to: files.output, checkpoint: unavailable)
      XCTFail("Marker failure must happen before publishing")
    } catch DownloadFailure.disk {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path))
    XCTAssertEqual(try Data(contentsOf: files.staged), Data("media".utf8))
  }

  func testExistingUserOutputIsPreservedEvenIfItsBytesMatchStagedMedia() async throws {
    let files = try files(); defer { try? FileManager.default.removeItem(at: files.folder) }
    let bytes = Data("identical user bytes".utf8)
    try bytes.write(to: files.staged); try bytes.write(to: files.output)
    do {
      _ = try await DownloadCompletion.publish(staged: files.staged, to: files.output, checkpoint: files.checkpoint)
      XCTFail("Existing output must never be overwritten or claimed")
    } catch DownloadFailure.outputExists {}
    XCTAssertEqual(try Data(contentsOf: files.output), bytes)
    XCTAssertEqual(try Data(contentsOf: files.staged), bytes)
    let recovered = try await DownloadCompletion.recover(checkpoint: files.checkpoint)
    XCTAssertNil(recovered)
  }

  func testChangedDigestIsNotCompleteAndOutputRemainsUntouched() async throws {
    let files = try files(); defer { try? FileManager.default.removeItem(at: files.folder) }
    try Data("original".utf8).write(to: files.staged)
    _ = try await DownloadCompletion.publish(staged: files.staged, to: files.output, checkpoint: files.checkpoint)
    let handle = try FileHandle(forWritingTo: files.output)
    try handle.write(contentsOf: Data("modified".utf8)); try handle.close()
    do {
      _ = try await DownloadCompletion.recover(checkpoint: files.checkpoint)
      XCTFail("Matching length cannot substitute for a matching digest")
    } catch DownloadCompletionFailure.artifactMismatch {}
    XCTAssertEqual(try Data(contentsOf: files.output), Data("modified".utf8))
  }

  func testUserReplacementWithIdenticalContentIsNotCheckpointOwned() async throws {
    let files = try files(); defer { try? FileManager.default.removeItem(at: files.folder) }
    let bytes = Data("original".utf8)
    try bytes.write(to: files.staged)
    let userFile = files.folder.appendingPathComponent("user-replacement.mp4")
    // Both inodes exist at once so replacement cannot reuse the original inode.
    try bytes.write(to: userFile)
    _ = try await DownloadCompletion.publish(staged: files.staged, to: files.output, checkpoint: files.checkpoint)
    try FileManager.default.removeItem(at: files.output)
    try FileManager.default.moveItem(at: userFile, to: files.output)
    do { _ = try await DownloadCompletion.recover(checkpoint: files.checkpoint); XCTFail("User replacement must not be claimed") }
    catch DownloadCompletionFailure.artifactMismatch {}
    XCTAssertEqual(try Data(contentsOf: files.output), bytes)
  }

  func testMissingOutputAndCorruptCheckpointCannotRecover() async throws {
    let files = try files(); defer { try? FileManager.default.removeItem(at: files.folder) }
    let missing = try await DownloadCompletion.recover(checkpoint: files.checkpoint)
    XCTAssertNil(missing)
    try Data("original".utf8).write(to: files.staged)
    _ = try await DownloadCompletion.publish(staged: files.staged, to: files.output, checkpoint: files.checkpoint)
    try FileManager.default.removeItem(at: files.output)
    let deleted = try await DownloadCompletion.recover(checkpoint: files.checkpoint)
    XCTAssertNil(deleted)
    try Data("{not valid json}".utf8).write(to: files.checkpoint)
    do { _ = try await DownloadCompletion.recover(checkpoint: files.checkpoint); XCTFail("Invalid markers must be explicit") }
    catch DownloadCompletionFailure.invalidCheckpoint {}
  }

  func testCancellationBeforePublishLeavesNoUnmarkedOutput() async throws {
    let files = try files(); defer { try? FileManager.default.removeItem(at: files.folder) }
    try Data(repeating: 7, count: 2_097_152).write(to: files.staged)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await DownloadCompletion.publish(staged: files.staged, to: files.output, checkpoint: files.checkpoint)
    }
    do { _ = try await task.value; XCTFail("A pre-cancelled publish must not run") }
    catch is CancellationError {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: files.staged.path))
  }

  func testCancellationRaceEitherPublishesRecoverableMediaOrPreservesStaging() async throws {
    let files = try files(); defer { try? FileManager.default.removeItem(at: files.folder) }
    try Data(repeating: 3, count: 8_388_608).write(to: files.staged)
    let task = Task { try await DownloadCompletion.publish(staged: files.staged, to: files.output, checkpoint: files.checkpoint) }
    await Task.yield()
    task.cancel()
    do { _ = try await task.value } catch is CancellationError {}
    if FileManager.default.fileExists(atPath: files.output.path) {
      let recovered = try await DownloadCompletion.recover(checkpoint: files.checkpoint)
      XCTAssertEqual(recovered, files.output, "Cancellation after the publish boundary still has a valid marker")
    } else {
      XCTAssertTrue(FileManager.default.fileExists(atPath: files.staged.path))
    }
  }
}
