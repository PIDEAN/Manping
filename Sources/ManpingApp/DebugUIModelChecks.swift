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

/// A real transport wait that responds to the service cancelling its in-flight request.
private actor ModelCancellableGate {
  private var entered = false
  private var cancelled = false
  private var waiter: CheckedContinuation<Void, Error>?
  private var observer: CheckedContinuation<Void, Never>?
  private(set) var cancellations = 0
  func pause() async throws {
    entered = true; observer?.resume(); observer = nil
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if cancelled || Task.isCancelled { continuation.resume(throwing: CancellationError()) }
        else { waiter = continuation }
      }
    } onCancel: { Task { await self.cancel() } }
  }
  private func cancel() {
    cancelled = true; cancellations += 1
    waiter?.resume(throwing: CancellationError()); waiter = nil
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { observer = $0 }
  }
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
  private let requestGate: ModelCancellableGate?
  private let suspendedPath: String?
  private var suspendedOnce = false
  init(curatedGate: ModelCheckGate? = nil, requestGate: ModelCancellableGate? = nil, suspendedPath: String? = nil) {
    self.curatedGate = curatedGate; self.requestGate = requestGate; self.suspendedPath = suspendedPath
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    guard let url = request.url, request.httpMethod == "GET" else { throw URLError(.unsupportedURL) }
    paths.append(url.path)
    if !suspendedOnce, url.path == suspendedPath, let requestGate {
      suspendedOnce = true
      try await requestGate.pause()
    }
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
      try await checkPausedBrowsing()
      try await checkIdentityCancellationDuringBrowsing()
      try await checkDeferredRetryPlacement()
      try await checkPendingPlacementDuringBrowsing()
      try await checkLateQualityPosition()
      try await checkMessageUnreadSnapshots()
      return true
    } catch { print("FAIL AppModel fixture assertion: \(error)"); return false }
  }
  private static func fixtureModel(_ transport: ModelCheckTransport) async throws -> AppModel {
    let service = BiliService(transport: transport, credentials: DebugUICredentialStore())
    try await service.restoreCookies()
    let model = AppModel(probeService: service)
    model.debugSuppressPlaybackWindows = true
    await model.debugWaitForIdentity()
    return model
  }
  private static func checkMessageUnreadSnapshots() async throws {
    let model = try await fixtureModel(ModelCheckTransport())
    defer { model.shutdown() }
    await model.initialize(skipAuthentication: true)
    let token = model.beginMessageReadOperation()
    let zero = MessageUnreadCounts(UnreadMessages(reply: 0, at: 0, like: 0, chat: 0))
    model.updateMessageReadOperation(token, unread: zero)
    try require(model.messageUnreadCounts.total == 0 && model.unreadMessageCount == 0,
      "known zero snapshot sets badge to zero")
    let partial = MessageUnreadCounts(values: [.reply: 3, .at: 1, .like: 12])
    model.updateMessageReadOperation(token, unread: partial)
    try require(model.messageUnreadCounts[.chat] == nil && model.messageUnreadCounts.total == nil && model.unreadMessageCount == 16,
      "partial progress removes cached chat zero and preserves known badge lower bound")
    model.finishMessageReadOperation(token, result: MarkAllMessagesReadResult(outcomes: [.chat: .unknown],
      unread: MessageUnreadCounts(values: [.reply: 0, .at: 0, .like: 0])))
    try require(model.messageUnreadCounts[.chat] == nil && model.messageUnreadCounts.total == nil && model.unreadMessageCount == 0,
      "final unknown result replaces cached counts instead of merging old zero")
    let retry = MessageMarkReadState.partialFailure("可以重试")
    try require(retry.needsRetry && zero.canMarkAllRead(isRunning: retry.isRunning, needsRetry: retry.needsRetry),
      "unknown or partial operation remains retryable with a cached zero badge")
    let running = MessageMarkReadState.running(completed: 0)
    try require(!partial.canMarkAllRead(isRunning: running.isRunning, needsRetry: running.needsRetry),
      "running operation disables duplicate clicks")
    print("PASS AppModel message unread snapshots replace cached zeros; partial badge=16, final unknown retry enabled, running disabled")
  }
  private static func checkIdentityCancellationDuringBrowsing() async throws {
    for path in ["/x/web-interface/wbi/view/detail", "/x/player/playurl"] {
      for explicitPlay in [false, true] {
        let gate = ModelCancellableGate()
        let latch = ModelIdentityLatch()
        let model = try await fixtureModel(ModelCheckTransport(requestGate: gate, suspendedPath: path))
        model.debugAfterIdentityEvent = { await latch.record($0) }
        model.open(Video(bvid: "", title: "Cancelled in transport", cid: 1000, aid: 100))
        await gate.waitUntilEntered()
        let pending = model.debugVideoLoadRequest
        let original = model.player
        model.openOverlay(.userSpace(946974))
        _ = await model.service.beginLogin()
        await latch.waitFor(await model.service.authSnapshot())
        await pending?.value
        let cancellations = await gate.cancellations
        try require(cancellations > 0, "identity cancels a genuinely suspended transport request")
        try require(model.player === original && model.currentOverlay == .userSpace(946974) &&
          model.pausedBrowsing.isBrowsing && model.player.paused && model.debugHasDeferredVideoRetry,
          "cancelled detail/playback defers retry without replacing overlay or engine")
        if explicitPlay { model.player.requestPlay() } else { model.goBack() }
        await model.debugVideoLoadRequest?.value
        try require(model.mainShowsPlayer && model.manifest != nil && model.player !== original &&
          model.player.paused == !explicitPlay && !model.debugHasDeferredVideoRetry,
          "deferred identity retry respects return pause and explicit media-key play")
        if !explicitPlay {
          try require(model.canGoForward, "deferred retry preserves the space route in forward history")
          model.goForward()
          try require(model.currentOverlay == .userSpace(946974) && model.pausedBrowsing.isBrowsing &&
            !model.mainShowsPlayer && model.player.paused, "forward after deferred retry shows space and remains paused")
          model.goBack()
          try require(model.mainShowsPlayer && model.player.paused, "back after deferred-retry forward stays paused")
        }
        model.shutdown()
      }
    }
    print("PASS AppModel actual detail/playback transport cancellation defers retries; Back/Forward/Back stays paused, media Play resumes")
  }
  private static func checkDeferredRetryPlacement() async throws {
    for mode in [MacOpenMode.compact, .detached, .fullScreen] {
      let gate = ModelCancellableGate()
      let latch = ModelIdentityLatch()
      let model = try await fixtureModel(ModelCheckTransport(requestGate: gate, suspendedPath: "/x/player/playurl"))
      model.debugAfterIdentityEvent = { await latch.record($0) }
      model.open(Video(bvid: "", title: "Deferred placement", cid: 1000, aid: 100))
      await gate.waitUntilEntered()
      let pending = model.debugVideoLoadRequest
      model.openOverlay(.userSpace(946974))
      _ = await model.service.beginLogin()
      await latch.waitFor(await model.service.authSnapshot())
      await pending?.value
      switch mode {
      case .compact: model.toggleCompactPlayer()
      case .detached: model.togglePlaybackWindow()
      case .fullScreen: model.togglePlayerFullScreen()
      case .mainWindow: break
      }
      await model.debugVideoLoadRequest?.value
      try require(model.manifest != nil && !model.debugHasDeferredVideoRetry && model.player.paused,
        "placement consumes deferred retry without restoring revoked playing intent")
      try require(mode == .fullScreen ? model.mainShowsPlayer : model.currentOverlay == .userSpace(946974),
        "external placement preserves overlay; explicit fullscreen reveals video")
      model.shutdown()
    }
    print("PASS AppModel deferred identity retry loads on mini/detached/fullscreen placement and stays paused")
  }
  private static func checkPendingPlacementDuringBrowsing() async throws {
    for mode in [MacOpenMode.compact, .detached] {
      let gate = ModelCheckGate()
      let model = try await fixtureModel(ModelCheckTransport())
      model.debugSetDefaultOpenMode(mode)
      model.debugAfterManifest = { await gate.pause() }
      model.open(Video(bvid: "", title: "Pending placement", cid: 1000, aid: 100))
      await gate.waitUntilEntered()
      let pending = model.debugVideoLoadRequest
      model.openOverlay(.userSpace(946974))
      await gate.release(); await pending?.value
      try require(!model.playbackElsewhere && model.pausedBrowsing.isBrowsing && model.player.paused &&
        model.currentOverlay == .userSpace(946974), "late manifest cannot apply old compact/detached default")
      model.shutdown()
    }
    print("PASS AppModel compact/detached defaults are revoked by navigation before manifest completion")
  }
  private static func checkLateQualityPosition() async throws {
    let gate = ModelCheckGate()
    let model = try await fixtureModel(ModelCheckTransport())
    defer { model.shutdown() }
    model.open(Video(bvid: "", title: "Late quality", cid: 1000, aid: 100))
    await model.debugVideoLoadRequest?.value
    guard let stream = model.manifest?.video.first else { throw Failure.assertion("quality fixture stream") }
    model.debugAllowFixtureQualityChanges = true
    model.debugAfterQualityPrepare = { await gate.pause() }
    model.player.time = 3
    model.changeQuality(stream, persist: false)
    await gate.waitUntilEntered()
    let pending = model.debugQualityRequest
    model.player.time = 12
    model.openOverlay(.userSpace(946974))
    await gate.release(); await pending?.value
    try require(model.player.time == 12 && model.player.paused && model.player.browsingSuspended,
      "actual CDN prepare -> late quality load uses submission position and suspended pause")
    print("PASS AppModel actual late quality commit keeps position 12s instead of request position 3s")
  }
  private static func checkPausedBrowsing() async throws {
    let model = try await fixtureModel(ModelCheckTransport())
    defer { model.shutdown() }
    let first = Video(bvid: "", title: "Suspended", cid: 1000, aid: 100)
    model.open(first)
    await model.debugVideoLoadRequest?.value
    let originalPlayer = model.player
    model.player.set("pause", "yes")
    model.openOverlay(.userSpace(946974))
    try require(model.pausedBrowsing.isBrowsing && !model.mainShowsPlayer && model.selected != nil,
      "main UGC overlay retains engine and independent browsing state")
    model.goBack()
    try require(model.mainShowsPlayer && model.player.paused, "original pause remains paused")
    model.player.requestPlay()
    model.debugRequestNextPlayback()
    try require(model.nextPlaybackDeadline != nil, "fixture establishes actual next-playback countdown")
    model.openOverlay(.userSpace(946974))
    try require(model.nextPlaybackDeadline == nil, "overlay cancels next-playback countdown")
    model.openOverlay(.following(946974))
    let refresh = model.refreshToken
    await model.refresh()
    try require(model.refreshToken > refresh && model.player === originalPlayer, "refresh targets visible overlay")
    model.goBack()
    try require(model.pausedBrowsing.isBrowsing && model.player.paused, "nested back cannot resume")
    model.goBack()
    try require(model.mainShowsPlayer && !model.player.paused, "final back resumes original engine")
    model.goForward()
    try require(model.pausedBrowsing.isBrowsing && model.player.paused, "forward suspends again")
    model.player.set("pause", "no")
    try require(model.player.paused, "automatic play cannot defeat central gate")
    model.player.requestPlay()
    try require(model.mainShowsPlayer && !model.player.paused, "media play reveals playback before resuming")
    model.openOverlay(.userSpace(946974))
    model.setWindowFullScreen(true, detached: false)
    model.setWindowFullScreen(false, detached: false)
    try require(model.pausedBrowsing.isBrowsing && model.player.paused, "native fullscreen preserves paused browsing")
    // No native window exists in this model-only launch; the actual action still runs navigation.
    model.togglePlayerFullScreen()
    try require(model.mainShowsPlayer && !model.player.paused, "explicit picture fullscreen returns before resuming")
    model.openOverlay(.userSpace(946974))
    model.toggleCompactPlayer()
    try require(model.compactPlayer && !model.pausedBrowsing.isBrowsing && !model.player.paused,
      "mini migration preserves original playing intent")
    model.closeMiniPlayer(activateMain: false)
    try require(model.mainShowsPlayer && !model.playbackElsewhere, "mini return restores sole main owner")
    model.player.set("pause", "yes")
    model.openOverlay(.userSpace(946974))
    model.togglePlaybackWindow()
    try require(model.playbackDetached && !model.pausedBrowsing.isBrowsing && model.player.paused,
      "detached migration preserves original pause")
    model.togglePlaybackWindow()
    try require(model.mainShowsPlayer && !model.playbackDetached && model.player.paused,
      "closing detached restores paused main picture")
    model.openOverlay(.userSpace(946974))
    model.open(Video(bvid: "", title: "Replacement", cid: 1001, aid: 101))
    await model.debugVideoLoadRequest?.value
    let routes = model.overlays.filter { if case .video = $0 { return true }; return false }
    try require(routes.count == 1 && model.player !== originalPlayer && !model.pausedBrowsing.isBrowsing,
      "replacement removes every stale playback route and suspension")
    model.navigate(to: .popular)
    try require(!model.hasPlayback && !model.pausedBrowsing.isBrowsing, "sidebar ends main playback session")
    // Freeze the actual load after details, then navigate before the manifest is published.
    let gate = ModelCheckGate()
    model.debugAfterDetails = { await gate.pause() }
    model.open(first)
    await gate.waitUntilEntered()
    let pending = model.debugVideoLoadRequest
    model.openOverlay(.userSpace(946974))
    await gate.release(); await pending?.value
    try require(model.manifest != nil && model.player.browsingSuspended && model.player.paused,
      "late manifest cannot auto-play over overlay")
    model.goBack()
    try require(model.mainShowsPlayer && !model.player.paused, "loading intent resumes on final return")
    model.debugAfterDetails = nil
    let latch = ModelIdentityLatch()
    model.debugAfterIdentityEvent = { await latch.record($0) }
    model.openOverlay(.userSpace(946974))
    _ = await model.service.beginLogin()
    await latch.waitFor(await model.service.authSnapshot())
    try require(model.pausedBrowsing.suspension == nil, "identity change revokes captured resume")
    model.goBack()
    try require(model.mainShowsPlayer && model.player.paused, "account change cannot resume old playback")
    print("PASS AppModel paused browsing: paused/loading/nested/back/forward/refresh/replacement/media-key/identity/countdown/mini/detached/fullscreen")
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
