import CryptoKit
import Darwin
import Foundation

public enum DownloadCompletionFailure: LocalizedError, Equatable, Sendable {
  case invalidPaths, invalidCheckpoint, artifactMismatch
  public var errorDescription: String? {
    switch self {
    case .invalidPaths: "下载完成文件路径无效"
    case .invalidCheckpoint: "下载完成记录无效，请检查任务文件"
    case .artifactMismatch: "已保存文件与下载完成记录不匹配，未认定为完成；原文件已保留"
    }
  }
}

/// A private, per-download checkpoint must remain outside any disposable transfer directory.
/// It contains local artifact metadata only, never source URLs, credentials or account identity.
public enum DownloadCompletion {
  private struct Marker: Codable {
    let version: Int
    let outputPath: String
    let expectedSize: Int64
    let sha256: String
    // Rename preserves identity: an unrelated file with identical bytes is still not our artifact.
    let device: UInt64
    let inode: UInt64
  }
  private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanos: Int64
    init(_ info: stat) {
      device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = info.st_size
      modificationSeconds = Int64(info.st_mtimespec.tv_sec)
      modificationNanos = Int64(info.st_mtimespec.tv_nsec)
    }
  }

  public static func publish(staged: URL, to output: URL, checkpoint: URL) async throws -> URL {
    try await utility {
      let staged = try local(staged); let output = try local(output); let checkpoint = try local(checkpoint)
      guard Set([staged.path, output.path, checkpoint.path]).count == 3 else {
        throw DownloadCompletionFailure.invalidPaths
      }
      guard try inspect(output) == nil else { throw DownloadFailure.outputExists }
      guard let source = try inspect(staged), source.size >= 0 else { throw DownloadCompletionFailure.invalidPaths }
      let parent = output.deletingLastPathComponent()
      var parentInfo = stat()
      guard parent.path.withCString({ Darwin.lstat($0, &parentInfo) }) == 0 else {
        throw DownloadFailure.disk(operation: "读取保存目录", code: Int(errno))
      }
      guard parentInfo.st_mode & S_IFMT == S_IFDIR else { throw DownloadCompletionFailure.invalidPaths }

      var candidate = staged
      var copied: URL?
      var committed = false
      defer {
        if !committed, let copied { try? FileManager.default.removeItem(at: copied) }
      }
      let digest: String
      if source.device == UInt64(parentInfo.st_dev) {
        digest = try stream(staged)
      } else {
        // Cross-volume FileManager moves can expose a partial destination. Copy privately first.
        candidate = parent.appendingPathComponent(".bilibili-publish-\(UUID().uuidString)")
        copied = candidate
        digest = try stream(staged, copyTo: candidate)
      }
      guard try inspect(staged) == source, let artifact = try inspect(candidate), artifact.size == source.size else {
        throw DownloadCompletionFailure.artifactMismatch
      }
      try Task.checkCancellation()
      let marker = Marker(version: 1, outputPath: output.path, expectedSize: artifact.size,
        sha256: digest, device: artifact.device, inode: artifact.inode)
      // Prepare the recoverable record before the only operation that makes media public.
      do { try JSONEncoder().encode(marker).write(to: checkpoint, options: .atomic) }
      catch { throw DownloadFailure.disk("写入完成记录", error) }
      try Task.checkCancellation()
      let result = candidate.path.withCString { sourcePath in
        output.path.withCString { targetPath in Darwin.renamex_np(sourcePath, targetPath, UInt32(RENAME_EXCL)) }
      }
      guard result == 0 else {
        let code = errno
        if code == EEXIST { throw DownloadFailure.outputExists }
        throw DownloadFailure.disk(operation: "发布下载文件", code: Int(code))
      }
      // The marker already identifies this inode. Nothing after the successful rename may throw,
      // including cancellation, cleanup or an optional "final" marker update.
      committed = true
      if copied != nil { try? FileManager.default.removeItem(at: staged) }
      return output
    }
  }

  /// Missing checkpoint/output returns nil; a changed or unowned output throws without deleting it.
  public static func recover(checkpoint: URL) async throws -> URL? {
    try await utility {
      let checkpoint = try local(checkpoint)
      guard let record = try inspect(checkpoint) else { return nil }
      guard record.size > 0, record.size <= 16_384 else { throw DownloadCompletionFailure.invalidCheckpoint }
      let marker: Marker
      do { marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: checkpoint)) }
      catch { throw DownloadCompletionFailure.invalidCheckpoint }
      guard marker.version == 1, marker.outputPath.hasPrefix("/"), !marker.outputPath.utf8.contains(0),
        marker.expectedSize >= 0, marker.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw DownloadCompletionFailure.invalidCheckpoint
      }
      let output = try local(URL(fileURLWithPath: marker.outputPath))
      guard output.path != checkpoint.path else { throw DownloadCompletionFailure.invalidCheckpoint }
      guard let before = try inspect(output) else { return nil }
      guard before.device == marker.device, before.inode == marker.inode, before.size == marker.expectedSize else {
        throw DownloadCompletionFailure.artifactMismatch
      }
      let digest = try stream(output)
      guard digest == marker.sha256, try inspect(output) == before else { throw DownloadCompletionFailure.artifactMismatch }
      try Task.checkCancellation()
      return output
    }
  }

  private static func local(_ url: URL) throws -> URL {
    guard url.isFileURL, url.query == nil, url.fragment == nil, !url.path.utf8.contains(0) else {
      throw DownloadCompletionFailure.invalidPaths
    }
    return url.standardizedFileURL
  }
  private static func inspect(_ url: URL) throws -> FileIdentity? {
    var info = stat()
    guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
      let code = errno
      if code == ENOENT { return nil }
      throw DownloadFailure.disk(operation: "检查完成文件", code: Int(code))
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw DownloadCompletionFailure.artifactMismatch }
    return FileIdentity(info)
  }

  /// The source is opened without following symlinks; memory use is bounded to one 1 MiB chunk.
  private static func stream(_ input: URL, copyTo: URL? = nil) throws -> String {
    let descriptor = input.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw DownloadFailure.disk(operation: "读取媒体校验", code: Int(errno)) }
    let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? reader.close() }
    var info = stat()
    guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw DownloadCompletionFailure.artifactMismatch
    }
    let writer: FileHandle?
    if let copyTo {
      let fd = copyTo.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
      guard fd >= 0 else { throw DownloadFailure.disk(operation: "暂存跨卷文件", code: Int(errno)) }
      writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    } else { writer = nil }
    defer { try? writer?.close() }
    var hasher = SHA256()
    while true {
      try Task.checkCancellation()
      let chunk = try reader.read(upToCount: 1_048_576) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
      try writer?.write(contentsOf: chunk)
    }
    try writer?.synchronize()
    try Task.checkCancellation()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private static func utility<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try operation() }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
}
