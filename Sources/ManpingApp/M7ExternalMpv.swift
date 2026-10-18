import ManpingCore
import Darwin
import Foundation

struct M7ExternalMpvState: Sendable {
  var time: Double = 0
  var duration: Double = 0
  var paused = false
  var idle = true
  var eof = false
  var speed: Double = 1
  var volume: Double = 80
  var chapters: [PlaybackChapter] = []
  var error: String?
  var exited = false
}

/// All Process and Unix socket ownership stays on this serial queue. Media URLs are sent
/// as JSON data after startup, never interpolated into a shell or process command line.
final class M7ExternalMpv: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.pidean.manping.external-mpv", qos: .userInitiated)
  private let update: @Sendable (M7ExternalMpvState) -> Void
  private var process: Process?
  private var directory: URL?
  private var socketPath = ""
  private var descriptor: Int32 = -1
  private var timer: DispatchSourceTimer?
  private var connectedDeadline = Date.distantPast
  private var buffered = Data()
  private var outgoing: [Data] = []
  private var state = M7ExternalMpvState()
  private var sequence = 0
  private var stopped = false
  private var awaitingLoad = false
  private var epoch = UUID()
  init(update: @escaping @Sendable (M7ExternalMpvState) -> Void) { self.update = update }

  func start(executable: String) {
    queue.async { [self] in
      guard process == nil, !stopped else { return }
      guard executable.hasPrefix("/"), !executable.contains("\0"),
        FileManager.default.isExecutableFile(atPath: executable) else {
        fail("外部 mpv 路径无效或不可执行")
        return
      }
      // Short path satisfies sockaddr_un's fixed capacity; private directory prevents
      // other users replacing the socket while mpv starts.
      let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bmpv-" + String(UUID().uuidString.prefix(8)))
      let path = directory.appendingPathComponent("ipc").path
      guard path.utf8.count < 104 else { fail("外部 mpv 的连接路径过长"); return }
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: NSNumber(value: 0o700)])
        self.directory = directory; socketPath = path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--config=no", "--idle=yes", "--keep-open=yes", "--terminal=no",
          "--input-default-bindings=no", "--hwdec=videotoolbox", "--tls-verify=yes",
          "--user-agent=\(BiliService.browserUserAgent)", "--referrer=https://www.bilibili.com/",
          "--input-ipc-server=" + path]
        if let certificate = Bundle.main.url(forResource: "cacert", withExtension: "pem") {
          process.arguments?.append("--tls-ca-file=" + certificate.path)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let epoch = self.epoch
        process.terminationHandler = { [weak self] process in
          let status = process.terminationStatus
          self?.queue.async { [weak self] in
            guard let self, self.epoch == epoch else { return }
            self.state.exited = true
            if !self.stopped && status != 0 { self.state.error = "外部 mpv 已退出（\(status)）" }
            self.update(self.state)
            self.cleanup()
          }
        }
        self.process = process
        try process.run()
        connectedDeadline = Date().addingTimeInterval(5)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
      } catch { fail("无法启动外部 mpv：\(error.localizedDescription)") }
    }
  }
  func load(video: URL, audio: URL?, start: Double, paused: Bool) {
    queue.async { [self] in
      guard !stopped else { return }
      state.eof = false; state.idle = true
      awaitingLoad = true
      send(["set_property", "pause", paused ? "yes" : "no"])
      var options: [String: String] = ["start": String(max(0, start.isFinite ? start : 0))]
      if let audio { options["audio-file"] = audio.absoluteString }
      // mpv >= 0.38: playlist insertion index precedes per-file options.
      sendObject(["loadfile", video.absoluteString, "replace", -1, options])
    }
  }
  func command(_ command: [String]) { queue.async { [self] in send(command) } }
  func set(_ name: String, _ value: String) { command(["set_property", name, value]) }
  func shutdown() {
    queue.async { [self] in
      guard !stopped else { return }
      send(["quit"]); flush()
      stopped = true
      timer?.cancel(); timer = nil
      let process = self.process
      if process?.isRunning == true { process?.terminate() }
      // No waitUntilExit and no main-thread wait. A noncooperative process gets a
      // bounded grace period, then SIGKILL. The exit handler owns final cleanup.
      queue.asyncAfter(deadline: .now() + 1) { [self] in
        if let process, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        cleanup()
      }
    }
  }
  private func send(_ command: [String]) {
    guard !stopped else { return }
    sequence += 1
    do { outgoing.append(try MpvRuntimePlan.ipcData(command: command, requestID: sequence)) }
    catch { fail("外部 mpv 命令无效") }
    flush()
  }
  private func sendObject(_ command: [Any]) {
    guard !stopped else { return }
    sequence += 1
    do {
      var data = try JSONSerialization.data(withJSONObject: ["command": command, "request_id": sequence])
      guard data.count <= 1_048_576 else { fail("外部 mpv 命令过长"); return }
      data.append(10); outgoing.append(data); flush()
    } catch { fail("外部 mpv 命令无效") }
  }
  private func connectSocket() {
    guard descriptor < 0, !stopped else { return }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(socketPath.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("无法创建与外部 mpv 的连接"); return }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      Darwin.close(fd)
      if Date() > connectedDeadline { fail("连接外部 mpv 超时") }
      return
    }
    descriptor = fd
    let names = ["time-pos", "duration", "pause", "idle-active", "eof-reached", "speed", "volume", "chapter-list"]
    for (id, name) in names.enumerated() { send(["observe_property", String(id + 1), name]) }
    flush()
  }
  private func flush() {
    guard descriptor >= 0 else { return }
    while let data = outgoing.first {
      let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, data.count, 0) }
      if sent < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        fail("向外部 mpv 发送命令失败"); return
      }
      guard sent > 0 else { return }
      if sent == data.count { outgoing.removeFirst() }
      else { outgoing[0] = data.dropFirst(sent); return }
    }
  }
  private func poll() {
    guard !stopped else { return }
    if descriptor < 0 { connectSocket() }
    guard descriptor >= 0 else { return }
    flush()
    var bytes = [UInt8](repeating: 0, count: 16_384)
    for _ in 0..<64 {
      let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
      if count < 0 {
        if errno != EAGAIN && errno != EWOULDBLOCK { fail("读取外部 mpv 的响应失败") }
        break
      }
      if count == 0 { disconnected(); return }
      buffered.append(contentsOf: bytes.prefix(count))
      guard buffered.count <= 1_048_576 else { fail("外部 mpv 的响应过长"); return }
      while let newline = buffered.firstIndex(of: 10) {
        let message = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
        consume(message)
      }
    }
  }
  private func consume(_ data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      fail("外部 mpv 的响应无效"); return
    }
    if object["event"] as? String == "file-loaded" {
      awaitingLoad = false; state.idle = false; state.eof = false
      update(state); return
    }
    guard object["event"] as? String == "property-change", let name = object["name"] as? String else {
      if let error = object["error"] as? String, error != "success" {
        state.error = "外部 mpv 命令失败：" + String(error.prefix(120)); update(state)
      }
      return
    }
    let number = (object["data"] as? NSNumber)?.doubleValue
    switch name {
    case "time-pos": if let number, number.isFinite { state.time = max(0, number) }
    case "duration": if let number, number.isFinite { state.duration = max(0, number) }
    case "speed": if let number, number.isFinite { state.speed = max(0.01, number) }
    case "volume": if let number, number.isFinite { state.volume = max(0, number) }
    case "pause": if let value = object["data"] as? Bool { state.paused = value }
    case "idle-active": if !awaitingLoad, let value = object["data"] as? Bool { state.idle = value }
    case "eof-reached": if !awaitingLoad, let value = object["data"] as? Bool { state.eof = value }
    case "chapter-list":
      if let rows = object["data"] as? [[String: Any]],
        let data = try? JSONSerialization.data(withJSONObject: Array(rows.prefix(1024))),
        let chapters = try? PlaybackChapter.parse(data) { state.chapters = chapters }
    default: return
    }
    update(state)
  }
  private func fail(_ message: String) {
    state.error = message; state.exited = true; update(state)
    if process?.isRunning == true { process?.terminate() }
    stopped = true
    let process = self.process
    queue.asyncAfter(deadline: .now() + 1) {
      if let process, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    cleanup()
  }
  private func disconnected() {
    guard !stopped else { return }
    state.exited = true; update(state)
    stopped = true
    // Closing the IPC socket does not prove that the owned process exited.
    // Retain both owners until the bounded termination sequence completes.
    stopIPC()
    let process = self.process
    queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in
      // Natural quit may close its socket just before Foundation reaps the process.
      // Give that normal path a short grace period before sending any signal.
      guard let process, process.isRunning else { cleanup(); return }
      process.terminate()
      queue.asyncAfter(deadline: .now() + 1) { [self] in
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        cleanup()
      }
    }
  }
  private func stopIPC() {
    timer?.cancel(); timer = nil
    if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    if let directory { try? FileManager.default.removeItem(at: directory) }
    directory = nil; outgoing.removeAll(); buffered.removeAll()
  }
  private func cleanup() {
    stopIPC()
    process = nil
  }
}
