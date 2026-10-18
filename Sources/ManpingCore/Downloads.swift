import CSQLite
import Foundation
import Darwin

public struct DownloadRecord: Codable, Identifiable, Sendable {
  public let id: String
  public let bvid: String
  public let title: String
  public var state: String
  public var progress: Double
  public var output: String
  public var error: String
  public var options: DownloadOptions?
  public init(
    id: String = UUID().uuidString, bvid: String, title: String, state: String = "queued",
    progress: Double = 0, output: String = "", error: String = "", options: DownloadOptions? = nil
  ) {
    self.id = id
    self.bvid = bvid
    self.title = title
    self.state = state
    self.progress = progress
    self.output = output
    self.error = error
    self.options = options
  }
}
public final class DownloadStore {
  private var db: OpaquePointer?
  private let lock = NSLock()
  public init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
      sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else { throw BiliError.dependency("无法打开下载记录数据库") }
    try execute("CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
    // A process crash leaves transfer/merge incomplete; recover as interrupted, never complete.
    for var record in try records()
    where ["downloading", "merging", "queued"].contains(record.state) {
      record.state = "interrupted"
      record.error = "上次运行中断，可重新下载"
      try save(record)
    }
  }
  deinit { sqlite3_close(db) }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw BiliError.dependency("下载记录数据库结构异常")
    }
  }
  public func save(_ record: DownloadRecord) throws {
    lock.lock()
    defer { lock.unlock() }
    let data = try JSONEncoder().encode(record)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db, "INSERT OR REPLACE INTO tasks(id,payload) VALUES(?,?)", -1, &statement, nil)
        == SQLITE_OK
    else { throw BiliError.dependency("下载记录数据库准备失败") }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_bind_text(statement, 1, record.id, -1, transient) == SQLITE_OK else {
      throw BiliError.dependency("下载记录数据库写入参数失败")
    }
    let status = data.withUnsafeBytes {
      sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient)
    }
    guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
      throw BiliError.dependency("下载记录保存失败")
    }
  }
  public func records() throws -> [DownloadRecord] {
    lock.lock()
    defer { lock.unlock() }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "SELECT payload FROM tasks ORDER BY rowid DESC", -1, &statement, nil)
        == SQLITE_OK
    else { throw BiliError.dependency("下载记录查询失败") }
    defer { sqlite3_finalize(statement) }
    var result: [DownloadRecord] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else {
        throw BiliError.dependency("下载记录读取失败")
      }
      result.append(
        try JSONDecoder().decode(
          DownloadRecord.self,
          from: Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))))
    }
    return result
  }
}
/// Response validators and a caller-provided media identity only. Never persists signed URLs, headers or resumeData.
public struct DownloadResumeMetadata: Codable, Equatable, Sendable {
  public var etag: String?
  public var lastModified: String?
  public var totalBytes: Int64?
  public var identity: String?
  public init(etag: String? = nil, lastModified: String? = nil, totalBytes: Int64? = nil, identity: String? = nil) {
    self.etag = etag; self.lastModified = lastModified; self.totalBytes = totalBytes; self.identity = identity
  }
  var validator: String? {
    if let etag, !etag.hasPrefix("W/"), !etag.isEmpty { return etag }
    return lastModified.flatMap { $0.isEmpty ? nil : $0 }
  }
}
public enum DownloadFailure: LocalizedError, Sendable {
  case disk(operation: String, code: Int)
  case invalidRange
  case incomplete(expected: Int64, received: Int64)
  case outputExists
  public var errorDescription: String? {
    switch self {
    case .disk(let operation, let code): return "磁盘操作失败（\(operation)，\(code)），请检查可用空间和文件夹权限"
    case .invalidRange: return "服务器断点响应不匹配，请重新获取下载地址后重试"
    case .incomplete(let expected, let received): return "下载未完成：收到 \(received) / \(expected) 字节，可继续下载"
    case .outputExists: return "目标文件已存在，请更换保存位置"
    }
  }
  static func disk(_ operation: String, _ error: Error) -> Self {
    .disk(operation: operation, code: (error as NSError).code)
  }
}
private enum TransferControl: Error { case restart }
/// A private ephemeral session and one serial delegate queue per transfer stream chunks to disk.
private final class ResumableTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let destination: URL
  private let metadataURL: URL
  private let progress: @Sendable (Double) -> Void
  private let configuration: URLSessionConfiguration
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var cancelled = false
  // Below is used only on the URLSession serial delegate queue (setup precedes task.resume).
  private var continuation: CheckedContinuation<URL, Error>?
  private var handle: FileHandle?
  private var failure: Error?
  private var metadata: DownloadResumeMetadata
  private var offset: Int64
  private var responseBytes: Int64 = 0
  private var expectedResponseBytes: Int64?
  private var alreadyComplete = false
  init(destination: URL, metadataURL: URL, offset: Int64, metadata: DownloadResumeMetadata,
       configuration: URLSessionConfiguration, progress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination; self.metadataURL = metadataURL; self.offset = offset
    self.metadata = metadata; self.configuration = configuration; self.progress = progress
  }
  func start(request: URLRequest) async throws -> URL {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        task.resume()
        if cancel { task.cancel() }
      }
    }, onCancel: {
      self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
      task?.cancel()
    })
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    guard let response = response as? HTTPURLResponse else {
      failure = DownloadFailure.invalidRange; completionHandler(.cancel); return
    }
    guard (response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity" else {
      failure = DownloadFailure.invalidRange; completionHandler(.cancel); return
    }
    let newETag = response.value(forHTTPHeaderField: "ETag")
    let modified = response.value(forHTTPHeaderField: "Last-Modified")
    let contentRange = response.value(forHTTPHeaderField: "Content-Range") ?? ""
    if response.statusCode == 416 {
      let total = contentRange.hasPrefix("bytes */") ? Int64(contentRange.dropFirst(8)) : nil
      // 416 alone does not prove content equality: validate the actual If-Range field used.
      let ifRange = dataTask.currentRequest?.value(forHTTPHeaderField: "If-Range")
      let unchanged: Bool
      if let ifRange, let etag = metadata.etag, !etag.hasPrefix("W/"), !etag.isEmpty, etag == ifRange {
        unchanged = newETag == ifRange
      } else if let ifRange {
        unchanged = modified == ifRange
      } else { unchanged = false }
      if offset > 0, total == offset, metadata.totalBytes == offset, unchanged {
        alreadyComplete = true; completionHandler(.allow)
      } else { failure = TransferControl.restart; completionHandler(.cancel) }
      return
    }
    guard response.statusCode == 200 || response.statusCode == 206 else {
      failure = BiliError.http(response.statusCode); completionHandler(.cancel); return
    }
    if response.statusCode == 206 {
      guard let range = Self.range(contentRange), range.start == offset,
        range.total > range.end,
        response.expectedContentLength < 0 || response.expectedContentLength == range.end - range.start + 1,
        offset == 0 || newETag == nil || metadata.etag == nil || newETag == metadata.etag,
        offset == 0 || modified == nil || metadata.lastModified == nil || modified == metadata.lastModified
      else { failure = DownloadFailure.invalidRange; completionHandler(.cancel); return }
      expectedResponseBytes = range.end - range.start + 1
      metadata.totalBytes = range.total
    } else {
      offset = 0
      expectedResponseBytes = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
      metadata.totalBytes = expectedResponseBytes
    }
    metadata.etag = newETag; metadata.lastModified = modified
    do {
      if !FileManager.default.fileExists(atPath: destination.path) {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
          throw DownloadFailure.disk(operation: "创建文件", code: 0)
        }
      }
      let file = try FileHandle(forWritingTo: destination)
      handle = file
      if offset == 0 { try file.truncate(atOffset: 0) }
      try file.seek(toOffset: UInt64(offset))
      try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
      completionHandler(.allow)
    } catch {
      failure = (error as? DownloadFailure) ?? DownloadFailure.disk("准备下载", error)
      completionHandler(.cancel)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    var next = request
    if task.currentRequest?.url?.scheme == "https", next.url?.scheme != "https" {
      failure = DownloadFailure.invalidRange; completionHandler(nil); return
    }
    if task.currentRequest?.url?.host != next.url?.host {
      next.setValue(nil, forHTTPHeaderField: "Cookie")
      next.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    completionHandler(next)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !alreadyComplete, failure == nil else { return }
    if let expectedResponseBytes, Int64(data.count) > expectedResponseBytes - responseBytes {
      failure = DownloadFailure.invalidRange; dataTask.cancel(); return
    }
    do {
      try handle?.write(contentsOf: data); responseBytes += Int64(data.count)
      if let total = metadata.totalBytes, total > 0 {
        progress(min(1, Double(offset + responseBytes) / Double(total)))
      }
    } catch { failure = DownloadFailure.disk("写入文件", error); dataTask.cancel() }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    do { try handle?.synchronize(); try handle?.close() }
    catch { if failure == nil { failure = DownloadFailure.disk("保存文件", error) } }
    handle = nil
    lock.lock(); let cancelled = self.cancelled; self.task = nil; lock.unlock()
    var resultError = failure ?? error
    if cancelled { resultError = CancellationError() }
    if resultError == nil, !alreadyComplete {
      if let expectedResponseBytes, responseBytes != expectedResponseBytes {
        resultError = DownloadFailure.incomplete(expected: expectedResponseBytes, received: responseBytes)
      } else if let total = metadata.totalBytes, offset + responseBytes != total {
        resultError = DownloadFailure.incomplete(expected: total, received: offset + responseBytes)
      }
    }
    if let resultError { continuation?.resume(throwing: resultError) }
    else { progress(1); continuation?.resume(returning: destination) }
    continuation = nil
    session.finishTasksAndInvalidate()
  }
  private static func range(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
    guard value.hasPrefix("bytes ") else { return nil }
    let pair = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard pair.count == 2, let total = Int64(pair[1]) else { return nil }
    let bounds = pair[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
      start >= 0, end >= start, end < Int64.max else { return nil }
    return (start, end, total)
  }
}
private final class MergeProcess: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  func cancel() {
    lock.lock(); cancelled = true; let process = process; lock.unlock()
    if let process, process.isRunning { process.terminate() }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.killIfStillRunning()
    }
  }
  private func killIfStillRunning() {
    lock.lock(); defer { lock.unlock() }
    if cancelled, let process, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
  }
  func run(video: URL, audio: URL, output: URL, ffmpeg: URL) throws {
    let temporary = output.deletingLastPathComponent().appendingPathComponent(".merge-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard !FileManager.default.fileExists(atPath: output.path) else { throw DownloadFailure.outputExists }
    let p = Process(); p.executableURL = ffmpeg
    p.arguments = ["-nostdin", "-y", "-i", video.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-movflags", "+faststart", temporary.path]
    let pipe = Pipe(); p.standardError = pipe; p.standardOutput = FileHandle.nullDevice
    lock.lock()
    guard !cancelled else { lock.unlock(); throw CancellationError() }
    process = p
    do { try p.run() } catch { process = nil; lock.unlock(); throw error }
    lock.unlock()
    // Bounded diagnostic tail, drained continuously so the child cannot fill its stderr pipe.
    var log = Data()
    while true {
      let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
      if chunk.isEmpty { break }
      log.append(chunk)
      if log.count > 4096 { log.removeFirst(log.count - 4096) }
    }
    p.waitUntilExit()
    lock.lock(); defer { process = nil; lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    guard p.terminationStatus == 0 else {
      throw BiliError.process(p.terminationStatus, DiagnosticRedactor.sanitize(String(decoding: log, as: UTF8.self)))
    }
    guard !FileManager.default.fileExists(atPath: output.path) else { throw DownloadFailure.outputExists }
    do { try FileManager.default.moveItem(at: temporary, to: output) }
    catch { throw DownloadFailure.disk("合并文件", error) }
  }
}
public enum DownloadWorker {
  public static func transfer(request: URLRequest, to destination: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadFailure.outputExists }
    return try await resumeTransfer(request: request, to: destination, progress: progress)
  }
  /// Caller obtains a fresh signed URL for every attempt. Existing bytes require a validator.
  /// identity must describe media IDs/actual quality/codec/bandwidth, never a URL or credential.
  /// A new identity (including an unbound legacy sidecar) discards only this internal partial.
  public static func resumeTransfer(request: URLRequest, to destination: URL, metadataURL: URL? = nil,
                                   configuration: URLSessionConfiguration? = nil, identity: String? = nil,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
    let sidecar = metadataURL ?? destination.appendingPathExtension("resume.json")
    var metadata = (try? Data(contentsOf: sidecar)).flatMap { try? JSONDecoder().decode(DownloadResumeMetadata.self, from: $0) } ?? DownloadResumeMetadata()
    for attempt in 0...1 {
      try Task.checkCancellation()
      do { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
      catch { throw DownloadFailure.disk("创建文件夹", error) }
      let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
      if let type = attributes?[.type] as? FileAttributeType, type != .typeRegular {
        throw DownloadFailure.disk(operation: "下载目标不是普通文件", code: Int(EISDIR))
      }
      var offset = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      if let identity, metadata.identity != identity {
        do {
          if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
          if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        } catch { throw DownloadFailure.disk("重置下载资源", error) }
        offset = 0
        metadata = DownloadResumeMetadata(identity: identity)
      }
      if offset > 0, metadata.validator == nil {
        do { try FileManager.default.removeItem(at: destination) }
        catch { throw DownloadFailure.disk("重置下载", error) }
        offset = 0
      }
      var request = request
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      request.setValue(nil, forHTTPHeaderField: "Range"); request.setValue(nil, forHTTPHeaderField: "If-Range")
      if offset > 0 {
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        request.setValue(metadata.validator, forHTTPHeaderField: "If-Range")
      }
      // Ephemeral + explicitly disabled shared cookie/cache/credential stores also for injected test sessions.
      let config = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
      config.httpCookieStorage = nil; config.httpShouldSetCookies = false
      config.urlCredentialStorage = nil; config.urlCache = nil
      config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
      do {
        return try await ResumableTransfer(destination: destination, metadataURL: sidecar, offset: offset,
                                          metadata: metadata, configuration: config, progress: progress).start(request: request)
      } catch TransferControl.restart where attempt == 0 {
        do {
          if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
          if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        } catch { throw DownloadFailure.disk("重置断点", error) }
        metadata = DownloadResumeMetadata(identity: metadata.identity)
      } catch TransferControl.restart { throw DownloadFailure.invalidRange }
    }
    throw DownloadFailure.invalidRange
  }
  public static func merge(video: URL, audio: URL, output: URL, ffmpeg: URL) async throws {
    guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
      throw BiliError.dependency("找不到 FFmpeg，无法合并音视频")
    }
    let runner = MergeProcess()
    try await withTaskCancellationHandler(operation: {
      try await Task.detached(priority: .utility) { try runner.run(video: video, audio: audio, output: output, ffmpeg: ffmpeg) }.value
    }, onCancel: { runner.cancel() })
  }
}
