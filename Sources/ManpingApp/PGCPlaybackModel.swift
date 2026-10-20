import ManpingCore
import Combine
import SwiftUI
import VideoToolbox

/// A PGC load owns one player and one identity boundary; episode changes retain its surface.
@MainActor final class PGCPlaybackModel: ObservableObject {
  @Published private(set) var details: PGCDetails?
  @Published private(set) var episode: PGCEpisode?
  @Published private(set) var manifest: PlaybackManifest?
  @Published private(set) var selectedStream: MediaStream?
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  @Published private(set) var identityVersion = 0
  let interactions: PGCInteractionModel
  let player: PlayerModel
  let usesFixtures: Bool
  private let service: BiliService
  private var preferences: PlaybackPreferences
  private var expected: AuthSnapshot?
  private var flight: Task<Void, Never>?
  private var identityTask: Task<Void, Never>?
  private var eofObservation: AnyCancellable?
  var onPlaybackEnd: (() -> Void)?
  var onEpisodeChange: (() -> Void)?
  var onMediaReady: (() -> Void)?
  /// 设置 › 自动跳过片头片尾, read on every check so a change applies while the episode plays.
  var automaticSkip: () -> Bool = { false }
  var skipNextPrompt: () -> Bool = { false }
  /// Which marked ranges of this episode were skipped already. Kept here, not in a view, so it
  /// works from the first frame, in the mini window and across window moves.
  private var skipTracker = PlaybackSkipTracker()
  private var skipObservation: AnyCancellable?
  private var generation = UUID()
  private var selection: PGCSelection?
  private var requestedSelection: PGCSelection?
  @Published private(set) var fixturePosition: Double = 0
  private weak var cdn: CDNController?
  init(service: BiliService, player: PlayerModel, preferences: PlaybackPreferences = PlaybackPreferences(), usesFixtures: Bool = false,
    cdn: CDNController? = nil) {
    self.cdn = cdn
    self.interactions = PGCInteractionModel(service: service)
    self.service = service; self.player = player; self.preferences = preferences; self.usesFixtures = usesFixtures
    identityTask = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, let expected = self.expected, !Task.isCancelled else { continue }
        if expected.epoch != event.epoch || expected.identityRevision != event.identityRevision {
          if let episode = self.episode, self.details != nil, !self.usesFixtures {
            // Keep watching: reload the same episode at the same position under the new identity
            // (an account restored at launch can unlock higher qualities).
            self.reload(episode, at: self.player.time)
          } else {
            self.cancelRequests(); self.expected = nil
            self.details = nil; self.episode = nil; self.manifest = nil; self.selectedStream = nil
            self.player.command(["stop"]); self.identityVersion &+= 1
            self.error = "登录状态已改变，请重新打开剧集。"
          }
        }
      }
    }
  }
  deinit { identityTask?.cancel(); flight?.cancel() }
  func cancelRequests() {
    cdn?.detach()
    generation = UUID(); flight?.cancel(); flight = nil; eofObservation = nil; skipObservation = nil; isLoading = false
  }
  func shutdown() { interactions.shutdown(); cancelRequests(); identityTask?.cancel(); identityTask = nil; player.shutdown() }
  func ensureLoaded(_ selection: PGCSelection) async {
    guard requestedSelection != selection || (!isLoading && manifest == nil && error == nil) else { return }
    await load(selection)
  }
  func load(_ selection: PGCSelection) async {
    onEpisodeChange?()
    requestedSelection = selection
    cancelRequests(); self.selection = selection
    player.command(["stop"]); player.resetPlaybackEnd(); player.timeline = DanmakuTimeline(comments: [])
    interactions.reset(episodeID: nil, seasonID: nil, aid: nil)
    details = nil; episode = nil; manifest = nil; selectedStream = nil; error = nil; isLoading = true
    let revision = generation
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      let snapshot = await service.authSnapshot()
      guard generation == revision, !Task.isCancelled else { return }
      expected = snapshot
      do {
        let result = try await service.pgcDetails(selection, expectedIdentity: snapshot)
        try await check(revision, expected: snapshot)
        details = result
        let restoreHistory = PerformanceEnvironment.defaults.object(forKey: "autoLoadHistory") as? Bool ?? true
        guard let initial = result.initialEpisode(requested: selection.episodeID, restoreHistory: restoreHistory) else {
          throw BiliError.invalidResponse(result.warning ?? "该剧集没有可播放的分集。")
        }
        episode = initial
        skipTracker.reset(episode: initial.id)
        interactions.reset(episodeID: initial.id, seasonID: initial.seasonID, aid: initial.aid)
        let start = selection.episodeID == nil && restoreHistory && initial.id == result.progressEpisodeID ? max(0, result.progressSeconds) : 0
        try await loadMedia(initial, start: Double(start), revision: revision, expected: snapshot)
      } catch is CancellationError {} catch {
        if (try? await check(revision, expected: snapshot)) != nil { self.error = error.localizedDescription }
      }
      if generation == revision { isLoading = false; flight = nil }
    }
    flight = task
    // The model owns the load: a view disappearing (window move, compact mode) must not
    // cancel it. A newer load or selection cancels it through `cancelRequests()`.
    await task.value
  }
  func refresh() async { if let selection { await load(selection) } }
  private func reload(_ episode: PGCEpisode, at position: Double) {
    cancelRequests()
    interactions.reset(episodeID: episode.id, seasonID: episode.seasonID, aid: episode.aid)
    error = nil; isLoading = true
    let revision = generation
    flight = Task { @MainActor [weak self] in
      guard let self else { return }
      let snapshot = await service.authSnapshot()
      guard generation == revision, !Task.isCancelled else { return }
      expected = snapshot
      do { try await loadMedia(episode, start: position, revision: revision, expected: snapshot) }
      catch is CancellationError {} catch {
        if (try? await check(revision, expected: snapshot)) != nil { self.error = error.localizedDescription }
      }
      if generation == revision { isLoading = false; flight = nil }
    }
  }
  func selectEpisode(_ episode: PGCEpisode) {
    // Choosing another episode while one is loading replaces that load (cancelRequests below).
    guard let details, let expected,
      (details.episodes + details.extras.flatMap(\.episodes)).contains(where: { $0.id == episode.id }) else { return }
    onEpisodeChange?()
    cancelRequests(); player.command(["stop"]); player.resetPlaybackEnd(); player.timeline = DanmakuTimeline(comments: [])
    self.selection = PGCSelection(seasonID: episode.seasonID, episodeID: episode.id)
    interactions.reset(episodeID: episode.id, seasonID: episode.seasonID, aid: episode.aid)
    self.episode = episode; manifest = nil; selectedStream = nil; error = nil; isLoading = true
    skipTracker.reset(episode: episode.id)
    let revision = generation
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do { try await loadMedia(episode, start: 0, revision: revision, expected: expected) }
      catch is CancellationError {} catch {
        if (try? await check(revision, expected: expected)) != nil { self.error = error.localizedDescription }
      }
      if generation == revision { isLoading = false; flight = nil }
    }
    flight = task
  }
  var canPlayNext: Bool {
    guard !isLoading, let details, let index = details.episodes.firstIndex(where: { $0.id == episode?.id }) else { return false }
    return index + 1 < details.episodes.count
  }
  func nextEpisode() {
    guard canPlayNext, let details, let index = details.episodes.firstIndex(where: { $0.id == episode?.id }) else { return }
    selectEpisode(details.episodes[index + 1])
  }
  private func loadMedia(_ episode: PGCEpisode, start: Double, revision: UUID, expected: AuthSnapshot) async throws {
    try await check(revision, expected: expected)
    let streams = try await service.pgcPlayback(episode, expectedIdentity: expected)
    try await check(revision, expected: expected)
    let choice = try PlaybackSelector.select(streams, preferences: preferences, supportsHardware: Self.supportsHardware)
    manifest = streams; selectedStream = choice.video
    fixturePosition = start
    if usesFixtures { player.status = "本地样本 · 未加载在线媒体" }
    else if let cdn {
      let prepared = await cdn.prepare(video: choice.video, audio: choice.audio, avoidP2P: preferences.avoidP2P,
        reportFailureTo: player)
      try await check(revision, expected: expected)
      // nil: a quality change made during startup already loaded the newer stream.
      if let prepared {
        player.load(video: prepared.video, audio: prepared.audio, start: start); AppModel.configurePlayerPreferences(player)
        attachCDN(ticket: prepared.ticket)
      }
    } else { player.load(video: choice.videoURL, audio: choice.audioURL, start: start); AppModel.configurePlayerPreferences(player) }
    isLoading = false
    onMediaReady?()
    observeSkips(revision: revision)
    var prompted = false
    eofObservation = player.clock.$time.combineLatest(player.$duration, player.$eofReached).sink { [weak self] position, duration, ended in
      guard let self, !prompted, self.generation == revision, self.canPlayNext else { return }
      let threshold = skipNextPrompt() ? 0.1 : 2
      guard ended || (duration > 5 && abs(position - duration) < threshold) else { return }
      prompted = true
      self.player.endTemporarySpeed()
      // Dispatch after publication completes, avoiding reentrant reset of the same @Published flag.
      Task { @MainActor [weak self] in
        guard let self, self.generation == revision, !self.isLoading else { return }
        if self.canPlayNext { self.onPlaybackEnd?() }
      }
    }
    if let cid = episode.cid {
      do {
        let comments = try await service.comments(cid: cid, expectedIdentity: expected)
        try await check(revision, expected: expected)
        player.timeline = DanmakuTimeline(comments: comments)
      } catch is CancellationError { throw CancellationError() } catch {
        try await check(revision, expected: expected)
        player.status = "没能加载弹幕：\(error.localizedDescription)"
      }
    }
  }
  func seek(_ seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    if usesFixtures { fixturePosition = seconds }
    else { player.seek(seconds) }
  }

  // MARK: 跳过片头片尾

  /// 「跳过片头 / 片尾」 pressed: jumps past the range, which is then not skipped again.
  func skip(_ range: PlaybackSkip) {
    skipTracker.markHandled(range)
    seek(range.end)
  }
  /// The automatic-skip setting changed: act on the current position at once (also paused).
  func automaticSkipChanged() { checkSkip(at: player.time) }
  /// Checks the marked ranges on every clock tick of this episode's media.
  private func observeSkips(revision: UUID) {
    skipObservation = nil
    guard !usesFixtures, !(manifest?.skips.isEmpty ?? true) else { return }
    skipObservation = player.clock.$time.sink { [weak self] time in
      // Seek after the clock finished publishing this value.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == revision else { return }
        self.checkSkip(at: time)
      }
    }
  }
  private func checkSkip(at time: Double) {
    // Before the file opens the position is not yet the start position (a resumed episode).
    guard !usesFixtures, !isLoading, player.duration > 0, let skips = manifest?.skips, !skips.isEmpty,
      let target = skipTracker.target(skips, at: time, automatic: automaticSkip()) else { return }
    seek(target)
  }
  /// `persist: false` is used by automatic downgrades so they do not overwrite the user's choice.
  func changeQuality(_ stream: MediaStream, persist: Bool = true, recovering: Bool = false) {
    guard let expected, let manifest,
      manifest.video.contains(where: { $0.id == stream.id }), let audio = manifest.audio.max(by: { $0.bandwidth < $1.bandwidth }) else { return }
    let revision = generation
    Task { [weak self] in
      guard let self, (try? await check(revision, expected: expected)) != nil else { return }
      selectedStream = stream
      if persist { preferences.lastQuality = stream.quality }
      guard !usesFixtures else { return }
      if let cdn {
        let time = player.time, paused = player.paused
        guard let prepared = await cdn.prepare(video: stream, audio: audio, avoidP2P: preferences.avoidP2P, allowProbe: false, preserveRecovery: recovering),
          (try? await check(revision, expected: expected)) != nil, selectedStream?.id == stream.id else { return }
        player.load(video: prepared.video, audio: prepared.audio, start: time, paused: paused)
        attachCDN(ticket: prepared.ticket)
      } else {
        player.load(video: preferredURL(stream), audio: preferredURL(audio), start: player.time, paused: player.paused)
      }
    }
  }
  private func attachCDN(ticket: Int) {
    let revision = generation
    let target = player
    let episode = episode
    let identity = expected
    let stream = selectedStream
    cdn?.attach(player: player, ticket: ticket, reload: { [weak player] video, audio in
      guard let player else { return }
      player.load(video: video, audio: audio, start: player.time, paused: player.paused)
    }, downgrade: { [weak self] in
      guard let self, let manifest = self.manifest, let current = self.selectedStream else { return false }
      let lower = manifest.video.filter { $0.quality < current.quality }.sorted { $0.quality > $1.quality }
      guard let next = lower.first(where: { $0.codec.hasPrefix(current.codec.prefix(3)) }) ?? lower.first else { return false }
      self.changeQuality(next, persist: false, recovering: true)
      return true
    }, refresh: { [weak self, weak target] in
      guard let self, let target, self.player === target, let episode, let identity,
        !self.usesFixtures else { throw CancellationError() }
      try await self.check(revision, expected: identity)
      let streams = try await self.service.pgcPlayback(episode, expectedIdentity: identity)
      try await self.check(revision, expected: identity)
      guard self.player === target else { throw CancellationError() }
      let choice = try PlaybackSelector.select(streams, preferences: self.preferences, supportsHardware: Self.supportsHardware)
      let selected = streams.video.first { $0.quality == stream?.quality && $0.codec == stream?.codec } ?? choice.video
      self.manifest = streams; self.selectedStream = selected
      return (selected, choice.audio)
    })
  }
  private func preferredURL(_ stream: MediaStream) -> URL {
    if preferences.avoidP2P { return ([stream.url] + stream.backupURLs).first { !PlaybackSelector.isP2P($0) } ?? stream.url }
    return stream.url
  }
  private static func supportsHardware(_ codec: PlaybackCodec) -> Bool {
    switch codec {
    case .h264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
    case .hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    case .av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }
  }
  private func check(_ revision: UUID, expected: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    try Task.checkCancellation()
    guard generation == revision, current.epoch == expected.epoch, current.identityRevision == expected.identityRevision else { throw CancellationError() }
  }
}
