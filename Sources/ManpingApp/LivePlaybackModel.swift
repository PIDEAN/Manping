import ManpingCore
import Combine
import Foundation

/// Recent live chat lines for the side panel. Kept apart from the playback model so a busy
/// room only re-renders the chat list, and flushed at most every 0.3 s.
@MainActor final class LiveChatModel: ObservableObject {
  struct Line: Identifiable, Equatable {
    enum Kind: Equatable { case danmaku, superChat(Int), gift, notice }
    let id: Int
    let user: String
    let text: String
    let kind: Kind
  }
  @Published private(set) var lines: [Line] = []
  @Published private(set) var connected = false
  private var pending: [Line] = []
  private var flush: Task<Void, Never>?
  private var nextID = 0
  private static let limit = 200

  func add(user: String, text: String, kind: Line.Kind) {
    nextID += 1
    pending.append(Line(id: nextID, user: user, text: text, kind: kind))
    guard flush == nil else { return }
    flush = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard let self else { return }
      self.lines = Array((self.lines + self.pending).suffix(Self.limit))
      self.pending = []; self.flush = nil
    }
  }
  func setConnected(_ value: Bool) { if connected != value { connected = value } }
}

/// One live room: resolves the room, picks a stream, plays it in mpv and keeps it alive.
/// Live streams never end on their own, so a watchdog treats a stopped clock, a player error
/// or an upstream EOF as a dropped connection: it re-checks the room (ended → show it), then
/// reloads with the next CDN line or a fresh address, backing off 1–16 s.
@MainActor final class LivePlaybackModel: ObservableObject {
  @Published private(set) var room: LiveRoomInfo?
  @Published private(set) var playback: LivePlayback?
  @Published private(set) var stream: LiveStream?
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  @Published private(set) var ended = false
  @Published private(set) var reconnecting: String?
  @Published private(set) var watched: Int64?
  @Published private(set) var online: Int64?
  @Published private(set) var reconnects = 0
  /// The line now playing, counted from 1, and its host; nil before a stream is chosen.
  var currentLineNumber: Int? {
    guard let stream, !stream.urls.isEmpty else { return nil }
    return lineIndex % stream.urls.count + 1
  }
  var currentLineHost: String? {
    guard let stream, !stream.urls.isEmpty else { return nil }
    return stream.urls[lineIndex % stream.urls.count].host
  }
  #if DEBUG
  /// Diagnostics: chat events received and whether the chat auth carried a device id.
  private(set) var chatEvents = 0
  private(set) var chatHasBuvid = false
  #endif
  let player: PlayerModel
  let chat = LiveChatModel()
  let roomID: Int64
  let usesFixtures: Bool
  private let service: BiliService
  private let preferHEVC: Bool
  private let avoidPeerAssisted: Bool
  /// Index into `stream.urls` of the line now playing (the fastest one when the stream was chosen).
  @Published private(set) var lineIndex = 0
  private var retryBudget = LiveReconnectBudget()
  private var loadTask: Task<Void, Never>?
  private var chatTask: Task<Void, Never>?
  private let chatClient = LiveChatClient()
  private let probe = CDNURLSessionFetcher(maximumConnectionsPerHost: 2)
  private var watchdog: Timer?
  private var lastClock = -1.0
  private var stalledSince: Date?
  private var loadedAt = Date.distantPast
  /// The clock moved since the last load: the opening grace period is over.
  private var playedSinceLoad = false
  private var errorObservation: AnyCancellable?
  private var endObservation: AnyCancellable?
  private var generation = 0
  private var active = true
  static let qualityKey = "Manping.lastLiveQuality"

  init(roomID: Int64, service: BiliService, player: PlayerModel, preferHEVC: Bool, avoidPeerAssisted: Bool, usesFixtures: Bool = false) {
    self.roomID = roomID; self.service = service; self.player = player
    self.preferHEVC = preferHEVC; self.avoidPeerAssisted = avoidPeerAssisted; self.usesFixtures = usesFixtures
    player.tracksDuration = false
  }

  /// Requested quality: the last choice (原画 by default). The room may deliver less.
  var requestedQuality: Int {
    let saved = PerformanceEnvironment.defaults.integer(forKey: Self.qualityKey)
    return saved > 0 ? saved : 10000
  }
  var currentQuality: LiveQuality? {
    guard let stream else { return nil }
    return playback?.qualities.first { $0.qn == stream.currentQuality }
  }

  func start() {
    guard room == nil, loadTask == nil else { return }
    load(quality: requestedQuality, refreshRoom: true)
    startChat()
  }

  func refresh() {
    retryBudget.reset(); lineIndex = 0; ended = false
    load(quality: requestedQuality, refreshRoom: true)
    if chatTask == nil { startChat() }
  }

  /// Reconnects only when the stream is not playing (failed, ended or never loaded).
  func refreshIfNeeded() {
    guard error != nil || ended || (stream == nil && !isLoading) else { return }
    refresh()
  }

  func changeQuality(_ qn: Int) {
    PerformanceEnvironment.defaults.set(qn, forKey: Self.qualityKey)
    retryBudget.reset(); lineIndex = 0
    load(quality: qn, refreshRoom: false)
  }

  func shutdown() {
    active = false
    generation += 1
    loadTask?.cancel(); loadTask = nil
    chatTask?.cancel(); chatTask = nil
    chatClient.disconnect()
    watchdog?.invalidate(); watchdog = nil
    errorObservation = nil; endObservation = nil
    // The engine is pooled; do not leak live-only network options into the next video.
    player.set("stream-lavf-o", "")
    player.shutdown()
  }

  // MARK: Loading

  private func load(quality: Int, refreshRoom: Bool) {
    generation += 1
    let current = generation
    loadTask?.cancel()
    // This load takes over from any pending reconnect (its task was just cancelled).
    isLoading = true; error = nil; reconnecting = nil
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        #if DEBUG
        // The README demo shows the offline sample room playing its local file (the samples have no room API).
        if DemoConfig.playsLocalMedia, let media = DemoConfig.media {
          let stream = LiveStream(protocolName: "http_stream", formatName: "flv", codecName: "avc",
            currentQuality: 10000, acceptedQualities: [10000], urls: [media])
          self.stream = stream; self.lineIndex = 0
          self.play(stream)
          return
        }
        #endif
        if refreshRoom || self.room == nil {
          let room = try await self.service.liveRoom(self.roomID)
          guard current == self.generation else { return }
          self.room = room
          if room.status != .live {
            self.markEnded(); return
          }
        }
        let playback = try await self.service.livePlayback(roomID: self.room?.roomID ?? self.roomID, quality: quality)
        guard current == self.generation else { return }
        self.playback = playback
        let candidates = LiveStreamSelector.ranked(playback, preferHEVC: self.preferHEVC, requested: quality,
          avoidPeerAssisted: self.avoidPeerAssisted)
        guard playback.status == .live, !candidates.isEmpty else { self.markEnded(); return }
        // Same quality only: a fallback format must not silently change what the user picked.
        let sameQuality = candidates.filter { $0.currentQuality == candidates[0].currentQuality }
        guard let (stream, line) = await LiveStreamSelector.fastestLine(sameQuality.prefix(4), fetcher: self.probe) else {
          throw BiliError.invalidResponse("所有直播线路都无法连接")
        }
        guard current == self.generation else { return }
        self.stream = stream; self.lineIndex = line
        self.play(stream)
      } catch is CancellationError {
      } catch {
        guard current == self.generation else { return }
        self.isLoading = false
        if self.retryBudget.attempts > 0 { self.scheduleReconnect(reason: "获取直播地址失败") }
        else { self.error = Self.message(error) }
      }
    }
  }

  private func play(_ stream: LiveStream) {
    guard active, !ended, !stream.urls.isEmpty else { isLoading = false; return }
    let url = stream.urls[lineIndex % stream.urls.count]
    // ffmpeg's HTTP layer reconnects short network drops by itself before mpv sees an error.
    // Set before loadfile (both run on the player's serial queue) so the open uses it.
    player.start()
    // rw_timeout turns a dead edge into an error (and a watchdog reconnect) instead of a hang.
    // (HTTP options only: the README demo plays a local file.)
    if !url.isFileURL {
      player.set("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2,rw_timeout=8000000")
    }
    player.load(video: url, audio: nil)
    AppModel.configurePlayerPreferences(player)
    // A fresh stream restarts the media clock; start a new chat timeline with it.
    player.timeline = DanmakuTimeline(comments: [])
    loadedAt = Date(); lastClock = -1; stalledSince = nil; playedSinceLoad = false
    isLoading = false
    startWatchdog()
  }

  private func markEnded() {
    // Invalidate the running load or pending reconnect: a line race that finishes after the
    // room ended must not start the stream again under the ended panel.
    generation += 1
    loadTask?.cancel(); loadTask = nil
    ended = true; isLoading = false; reconnecting = nil
    watchdog?.invalidate(); watchdog = nil
    player.command(["stop"])
  }

  // MARK: Keeping the stream alive

  private func startWatchdog() {
    watchdog?.invalidate()
    watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    // Callbacks belong to this load; a later load or the end of the room retires them.
    let current = generation
    errorObservation = player.$error.removeDuplicates().sink { [weak self] value in
      guard value != nil else { return }
      Task { @MainActor [weak self] in
        guard let self, current == self.generation else { return }
        self.scheduleReconnect(reason: "直播流中断")
      }
    }
    // A live stream that reaches its end was cut upstream (or the room ended; reload tells).
    endObservation = player.$eofReached.removeDuplicates().sink { [weak self] ended in
      guard ended else { return }
      Task { @MainActor [weak self] in
        guard let self, current == self.generation else { return }
        self.scheduleReconnect(reason: "直播流已断开")
      }
    }
  }

  private func check() {
    guard active, !ended, !retryBudget.terminal, !isLoading, reconnecting == nil else { return }
    let now = Date()
    let clock = player.time
    retryBudget.recordProgress(at: ProcessInfo.processInfo.systemUptime,
      advancing: clock > lastClock + 0.2, paused: player.paused)
    if player.paused { stalledSince = nil; lastClock = clock; return }
    if clock > lastClock + 0.2 {
      if lastClock >= 0 { playedSinceLoad = true }
      lastClock = clock; stalledSince = nil
      return
    }
    // Opening a live stream may take a few seconds; once frames flowed, a frozen clock is a drop.
    let grace = !playedSinceLoad && now.timeIntervalSince(loadedAt) < 12
    if grace { return }
    if stalledSince == nil { stalledSince = now }
    if let since = stalledSince, now.timeIntervalSince(since) >= 4 {
      scheduleReconnect(reason: "画面停止 \(Int(now.timeIntervalSince(since))) 秒")
    }
  }

  /// Backs off 1, 2, 4… 16 s, then reloads with a new address and a new line race.
  private func scheduleReconnect(reason: String) {
    guard active, !ended, !retryBudget.terminal, reconnecting == nil else { return }
    guard let delay = retryBudget.nextDelay() else {
      generation += 1
      loadTask?.cancel(); loadTask = nil
      watchdog?.invalidate(); watchdog = nil
      errorObservation = nil; endObservation = nil
      isLoading = false; reconnecting = nil
      player.command(["stop"])
      error = "直播连接多次中断（\(reason)），请稍后点「重新连接」。"
      return
    }
    reconnects += 1
    reconnecting = "\(reason)，\(Int(delay)) 秒后重新连接（第 \(retryBudget.attempts) 次）"
    watchdog?.invalidate(); watchdog = nil
    let current = generation
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self, !Task.isCancelled, current == self.generation, self.active else { return }
      // A fresh address and a fresh line race: the play URL carries the room's live status (an
      // ended room shows as ended) and expiring tokens are renewed.
      self.reconnecting = nil
      self.load(quality: self.stream?.currentQuality ?? self.requestedQuality, refreshRoom: false)
    }
  }

  // MARK: Chat

  /// One chat loop per room; it reconnects by itself and clears `chatTask` when it gives up.
  private func startChat() {
    guard !usesFixtures, chatTask == nil else { return }
    chatTask = Task { [weak self] in
      defer { Task { @MainActor [weak self] in self?.chatTask = nil } }
      var failures = 0
      while let self, self.active, !Task.isCancelled {
        // The chat server needs the real room id; a short id (e.g. 6 for 7734200) authenticates
        // but never receives that room's messages. Wait until the room has been resolved.
        guard let room = self.room?.roomID else {
          try? await Task.sleep(nanoseconds: 300_000_000)
          continue
        }
        guard let endpoint = try? await self.service.liveChatEndpoint(roomID: room) else {
          failures += 1
          if failures > 5 { return }
          try? await Task.sleep(nanoseconds: UInt64(min(30, 3 * failures)) * 1_000_000_000)
          continue
        }
        #if DEBUG
        self.chatHasBuvid = !endpoint.buvid.isEmpty
        #endif
        for await event in self.chatClient.connect(endpoint) {
          guard self.active else { break }
          failures = 0
          self.handle(event)
        }
        self.chat.setConnected(false)
        guard self.active, !Task.isCancelled else { return }
        failures += 1
        if failures > 10 { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
      }
    }
  }

  private func handle(_ event: LiveChatEvent) {
    #if DEBUG
    chatEvents += 1
    #endif
    switch event {
    case .connected:
      chat.setConnected(true)
    case .danmaku(let user, let text, let color):
      chat.add(user: user, text: text, kind: .danmaku)
      // Stamp with the smooth clock the renderer uses, so a new line enters at the right edge
      // (the polled time-pos lags it by up to one poll and one video frame).
      if !ended { player.timeline.append(DanmakuComment(time: player.mediaClock + 0.05, color: color, text: text)) }
    case .superChat(let user, let text, let price):
      chat.add(user: user, text: text, kind: .superChat(price))
    case .gift(let user, let name, let count):
      chat.add(user: user, text: "赠送 \(name) ×\(count)", kind: .gift)
    case .watched(let value):
      if watched != value { watched = value }
    case .online(let value):
      if online != value { online = value }
    case .popularity:
      break
    case .liveStarted:
      if retryBudget.shouldRestartRoom(after: event, roomEnded: ended) {
        chat.add(user: "", text: "主播开播了", kind: .notice); refresh()
      }
    case .liveEnded:
      chat.add(user: "", text: "直播已结束", kind: .notice)
      markEnded()
    case .titleChanged(let title):
      if let room { self.room = LiveRoomInfo(roomID: room.roomID, shortID: room.shortID, anchorID: room.anchorID,
        anchorName: room.anchorName, anchorAvatar: room.anchorAvatar, status: room.status, title: title, cover: room.cover,
        area: room.area, online: room.online, description: room.description, startedAt: room.startedAt) }
    }
  }

  static func message(_ error: Error) -> String {
    if case BiliError.api(let code, _) = error {
      switch code {
      case 60004, 19002000: return "直播间不存在。"
      case 60005: return "直播间已被封禁。"
      default: return "没能加载直播（代码 \(code)）。"
      }
    }
    return "没能加载直播：\(error.localizedDescription)"
  }
}
