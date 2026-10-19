#if DEBUG
import ManpingCore
import Darwin
import Foundation

private final class M7RuntimeStateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = M7ExternalMpvState()
  func store(_ state: M7ExternalMpvState) { lock.withLock { value = state } }
  var state: M7ExternalMpvState { lock.withLock { value } }
}

/// Exercises the production IPC driver against a local Unix socket executable.
/// The fixture cannot load media, read saved credentials, or make network requests.
@MainActor enum DebugM7RuntimeChecks {
  private enum Failure: Error { case assertion(String) }
  static func run(mockExecutable: String) async -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bili-runtime-check-" + UUID().uuidString)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
      defer { try? FileManager.default.removeItem(at: directory) }
      try await checkNormal(mockExecutable: mockExecutable, directory: directory)
      try await checkStubborn(mockExecutable: mockExecutable, directory: directory)
      try await checkDisconnected(mockExecutable: mockExecutable, directory: directory)
      print("PASS M7 Unix socket IPC: literal load, state, seek, pause, chapters, natural exit, bounded shutdown, disconnected child termination")
      return true
    } catch {
      print("FAIL M7 Unix socket IPC fixture: \(error)")
      return false
    }
  }
  private static func prepare(_ source: String, directory: URL, name: String) throws -> URL {
    let executable = directory.appendingPathComponent(name + ".py")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: executable)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: executable.path)
    return executable
  }
  private static func wait(_ name: String, timeout: Double = 6, until predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
      guard Date() < deadline else { throw Failure.assertion(name + " timed out") }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
  private static func require(_ condition: Bool, _ name: String) throws {
    guard condition else { throw Failure.assertion(name) }
  }
  private static func journal(_ executable: URL) -> [[String: Any]] {
    let url = executable.deletingPathExtension().appendingPathExtension("journal.jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
  }
  private static func processID(_ executable: URL) -> Int32? {
    journal(executable).first { $0["event"] as? String == "start" }.flatMap { ($0["pid"] as? NSNumber)?.int32Value }
  }
  private static func isAlive(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 || errno == EPERM }
  private static func checkNormal(mockExecutable: String, directory: URL) async throws {
    let executable = try prepare(mockExecutable, directory: directory, name: "normal-mpv")
    let box = M7RuntimeStateBox()
    let driver = M7ExternalMpv(update: { box.store($0) })
    defer { driver.shutdown() }
    driver.start(executable: executable.path)
    let literal = "https://example.invalid/video?fixture=only&name=%22hello%22&text=%E6%B5%8B%E8%AF%95"
    driver.load(video: URL(string: literal)!, audio: URL(string: "https://example.invalid/audio?fixture=only"), start: 0, paused: false)
    try await wait("load/state") { box.state.time == 3.25 && box.state.duration == 99 && box.state.chapters.count == 2 }
    try require(box.state.speed == 1.5 && box.state.volume == 42, "observed speed/volume")
    try require(box.state.chapters[1].title == "第二章" && box.state.chapters[1].time == 25, "UTF-8 chapter state")
    try require(box.state.error == nil, "no IPC command errors")
    let records = journal(executable)
    let loaded = records.compactMap { $0["command"] as? [Any] }.first { $0.first as? String == "loadfile" }
    try require(loaded?[1] as? String == literal, "load URL arrives literally in IPC")
    let arguments = records.first { $0["event"] as? String == "start" }?["argv"] as? [String] ?? []
    try require(!arguments.isEmpty && !arguments.contains { $0.contains("example.invalid") }, "media URL absent from argv")
    driver.command(["seek", "17.5", "absolute+exact"])
    try await wait("seek") { box.state.time == 17.5 }
    driver.set("pause", "yes")
    try await wait("pause") { box.state.paused }
    driver.set("speed", "2.25"); driver.set("volume", "65")
    try await wait("set speed/volume") { box.state.speed == 2.25 && box.state.volume == 65 }
    let pid = try processID(executable).unwrap("normal PID")
    driver.command(["quit"])
    try await wait("natural quit") { box.state.exited && !isAlive(pid) }
    try require(journal(executable).contains { $0["event"] as? String == "quit" }, "quit reached socket")
    try require(!journal(executable).contains { $0["event"] as? String == "terminated" }, "natural quit avoided SIGTERM")
  }
  private static func checkStubborn(mockExecutable: String, directory: URL) async throws {
    let executable = try prepare(mockExecutable, directory: directory, name: "stubborn-mpv")
    let box = M7RuntimeStateBox()
    let driver = M7ExternalMpv(update: { box.store($0) })
    defer { driver.shutdown() }
    driver.start(executable: executable.path)
    driver.load(video: URL(string: "https://example.invalid/stubborn?fixture=only")!, audio: nil, start: 0, paused: false)
    try await wait("stubborn ready") { box.state.duration == 99 }
    let pid = try processID(executable).unwrap("stubborn PID")
    let started = Date()
    driver.shutdown()
    try await wait("bounded shutdown", timeout: 4) { !isAlive(pid) }
    try require(Date().timeIntervalSince(started) < 3, "TERM-ignoring process killed within grace bound")
  }
  private static func checkDisconnected(mockExecutable: String, directory: URL) async throws {
    let executable = try prepare(mockExecutable, directory: directory, name: "disconnected-mpv")
    let box = M7RuntimeStateBox()
    let driver = M7ExternalMpv(update: { box.store($0) })
    defer { driver.shutdown() }
    driver.start(executable: executable.path)
    // Finish registering observers before loadfile; EOF then exercises recv == 0
    // rather than a concurrent outgoing command hitting a closed socket.
    try await wait("disconnected observers ready") { box.state.speed == 1.5 && box.state.volume == 42 }
    let pid = try processID(executable).unwrap("disconnected PID")
    let started = Date()
    driver.load(video: URL(string: "https://example.invalid/disconnected?fixture=only")!, audio: nil, start: 0, paused: false)
    try await wait("disconnected child exit", timeout: 4) { box.state.exited && !isAlive(pid) }
    try require(Date().timeIntervalSince(started) < 3, "IPC EOF retains and terminates still-running child")
    try require(journal(executable).contains { $0["event"] as? String == "disconnected" }, "fixture closed IPC while remaining alive")
  }
}
private extension Optional {
  func unwrap(_ name: String) throws -> Wrapped {
    guard let value = self else { throw NSError(domain: "M7RuntimeFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    return value
  }
}
#endif
