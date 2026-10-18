#if DEBUG
import ManpingCore
import Foundation

private actor ModelCheckGate {
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  func pause() async {
    entered = true
    observers.forEach { $0.resume() }; observers = []
    await withCheckedContinuation { waiter = $0 }
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() { waiter?.resume(); waiter = nil }
}

private actor ModelIdentityLatch {
  private var latest: AuthIdentityEvent?
  private var waiter: (UInt64, UInt64, CheckedContinuation<Void, Never>)?
  func record(_ event: AuthIdentityEvent) {
    latest = event
    if let waiting = waiter, waiting.0 == event.epoch, waiting.1 == event.identityRevision {
      waiter = nil; waiting.2.resume()
    }
  }
  func waitFor(_ snapshot: AuthSnapshot) async {
    if latest?.epoch == snapshot.epoch && latest?.identityRevision == snapshot.identityRevision { return }
    await withCheckedContinuation { waiter = (snapshot.epoch, snapshot.identityRevision, $0) }
  }
}

private actor ModelCheckTransport: AuthTransport {
  let fixture = DebugUITransport()
  let curatedGate: ModelCheckGate?
  private(set) var paths: [String] = []
  init(curatedGate: ModelCheckGate? = nil) { self.curatedGate = curatedGate }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    guard let url = request.url, request.httpMethod == "GET" else { throw URLError(.unsupportedURL) }
    paths.append(url.path)
    if url.path == "/x/web-interface/index/top/feed/rcmd", let curatedGate { await curatedGate.pause() }
    // Synthetic replies only; deliberately finish after cancellation to test late publication.
    return try await fixture.send(request)
  }
}

/// Executes the actual AppModel against isolated synthetic transports; no windows or media loads.
@MainActor enum DebugUIModelChecks {
  private enum Failure: Error { case assertion(String) }
  private static func require(_ condition: Bool, _ name: String) throws {
    guard condition else { throw Failure.assertion(name) }
  }
  static func run() async -> Bool {
    do {
      try await checkOverlayRace()
      try await checkQueueIdentityRace(afterManifest: false)
      try await checkQueueIdentityRace(afterManifest: true)
      try await checkIndependentPublicLoad()
      return true
    } catch { print("FAIL AppModel fixture assertion: \(error)"); return false }
  }
  private static func fixtureModel(_ transport: ModelCheckTransport) async throws -> AppModel {
    let service = BiliService(transport: transport, credentials: DebugUICredentialStore())
    try await service.restoreCookies()
    return AppModel(probeService: service)
  }
  private static func checkOverlayRace() async throws {
    let gate = ModelCheckGate()
    let transport = ModelCheckTransport(curatedGate: gate)
    let model = try await fixtureModel(transport)
    defer { model.shutdown() }
    model.playCuratedList()
    await gate.waitUntilEntered()
    let pending = model.debugCuratedRequest
    model.openOverlay(.search("race"))
    await gate.release(); await pending?.value
    try require(model.currentOverlay == .search("race"), "curated navigation overlay remains selected")
    try require(model.playbackQueue.count == 0 && model.selected == nil && !model.curatedLoading,
      "curated late response cannot open a queue")
    print("PASS AppModel curated -> overlay cancels late playlist")
  }
  private static func checkQueueIdentityRace(afterManifest: Bool) async throws {
    let gate = ModelCheckGate()
    let latch = ModelIdentityLatch()
    let transport = ModelCheckTransport()
    let model = try await fixtureModel(transport)
    defer { model.shutdown() }
    model.debugAfterIdentityEvent = { await latch.record($0) }
    if afterManifest { model.debugAfterManifest = { await gate.pause() } }
    else { model.debugAfterDetails = { await gate.pause() } }
    model.playCuratedList()
    await gate.waitUntilEntered()
    let pending = model.debugVideoLoadRequest
    _ = await model.service.beginLogin()
    await latch.waitFor(await model.service.authSnapshot())
    await gate.release(); await pending?.value
    try require(model.playbackQueue.count == 0, "identity change clears actual VM queue")
    try require(model.videoDetails == nil && model.manifest == nil && model.selectedStream == nil,
      "service result returned before identity change cannot publish to UI")
    let paths = await transport.paths
    let playbackCount = paths.filter { $0 == "/x/player/playurl" }.count
    try require(playbackCount == (afterManifest ? 1 : 0), "no new-identity playback request from old queue context")
    print(afterManifest
      ? "PASS AppModel identity change after manifest return rejects late UI publication"
      : "PASS AppModel identity change after detail return cancels queue load before playback")
  }
  private static func checkIndependentPublicLoad() async throws {
    let gate = ModelCheckGate()
    let latch = ModelIdentityLatch()
    let transport = ModelCheckTransport()
    let model = try await fixtureModel(transport)
    defer { model.shutdown() }
    model.debugAfterIdentityEvent = { await latch.record($0) }
    model.debugAfterDetails = { await gate.pause() }
    model.open(Video(bvid: "", title: "Public", cid: 1000, aid: 100))
    await gate.waitUntilEntered()
    let pending = model.debugVideoLoadRequest
    _ = await model.service.beginLogin()
    await latch.waitFor(await model.service.authSnapshot())
    await gate.release(); await pending?.value
    try require(model.playbackQueue.count == 0 && model.manifest != nil && model.selectedStream != nil,
      "identity queue observer must not cancel unrelated public video load")
    print("PASS AppModel identity queue observer preserves independent public load")
  }
}
#endif
