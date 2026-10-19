import AppKit
import ManpingCore
import Combine
import ImageIO
import SwiftUI
import VideoToolbox
import WebKit

@MainActor final class AppModel: ObservableObject {
  // Source: ViewModels/Core/NavigationViewModel.cs:225,252 at UI 896a062.
  enum Page: String, CaseIterable {
    case popular = "流行"
    case moment = "动态"
    case video = "视频"
    case live = "直播"
    case anime = "动漫"
    case cinema = "影视"
    case article = "文章"
    case message = "消息"
    case downloads = "下载"
    /// The name shown in the sidebar, toolbar and menus (the raw values are the original names).
    var title: String {
      switch self {
      case .popular: "首页"
      case .moment: "动态"
      case .video: "分区"
      case .live: "直播"
      case .anime: "番剧"
      case .cinema: "影视"
      case .article: "专栏"
      case .message: "消息"
      case .downloads: "下载"
      }
    }
    var symbol: String {
      switch self {
      case .popular: "house"
      case .moment: "person.2"
      case .video: "square.grid.2x2"
      case .live: "dot.radiowaves.left.and.right"
      case .anime: "sparkles.tv"
      case .cinema: "film"
      case .article: "doc.richtext"
      case .message: "bubble.left.and.bubble.right"
      case .downloads: "arrow.down.circle"
      }
    }
    /// The sidebar switch in 设置 › 通用 › 侧边栏项目, for the pages that have one.
    var visibilityKey: MacSettingKey? {
      switch self {
      case .popular: .navPopular
      case .moment: .navMoment
      case .video: .navVideo
      case .live: .navLive
      case .anime: .navAnime
      case .cinema: .navCinema
      case .article: .navArticle
      case .message, .downloads: nil
      }
    }
  }
  /// A sidebar item: a top-level page, or one of the library lists that live on the overlay stack.
  enum Destination: Hashable {
    case page(Page)
    case favorites, viewLater, history
    /// 发现 (⌘1–⌘6) and 我的 (⌥⌘1–⌥⌘6), in sidebar and 前往 menu order.
    static let discover: [Destination] = [.page(.popular), .page(.video), .page(.live), .page(.anime), .page(.cinema), .page(.article)]
    static let mine: [Destination] = [.page(.moment), .favorites, .viewLater, .history, .page(.downloads), .page(.message)]
    var title: String {
      switch self {
      case .page(let page): page.title
      case .favorites: "收藏"
      case .viewLater: "稍后再看"
      case .history: "历史记录"
      }
    }
    var symbol: String {
      switch self {
      case .page(let page): page.symbol
      case .favorites: "star"
      case .viewLater: "clock"
      case .history: "clock.arrow.circlepath"
      }
    }
    var route: OverlayRoute? {
      switch self {
      case .page: nil
      case .favorites: .favorites
      case .viewLater: .viewLater
      case .history: .history
      }
    }
  }
  enum PopularTab: String, CaseIterable {
    case recommended = "推荐"
    case popular = "热门"
    case ranking = "排行榜"
  }
  enum OverlayRoute: Equatable {
    case search(String)
    case video(String)
    case userSpace(Int64)
    case favorites
    case viewLater
    case history
    case following(Int64)
    case followers(Int64)
    case pgc(PGCSelection)
    case article(Int64)
    case live(Int64)
  }
  struct RegionalSearchRequest {
    let route: OverlayRoute
    let keyword: String
    let revision = UUID()
  }
  @Published var regionalSearchRequest: RegionalSearchRequest?
  private var launchOwnPage: String?
  private var launchPGCSelection: PGCSelection?
  @Published private(set) var pgcPlayback: PGCPlaybackModel?
  @Published private(set) var livePlayback: LivePlaybackModel?
  /// AI presets, conversations (ai.sqlite) and panels; created at launch (`initialize`) or on
  /// first use.
  var ai: AIRuntime {
    if let aiRuntime { return aiRuntime }
    let runtime = AIRuntime(app: self)
    aiRuntime = runtime
    return runtime
  }
  /// Nil until `ai` is first used, so quitting never creates ai.sqlite just to close it.
  private var aiRuntime: AIRuntime?
  /// 只看 3 分钟 依次播放, independent of the AI panel and of the window showing the picture.
  let clipPlayback = ClipPlaybackController()
  /// Amber marks on the progress bar for the answer the AI panel shows.
  @Published var aiTimelineMarks: AITimelineMarks?
  private var launchLiveRoom: Int64?
  /// A video, an episode or a live room is open (in this window or the detached one).
  var hasPlayback: Bool { selected != nil || pgcPlayback != nil || livePlayback != nil }
  /// The picture plays in the mini window or the standalone window, not in the main window.
  var playbackElsewhere: Bool { compactPlayer || playbackDetached }
  /// The main window moved on to other pages while playback continues in the mini window or
  /// the standalone window. The player's route is then off the stack; returning the picture to
  /// the main window puts it back on top.
  @Published private(set) var browsingBesidePlayback = false
  /// The main window shows the playback page (or, while playback is elsewhere, its placeholder).
  var mainShowsPlayer: Bool { hasPlayback && !browsingBesidePlayback && !pausedBrowsing.isBrowsing }
  @Published private(set) var pausedBrowsing = PlaybackBrowsingState()
  private var browsingBinding: PlaybackBrowsingState.Binding {
    .init(player: player.playbackIdentity, media: sessionMediaKey, generation: clipGeneration,
      epoch: accountDisplayIdentity?.epoch ?? 0, revision: accountDisplayIdentity?.revision ?? 0)
  }
  private func beginPausedBrowsing() {
    guard selected != nil, !playbackElsewhere else { return }
    // Browsing is a newer user choice than the open's not-yet-applied default placement.
    pendingOpenMode = nil
    let effects = pausedBrowsing.enter(binding: browsingBinding, depth: overlays.count, playing: player.playbackIntended)
    if effects.cancelNextPlayback { cancelNextPlayback() }
    clipPlayback.stop(.stopped)
    if effects.pause { player.suspendForBrowsing() }
  }
  private func resumeVisiblePlayback() {
    let visible = currentOverlay == playbackRoute
    guard let resume = pausedBrowsing.returnToPlayback(binding: browsingBinding,
      depth: overlays.count, playbackVisible: visible) else { return }
    player.finishBrowsing(resume: resume)
    retryDeferredVideo(resume: resume)
  }
  /// Explicit media-key Play returns to the current video before enabling playback.
  private func revealAndPlay() {
    guard selected != nil else { return }
    if pausedBrowsing.isBrowsing {
      if let index = overlays.lastIndex(where: Self.isPlayerRoute) {
        overlays = Array(overlays.prefix(index + 1))
      } else if let route = playbackRoute { overlays.append(route) }
      pausedBrowsing.reset()
      forwardRoutes = []
    }
    player.finishBrowsing(resume: true)
    retryDeferredVideo(resume: true)
  }
  /// User-requested placement ends suspended browsing and resumes only the captured intent.
  private func finishBrowsingForPlacement() {
    guard pausedBrowsing.isBrowsing else { return }
    let resume = pausedBrowsing.presentationChanged(.externalWindow, binding: browsingBinding) ?? false
    player.finishBrowsing(resume: resume)
    retryDeferredVideo(resume: resume, preservingOverlay: true)
    browsingBesidePlayback = currentOverlay != playbackRoute
  }
  /// The selection the open episode page was opened with (its route and its page key).
  @Published private(set) var pgcSelection: PGCSelection?
  private static func isPlayerRoute(_ route: OverlayRoute) -> Bool {
    switch route {
    case .video, .pgc, .live: true
    default: false
    }
  }
  /// The route of what is playing now.
  private var playbackRoute: OverlayRoute? {
    if let livePlayback { return .live(livePlayback.roomID) }
    if pgcPlayback != nil, let pgcSelection { return .pgc(pgcSelection) }
    if selected != nil { return .video(sessionMediaKey) }
    return nil
  }
  /// UGC main-window navigation keeps the engine/reporter and removes its surface. onDisappear
  /// cancels page-local work only; returning reattaches the parked render layer without loadfile.
  /// Window table: suspended -> mini/detached ends browsing, retains the original play intent;
  /// returning/closing external windows restores the playback page. Native fullscreen keeps
  /// the overlay paused; the explicit player-fullscreen action returns to playback first.
  /// PGC/live keep their old close-on-main-navigation behavior; external playback keeps going.
  private func leavePlaybackPage() {
    guard hasPlayback else { return }
    if playbackElsewhere {
      browsingBesidePlayback = true
      overlays.removeAll(where: Self.isPlayerRoute)
    } else if selected != nil {
      beginPausedBrowsing()
    } else {
      closePlayer()
    }
  }
  /// The picture came back to the main window: show its page again.
  private func restorePlaybackPage() {
    guard browsingBesidePlayback, !playbackElsewhere else { return }
    browsingBesidePlayback = false
    guard hasPlayback, let route = playbackRoute else { return }
    overlays.removeAll(where: Self.isPlayerRoute)
    overlays.append(route)
  }
  @Published private(set) var pgcFavoriteIntent: (cinema: Bool, revision: UUID)?
  @Published var page: Page = .popular
  @Published var popularTab: PopularTab = .popular
  @Published var overlays: [OverlayRoute] = [] {
    didSet {
      // Going somewhere new (a longer stack that was not a step forward) ends the forward history.
      if !steppingForward, overlays.count > oldValue.count { forwardRoutes = [] }
    }
  }
  /// Routes left with 返回, newest last; 前进 (⌘]) reopens them. Players are never kept here.
  @Published private(set) var forwardRoutes: [OverlayRoute] = []
  private var steppingForward = false
  @Published var search = ""
  @Published var searchFocusRequest = 0
  /// 热搜 (⌘K): bumped to open the trending list under the toolbar search box.
  @Published var hotSearchRequest = 0
  @Published var theme: AppTheme =
    AppTheme(rawValue: PerformanceEnvironment.defaults.string(forKey: "appTheme") ?? "") ?? .system
  {
    didSet { PerformanceEnvironment.defaults.set(theme.rawValue, forKey: "appTheme") }
  }
  var canGoBack: Bool { !overlays.isEmpty }
  var canGoForward: Bool { !forwardRoutes.isEmpty }
  var currentOverlay: OverlayRoute? { overlays.last }
  /// The sidebar item the current screen belongs to.
  var currentDestination: Destination {
    for route in overlays.reversed() {
      switch route {
      case .favorites: return .favorites
      case .viewLater: return .viewLater
      case .history: return .history
      default: continue
      }
    }
    return .page(page)
  }
  /// The toolbar title when the page does not name itself.
  var toolbarTitle: String {
    switch currentOverlay {
    case .search(let term): term.isEmpty ? "搜索" : term
    case .favorites: "收藏"
    case .viewLater: "稍后再看"
    case .history: "历史记录"
    case .userSpace: "UP 主空间"
    case .following: "关注"
    case .followers: "粉丝"
    case .article: "专栏"
    case .video, .pgc, .live: ""
    case nil: page.title
    }
  }
  @Published var error: String?
  @Published var selected: Video?
  @Published var manifest: PlaybackManifest?
  @Published var videoDetails: VideoDetails?
  /// When the next item starts. Published once per prompt; the prompt view animates the
  /// remaining time itself, so the countdown no longer re-renders the app ten times a second.
  @Published private(set) var nextPlaybackDeadline: Date?
  private var nextPlaybackTask: Task<Void, Never>?
  @Published var refreshToken = 0
  @Published var playbackPreferences = PlaybackPreferences(
    codec: PlaybackCodec(rawValue: PerformanceEnvironment.defaults.string(forKey: "preferredCodec") ?? "h264") ?? .h264,
    quality: PerformanceEnvironment.defaults.object(forKey: "preferredVideoQuality") as? Int,
    lastQuality: PerformanceEnvironment.defaults.object(forKey: "lastVideoQuality") as? Int,
    avoidP2P: PerformanceEnvironment.defaults.bool(forKey: "playWithoutP2P")) {
    didSet {
      PerformanceEnvironment.defaults.set(playbackPreferences.codec.rawValue, forKey: "preferredCodec")
      PerformanceEnvironment.defaults.set(playbackPreferences.quality, forKey: "preferredVideoQuality")
      PerformanceEnvironment.defaults.set(playbackPreferences.lastQuality, forKey: "lastVideoQuality")
      PerformanceEnvironment.defaults.set(playbackPreferences.avoidP2P, forKey: "playWithoutP2P")
    }
  }
  @Published private(set) var selectedStream: MediaStream? {
    didSet { if selectedStream != nil { updateMiniPlayerAspect() } }
  }
  /// `--ui-page settings…`: the settings window opens on this category after launch.
  var launchSettingsGroup: MacSettingGroup?
  /// `--ui-page settings:playerbar`: the settings window on 控制条.
  var launchSettingsPlayerBar = false
  var launchVideoTab: String?
  @Published var player = PlayerModel()
  /// CDN selection, multi-node relay, stall recovery and smart cache for every playback.
  let cdn = CDNController()
  /// Proxy / VPN path shared by the API (region unlock) and the CDN relay (proxied routes).
  let proxy = ProxyRuntime()
  private(set) lazy var proxyTransport = ProxyAuthTransport(runtime: proxy)
  let proxySettingsModel = ProxySettingsModel()
  /// Debug playback reports exercise real playback but must never write to the account.
  private static let writesHistory = !ProcessInfo.processInfo.arguments.contains("--ui-playback-report")
  private(set) lazy var progressReporter = WatchProgressReporter(service: service) { [weak self] in
    guard let self else { return false }
    return Self.writesHistory && !self.usesUIFixtures && self.appSettings.bool(.reportProgress)
  }
  @Published var account = "登录"
  @Published private(set) var fixtureReady = false
  @Published var accountAvatar: URL?
  /// Account level (0–6) for the sidebar account row; nil until the profile loads.
  @Published var accountLevel: Int?
  @Published private(set) var accountMID: Int64? {
    didSet {
      if oldValue != accountMID {
        restartUnreadPolling()
        DanmakuShieldSync.shared.configure(service: service, mid: accountMID)
        followedLiveNow = []; followedLiveAt = .distantPast; followedLiveTask?.cancel(); followedLiveTask = nil
        followedLiveGeneration &+= 1
      }
    }
  }
  private var accountDisplayIdentity: (epoch: UInt64, revision: UInt64)?
  @Published var unreadMessageCount = 0 {
    didSet { if oldValue != unreadMessageCount { updateDockBadge() } }
  }
  @Published private(set) var messageUnreadCounts = MessageUnreadCounts()
  private var unreadTask: Task<Void, Never>?
  private var unreadGeneration = MessageUnreadGeneration()
  private var messageReadOperation: UUID?
  /// Invalidate any in-flight poll before the explicit operation starts.
  func beginMessageReadOperation() -> UUID {
    let token = unreadGeneration.invalidate()
    unreadTask?.cancel(); unreadTask = nil; messageReadOperation = token
    return token
  }
  func updateMessageReadOperation(_ token: UUID, unread: MessageUnreadCounts) {
    guard messageReadOperation == token else { return }
    messageUnreadCounts = unread
    unreadMessageCount = Int(min(unread.knownTotal, 9_999))
  }
  func finishMessageReadOperation(_ token: UUID, result: MarkAllMessagesReadResult?) {
    guard messageReadOperation == token else { return }
    if let result { updateMessageReadOperation(token, unread: result.unread) }
    messageReadOperation = nil
    restartUnreadPolling()
  }
  func refreshMessageUnreadCounts() { if messageReadOperation == nil { restartUnreadPolling() } }
  /// Reads unread replies, @, likes and private messages every two minutes while signed in.
  private func restartUnreadPolling() {
    let generation = unreadGeneration.invalidate()
    unreadTask?.cancel(); unreadTask = nil
    guard accountMID != nil else {
      messageReadOperation = nil; messageUnreadCounts = MessageUnreadCounts(); unreadMessageCount = 0; return
    }
    guard messageReadOperation == nil else { return }
    let service = self.service
    unreadTask = Task { [weak self] in
      while !Task.isCancelled {
        let before = await service.authSnapshot()
        if let unread = try? await service.unreadMessageCounts(expectedIdentity: before) {
          let after = await service.authSnapshot()
          guard let self, !Task.isCancelled, self.unreadGeneration.accepts(generation) else { return }
          if after.epoch == before.epoch, after.identityRevision == before.identityRevision, self.accountMID != nil {
            self.messageUnreadCounts = unread
            self.unreadMessageCount = Int(min(unread.knownTotal, 9_999))
          }
        }
        do { try await Task.sleep(for: .seconds(120)) } catch { return }
      }
    }
  }
  /// Dock badge mirrors the sidebar's unread dot (设置 › 通知 › Dock 图标显示未读数).
  func updateDockBadge() {
    let count = appSettings.bool(.dockBadge) ? unreadMessageCount : 0
    NSApp?.dockTile.badgeLabel = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
  }
  @Published private(set) var playbackQueue = VideoPlaybackQueue()
  @Published private(set) var curatedLoading = false
  private var curatedTask: Task<Void, Never>?
  private var curatedGeneration = UUID()
  private var curatedIdentity: PlaybackQueueIdentity?
  private var queueIdentityTask: Task<Void, Never>?
  private var eofObservation: AnyCancellable?
  private var clipGeneration = UUID()
  private var sessionMediaKey = ""
  private var reportIdentity: AuthSnapshot?
  private var queueLoadIdentity: AuthSnapshot?
  #if DEBUG
  var launchCuratedPlaylist = false
  var debugAfterDetails: (() async -> Void)?
  var debugAfterManifest: (() async -> Void)?
  var debugAfterIdentityEvent: ((AuthIdentityEvent) async -> Void)?
  var debugCuratedRequest: Task<Void, Never>? { curatedTask }
  var debugVideoLoadRequest: Task<Void, Never>? { loadTask }
  var debugSuppressPlaybackWindows = false
  var debugAllowFixtureQualityChanges = false
  var debugAfterQualityPrepare: (() async -> Void)?
  var debugQualityRequest: Task<Void, Never>?
  var debugHasDeferredVideoRetry: Bool { deferredVideoRetry != nil }
  func debugSetDefaultOpenMode(_ mode: MacOpenMode) {
    for (key, value) in mode.values { _ = appSettings.set(key, value, capabilities: [key]) }
  }
  func debugRequestNextPlayback() { requestNextPlayback() }
  func debugWaitForIdentity() async {
    while reportIdentity == nil { await Task.yield() }
  }
  #endif
  /// 小窗 is open: the picture lives in the floating mini panel (`MiniPlayerCoordinator`).
  @Published private(set) var compactPlayer = false
  private let miniPlayer = MiniPlayerCoordinator()
  @Published var showingLogin = false {
    didSet {
      writeCaptureState()
      if showingLogin, playbackDetached { (NSApp.delegate as? AppDelegate)?.window?.makeKeyAndOrderFront(nil) }
    }
  }
  func writeCaptureState() {
    #if DEBUG
    guard Bundle.main.bundleIdentifier == "io.github.pidean.manping.debug" else { return }
    let file = Bundle.main.bundleURL.deletingLastPathComponent()
      .appendingPathComponent("capture-\(ProcessInfo.processInfo.processIdentifier).state")
    try? (showingLogin ? "blocked" : "ready").write(to: file, atomically: true, encoding: .utf8)
    #endif
  }
  @Published var downloads: [DownloadRecord] = []
  @Published var showingDownloadOptions = false
  @Published private(set) var appSettings = MacSettings.load(from: PerformanceEnvironment.defaults)
  private let scrollAcceleration = M7ScrollAcceleration()
  private let systemMedia = M7SystemMediaController()
  /// Starts from the saved preference: a launch with indexing off must not index (or keep) items.
  lazy var watchActivity: WatchActivity = {
    let activity = WatchActivity()
    activity.indexesSpotlight = appSettings.bool(.spotlightIndex)
    if !activity.indexesSpotlight { activity.clearSpotlight() }
    return activity
  }()
  private var liveMediaSubscription: AnyCancellable?
  private let playbackWindow = M7PlaybackWindowCoordinator()
  /// Brings whichever window shows the player to the front.
  func showPlayer() {
    NSApp.activate()
    if compactPlayer { miniPlayer.bringToFront() }
    else if playbackDetached, let window = playbackWindow.window { window.makeKeyAndOrderFront(nil) }
    else { NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.level == .normal }?.makeKeyAndOrderFront(nil) }
  }
  /// Followed streamers live right now, for the menu bar item (refreshed at most every 2 min).
  @Published private(set) var followedLiveNow: [LiveRoom] = []
  private var followedLiveAt = Date.distantPast
  private var followedLiveTask: Task<Void, Never>?
  private var followedLiveGeneration = 0
  func refreshFollowedLive() {
    guard !usesUIFixtures, let mid = accountMID, followedLiveTask == nil,
      Date().timeIntervalSince(followedLiveAt) > 120 else { return }
    let service = self.service
    followedLiveGeneration &+= 1
    let generation = followedLiveGeneration
    followedLiveTask = Task { [weak self] in
      let identity = await service.authSnapshot()
      let page = try? await service.liveFeed(page: 1, expectedIdentity: identity)
      let current = await service.authSnapshot()
      // Only this refresh, for this account, may publish (an account switch cancels it).
      guard let self, self.followedLiveGeneration == generation else { return }
      self.followedLiveTask = nil
      guard !Task.isCancelled, self.accountMID == mid, let page, current.epoch == identity.epoch,
        current.identityRevision == identity.identityRevision else { return }
      self.followedLiveNow = page.following; self.followedLiveAt = Date()
    }
  }
  @Published private(set) var playbackDetached = false
  private var artworkTask: Task<Void, Never>?
  private lazy var notifications = makeNotifications()
  lazy var playbackFeatures: PlaybackFeaturesModel = makePlaybackFeatures()
  private func makePlaybackFeatures() -> PlaybackFeaturesModel {
    PlaybackFeaturesModel(service: service, fixtures: usesUIFixtures)
  }
  lazy var aiConfiguration: AIConfigurationStore = makeAIConfiguration()
  private func makeAIConfiguration() -> AIConfigurationStore {
    usesUIFixtures ? AIConfigurationStore.previewFixture() : AIConfigurationStore(chatGPT: ChatGPTPlanAuth())
  }
  lazy var aiPrompts: AIPromptStore = makeAIPrompts()
  private func makeAIPrompts() -> AIPromptStore { AIPromptStore(fixtures: usesUIFixtures) }
  lazy var aiSettings: M8AISettingsModel = makeAISettings()
  private func makeAISettings() -> M8AISettingsModel {
    let settings = M8AISettingsModel(store: aiConfiguration)
    settings.runtime = ai
    return settings
  }
  lazy var settingsModel: M7SettingsModel = makeSettingsModel()
  private func makeSettingsModel() -> M7SettingsModel {
    M7SettingsModel(defaults: PerformanceEnvironment.defaults, capabilities: Set(MacSettingKey.allCases),
      apply: { [weak self] in self?.applySettings($0) }, clearImageCache: { try await ImageCache.shared.clear() },
    takeScreenshot: { [weak self] in self?.takePlayerScreenshot() })
  }
  private func makeNotifications() -> M7NotificationCoordinator {
    let rpc = try? standardRPCService()
    let service = self.service
    return M7NotificationCoordinator(fetch: {
      guard let rpc else { throw BiliError.dependency("动态服务初始化失败") }
      let before = await service.authSnapshot()
      let expected = try await service.authorizeAppInteraction(expectedIdentity: before)
      let page = try await rpc.dynamics(.video(offset: "", baseline: ""))
      let current = await service.authSnapshot()
      try Task.checkCancellation()
      guard current.epoch == expected.epoch, current.identityRevision == expected.identityRevision else { throw CancellationError() }
      return page.items.compactMap { item in
        switch item.content {
        case .video(let video):
          return M7MomentNotification(id: item.id, title: video.title, publisher: item.author?.name ?? "",
            page: "video", mediaID: video.bvid.isEmpty ? "av\(video.aid)" : video.bvid)
        case .episode(let episode):
          guard episode.episodeID > 0 else { return nil }
          return M7MomentNotification(id: item.id, title: episode.title, publisher: item.author?.name ?? "",
            page: "episode", mediaID: String(episode.episodeID))
        default: return nil
        }
      }
    }, liveFetch: {
      // The coordinator only polls with a signed-in identity scope.
      let before = await service.authSnapshot()
      let page = try await service.liveFeed(page: 1, expectedIdentity: before)
      let current = await service.authSnapshot()
      try Task.checkCancellation()
      guard current.epoch == before.epoch, current.identityRevision == before.identityRevision else { throw CancellationError() }
      return page.following.map { room in
        M7MomentNotification(id: "live-\(room.id)", title: room.title,
          publisher: room.author.isEmpty ? "关注的主播开播了" : "\(room.author) 开播了", page: "live", mediaID: String(room.id))
      }
    }, didOpen: { [weak self] page, id in
      guard let self else { return }
      if page == "live", let room = Int64(id), room > 0 { self.openLive(room); return }
      if page == "episode", let episode = Int64(id), episode > 0 { self.openPGC(PGCSelection(episodeID: episode)) }
      else if page == "video" {
        if id.hasPrefix("av"), let aid = Int64(id.dropFirst(2)), aid > 0 { self.open(Video(bvid: "", title: "视频动态", aid: aid)) }
        else if id.hasPrefix("BV") { self.open(Video(bvid: id, title: "视频动态")) }
      }
    }, report: { [weak self] in self?.error = $0 })
  }
  private func configureNotifications() {
    notifications.configure(enabled: appSettings.bool(.notifications), momentEnabled: appSettings.bool(.momentNotifications),
      liveEnabled: appSettings.bool(.liveNotifications),
      identityID: accountMID.map(String.init), fixture: usesUIFixtures)
  }
  /// Sidebar items left visible in 设置 › 通用 › 侧边栏项目 (the 前往 menu always lists all of them).
  func visibleDestinations(_ items: [Destination]) -> [Destination] {
    items.filter { item in
      guard case .page(let page) = item, let key = page.visibilityKey else { return true }
      return appSettings.bool(key)
    }
  }
  /// Opens a sidebar item: a page, or a library list as the only route on the stack.
  func go(to destination: Destination) {
    switch destination {
    case .page(let page): navigate(to: page)
    default:
      guard let route = destination.route else { return }
      if overlays == [route] { return }
      noteNavigation()
      pgcFavoriteIntent = nil
      cancelCuratedPlaylist()
      if hasPlayback && playbackElsewhere { leavePlaybackPage() } else { closePlayer() }
      overlays = [route]
      forwardRoutes = []
    }
  }
  /// 设置… (⌘,) and every「设置」link open the settings window, optionally on one category.
  func openSettings(_ group: MacSettingGroup? = nil) {
    SettingsWindowController.shared.show(model: self, group: group)
  }
  /// 「更多」 › 自定义控制条…: the settings window on 控制条; playback carries on.
  func openPlayerBarSettings() {
    SettingsWindowController.shared.show(model: self, page: .playerBar)
  }
  private func applySettings(_ settings: MacSettings) {
    let previous = appSettings; appSettings = settings
    if previous.bool(.dockBadge) != settings.bool(.dockBadge) { updateDockBadge() }
    watchActivity.indexesSpotlight = settings.bool(.spotlightIndex)
    if previous.bool(.spotlightIndex), !settings.bool(.spotlightIndex) { watchActivity.end(); watchActivity.clearSpotlight() }
    theme = AppTheme(rawValue: settings.text(.theme)) ?? .system
    playbackPreferences.codec = PlaybackCodec(rawValue: settings.text(.codec)) ?? .h264
    playbackPreferences.quality = settings.number(.quality) > 0 ? Int(settings.number(.quality)) : nil
    playbackPreferences.avoidP2P = settings.bool(.avoidP2P)
    scrollAcceleration.setEnabled(settings.bool(.scrollAcceleration))
    configureNotifications()
    for target in [player, pgcPlayback?.player].compactMap({ $0 }) {
      Self.configurePlayerPreferences(target, settings: settings, previous: previous)
    }
    if previous.bool(.autoSkipClips) != settings.bool(.autoSkipClips) { pgcPlayback?.automaticSkipChanged() }
    cdn.apply(settings)
  }
  static func configurePlayerPreferences(_ target: PlayerModel, settings: MacSettings = MacSettings.load(from: PerformanceEnvironment.defaults), previous: MacSettings? = nil) {
    target.configureRuntime(settings: settings, previous: previous)
    func changed(_ key: MacSettingKey) -> Bool { previous == nil || previous?[key] != settings[key] }
    if changed(.speed) || changed(.globalSpeed), settings.bool(.globalSpeed) { target.speed = settings.number(.speed); target.set("speed", String(target.speed)) }
    // A settings change applies the new default; a (re)load keeps what the user chose this session.
    if changed(.volume) {
      target.volume = previous == nil ? (PlayerModel.sessionVolume ?? settings.number(.volume)) : settings.number(.volume)
      target.set("volume", String(target.volume))
    }
    if changed(.danmakuEnabled) {
      let value = previous == nil ? (PlayerModel.sessionComments ?? settings.bool(.danmakuEnabled)) : settings.bool(.danmakuEnabled)
      if target.commentsEnabled != value { target.commentsEnabled = value }
    }
    for (key, property, value) in [
      (MacSettingKey.decode, "hwdec", settings.text(.decode)),
      (.audioChannels, "audio-channels", settings.text(.audioChannels)),
      (.maxVolume, "volume-max", String(Int(settings.number(.maxVolume)))),
      (.cacheMB, "demuxer-max-bytes", String(Int(settings.number(.cacheMB) * 1024 * 1024))),
      (.backCacheMB, "demuxer-max-back-bytes", String(Int(settings.number(.backCacheMB) * 1024 * 1024))),
      (.cacheSeconds, "demuxer-readahead-secs", String(settings.number(.cacheSeconds)))
    ] where changed(key) { target.set(property, value) }
  }
  /// The player whose picture a screenshot reads: a live room with a stream, an episode, or a
  /// video. Every 截取画面 entry (player menus, the live page, 播放 › 截取画面, settings) uses it.
  private var screenshotTarget: PlayerModel? {
    guard !usesUIFixtures else { return nil }
    if let livePlayback { return livePlayback.stream != nil && !livePlayback.ended ? livePlayback.player : nil }
    if let pgcPlayback { return pgcPlayback.episode != nil ? pgcPlayback.player : nil }
    return selected != nil ? player : nil
  }
  var canTakeScreenshot: Bool { screenshotTarget != nil }
  func takePlayerScreenshot() {
    guard let target = screenshotTarget else { error = "开始播放视频、剧集或直播后才能截取画面。"; return }
    let settings = appSettings
    let ext = settings.text(.screenshotFormat)
    let name = "Manping-" + UUID().uuidString + "." + ext
    // The frame is read back from our own renderer: mpv's screenshot cannot convert
    // VideoToolbox frames ("format videotoolbox not supported by libswscale").
    let save: (URL) -> Void = { [weak self] url in
      if target.usesExternalMpv {
        // External mpv keeps its own screenshot path (it decodes and owns the frame).
        target.command(["screenshot-to-file", url.path, "video"])
        if settings.text(.screenshotAction) != "save" {
          Task { @MainActor [weak self] in
            for _ in 0..<100 {
              if let image = NSImage(contentsOf: url) {
                if settings.text(.screenshotAction) == "copy" {
                  NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                } else { NSWorkspace.shared.open(url) }
                return
              }
              try? await Task.sleep(for: .milliseconds(50))
            }
            self?.error = "截图文件尚未生成，请检查外部 mpv 的设置和保存目录。"
          }
        }
        return
      }
      Task { @MainActor [weak self] in
        guard let image = await target.captureFrame() else {
          self?.error = "无法读取当前画面；请在视频开始播放后再截图。"; return
        }
        let type = (ext == "jpg" ? "public.jpeg" : "public.png") as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
          self?.error = "无法写入截图文件，请检查保存目录。"; return
        }
        CGImageDestinationAddImage(destination, image, ext == "jpg" ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { self?.error = "无法写入截图文件，请检查保存目录。"; return }
        switch settings.text(.screenshotAction) {
        case "copy":
          NSPasteboard.general.clearContents()
          NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        case "save": break
        default: NSWorkspace.shared.open(url)
        }
      }
    }
    let path = settings.text(.screenshotDirectory)
    if path.isEmpty {
      let panel = NSSavePanel(); panel.nameFieldStringValue = name
      panel.begin { response in MainActor.assumeIsolated { if response == .OK, let url = panel.url { save(url) } } }
    } else { save(URL(fileURLWithPath: path).appendingPathComponent(name)) }
  }
  @Published var shaderSelections: [String: String] = [:]
  let service: BiliService
  var libraryRPCTransport: (any BiliRPCTransport)?
  var libraryStandardRPC: (any BiliRPCService)?
  var usesUIFixtures: Bool {
    DebugUIFixtures.enabled
  }
  var usesEpisodicFixture: Bool {
    DebugUIFixtures.episodic
  }
  private let authCallbacks = AuthCallbackGate()
  private var accountTask: Task<Void, Never>?
  private var loadTask: Task<Void, Never>?
  private var downloadTasks: [String: Task<Void, Never>] = [:]
  private var downloadIdentities: [String: AuthSnapshot] = [:]
  private var store: DownloadStore?
  static var support: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Manping")
  }
  static var ffmpeg: URL {
    let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg")
    return FileManager.default.fileExists(atPath: bundled.path)
      ? bundled : URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
  }
  init() {
    if DebugUIFixtures.enabled {
      service = BiliService(transport: DebugUITransport(), credentials: DebugUICredentialStore())
      let transport = M3FixtureRPCTransport(richUI: true)
      libraryRPCTransport = transport
      libraryStandardRPC = try? NativeBiliRPCService(auth: service, transport: transport, installationID: "ui-fixture")
      downloads = [
        DownloadRecord(id: "fixture-complete", bvid: "BV1fixture01", title: "山野记录 · 已完成的样本", state: "complete", progress: 1, output: "/tmp/Bili Downloads/sample.mp4", options: DownloadOptions(cid: 1000, directory: "/tmp/Bili Downloads")),
        DownloadRecord(id: "fixture-interrupted", bvid: "BV1fixture02", title: "城市的声音 · 中断后可恢复", state: "interrupted", progress: 0.42, error: "上次运行中断，可恢复下载", options: DownloadOptions(cid: 1001, directory: "/tmp/Bili Downloads")),
        DownloadRecord(id: "fixture-failed", bvid: "BV1fixture03", title: "桌面计划 · 磁盘错误样本", state: "failed", progress: 0.12, error: "磁盘空间不足，请释放空间后恢复", options: DownloadOptions(cid: 1002, directory: "/tmp/Bili Downloads"))
      ]
      observeQueueIdentity()
      return
    }
    service = BiliService(webDeviceCookies: true)
    observeQueueIdentity()
    setUpProxy()
    do {
      store = try DownloadStore(url: Self.support.appendingPathComponent("downloads.sqlite"))
      downloads = try store?.records() ?? []
    } catch { self.error = error.localizedDescription }
  }
  #if DEBUG
  init(probeService: BiliService) {
    service = probeService
    observeQueueIdentity()
  }
  #endif
  func initialize(skipAuthentication: Bool = false) async {
    configureAI()
    // The account's shield list and the user's own rules both re-filter every open player.
    let refreshShields: () -> Void = { [weak self] in
      guard let self else { return }
      for player in [self.player, self.pgcPlayback?.player, self.livePlayback?.player].compactMap({ $0 }) {
        player.refreshAccountShield()
      }
    }
    DanmakuShieldSync.shared.onChange = refreshShields
    DanmakuFilterStore.shared.onChange = refreshShields
    // Applies the saved Spotlight preference now (clearing a disabled index left from before).
    if !usesUIFixtures { _ = watchActivity }
    scrollAcceleration.setEnabled(appSettings.bool(.scrollAcceleration))
    if usesUIFixtures {
      try? await service.restoreCookies()
      let identity = await service.authSnapshot()
      accountDisplayIdentity = (epoch: identity.epoch, revision: identity.identityRevision)
      account = "本地样本"
      accountAvatar = URL(string: "https://fixture.invalid/avatar/1"); accountLevel = 6
      accountMID = M3Fixture.owner
      configureNotifications()
      unreadMessageCount = 3
      fixtureReady = true
      // Read-only pages load in their own structured view task. Avoid cancelling
      // their first fixture load before launch-only section/preview selection.
      if selected != nil { await refresh() }
      return
    }
    // A proxy without a password applies before the first request; one with a password after the
    // credential read below (the same entry as the account).
    let proxySettings = ProxySettings.load(from: PerformanceEnvironment.defaults)
    if proxySettings.kind != .none, !Self.proxyNeedsSecret(proxySettings) || Self.debugProxySecret != nil {
      _ = await applyProxy(proxySettings, secret: nil, saveSecret: false)
    }
    if skipAuthentication {
      await refresh()
      return
    }
    let generation = authCallbacks.generation
    // Lists start loading anonymously right away; the credential read (which, on the first launch
    // after 0.1.2, moves the Keychain item over and may wait on its prompt) happens off the
    // service actor, then the account is applied.
    refreshToken &+= 1
    // A video requested at launch starts now (anonymously if needed) instead of waiting for
    // the stored credentials; if the identity changes underneath, startVideo reloads it once.
    if let launch = selected, loadTask == nil, !usesUIFixtures { startVideo(launch, preservingQueue: false) }
    do {
      let service = self.service
      // A logout or new login during the (possibly prompting) credential read makes this stale.
      let before = await service.authSnapshot()
      let stored = try await Task.detached(priority: .userInitiated) { try service.loadStoredCredentials() }.value
      if Self.proxyNeedsSecret(proxySettings), Self.debugProxySecret == nil {
        _ = await applyProxy(proxySettings, secret: nil, saveSecret: false)
      }
      let applied = try await service.restore(stored, ifUnchangedSince: before)
      guard applied, authCallbacks.accepts(generation) else { return }
      let snapshot = await service.authSnapshot()
      if snapshot.state != .needsLogin {
        await loginCompleted(token: snapshot.epoch)
        // The launch video already failed anonymously: try it once more with the account.
        if let launch = selected, anonymousLoadFailure == clipGeneration, manifest == nil {
          anonymousLoadFailure = nil
          retryVideoForIdentity(launch)
        }
      }
    } catch {
      if authCallbacks.accepts(generation) { self.error = "无法读取本机保存的登录信息，请重新扫码登录" }
    }
    // A video the user opened while credentials were restoring is already loading: refresh the
    // lists only instead of restarting it from the beginning.
    if selected != nil, loadTask != nil || manifest != nil { refreshToken &+= 1 } else { await refresh() }
  }
  func navigate(to page: Page) {
    noteNavigation()
    if hasPlayback && playbackElsewhere { leavePlaybackPage() } else { closePlayer() }
    overlays = []
    forwardRoutes = []
    self.page = page
    Task { await refresh() }
  }
  func selectPopularTab(_ tab: PopularTab) {
    popularTab = tab
    Task { await refresh() }
  }
  func showSearch() {
    if case .search = currentOverlay {} else { openOverlay(.search("")) }
    searchFocusRequest += 1
  }
  func submitSearch() {
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else {
      showSearch()
      return
    }
    if term.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil {
      open(Video(bvid: term, title: term))
      return
    }
    if term.lowercased().hasPrefix("av"), let aid = Int64(term.dropFirst(2)), aid > 0 {
      open(Video(bvid: "", title: term, aid: aid))
      return
    }
    if case .search = currentOverlay {
      noteNavigation()
      overlays[overlays.count - 1] = .search(term)
    } else {
      openOverlay(.search(term))
    }
    Task { await refresh() }
  }
  func openOverlay(_ route: OverlayRoute) {
    noteNavigation()
    pgcFavoriteIntent = nil
    cancelCuratedPlaylist()
    leavePlaybackPage()
    overlays.append(route)
  }
  func submitRegionalSearch(_ keyword: String) {
    guard let route = currentOverlay else { search = keyword; submitSearch(); return }
    switch route {
    case .userSpace, .history:
      regionalSearchRequest = RegionalSearchRequest(route: route, keyword: keyword)
    default: search = keyword; submitSearch()
    }
  }
  func resolveAccountLaunch() async {
    guard let target = launchOwnPage else { return }
    launchOwnPage = nil
    let snapshot = await service.authSnapshot()
    guard let mid = snapshot.token?.mid, mid > 0 else {
      error = "请先登录，再打开用户列表。"; return
    }
    accountMID = mid
    switch target {
    case "space": openOverlay(.userSpace(mid))
    case "following": openOverlay(.following(mid))
    case "followers": openOverlay(.followers(mid))
    default: break
    }
  }
  func goBack() {
    noteNavigation()
    guard let route = overlays.last else { return }
    switch route {
    case .video, .pgc, .live:
      if playbackElsewhere { leavePlaybackPage() } else { closePlayer() }
    default: forwardRoutes.append(route); overlays.removeLast()
    }
    resumeVisiblePlayback()
    // Returning to retained UGC playback must not restart an engine still awaiting its surface.
    if !mainShowsPlayer || selected == nil { Task { await refresh() } }
  }
  /// 前进 (⌘]): reopens the route last left with 返回.
  func goForward() {
    guard let route = forwardRoutes.popLast() else { return }
    noteNavigation()
    pgcFavoriteIntent = nil
    cancelCuratedPlaylist()
    leavePlaybackPage()
    steppingForward = true
    overlays.append(route)
    steppingForward = false
    Task { await refresh() }
  }
  func refresh() async {
    // While the main window browses beside the mini or standalone window, it refreshes its page.
    if mainShowsPlayer, let pgcPlayback { await pgcPlayback.refresh(); return }
    // List refreshes (launch, account restore) must not interrupt a healthy live stream.
    if mainShowsPlayer, let livePlayback { livePlayback.refreshIfNeeded(); return }
    if mainShowsPlayer, let selected {
      // A video that is playing keeps playing; ⌘R then only refreshes its side data.
      if manifest != nil, player.error == nil, player.duration > 0 {
        await refreshVideoDetails(selected)
      } else {
        startVideo(selected, preservingQueue: playbackQueue.current?.id == selected.id)
      }
      return
    }
    refreshToken &+= 1
  }
  func standardRPCService() throws -> any BiliRPCService {
    if let libraryStandardRPC { return libraryStandardRPC }
    let key = "Manping.RPCInstallationID"
    let installationID: String
    if let saved = PerformanceEnvironment.defaults.string(forKey: key), !saved.isEmpty { installationID = saved }
    else {
      installationID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      PerformanceEnvironment.defaults.set(installationID, forKey: key)
    }
    let rpc = try NativeBiliRPCService(auth: service, installationID: installationID)
    libraryStandardRPC = rpc
    return rpc
  }
  /// Developer launch targets select live requests unless Debug fixtures are explicitly enabled.
  func configureLaunchPage(_ name: String) -> Bool {
    switch name {
    #if DEBUG
    case "curated":
      guard usesUIFixtures else { return false }
      page = .popular; launchCuratedPlaylist = true
    #endif
    case "popular":
      page = .popular
      popularTab = .popular
    case "recommended":
      page = .popular
      popularTab = .recommended
    case "partitions": page = .video
    case "live": page = .live
    case "anime", "anime:index": page = .anime
    case "cinema", "cinema:tv", "cinema:documentary": page = .cinema
    case "article", "article:ranking", "article:partition": page = .article
    case "messages", "messages:reply", "messages:at", "messages:like", "messages:chat": page = .message
    case "moment": page = .moment
    case "moment:all", "moment:comments":
      guard usesUIFixtures else { return false }
      page = .moment
    case "ranking":
      page = .popular
      popularTab = .ranking
    case "search": overlays = [.search("")]
    case "space", "following", "followers": launchOwnPage = name
    case "favorites": overlays = [.favorites]
    case "later": overlays = [.viewLater]
    case "history": overlays = [.history]
    case "settings", "settings:general", "settings:appearance", "settings:navigation", "settings:cache":
      launchSettingsGroup = .general
    case "settings:playback", "settings:behavior": launchSettingsGroup = .playback
    case "settings:playerbar":
      launchSettingsGroup = .playback; launchSettingsPlayerBar = true
    case "settings:danmaku": launchSettingsGroup = .danmaku
    case "settings:network", "settings:proxy": launchSettingsGroup = .network
    case "settings:download", "settings:screenshot": launchSettingsGroup = .download
    case "settings:notifications": launchSettingsGroup = .notifications
    case "settings:privacy": launchSettingsGroup = .privacy
    case "settings:ai": launchSettingsGroup = .ai
    case "settings:advanced", "settings:mpv", "settings:logging": launchSettingsGroup = .advanced
    case "downloads": page = .downloads
    case "downloads:options":
      guard usesUIFixtures else { return false }
      _ = configureLaunchPage("video:av100"); showingDownloadOptions = true
    default:
      if name.hasPrefix("article:cv"), let id = Int64(name.dropFirst(10)), id > 0 {
        page = .article; overlays = [.article(id)]; return true
      }
      if name.hasPrefix("live:"), let id = Int64(name.dropFirst(5)), id > 0 {
        launchLiveRoom = id; page = .live; return true
      }
      if name.hasPrefix("pgc:") {
        let identifier = String(name.dropFirst(4))
        guard identifier.range(of: "^(ss|ep)[1-9][0-9]*$", options: .regularExpression) != nil,
          let id = Int64(identifier.dropFirst(2)) else { return false }
        launchPGCSelection = identifier.hasPrefix("ss") ? PGCSelection(seasonID: id) : PGCSelection(episodeID: id)
        page = .anime; return true
      }
      #if DEBUG
      if usesUIFixtures && name == "favorites:11" { overlays = [.favorites]; return true }
      #endif
      for (prefix, route) in [("space:", 0), ("following:", 1), ("followers:", 2)] {
        if name.hasPrefix(prefix) {
          guard let mid = Int64(name.dropFirst(prefix.count)), mid > 0 else { return false }
          overlays = [route == 0 ? .userSpace(mid) : route == 1 ? .following(mid) : .followers(mid)]
          return true
        }
      }
      if name.hasPrefix("history:") {
        overlays = [.history]
        regionalSearchRequest = RegionalSearchRequest(route: .history, keyword: String(name.dropFirst(8)))
        return true
      }
      if name.hasPrefix("search:") {
        let term = String(name.dropFirst(7))
        guard !term.isEmpty else { return false }
        search = term; overlays = [.search(term)]; return true
      }
      guard name.hasPrefix("video:") else { return false }
      let identifier = String(name.dropFirst(6))
      if identifier.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil {
        selected = Video(bvid: identifier, title: identifier)
      } else if identifier.hasPrefix("av"), let aid = Int64(identifier.dropFirst(2)), aid > 0 {
        selected = Video(bvid: "", title: identifier, aid: aid)
      } else { return false }
      pendingOpenMode = defaultOpenPlacement
      #if DEBUG
        if DebugUIFixtures.episodic { page = .anime }
      #endif
    }
    return true
  }
  /// Plays a video. `mode` is where it plays this time (a card's 小窗播放 or 在独立窗口播放);
  /// nil uses 设置 › 打开视频时. Either way the choice is applied once, for this open: later
  /// items (next part, playlist, related) stay where the picture is.
  func open(_ video: Video) { open(video, mode: nil) }
  func open(_ video: Video, mode: MacOpenMode?) {
    startVideo(video, preservingQueue: false)
    pendingOpenMode = mode.map { OpenPlacement(mode: $0) } ?? defaultOpenPlacement
    // An explicit window opens right away; the media fills it when it loads, leaving the
    // window as it is by then.
    if let mode, [.compact, .detached].contains(mode) {
      applyOpenMode(OpenPlacement(mode: mode))
      pendingOpenMode = OpenPlacement(mode: mode, windowDisplay: nil)
    }
  }
  func resolvePGCLaunch() {
    if let room = launchLiveRoom { launchLiveRoom = nil; openLive(room); return }
    guard let selection = launchPGCSelection else { return }
    launchPGCSelection = nil; openPGC(selection)
  }
  /// Opens an episode or a season; its first load applies 设置 › 打开视频时 (no entry offers
  /// another place for episodes).
  func openPGC(_ selection: PGCSelection) {
    noteNavigation()
    closePlayer()
    pendingOpenMode = defaultOpenPlacement
    player = PlayerModel()
    Self.configurePlayerPreferences(player, settings: appSettings)
    let playback = PGCPlaybackModel(service: service, player: player,
      preferences: playbackPreferences, usesFixtures: usesUIFixtures, cdn: cdn)
    pgcPlayback = playback
    playback.onPlaybackEnd = { [weak self] in self?.requestNextPlayback() }
    playback.onEpisodeChange = { [weak self] in
      self?.noteNavigation(); self?.progressReporter.flush(); self?.cancelNextPlayback()
      self?.clipPlayback.stop(.mediaChanged)
    }
    playback.onMediaReady = { [weak self] in self?.playbackDidLoad() }
    playback.skipNextPrompt = { [weak self] in self?.appSettings.bool(.skipNextPrompt) ?? false }
    // 依次播放 moves the playhead itself: automatic skips wait until it ends.
    playback.automaticSkip = { [weak self] in
      guard let self else { return false }
      return self.appSettings.bool(.autoSkipClips) && !self.clipPlayback.isActive
    }
    // Subtitles and danmaku sending follow the episode wherever the picture is.
    pgcEpisodeObservation = playback.$episode
      .map { EpisodeMedia(aid: $0?.aid, cid: $0?.cid) }
      .removeDuplicates()
      .sink { [weak self] media in self?.playbackFeatures.follow(aid: media.aid, cid: media.cid) }
    pgcSelection = selection
    overlays.append(.pgc(selection))
    // The model owns the load, so it runs even when the page is not on screen (小窗).
    Task { await playback.ensureLoaded(selection) }
  }
  private struct EpisodeMedia: Equatable { let aid: Int64?; let cid: Int64? }
  private var pgcEpisodeObservation: AnyCancellable?
  // MARK: Proxy

  /// Debug builds only: a test password from the environment, never stored.
  private static var debugProxySecret: String? {
    #if DEBUG
    ProcessInfo.processInfo.environment["MANPING_DEBUG_PROXY_SECRET"]
    #else
    nil
    #endif
  }

  private static func proxyNeedsSecret(_ settings: ProxySettings) -> Bool {
    settings.kind == .shadowsocks || (settings.kind == .socks5 && !settings.username.isEmpty)
  }

  private func setUpProxy() {
    let settings = ProxySettings.load(from: PerformanceEnvironment.defaults)
    proxySettingsModel.load(settings, hasSecret: false, status: settings.kind == .none ? "未配置" : "等待启动")
    proxySettingsModel.apply = { [weak self] settings, secret in
      // nil is success; only a released model reports an error here.
      guard let self else { return "应用已关闭" }
      return await self.applyProxy(settings, secret: secret, saveSecret: true)
    }
    proxySettingsModel.test = { [weak self] in
      guard let self else { return (.failure(BiliError.invalidResponse("应用已关闭")), nil) }
      let proxy = self.proxy
      async let proxied: Result<ProxyProbeResult, Error> = { do { return .success(try await proxy.probe()) } catch { return .failure(error) } }()
      async let direct = try? await proxy.probe(direct: true)
      return (await proxied, await direct)
    }
    proxy.onChange = { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let settings = ProxySettings.load(from: PerformanceEnvironment.defaults)
        self.cdn.configureProxy(settings.isConfigured ? self.proxy : nil, media: settings.media)
        self.proxySettingsModel.setStatus(self.proxy.status.message)
      }
    }
  }

  /// Saves and applies proxy settings. `secret` nil keeps the stored password. Returns an error.
  @discardableResult
  func applyProxy(_ settings: ProxySettings, secret: String?, saveSecret: Bool) async -> String? {
    settings.save(to: PerformanceEnvironment.defaults)
    var resolved = secret
    if saveSecret, let secret {
      do { try await Task.detached(priority: .userInitiated) { try CredentialStore().saveProxySecret(secret) }.value }
      catch { return "无法保存密码：\(error.localizedDescription)" }
    }
    if resolved == nil, let debug = Self.debugProxySecret { resolved = debug }
    if resolved == nil, Self.proxyNeedsSecret(settings) {
      resolved = try? await Task.detached(priority: .userInitiated) { try CredentialStore().proxySecret() }.value
    }
    var message: String?
    do { try proxy.apply(settings, secret: resolved) } catch {
      message = "代理隧道启动失败（\(error)），稍后会自动重试。"
    }
    await service.setProxy(settings.isConfigured ? proxyTransport : nil, region: settings.region)
    cdn.configureProxy(settings.isConfigured ? proxy : nil, media: settings.media)
    proxySettingsModel.setStatus(proxy.status.message)
    if resolved?.isEmpty == false { proxySettingsModel.secretStored() }
    return message
  }

  /// Changes only the video acceleration mode (the CDN panel's VPN menu).
  func setProxyMediaRoute(_ route: MediaRoute) {
    var settings = ProxySettings.load(from: PerformanceEnvironment.defaults)
    guard settings.media != route else { return }
    settings.media = route
    settings.save(to: PerformanceEnvironment.defaults)
    proxySettingsModel.media = route
    cdn.configureProxy(settings.isConfigured ? proxy : nil, media: route)
  }

  /// Plays a live room in the app. `roomID` may be the short or the real room number. `mode`
  /// is where it plays this time (a card's 小窗播放); without one it plays in the main window.
  func openLive(_ roomID: Int64) { openLive(roomID, mode: nil) }
  func openLive(_ roomID: Int64, mode: MacOpenMode?) {
    noteNavigation()
    guard roomID > 0 else { return }
    closePlayer()
    defer { if let mode { applyOpenMode(OpenPlacement(mode: mode)) } }
    player = PlayerModel()
    player.suspendAudioOnly()
    Self.configurePlayerPreferences(player, settings: appSettings)
    let live = LivePlaybackModel(roomID: roomID, service: service, player: player,
      preferHEVC: playbackPreferences.codec == .hevc, avoidPeerAssisted: playbackPreferences.avoidP2P, usesFixtures: usesUIFixtures)
    livePlayback = live
    overlays.append(.live(roomID))
    live.start()
    if !usesUIFixtures { attachLiveSystemMedia(live) }
  }
  /// Control Center, media keys and the lock screen follow the live room once its info loads,
  /// and again whenever the streamer retitles it.
  private func attachLiveSystemMedia(_ live: LivePlaybackModel) {
    liveMediaSubscription = live.$room
      .compactMap { $0 }
      .removeDuplicates { $0.title == $1.title && $0.anchorName == $1.anchorName }
      .sink { [weak self, weak live] room in
        // @Published delivers before storing; act on the next main turn.
        DispatchQueue.main.async {
          guard let self, let live, self.livePlayback === live else { return }
          if let web = URL(string: "https://live.bilibili.com/\(room.roomID)") {
            self.watchActivity.begin(.init(link: "manping://live/\(room.roomID)", web: web, title: room.title,
              author: room.anchorName))
          }
          self.systemMedia.attach(player: live.player, title: room.title,
            artist: room.anchorName.isEmpty ? "直播" : room.anchorName, live: true, previous: nil, next: nil)
          self.artworkTask?.cancel()
          guard let cover = room.cover else { return }
          self.artworkTask = Task { @MainActor [weak self, weak live] in
            guard let image = try? await ImageCache.shared.imageForReader(for: cover), !Task.isCancelled,
              let self, let live, self.livePlayback === live else { return }
            self.systemMedia.updateArtwork(NSImage(cgImage: image, size: .zero))
          }
        }
      }
  }
  /// Opens a live room from a card, row or pin: the web page when 「直播间在浏览器打开」 is on, the in-app player otherwise.
  func openLiveRoom(_ roomID: Int64) {
    guard roomID > 0 else { return }
    if appSettings.bool(.liveWebPlayer) {
      if let url = URL(string: "https://live.bilibili.com/\(roomID)") { NSWorkspace.shared.open(url) }
    } else {
      openLive(roomID)
    }
  }
  func openPGCFavorites(cinema: Bool) {
    openOverlay(.favorites); pgcFavoriteIntent = (cinema, UUID())
  }
  /// Opens a pasted, dropped or `manping://` link in the app. Returns false when the text is not
  /// a Bilibili destination, so callers can say so instead of guessing.
  @discardableResult func openLink(_ text: String) -> Bool {
    guard let link = BiliLinkParser.parse(text) else { return false }
    openLink(link); return true
  }
  func openLink(_ link: BiliLink) {
    // A newer link supersedes a short link still resolving.
    noteNavigation()
    switch link {
    case .video(let bvid): open(Video(bvid: bvid, title: "视频"))
    case .archive(let aid): open(Video(bvid: "", title: "视频", aid: aid))
    case .episode(let id): openPGC(PGCSelection(episodeID: id))
    case .season(let id): openPGC(PGCSelection(seasonID: id))
    case .live(let room): openLive(room)
    case .article(let id): openOverlay(.article(id))
    case .space(let mid): openOverlay(.userSpace(mid))
    case .short(let url):
      // Follow the short link's redirects without cookies; only a bilibili.com target opens,
      // and only if the user has not gone somewhere else in the meantime.
      let origin = navigationGeneration
      linkTask = Task { [weak self] in
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"; request.httpShouldHandleCookies = false
        let response = try? await URLSession.shared.data(for: request).1
        guard let self, !Task.isCancelled, self.navigationGeneration == origin else { return }
        guard let final = response?.url, BiliLinkParser.isBilibili(final), let link = BiliLinkParser.parse(final) else {
          self.error = "无法解析这个短链接。"; return
        }
        if case .short = link { return }
        self.openLink(link)
      }
    }
  }
  private var linkTask: Task<Void, Never>?
  /// Bumped by every navigation (pages, overlays, back, videos, parts, episodes, live rooms,
  /// closing the player). A short link resolving in the background opens only if it is unchanged.
  private var navigationGeneration = 0
  private func noteNavigation() {
    navigationGeneration &+= 1
    linkTask?.cancel(); linkTask = nil
  }
  func open(_ entry: LibraryEntry) {
    switch entry.destination {
    case .video(let video): open(video)
    case .user(let mid): openOverlay(.userSpace(mid))
    case .web(let url): openLibraryURL(url)
    case .unavailable: break
    }
  }
  func openLibraryURL(_ url: URL) {
    if ["www.bilibili.com", "bilibili.com"].contains(url.host?.lowercased() ?? ""),
      url.user == nil, url.password == nil, ["http", "https"].contains(url.scheme ?? ""),
      url.path.range(of: "^/read/cv[1-9][0-9]*/?$", options: .regularExpression) != nil,
      let id = Int64(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).dropFirst(7)) {
      openOverlay(.article(id)); return
    }
    if ["www.bilibili.com", "bilibili.com"].contains(url.host?.lowercased() ?? ""),
      url.user == nil, url.password == nil, ["http", "https"].contains(url.scheme ?? ""),
      url.path.range(of: "^/bangumi/play/(ss|ep)[1-9][0-9]*/?$", options: .regularExpression) != nil {
      let identifier = url.path.split(separator: "/").last.map(String.init) ?? ""
      if let id = Int64(identifier.dropFirst(2)) {
        openPGC(identifier.hasPrefix("ss") ? PGCSelection(seasonID: id) : PGCSelection(episodeID: id)); return
      }
    }
    NSWorkspace.shared.open(url)
  }
  /// The clip generation of a launch video whose anonymous load failed (not cancelled).
  private var anonymousLoadFailure: UUID?
  private var deferredVideoRetry: (video: Video, generation: UUID)?
  private func retryVideoForIdentity(_ video: Video) {
    if pausedBrowsing.isBrowsing {
      pausedBrowsing.invalidate()
      player.suspendForBrowsing()
      deferredVideoRetry = (video, clipGeneration)
    } else {
      startVideo(video, preservingQueue: false, identityRetry: true, initiallyPaused: !player.playbackIntended)
    }
  }
  private func retryDeferredVideo(resume: Bool, preservingOverlay: Bool = false) {
    guard let retry = deferredVideoRetry, retry.generation == clipGeneration else { return }
    let routes = overlays, forward = forwardRoutes
    deferredVideoRetry = nil
    startVideo(retry.video, preservingQueue: false, identityRetry: true, initiallyPaused: !resume)
    if preservingOverlay, let route = playbackRoute {
      var restored = routes.filter { !Self.isPlayerRoute($0) }
      let index = min(routes.firstIndex(where: Self.isPlayerRoute) ?? restored.count, restored.count)
      restored.insert(route, at: index)
      overlays = restored
    }
    forwardRoutes = forward.filter { !Self.isPlayerRoute($0) }
  }
  private func startVideo(_ video: Video, preservingQueue: Bool, identityRetry: Bool = false,
    initiallyPaused: Bool = false) {
    deferredVideoRetry = nil
    cdn.detach()
    noteNavigation()
    clipPlayback.stop(.mediaChanged)
    progressReporter.flush()
    cancelNextPlayback()
    playbackFeatures.shutdown()
    if livePlayback != nil {
      closeMiniPlayer(activateMain: false)
      livePlayback?.shutdown(); livePlayback = nil; liveMediaSubscription = nil
      if case .live = overlays.last { overlays.removeLast() }
    }
    if pgcPlayback != nil {
      closeMiniPlayer(activateMain: false)
      pgcEpisodeObservation = nil
      pgcPlayback?.shutdown(); pgcPlayback = nil; pgcSelection = nil
      if case .pgc = overlays.last { overlays.removeLast() }
    }
    if !preservingQueue { cancelCuratedPlaylist(); clearPlaybackQueue() }
    eofObservation = nil; clipGeneration = UUID()
    // A new video replaces what plays; the main window shows its page (or placeholder) again.
    browsingBesidePlayback = false
    pausedBrowsing.reset()
    overlays.removeAll(where: Self.isPlayerRoute)
    forwardRoutes.removeAll(where: Self.isPlayerRoute)
    overlays.append(.video(video.id))
    loadTask?.cancel()
    player.shutdown()
    sessionMediaKey = video.id
    player = PlayerModel()
    player.onExplicitPlay = { [weak self] in self?.revealAndPlay() }
    if initiallyPaused { player.set("pause", "yes") }
    Self.configurePlayerPreferences(player, settings: appSettings)
    selected = video
    manifest = nil
    selectedStream = nil
    videoDetails = nil
    error = nil
    let loadGeneration = clipGeneration
    let expected = preservingQueue ? queueLoadIdentity : nil
    loadTask = Task {
      do {
        let reportIdentity = await service.authSnapshot()
        try await checkCurrentLoad(loadGeneration, expected: expected)
        let details = try await service.videoDetails(video, expectedIdentity: expected).selectingPart(cid: video.cid)
        #if DEBUG
        if let debugAfterDetails { await debugAfterDetails() }
        #endif
        try await checkCurrentLoad(loadGeneration, expected: expected)
        selected = details.video
        videoDetails = details
        playbackFeatures.follow(aid: details.video.aid, cid: details.video.cid)
        let streams = try await service.playback(details.video, expectedIdentity: expected)
        #if DEBUG
        if let debugAfterManifest { await debugAfterManifest() }
        #endif
        try await checkCurrentLoad(loadGeneration, expected: expected)
        manifest = streams
        let choice = try PlaybackSelector.select(streams, preferences: playbackPreferences,
          supportsHardware: Self.supportsHardware)
        selectedStream = choice.video
        if usesUIFixtures { player.status = "本地样本 · 不加载在线媒体" }
        else {
          let prepared = await cdn.prepare(video: choice.video, audio: choice.audio, avoidP2P: playbackPreferences.avoidP2P,
            reportFailureTo: player)
          try await checkCurrentLoad(loadGeneration, expected: expected)
          // nil: a quality change made during startup already loaded the newer stream.
          if let prepared {
            player.load(video: prepared.video, audio: prepared.audio, paused: !player.playbackIntended); Self.configurePlayerPreferences(player)
            await attachCDN(to: player, ticket: prepared.ticket)
            try await checkCurrentLoad(loadGeneration, expected: expected)
          }
        }
        observePlaybackEnd()
        playbackDidLoad(identity: reportIdentity)
        if let cid = details.video.cid {
          do {
            let comments = try await service.comments(cid: cid, expectedIdentity: expected)
            try await checkCurrentLoad(loadGeneration, expected: expected)
            player.timeline = DanmakuTimeline(comments: comments)
          } catch is CancellationError { return } catch {
            if (try? await checkCurrentLoad(loadGeneration, expected: expected)) != nil {
              player.status = "没能加载弹幕：\(error.localizedDescription)"
            }
          }
        }
      } catch is CancellationError {
        // An identity change (credentials restored, login sheet opened) cancels in-flight requests
        // without the user leaving the video: reload it once instead of leaving a dead page.
        if !Task.isCancelled, !identityRetry, expected == nil, loadGeneration == clipGeneration, manifest == nil {
          retryVideoForIdentity(video)
        }
      } catch {
        if (try? await checkCurrentLoad(loadGeneration, expected: expected)) != nil {
          self.error = error.localizedDescription
          // An anonymous launch load may fail only for lack of the account still being restored.
          if expected == nil, !identityRetry { anonymousLoadFailure = loadGeneration }
        }
      }
    }
  }
  /// A video that finished loading under the previous identity (for example anonymously, while
  /// credentials were still being read) re-reads its streams; when the new identity unlocks a
  /// better preferred quality, playback switches to it at the current position.
  private func refreshStreamsForIdentity() {
    guard !usesUIFixtures, queueLoadIdentity == nil, manifest != nil, let video = selected,
      let details = videoDetails else { return }
    let generation = clipGeneration
    let target = player
    Task { [weak self, weak target] in
      guard let self, let target else { return }
      let identity = await service.authSnapshot()
      do {
        try await checkCurrentLoad(generation, expected: identity)
        let streams = try await service.playback(details.video, expectedIdentity: identity)
        try await checkCurrentLoad(generation, expected: identity)
        guard player === target, selected?.bvid == video.bvid, manifest != nil else { return }
        manifest = streams
        guard let preferred = preferredVideo(streams) else { return }
        let current = selectedStream
        let replacement = streams.video.first { $0.id == current?.id }
        let next = current == nil || preferred.quality > current!.quality ? preferred : replacement ?? preferred
        // The old identity was detached immediately; attach even when quality stays unchanged.
        changeQuality(next, persist: false)
      } catch is CancellationError {
        return
      } catch {
        guard player === target, (try? await checkCurrentLoad(generation, expected: identity)) != nil else { return }
        target.failPlayback("登录状态已变化，重新获取播放地址失败。请重试。")
      }
    }
  }

  private func refreshVideoDetails(_ video: Video) async {
    let generation = clipGeneration
    do {
      let details = try await service.videoDetails(video).selectingPart(cid: video.cid)
      guard generation == clipGeneration, selected?.bvid == video.bvid else { return }
      videoDetails = details
    } catch is CancellationError {} catch {
      if generation == clipGeneration { self.error = error.localizedDescription }
    }
  }
  private static func supportsHardware(_ codec: PlaybackCodec) -> Bool {
    switch codec {
    case .h264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
    case .hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    case .av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }
  }
  private func preferredVideo(_ manifest: PlaybackManifest) -> MediaStream? {
    try? PlaybackSelector.select(manifest, preferences: playbackPreferences,
                                supportsHardware: Self.supportsHardware).video
  }
  func openPart(_ part: VideoPart) {
    noteNavigation()
    clipPlayback.stop(.mediaChanged)
    guard let details = videoDetails else { return }
    cdn.detach()
    progressReporter.flush()
    cancelNextPlayback()
    pausedBrowsing.invalidate()
    eofObservation = nil; clipGeneration = UUID(); player.resetPlaybackEnd()
    loadTask?.cancel()
    let source = details.video
    let video = Video(bvid: source.bvid, title: source.title, cover: source.cover,
      author: source.author, duration: part.duration, views: source.views, cid: part.cid,
      description: source.description, aid: source.aid, authorID: source.authorID, avatar: source.avatar,
      publishedAt: source.publishedAt, subtitle: source.subtitle, recommendationReason: source.recommendationReason)
    selected = video
    videoDetails = details.selectingPart(cid: part.cid)
    playbackFeatures.follow(aid: source.aid, cid: part.cid)
    manifest = nil
    selectedStream = nil
    error = nil
    player.timeline = DanmakuTimeline(comments: [])
    let loadGeneration = clipGeneration
    let expected = queueLoadIdentity
    loadTask = Task {
      do {
        let reportIdentity = await service.authSnapshot()
        try await checkCurrentLoad(loadGeneration, expected: expected)
        let streams = try await service.playback(video, expectedIdentity: expected)
        #if DEBUG
        if let debugAfterManifest { await debugAfterManifest() }
        #endif
        try await checkCurrentLoad(loadGeneration, expected: expected)
        manifest = streams
        let choice = try PlaybackSelector.select(streams, preferences: playbackPreferences,
          supportsHardware: Self.supportsHardware)
        selectedStream = choice.video
        if usesUIFixtures { player.status = "本地样本 · 不加载在线媒体" }
        else {
          let prepared = await cdn.prepare(video: choice.video, audio: choice.audio, avoidP2P: playbackPreferences.avoidP2P,
            reportFailureTo: player)
          try await checkCurrentLoad(loadGeneration, expected: expected)
          // nil: a quality change made during startup already loaded the newer stream.
          if let prepared {
            player.load(video: prepared.video, audio: prepared.audio); Self.configurePlayerPreferences(player)
            await attachCDN(to: player, ticket: prepared.ticket)
            try await checkCurrentLoad(loadGeneration, expected: expected)
          }
        }
        observePlaybackEnd()
        playbackDidLoad(identity: reportIdentity)
        let lines = try await service.comments(cid: part.cid, expectedIdentity: expected)
        try await checkCurrentLoad(loadGeneration, expected: expected)
        player.timeline = DanmakuTimeline(comments: lines)
      } catch is CancellationError {} catch {
        if (try? await checkCurrentLoad(loadGeneration, expected: expected)) != nil { self.error = error.localizedDescription }
      }
    }
  }

  func closePlayer() {
    // First, so closing the mini or standalone window below does not put the page back.
    browsingBesidePlayback = false
    pausedBrowsing.reset()
    deferredVideoRetry = nil
    clipPlayback.stop(.mediaChanged)
    noteNavigation()
    progressReporter.flush()
    cancelNextPlayback()
    playbackFeatures.shutdown()
    artworkTask?.cancel(); artworkTask = nil; systemMedia.clear(); watchActivity.end()
    playbackWindow.close(showMain: true); playbackDetached = false
    cancelCuratedPlaylist()
    clearPlaybackQueue()
    closeMiniPlayer(activateMain: false)
    pendingOpenMode = nil
    pgcEpisodeObservation = nil
    pgcPlayback?.shutdown(); pgcPlayback = nil; pgcSelection = nil
    livePlayback?.shutdown(); livePlayback = nil; liveMediaSubscription = nil
    loadTask?.cancel()
    cdn.detach()
    player.shutdown()
    selected = nil
    manifest = nil
    selectedStream = nil
    videoDetails = nil
    overlays.removeAll(where: Self.isPlayerRoute)
    forwardRoutes.removeAll(where: Self.isPlayerRoute)
  }
  private func videoNavigation(previous: Bool = false) -> PlaybackNavigationAction {
    guard let details = videoDetails, let current = selected else { return .none }
    let playlist = playbackQueue.current == nil ? nil : playbackQueue.items
    let index = playbackQueue.current == nil ? nil : playbackQueue.index
    if previous {
      return PlaybackNavigation.previous(details: details, current: current, playlist: playlist, playlistIndex: index,
        endWithPlaylist: appSettings.bool(.endWithPlaylist), autoNextRelated: appSettings.bool(.autoNextRelated))
    }
    return PlaybackNavigation.next(details: details, current: current, playlist: playlist, playlistIndex: index,
      endWithPlaylist: appSettings.bool(.endWithPlaylist), autoNextRelated: appSettings.bool(.autoNextRelated))
  }
  var canPlayNext: Bool {
    if let pgcPlayback { return pgcPlayback.canPlayNext }
    return videoNavigation() != .none
  }
  var canPlayPrevious: Bool {
    if let playback = pgcPlayback, let episode = playback.episode {
      return !playback.isLoading && (playback.details?.episodes.firstIndex(where: { $0.id == episode.id }).map { $0 > 0 } ?? false)
    }
    return videoNavigation(previous: true) != .none
  }
  func playNext() {
    cancelNextPlayback()
    if let pgcPlayback { pgcPlayback.nextEpisode(); return }
    executeVideoNavigation(videoNavigation())
  }
  func playPrevious() {
    cancelNextPlayback()
    if let playback = pgcPlayback, let episode = playback.episode,
      let episodes = playback.details?.episodes, let index = episodes.firstIndex(where: { $0.id == episode.id }), index > 0 {
      playback.selectEpisode(episodes[index - 1]); return
    }
    executeVideoNavigation(videoNavigation(previous: true))
  }
  private func executeVideoNavigation(_ action: PlaybackNavigationAction) {
    switch action {
    case .part(let part): openPart(part)
    case .playlistNext: if let next = playbackQueue.next() { startVideo(next, preservingQueue: true) }
    case .playlistPrevious: if let previous = playbackQueue.previous() { startVideo(previous, preservingQueue: true) }
    case .video(let video): open(video)
    case .none: break
    }
  }
  func playQueueVideo(_ video: Video) {
    guard let selected = playbackQueue.select(id: video.id) else { return }
    startVideo(selected, preservingQueue: true)
  }
  /// Replaces the queue with a collected list and starts its first video. The hand-off is
  /// confirmed after the last wait, so a list whose read was replaced or whose page moved on
  /// meanwhile throws `CancellationError` and changes nothing. Its notice stays beside the
  /// player while this queue plays.
  func openPlaylist(_ handoff: PlaylistHandoff) async throws {
    let current = await service.authSnapshot()
    try handoff.confirm(current: current)
    var queue = VideoPlaybackQueue()
    try queue.replace(handoff.videos, identity: PlaybackQueueIdentity(handoff.identity))
    cancelCuratedPlaylist()
    playbackQueue = queue
    queueLoadIdentity = handoff.identity
    if let first = queue.current {
      startVideo(first, preservingQueue: true)
      pendingOpenMode = defaultOpenPlacement
      playbackNotice = handoff.notice
    }
  }
  /// What the playing queue has to say (e.g. its list was cut short). Shown under the player's
  /// controls in the main and standalone windows, never in the mini window; replaced with the
  /// queue and cleared when playback closes.
  @Published private(set) var playbackNotice: String?
  func dismissPlaybackNotice() { playbackNotice = nil }
  func playCuratedList() {
    guard !curatedLoading else { return }
    cancelCuratedPlaylist()
    let generation = curatedGeneration
    curatedLoading = true; error = nil
    curatedTask = Task { [weak self, service] in
      guard let self else { return }
      let snapshot = await service.authSnapshot()
      guard generation == curatedGeneration, !Task.isCancelled else { return }
      curatedIdentity = PlaybackQueueIdentity(snapshot)
      do {
        let videos = try await service.curatedPlaylist(expectedIdentity: snapshot)
        try Task.checkCancellation()
        let current = await service.authSnapshot()
        guard generation == curatedGeneration, PlaybackQueueIdentity(current) == PlaybackQueueIdentity(snapshot) else { return }
        try playbackQueue.replace(videos, identity: PlaybackQueueIdentity(snapshot))
        queueLoadIdentity = snapshot
        playbackNotice = nil
        curatedLoading = false; curatedIdentity = nil; curatedTask = nil
        if let first = playbackQueue.current {
          startVideo(first, preservingQueue: true)
          pendingOpenMode = defaultOpenPlacement
        }
      } catch is CancellationError {
        if generation == curatedGeneration { curatedLoading = false; curatedIdentity = nil; curatedTask = nil }
      } catch {
        if generation == curatedGeneration { self.error = error.localizedDescription; curatedLoading = false; curatedIdentity = nil; curatedTask = nil }
      }
    }
  }
  func cancelCuratedPlaylist() {
    curatedGeneration = UUID(); curatedTask?.cancel(); curatedTask = nil
    curatedLoading = false; curatedIdentity = nil
  }
  private func clearPlaybackQueue() {
    pausedBrowsing.invalidate()
    queueLoadIdentity = nil; playbackNotice = nil
    playbackQueue.clear(); eofObservation = nil; clipGeneration = UUID()
  }
  private func observeQueueIdentity() {
    queueIdentityTask = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let displaySnapshot = await service.authSnapshot()
        progressReporter.identityChanged(to: displaySnapshot)
        if let record = pausedBrowsing.suspension,
          record.binding.epoch != displaySnapshot.epoch || record.binding.revision != displaySnapshot.identityRevision {
          pausedBrowsing.invalidate()
          player.suspendForBrowsing()
        }
        for (id, binding) in downloadIdentities where binding.epoch != displaySnapshot.epoch || binding.identityRevision != displaySnapshot.identityRevision {
          downloadTasks[id]?.cancel()
        }
        let identity = (epoch: displaySnapshot.epoch, revision: displaySnapshot.identityRevision)
        if let previous = accountDisplayIdentity,
          previous.epoch != identity.epoch || previous.revision != identity.revision {
          if selected != nil { cdn.detach() }
          cancelNextPlayback()
          account = "登录"; accountMID = nil; accountAvatar = nil; accountLevel = nil; unreadMessageCount = 0
          DanmakuShieldSync.shared.configure(service: service, mid: nil)
          // Opening the login sheet bumps the identity without changing the account; show it again.
          // Only the display refreshes here: a login sheet opened to switch accounts stays open.
          if event.state != .needsLogin { Task { [weak self] in await self?.loginCompleted(dismissLogin: false) } }
          refreshStreamsForIdentity()
        }
        accountDisplayIdentity = identity
        reportIdentity = displaySnapshot
        configureNotifications()
        if playbackQueue.invalidate(epoch: event.epoch, revision: event.identityRevision) {
          pausedBrowsing.invalidate()
          if queueLoadIdentity != nil {
            // Leave the page instead of a dead player that can no longer load anything.
            closePlayer()
            error = "登录状态已变化，播放列表已停止，请重新打开。"
          }
          queueLoadIdentity = nil; playbackNotice = nil
          eofObservation = nil; clipGeneration = UUID()
        }
        if let pending = curatedIdentity, pending.epoch != event.epoch || pending.revision != event.identityRevision {
          cancelCuratedPlaylist()
        }
        #if DEBUG
        if let debugAfterIdentityEvent { await debugAfterIdentityEvent(event) }
        #endif
      }
    }
  }
  private func checkCurrentLoad(_ generation: UUID, expected: AuthSnapshot?) async throws {
    try Task.checkCancellation()
    guard generation == clipGeneration else { throw CancellationError() }
    if let expected {
      let current = await service.authSnapshot()
      try Task.checkCancellation()
      guard generation == clipGeneration,
        current.epoch == expected.epoch, current.identityRevision == expected.identityRevision else {
        throw CancellationError()
      }
    }
  }
  private func observePlaybackEnd() {
    eofObservation = nil
    guard selected != nil else { return }
    let generation = clipGeneration
    var prompted = false
    eofObservation = player.clock.$time.combineLatest(player.$duration, player.$eofReached).sink { [weak self] position, duration, ended in
      guard let self, !prompted, self.clipGeneration == generation,
        self.selected != nil, self.canPlayNext else { return }
      let threshold = self.appSettings.bool(.skipNextPrompt) ? 0.1 : 2
      guard ended || (duration > 5 && abs(position - duration) < threshold) else { return }
      prompted = true
      self.player.endTemporarySpeed()
      self.requestNextPlayback()
    }
  }
  private func requestNextPlayback() {
    // 依次播放 pauses at the end of its last clip instead of moving on.
    guard canPlayNext, !clipPlayback.isActive, pausedBrowsing.allowsAutomaticAdvance else { return }
    cancelNextPlayback()
    if appSettings.bool(.skipNextPrompt) { playNext(); return }
    nextPlaybackDeadline = Date().addingTimeInterval(8)
    nextPlaybackTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard let self, !Task.isCancelled, self.nextPlaybackDeadline != nil else { return }
      self.playNext()
    }
  }
  func cancelNextPlayback() {
    nextPlaybackTask?.cancel(); nextPlaybackTask = nil
    if nextPlaybackDeadline != nil { nextPlaybackDeadline = nil }
  }
  private func playbackDidLoad(identity: AuthSnapshot? = nil) {
    if PerformanceOptions.anonymousRequested { return }
    let identity = identity ?? reportIdentity
    let target = pgcPlayback?.player ?? player
    if let episode = pgcPlayback?.episode, let aid = episode.aid, let cid = episode.cid {
      progressReporter.begin(.init(aid: aid, cid: cid, episode: episode.id, season: episode.seasonID), player: target, identity: identity)
    } else if pgcPlayback == nil, let aid = selected?.aid, let cid = selected?.cid {
      progressReporter.begin(.init(aid: aid, cid: cid), player: target, identity: identity)
    }
    let title = pgcPlayback?.episode?.title ?? selected?.title ?? ""
    let author = pgcPlayback?.details?.season.title ?? selected?.author ?? ""
    if !usesUIFixtures {
      if let episode = pgcPlayback?.episode, let web = URL(string: "https://www.bilibili.com/bangumi/play/ep\(episode.id)") {
        watchActivity.begin(.init(link: "manping://episode/\(episode.id)", web: web, title: title, author: author))
      } else if pgcPlayback == nil, let video = selected {
        let id = video.bvid.hasPrefix("BV") ? video.bvid : video.aid.map { "av\($0)" } ?? ""
        if !id.isEmpty, let web = URL(string: "https://www.bilibili.com/video/\(id)") {
          watchActivity.begin(.init(link: "manping://video/\(id)", web: web, title: title, author: author))
        }
      }
      var previous: (@MainActor @Sendable () -> Void)?
      var next: (@MainActor @Sendable () -> Void)?
      if canPlayPrevious { previous = { [weak self] in self?.playPrevious() } }
      if canPlayNext { next = { [weak self] in self?.playNext() } }
      systemMedia.attach(player: target, title: title, artist: author,
        previous: previous, next: next)
      artworkTask?.cancel()
      if let cover = pgcPlayback?.episode?.cover ?? selected?.cover {
        artworkTask = Task { @MainActor [weak self, weak target] in
          guard let image = try? await ImageCache.shared.imageForReader(for: cover), !Task.isCancelled,
            let self, let target, (self.pgcPlayback?.player ?? self.player) === target else { return }
          self.systemMedia.updateArtwork(NSImage(cgImage: image, size: .zero))
        }
      }
    }
    // A new engine starts without shaders: put the checked 画面增强 modes back on it.
    applyShaders(reportingDropped: false)
    // The open's own choice (or the default) applies once; later loads keep the picture where it is.
    if let mode = pendingOpenMode {
      pendingOpenMode = nil
      applyOpenMode(mode)
    } else if playbackDetached {
      refreshPlaybackWindowContent()
    }
    updateMiniPlayerAspect()
  }
  /// Where an open shows its picture and, in the standalone window, how that window looks.
  /// An explicit choice (a card's 在独立窗口播放, the window toggle) is a plain window; only
  /// 设置 › 打开视频时 set to 独立窗口 carries its saved 全屏 / 小窗 look into it.
  private struct OpenPlacement {
    let mode: MacOpenMode
    /// `displayMode` value for the standalone window (default, fullscreen or compact); nil
    /// keeps an already shown window as it is (a fresh one is plain).
    var windowDisplay: String? = "default"
  }
  /// 设置 › 打开视频时, resolved for this open.
  private var defaultOpenPlacement: OpenPlacement {
    let mode = MacOpenMode(appSettings)
    return OpenPlacement(mode: mode, windowDisplay: mode == .detached ? appSettings.text(.displayMode) : "default")
  }
  /// Where the next load of a newly opened video or episode shows its picture; nil after it
  /// was applied (automatic loads such as the next part keep the current place).
  private var pendingOpenMode: OpenPlacement?
  /// The user moved the picture (standalone window, mini window, back to the main window, full
  /// screen) while an open was still loading: their choice stands, so that load leaves the
  /// windows as they are instead of applying the open's earlier placement.
  func userPlacedPicture() { pendingOpenMode = nil }
  private func applyOpenMode(_ placement: OpenPlacement) {
    switch placement.mode {
    case .detached:
      if playbackDetached { refreshPlaybackWindowContent(displayMode: placement.windowDisplay) }
      else { presentPlaybackWindow(displayMode: placement.windowDisplay ?? "default") }
    case .compact:
      if !compactPlayer { presentMiniPlayer() }
    case .fullScreen:
      // The mini window never goes full screen; the standalone window does.
      if compactPlayer { return }
      if let window = player.surface?.window ?? NSApp.mainWindow, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    case .mainWindow:
      if playbackDetached { refreshPlaybackWindowContent() }
    }
  }
  func togglePlaybackWindow() {
    guard hasPlayback else { return }
    userPlacedPicture()
    if playbackDetached {
      #if DEBUG
      if debugSuppressPlaybackWindows { returnFromPlaybackWindow(); return }
      #endif
      playbackWindow.close(showMain: true)
    } else { presentPlaybackWindow() }
  }
  /// Moves the picture into the standalone window, shown as `displayMode` (a plain window
  /// unless 设置 › 打开视频时 asked for 全屏 / 小窗 there).
  private func presentPlaybackWindow(displayMode: String = "default") {
    guard hasPlayback else { return }
    finishBrowsingForPlacement()
    closeMiniPlayer(activateMain: false)
    playbackDetached = true
    // Remove the primary SwiftUI surface before creating its single new owner.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.playbackDetached, self.hasPlayback else { return }
      #if DEBUG
      if self.debugSuppressPlaybackWindows { return }
      #endif
      self.refreshPlaybackWindowContent(displayMode: displayMode)
    }
  }
  private func returnFromPlaybackWindow() {
    userPlacedPicture()
    playbackDetached = false
    restorePlaybackPage()
  }
  /// Puts the playing page into the standalone window. With `displayMode` (an open) the window
  /// takes that look; without it (next part, playlist, reload) it stays as it is.
  private func refreshPlaybackWindowContent(displayMode: String? = nil) {
    #if DEBUG
    if debugSuppressPlaybackWindows { return }
    #endif
    let host = NSHostingView(rootView: DetachedPlaybackContent(model: self))
    playbackWindow.onUserPlaced = { [weak self] in self?.userPlacedPicture() }
    playbackWindow.onFullScreen = { [weak self] in self?.setWindowFullScreen($0, detached: true) }
    playbackWindow.present(content: host, mainWindow: (NSApp.delegate as? AppDelegate)?.window,
      hideMain: appSettings.bool(.hideMainOnPlay), displayMode: displayMode) { [weak self] in
        // Closing the standalone window (its close button included) puts the picture back in
        // the main window; a load still pending must not move it again.
        self?.returnFromPlaybackWindow()
      }
  }
  /// 小窗 on or off (⇧⌘P). Opening it leaves full screen and the standalone window first; the
  /// main window keeps its size and shows a placeholder. Closing returns the picture to the
  /// main window and brings that window forward.
  func toggleCompactPlayer() {
    guard hasPlayback else { return }
    userPlacedPicture()
    if compactPlayer { closeMiniPlayer(activateMain: true) } else { presentMiniPlayer() }
  }
  private var mainWindow: NSWindow? { (NSApp.delegate as? AppDelegate)?.window }
  private func presentMiniPlayer() {
    guard hasPlayback, !compactPlayer else { return }
    finishBrowsingForPlacement()
    if playbackDetached { playbackWindow.close(showMain: false) }
    if let window = mainWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    compactPlayer = true
    // The root swaps the page for its placeholder first, removing the current surface; the
    // panel then becomes the one owner of the picture.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.compactPlayer, self.hasPlayback else { return }
      #if DEBUG
      if self.debugSuppressPlaybackWindows { return }
      #endif
      let host = NSHostingView(rootView: MiniPlayerContent(model: self))
      self.miniPlayer.present(content: host, aspect: self.playbackAspect) { [weak self] key in self?.miniPlayerKey(key) }
    }
  }
  /// Closes the mini window. Its surface goes first, so the page that takes the picture back
  /// creates the only one.
  func closeMiniPlayer(activateMain: Bool) {
    guard compactPlayer else { return }
    miniPlayer.close()
    compactPlayer = false
    restorePlaybackPage()
    if activateMain, let window = mainWindow {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    }
  }
  /// Width ÷ height of the playing stream; live rooms and unknown sizes use 16:9.
  private var playbackAspect: CGFloat {
    guard livePlayback == nil, let stream = pgcPlayback?.selectedStream ?? selectedStream else {
      return CGFloat(MiniWindowSizing.fallbackAspect)
    }
    return CGFloat(MiniWindowSizing.aspect(width: stream.width, height: stream.height))
  }
  /// The mini window follows the video's size once it is known, and the next item's when
  /// playback moves on.
  private func updateMiniPlayerAspect() {
    guard compactPlayer else { return }
    miniPlayer.update(aspect: playbackAspect)
  }
  /// Space and ←/→ in the mini window while the menu bar is not handling them.
  private func miniPlayerKey(_ key: MiniPlayerCoordinator.Key) {
    switch key {
    case .togglePause: player.togglePause()
    case .back:
      guard livePlayback == nil else { return }
      player.seek(max(0, player.time - appSettings.number(.stepBackward)))
    case .forward:
      guard livePlayback == nil else { return }
      player.seek(min(player.duration, player.time + appSettings.number(.stepForward)))
    }
  }
  /// The main window is in full screen, or entering it (set before the transition moves the
  /// frame, so the layout switches first).
  @Published private(set) var mainWindowFullScreen = false
  /// The same for the standalone playback window.
  @Published private(set) var playbackWindowFullScreen = false
  /// The main window's playback page fills the screen: picture, danmaku and controls only,
  /// without the sidebar, the toolbar and the right column.
  var immersiveMainPlayback: Bool { mainWindowFullScreen && showsPlayerInMainWindow }
  /// The main window shows the playing page itself (not the placeholder of the mini window or
  /// the standalone window).
  var showsPlayerInMainWindow: Bool { mainShowsPlayer && !playbackElsewhere }
  /// Called by the windows' full-screen transitions. The layout changes without animation: the
  /// transition itself moves the window.
  func setWindowFullScreen(_ value: Bool, detached: Bool) {
    guard (detached ? playbackWindowFullScreen : mainWindowFullScreen) != value else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      if detached { playbackWindowFullScreen = value } else {
        _ = pausedBrowsing.presentationChanged(.nativeFullScreen, binding: browsingBinding)
        mainWindowFullScreen = value
      }
    }
  }
  /// Full screen for the window showing the picture. From the mini window the picture first
  /// returns to the main window, which then enters full screen.
  func togglePlayerFullScreen() {
    guard hasPlayback else { return }
    userPlacedPicture()
    if pausedBrowsing.isBrowsing {
      let resume = pausedBrowsing.presentationChanged(.playbackFullScreen, binding: browsingBinding) ?? false
      browsingBesidePlayback = false
      if let index = overlays.lastIndex(where: Self.isPlayerRoute) { overlays = Array(overlays.prefix(index + 1)) }
      player.finishBrowsing(resume: resume)
      retryDeferredVideo(resume: resume)
    }
    if compactPlayer {
      closeMiniPlayer(activateMain: true)
      // Let SwiftUI put the page back before the native transition.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.hasPlayback, !self.compactPlayer, let window = self.mainWindow,
          !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
      }
      return
    }
    guard let window = player.surface?.window ?? NSApp.mainWindow else { return }
    window.toggleFullScreen(nil)
  }
  /// `persist: false` is used by automatic downgrades so they do not overwrite the user's choice.
  func changeQuality(_ stream: MediaStream, persist: Bool = true, recovering: Bool = false) {
    guard let manifest,
      let audio = manifest.audio.max(by: { $0.quality < $1.quality }) else { return }
    selectedStream = stream
    if persist {
      playbackPreferences.lastQuality = stream.quality
      let codec: PlaybackCodec = stream.codec.hasPrefix("av01") ? .av1 :
        (stream.codec.hasPrefix("hev") || stream.codec.hasPrefix("hvc") ? .hevc : .h264)
      // The codec is a catalog setting: change it through the settings model, so the settings
      // window, `appSettings` and the stored value agree (and a later edit cannot revert it).
      settingsModel.set(.codec, .text(codec.rawValue))
    }
    if usesUIFixtures {
      #if DEBUG
      guard debugAllowFixtureQualityChanges else { return }
      #else
      return
      #endif
    }
    let target = player
    let generation = clipGeneration
    let request = Task { [weak self] in
      guard let self else { return }
      guard let prepared = await self.cdn.prepare(video: stream, audio: audio,
        avoidP2P: self.playbackPreferences.avoidP2P, allowProbe: false, preserveRecovery: recovering),
        self.player === target, self.clipGeneration == generation, self.selectedStream?.id == stream.id else { return }
      #if DEBUG
      if let debugAfterQualityPrepare { await debugAfterQualityPrepare() }
      #endif
      guard self.player === target, self.clipGeneration == generation, self.selectedStream?.id == stream.id else { return }
      target.load(video: prepared.video, audio: prepared.audio, start: target.time, paused: target.paused)
      await self.attachCDN(to: target, ticket: prepared.ticket)
    }
    #if DEBUG
    debugQualityRequest = request
    #endif
  }
  /// One step down, keeping the codec family when possible.
  private func downgradeQuality() -> Bool {
    guard let manifest, let current = selectedStream else { return false }
    let lower = manifest.video.filter { $0.quality < current.quality }.sorted { $0.quality > $1.quality }
    let family = current.codec.prefix(3)
    guard let next = lower.first(where: { $0.codec.hasPrefix(family) }) ?? lower.first else { return false }
    changeQuality(next, persist: false, recovering: true)
    return true
  }
  /// Gives the CDN layer the hooks it needs to rebuild URLs or step quality down.
  func attachCDN(to target: PlayerModel, ticket: Int) async {
    let generation = clipGeneration
    let video = selected
    let stream = selectedStream
    let identity = await service.authSnapshot()
    guard player === target, clipGeneration == generation else { return }
    let refresh: (() async throws -> (MediaStream, MediaStream?))? = usesUIFixtures ? nil : { [weak self, weak target] in
      guard let self, let target, self.player === target, let video else { throw CancellationError() }
      try await self.checkCurrentLoad(generation, expected: identity)
      let streams = try await self.service.playback(video, expectedIdentity: identity)
      try await self.checkCurrentLoad(generation, expected: identity)
      guard self.player === target else { throw CancellationError() }
      let choice = try PlaybackSelector.select(streams, preferences: self.playbackPreferences,
        supportsHardware: Self.supportsHardware)
      let selected = streams.video.first { $0.quality == stream?.quality && $0.codec == stream?.codec } ?? choice.video
      self.manifest = streams; self.selectedStream = selected
      return (selected, choice.audio)
    }
    cdn.attach(player: target, ticket: ticket, reload: { [weak target] video, audio in
      guard let target else { return }
      target.load(video: video, audio: audio, start: target.time, paused: target.paused)
    }, downgrade: { [weak self] in self?.downgradeQuality() ?? false }, refresh: refresh)
  }
  /// Applies the checked 画面增强 modes to the playing engine, so the menu's checkmarks always
  /// match what is drawn. A choice this engine cannot run (or that no longer exists) is
  /// unchecked instead of staying checked without effect.
  func applyShaders(reportingDropped: Bool = true) {
    let runnable = shaderSelections.filter { family, name in
      ShaderCatalog.presets.contains { $0.family == family && $0.name == name && !$0.unavailable }
    }
    if runnable != shaderSelections {
      shaderSelections = runnable
      if reportingDropped { error = "此画面增强模式需要带有坐标去重修复的 libmpv。" }
    }
    // A fresh engine has no shaders; nothing to send when none are chosen.
    guard !runnable.isEmpty || reportingDropped else { return }
    let target = pgcPlayback?.player ?? player
    // Shaders run on the high-quality scalers they always had, also when power saving chose fast.
    if !runnable.isEmpty { target.prepareForShaders() }
    target.set("glsl-shaders", ShaderCatalog.paths(runnable).joined(separator: ":"))
  }
  func enqueueDownload() { if selected != nil || pgcPlayback?.episode != nil { showingDownloadOptions = true } }
  func copyDownloadCommand(options: DownloadOptions) {
    let source = options.episodeID.map { "ep\($0)" } ?? selected.map { $0.bvid.isEmpty ? "av\($0.aid ?? 0)" : $0.bvid }
    guard let source else { return }
    do {
      let settings = MacSettings.load(from: PerformanceEnvironment.defaults)
      let executable = settings.text(.bbdownPath).isEmpty ? "BBDown" : settings.text(.bbdownPath)
      let formats = pgcPlayback?.manifest?.formats ?? manifest?.formats ?? []
      let description = formats.first { $0.quality == options.quality }?.description
      if options.content == .video, description == nil { throw BiliError.invalidResponse("没有所选画质的 BBDown 格式描述，请刷新播放信息。") }
      let command = try BBDownCommand.build(source: source, options: options, executable: executable, ffmpeg: Self.ffmpeg.path, qualityDescription: description)
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
    } catch { self.error = error.localizedDescription }
  }
  func startDownload(options: DownloadOptions) {
    if appSettings.bool(.copyDownloadCommand) || appSettings.bool(.externalBBDown) { copyDownloadCommand(options: options); showingDownloadOptions = false; return }
    guard !usesUIFixtures else { error = "本地样本不下载媒体；可以拷贝不含登录信息的命令。"; return }
    var choices: [(String, String, DownloadOptions)] = []
    if let playback = pgcPlayback, let current = playback.episode {
      let all = playback.details?.episodes ?? [current]
      let indices = options.allPages ? Array(all.indices) : options.pages.isEmpty ? all.indices.filter { all[$0].id == current.id } : options.pages.map { $0 - 1 }
      for index in indices where all.indices.contains(index) {
        var choice = options; choice.episodeID = all[index].id; choice.cid = all[index].cid; choice.pages = [index + 1]; choice.allPages = false
        choices.append(("ep\(all[index].id)", all[index].title, choice))
      }
    } else if let video = selected {
      let parts = videoDetails?.parts ?? []
      let chosen = options.allPages ? parts : options.pages.isEmpty ? parts.filter { $0.cid == video.cid } : parts.filter { options.pages.contains($0.page) }
      let source = video.bvid.isEmpty ? "av\(video.aid ?? 0)" : video.bvid
      if chosen.isEmpty && options.pages.isEmpty && !options.allPages {
        var choice = options; choice.cid = video.cid; choices.append((source, video.title, choice))
      } else {
        for part in chosen { var choice = options; choice.cid = part.cid; choice.pages = [part.page]; choice.allPages = false
          choices.append((source, "\(video.title) · \(part.title)", choice)) }
      }
    }
    guard let store, !choices.isEmpty else { error = "没有可下载的分集。"; return }
    let launch: (URL) -> Void = { [weak self] directory in
      guard let self else { return }
      for (source, title, var choice) in choices {
        choice.directory = directory.path
        let record = DownloadRecord(bvid: source, title: title, options: choice)
        do { try store.save(record); self.runDownload(record) } catch { self.error = error.localizedDescription }
      }
      self.downloads = (try? store.records()) ?? self.downloads
      self.showingDownloadOptions = false
    }
    if !options.directory.isEmpty { launch(URL(fileURLWithPath: options.directory)) }
    else {
      let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
      panel.prompt = "保存到此文件夹"
      panel.begin { response in MainActor.assumeIsolated { if response == .OK, let directory = panel.url { launch(directory) } } }
    }
  }
  func retryDownload(_ record: DownloadRecord) {
    guard !usesUIFixtures, downloadTasks[record.id] == nil, record.state != "complete" else { return }
    guard record.options != nil else { error = "旧任务缺少分集与画质信息，请从播放页重新建立任务。"; return }
    runDownload(record)
  }
  private func checkDownloadIdentity(_ snapshot: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    try Task.checkCancellation()
    guard current.epoch == snapshot.epoch, current.identityRevision == snapshot.identityRevision else { throw CancellationError() }
  }
  private func runDownload(_ record: DownloadRecord) {
    guard let options = record.options, let store, downloadTasks[record.id] == nil else { return }
    downloadTasks[record.id] = Task {
      var current = record
      let temporary = Self.support.appendingPathComponent("Transfers").appendingPathComponent(record.id)
      let checkpoint = Self.support.appendingPathComponent("Completion").appendingPathComponent(record.id + ".json")
      defer { downloadTasks[record.id] = nil; downloadIdentities[record.id] = nil }
      do {
        if let recovered = try await DownloadCompletion.recover(checkpoint: checkpoint) {
          current.state = "complete"; current.progress = 1; current.output = recovered.path
          current.error = "已从完成记录恢复媒体；如需要附加弹幕，请单独导出。"
          try update(current); return
        }
        let snapshot = await service.authSnapshot()
        downloadIdentities[record.id] = snapshot
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        do { try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw DownloadFailure.disk(operation: "创建完成记录目录", code: (error as NSError).code) }
        current.state = "downloading"; current.error = ""; try update(current)
        let video: Video
        let manifest: PlaybackManifest?
        if let episodeID = options.episodeID {
          let details = try await service.pgcDetails(PGCSelection(episodeID: episodeID), expectedIdentity: snapshot)
          guard let episode = details.episodes.first(where: { $0.id == episodeID }), episode.cid == options.cid else { throw BiliError.invalidResponse("剧集信息已改变，请重新创建任务。") }
          video = Video(bvid: episode.bvid, title: episode.title, cover: episode.cover, cid: episode.cid, aid: episode.aid)
          manifest = [.video, .audio].contains(options.content) ? try await service.pgcPlayback(episode, quality: options.quality, expectedIdentity: snapshot) : nil
        } else {
          let detail = try await service.detail(record.bvid, expectedIdentity: snapshot)
          video = Video(bvid: detail.bvid, title: detail.title, cover: detail.cover, cid: options.cid ?? detail.cid, aid: detail.aid)
          manifest = [.video, .audio].contains(options.content) ? try await service.playback(video, quality: options.quality, expectedIdentity: snapshot) : nil
        }
        try await checkDownloadIdentity(snapshot)
        let directory = URL(fileURLWithPath: options.directory).resolvingSymlinksInPath()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw DownloadFailure.disk(operation: "创建下载目录", code: (error as NSError).code) }
        let stem = record.bvid + "-" + String(options.cid ?? 0)
        var output = directory.appendingPathComponent(stem + ".mp4")
        switch options.content {
        case .video:
          guard let manifest else { throw BiliError.invalidResponse("没有播放地址") }
          let codec: PlaybackCodec = options.codec == .avc ? .h264 : options.codec == .hevc ? .hevc : .av1
          let preferences = PlaybackPreferences(codec: codec, quality: options.quality)
          let choice = try PlaybackSelector.select(manifest, preferences: preferences, supportsHardware: { _ in true })
          let audio = choice.audioURL
          let vFile = try await DownloadWorker.resumeTransfer(request: service.request(choice.videoURL), to: temporary.appendingPathComponent("video.m4s"), identity: "aid:\(video.aid ?? 0):cid:\(video.cid ?? 0):video:\(choice.video.quality):codec:\(choice.video.codecID):bw:\(choice.video.bandwidth)") { [weak self] progress in Task { @MainActor in self?.updateProgress(record.id, progress * 0.8) } }
          try await checkDownloadIdentity(snapshot)
          let aFile = try await DownloadWorker.resumeTransfer(request: service.request(audio), to: temporary.appendingPathComponent("audio.m4s"), identity: "aid:\(video.aid ?? 0):cid:\(video.cid ?? 0):audio:\(choice.audio.quality):codec:\(choice.audio.codecID):bw:\(choice.audio.bandwidth)") { [weak self] progress in Task { @MainActor in self?.updateProgress(record.id, 0.8 + progress * 0.15) } }
          try await checkDownloadIdentity(snapshot); current.state = "merging"; current.progress = 0.95; try update(current)
          let staged = temporary.appendingPathComponent("output.mp4")
          if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
          try await DownloadWorker.merge(video: vFile, audio: aFile, output: staged, ffmpeg: Self.ffmpeg)
          try await checkDownloadIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: staged, to: output, checkpoint: checkpoint)
        case .audio:
          guard let audio = manifest?.audio.first else { throw BiliError.invalidResponse("没有可下载的音频。") }
          let file = try await DownloadWorker.resumeTransfer(request: service.request(audio.url), to: temporary.appendingPathComponent("audio.m4a"), identity: "aid:\(video.aid ?? 0):cid:\(video.cid ?? 0):audio:\(audio.quality):codec:\(audio.codecID):bw:\(audio.bandwidth)") { [weak self] progress in Task { @MainActor in self?.updateProgress(record.id, progress) } }
          output = directory.appendingPathComponent(stem + ".m4a")
          try await checkDownloadIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: file, to: output, checkpoint: checkpoint)
        case .cover:
          guard let cover = video.cover else { throw BiliError.invalidResponse("没有可下载的封面。") }
          let file = try await DownloadWorker.resumeTransfer(request: service.request(ImageCache.secured(cover)), to: temporary.appendingPathComponent("cover"))
          output = directory.appendingPathComponent(stem + "." + (["png", "jpeg", "jpg", "webp", "avif"].contains(cover.pathExtension.lowercased()) ? cover.pathExtension.lowercased() : "jpg"))
          try await checkDownloadIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: file, to: output, checkpoint: checkpoint)
        case .danmaku:
          guard let cid = video.cid else { throw BiliError.invalidResponse("没有弹幕标识") }
          let xml = try await service.exportDanmakuXML(cid: cid, expectedIdentity: snapshot)
          output = directory.appendingPathComponent(stem + ".xml")
          let staged = temporary.appendingPathComponent("danmaku.xml")
          try xml.write(to: staged, options: .atomic)
          try await checkDownloadIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: staged, to: output, checkpoint: checkpoint)
        case .subtitle:
          guard let aid = video.aid, let cid = video.cid else { throw BiliError.invalidResponse("没有字幕媒体标识") }
          let tracks = DownloadSubtitleTrack.filtered(try await service.downloadSubtitleTracks(aid: aid, cid: cid, expectedIdentity: snapshot), filterAI: options.filterAISubtitle)
          guard let track = tracks.first(where: { $0.id == options.subtitleID }) ?? tracks.first(where: { $0.language == options.subtitleLanguage }) else {
            throw BiliError.invalidResponse("所选字幕已不可用，请重新选择字幕。")
          }
          let cues = try await service.downloadSubtitleCues(track: track, expectedIdentity: snapshot)
          let language = track.language.range(of: "^[A-Za-z0-9-]{1,32}$", options: .regularExpression) != nil ? track.language : "subtitle"
          output = directory.appendingPathComponent(stem + "-" + language + ".srt")
          let staged = temporary.appendingPathComponent("subtitle.srt")
          try DownloadExport.subtitleSRT(cues).write(to: staged, options: .atomic)
          try await checkDownloadIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: staged, to: output, checkpoint: checkpoint)
        }
        current.output = output.path
        if options.content == .video, options.includeDanmaku, let cid = video.cid {
          let xml = try await service.exportDanmakuXML(cid: cid, expectedIdentity: snapshot)
          try await checkDownloadIdentity(snapshot)
          try DownloadExport.write(xml, to: directory.appendingPathComponent(stem + ".xml"))
        }
        current.state = "complete"; current.progress = 1; current.output = output.path; try update(current)
        try? FileManager.default.removeItem(at: temporary)
        if MacSettings.load(from: PerformanceEnvironment.defaults).bool(.openDownloadFolder) { NSWorkspace.shared.activateFileViewerSelecting([output]) }
      } catch {
        current.state = !current.output.isEmpty ? "complete" : Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
        if !current.output.isEmpty { current.progress = 1 }
        current.error = !current.output.isEmpty ? "媒体已保存；附加导出或任务记录失败：" + error.localizedDescription : error.localizedDescription
        do { try update(current) } catch {
          if let index = downloads.firstIndex(where: { $0.id == current.id }) { downloads[index] = current }
          self.error = "任务记录写入失败；恢复下载时会校验持久完成记录。"
        }
      }
    }
  }
  private func update(_ record: DownloadRecord) throws {
    try store?.save(record)
    downloads = try store?.records() ?? []
  }
  /// Progress callbacks arrive per network packet; publish at most every half percent so a
  /// running download does not re-render the whole app (and close menus) hundreds of times a second.
  private func updateProgress(_ id: String, _ progress: Double) {
    if let index = downloads.firstIndex(where: { $0.id == id && $0.state == "downloading" }),
      progress - downloads[index].progress >= 0.005 || progress >= 1 {
      downloads[index].progress = progress
    }
  }
  func cancelDownload(_ id: String) { downloadTasks[id]?.cancel() }
  /// `dismissLogin: false` refreshes the account shown without closing an open login sheet.
  func loginCompleted(token: UInt64? = nil, dismissLogin: Bool = true) async {
    let generation = authCallbacks.generation
    let initial = await service.authSnapshot()
    guard authCallbacks.accepts(generation), token == nil || token == initial.epoch,
      initial.state != .needsLogin
    else { return }
    accountDisplayIdentity = (epoch: initial.epoch, revision: initial.identityRevision)
    account = "已登录"; accountMID = initial.token?.mid; accountAvatar = nil; accountLevel = nil
    do {
      let mid = initial.token?.mid
      let profile: LibraryUser?
      let name: String
      if let mid {
        let fetched = try await service.libraryProfile(mid: mid)
        profile = fetched; name = fetched.name
      } else {
        profile = nil; name = try await service.accountName()
      }
      // Web-only sign-in has no app token mid; the shield list still belongs to the Web
      // account. Read it before the final identity check so nothing awaits after it.
      let webMid = mid == nil ? await service.cookieValue("DedeUserID").flatMap(Int64.init) : nil
      let current = await service.authSnapshot()
      guard authCallbacks.accepts(generation), current.epoch == initial.epoch,
        current.identityRevision == initial.identityRevision,
        current.state != .needsLogin, !Task.isCancelled
      else { return }
      account = current.state == .appAuthorized ? name : "\(name)（仅网页登录）"
      accountMID = mid
      if mid == nil, let webMid, webMid > 0 { DanmakuShieldSync.shared.configure(service: service, mid: webMid) }
      accountAvatar = profile?.avatar; accountLevel = profile?.level
      if dismissLogin { showingLogin = false }
      configureNotifications()
    } catch is CancellationError {} catch {
      if authCallbacks.accepts(generation) { self.error = "无法获取登录账号，请重试" }
    }
  }
  func logout() {
    for task in downloadTasks.values { task.cancel() }
    authCallbacks.invalidate()
    accountTask?.cancel()
    showingLogin = false
    account = "登录"
    accountAvatar = nil; accountLevel = nil
    accountMID = nil
    DanmakuShieldSync.shared.configure(service: service, mid: nil)
    notifications.stop()
    watchActivity.clearSpotlight()
    unreadMessageCount = 0
    accountTask = Task {
      do { try await service.logout() } catch { self.error = "登录已在内存中清除；本机保存的登录信息未能删除，请检查「应用程序支持」目录权限" }
    }
  }
  func shutdown() {
    browsingBesidePlayback = false
    clipPlayback.stop(.stopped); aiRuntime?.shutdown()
    progressReporter.flush()
    cancelNextPlayback(); notifications.stop(); scrollAcceleration.stop()
    playbackFeatures.shutdown()
    artworkTask?.cancel(); systemMedia.clear(); watchActivity.end(); playbackWindow.close(showMain: false)
    miniPlayer.close()
    pgcPlayback?.shutdown(); pgcPlayback = nil
    livePlayback?.shutdown(); livePlayback = nil; liveMediaSubscription = nil
    cancelCuratedPlaylist(); clearPlaybackQueue()
    queueIdentityTask?.cancel(); queueIdentityTask = nil
    authCallbacks.invalidate()
    accountTask?.cancel()
    loadTask?.cancel()
    for task in downloadTasks.values { task.cancel() }
    cdn.detach()
    player.shutdown()
    MpvEnginePool.shared.drain()
  }
}
