import AppKit
import Combine
import Foundation
import ManpingCore

/// Progress-bar marks for the answer the AI panel shows: amber ticks at the cited times.
struct AITimelineMarks: Equatable {
  let mediaKey: String
  let times: [Double]
}

/// The app's AI pieces, created once at launch: presets and settings, the conversation service
/// on `ai.sqlite` (memory-only fixtures in screenshot builds), the account follower that moves or
/// clears saved answers, the retention purge, and one panel model per recently shown source so
/// an answer keeps streaming while another tab is shown.
@MainActor final class AIRuntime: ObservableObject {
  let presets: AIPresetStore
  let conversations: AIConversationService?
  let configuration: AIConfigurationStore
  let prompts: AIPromptStore
  let service: BiliService
  let fixtures: Bool
  /// `--ui-ai-scene` (fixtures only): which answer the screenshot run shows.
  let scene: String?
  /// Why the conversation database could not be opened (shown in 设置 › AI).
  let storeError: String?
  /// The first-use note at the top of the panel has been read.
  @Published private(set) var introShown: Bool
  /// Bumped after 清除全部 or an account change; panels reload their threads.
  @Published private(set) var generation = 0
  /// The model picked last in any panel; new panels start with it.
  var lastModel: (provider: AIProvider, modelID: String)?
  private weak var app: AppModel?
  private let coordinator: AIIdentityCoordinator?
  private var identityFollow: Task<Void, Never>?
  private var identityTask: Task<Void, Never>?
  private var configurationTask: Task<Void, Never>?
  private var purgeTask: Task<Void, Never>?
  private var retentionObservation: AnyCancellable?
  private var savingObservation: AnyCancellable?
  private var panels: [String: AIPanelModel] = [:]
  private var panelOrder: [String] = []
  private var started = false
  static let introKey = "Manping.AI.panelIntroShown"

  init(app: AppModel) {
    self.app = app
    service = app.service
    configuration = app.aiConfiguration
    prompts = app.aiPrompts
    fixtures = app.usesUIFixtures
    presets = AIPresetStore(fixtures: fixtures)
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    // `--ui-ai-preview` (older screenshot runs) shows the 章节总结 scene.
    scene = fixtures ? args.firstIndex(of: "--ui-ai-scene").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
      ?? (args.contains("--ui-ai-preview") ? "chapters" : nil) : nil
    #else
    scene = nil
    #endif
    introShown = fixtures ? scene != "intro" && scene != nil : UserDefaults.standard.bool(forKey: Self.introKey)
    if fixtures {
      conversations = try? AIConversationService.fixture(); coordinator = nil; storeError = nil
    } else {
      do {
        let store = try AIConversationStore(url: AIConversationStore.defaultURL)
        conversations = .live(service: app.service, rpc: try? app.standardRPCService(), configuration: app.aiConfiguration, store: store)
        coordinator = AIIdentityCoordinator(store: store); storeError = nil
      } catch {
        conversations = nil; coordinator = nil; storeError = "没能打开 AI 对话数据库，回答不会保存。"
      }
    }
  }

  /// Called at launch: follows the account and starts the retention purge.
  func start() {
    guard !started else { return }
    started = true
    if let coordinator {
      identityFollow = coordinator.follow(service)
      // Panels reload after the owner switch; applying here too keeps the order (apply is idempotent).
      identityTask = Task { [weak self, service, coordinator] in
        for await event in await service.identityEvents() {
          guard !Task.isCancelled else { return }
          let mid = await service.accountMid()
          try? await coordinator.apply(mid: mid, state: event.state)
          await self?.identityChanged()
        }
      }
    }
    configurationTask = Task { [weak self, configuration] in
      var first = true
      for await _ in await configuration.changes() {
        guard !Task.isCancelled else { return }
        if first { first = false; continue }
        await self?.configurationChanged()
      }
    }
    guard !fixtures, let conversations else { return }
    // Turning saving off also stops requests already under way from writing.
    savingObservation = presets.$saveConversations.removeDuplicates().sink { conversations.setSaving($0) }
    retentionObservation = presets.$retentionDays.dropFirst().removeDuplicates().sink { [weak self] _ in
      DispatchQueue.main.async { self?.purge() }
    }
    purgeTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.purge()
        try? await Task.sleep(for: .seconds(6 * 3600))
      }
    }
  }
  func shutdown() {
    identityFollow?.cancel(); identityTask?.cancel(); configurationTask?.cancel(); purgeTask?.cancel()
    for panel in panels.values { panel.shutdown() }
    Task { [conversations] in await conversations?.cancelAll() }
  }
  private func purge() {
    let days = presets.retentionDays
    Task { [conversations] in try? await conversations?.purgeExpired(retentionDays: days) }
  }
  private func identityChanged() {
    generation &+= 1
    for panel in panels.values { panel.identityChanged() }
  }
  private func configurationChanged() {
    for panel in panels.values { panel.configurationChanged() }
  }

  // MARK: Panels

  /// The panel model of a source; kept for the five most recently shown sources.
  func panel(for source: AISource) -> AIPanelModel {
    let key = source.identifier
    if let existing = panels[key] {
      existing.update(source: source)
      panelOrder.removeAll { $0 == key }; panelOrder.append(key)
      return existing
    }
    let panel = AIPanelModel(source: source, runtime: self)
    panels[key] = panel; panelOrder.append(key)
    while panelOrder.count > 5 {
      let dropped = panelOrder.removeFirst()
      // A panel still generating keeps running; the oldest idle one goes.
      if let old = panels[dropped], old.pending == nil { old.shutdown(); panels.removeValue(forKey: dropped) }
      else { panelOrder.append(dropped); break }
    }
    return panel
  }
  func markIntroShown() {
    guard !introShown else { return }
    introShown = true
    if !fixtures { UserDefaults.standard.set(true, forKey: Self.introKey) }
  }
  /// 清除全部: stops running answers, deletes every thread and cache, empties open panels.
  func clearAll() async throws {
    try await conversations?.clear()
    generation &+= 1
    for panel in panels.values { panel.identityChanged() }
  }

  // MARK: Playback

  /// The current media's AI identifier (matches `AISource.identifier`), nil without a video.
  var mediaKey: String? { app?.aiMediaKey }
  func isCurrentMedia(_ source: AISource) -> Bool { source.media != nil && source.identifier == mediaKey }
  /// Playback position of the source when it is the media playing now.
  func position(for source: AISource) -> Double? {
    guard isCurrentMedia(source), let app else { return nil }
    if fixtures { return app.player.time > 0 ? app.player.time : 372 }
    return app.player.time
  }
  /// mpv's chapter list, used when the player metadata has no view points.
  func fallbackChapters(for source: AISource) -> [AIViewPoint] {
    guard isCurrentMedia(source), let app else { return [] }
    let chapters = app.player.chapters
    let duration = app.player.duration > 0 ? app.player.duration : (source.duration ?? 0)
    return chapters.enumerated().compactMap { index, chapter in
      let end = index + 1 < chapters.count ? chapters[index + 1].time : duration
      guard end > chapter.time else { return nil }
      return AIViewPoint(id: "ch\(index + 1)", start: chapter.time, end: end, title: chapter.title)
    }
  }
  func seek(_ seconds: Double, in source: AISource) {
    guard isCurrentMedia(source) else { return }
    app?.seekCurrentMedia(seconds)
  }
  func setMarks(_ times: [Double], for source: AISource) {
    guard let app else { return }
    let marks = times.isEmpty ? nil : AITimelineMarks(mediaKey: source.identifier, times: times)
    if app.aiTimelineMarks != marks { app.aiTimelineMarks = marks }
  }
  func clearMarks(for source: AISource) {
    guard let app, app.aiTimelineMarks?.mediaKey == source.identifier else { return }
    app.aiTimelineMarks = nil
  }
  var clipPlayback: ClipPlaybackController? { app?.clipPlayback }
  /// The playback clock of the media playing now (the 当前进度 chip).
  var clock: PlaybackClock? { app?.player.clock }
  func openSettings() { app?.openSettings(.ai) }
}

extension AppModel {
  /// AI identifier of the media playing now: `video:aid:cid` or `pgc:epid`.
  var aiMediaKey: String? {
    if let pgcPlayback { return pgcPlayback.episode.map { "pgc:\($0.id)" } }
    guard let details = videoDetails else { return nil }
    return aiVideoSource(details).identifier
  }
  /// The AI source of the video page: the selected part of these details.
  func aiVideoSource(_ details: VideoDetails) -> AISource {
    var info = AIVideoInfo(details: details, cid: selected?.cid ?? details.video.cid)
    // The offline samples describe an 18:24 video; the fixture archive itself is shorter.
    if usesUIFixtures { info.duration = max(info.duration, 1104) }
    return .video(info)
  }
  /// The AI source of an episode, nil until its identifiers are known.
  func aiEpisodeSource(_ playback: PGCPlaybackModel) -> AISource? {
    guard let details = playback.details, let episode = playback.episode,
      var info = AIPGCInfo(details: details, episode: episode) else { return nil }
    if usesUIFixtures { info.duration = max(info.duration, 1104) }
    return .pgc(info)
  }
  /// Seeks whatever plays the current media: the main window, the separate window or 小窗.
  func seekCurrentMedia(_ seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    if let pgcPlayback { pgcPlayback.seek(seconds); return }
    if usesUIFixtures { player.time = seconds; return }
    player.seek(seconds)
  }
  func aiMarks(for key: String?) -> [Double] {
    guard let key, let marks = aiTimelineMarks, marks.mediaKey == key else { return [] }
    return marks.times
  }
}

extension AppModel {
  /// Launch: the conversation service and account follower start now so a sign-out clears
  /// saved answers even before the AI panel is opened.
  func configureAI() {
    clipPlayback.configure(currentMedia: { [weak self] in self?.aiMediaKey },
      activePlayer: { [weak self] in self.map { $0.pgcPlayback?.player ?? $0.player } },
      seek: { [weak self] in self?.seekCurrentMedia($0) })
    ai.start()
  }
}
