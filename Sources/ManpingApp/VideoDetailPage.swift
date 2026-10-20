import AppKit
import ManpingCore
import SwiftUI

struct VideoDetailPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject var player: PlayerModel
  let video: Video
  @StateObject private var interactions: VideoInteractionModel
  @StateObject private var comments: M4CommentModel
  @StateObject private var features: PlaybackFeaturesModel
  @StateObject private var chrome = PlayerChromeState()
  @State private var danmakuSettingsShown = DanmakuSettingsPopover.debugOpen
  @State private var networkShown = CDNPanel.debugOpen
  @State private var scrubbing = false
  @State private var stageWidth: CGFloat = 900
  @AppStorage(PlayerPreferences.sidebarHiddenKey) private var sidebarHidden = false
  /// Full screen: the picture fills the window; the right column's own setting is kept.
  @Environment(\.immersivePlayback) private var immersive
  @Environment(\.colorScheme) private var scheme
  @State private var section: Section = .info
  @State private var userPickedSection = false
  @State private var showingCoin = false
  @State private var coinCount = 1
  @State private var coinAlsoLike = true
  @State private var showingFavorites = false
  @State private var showingTriple = false
  @State private var detailLoadError: String?
  @State private var onlyPartNumbers = false
  @State private var fixturePaused = false
  @State private var fixtureTime = 0.0
  @State private var showingVolume = false
  @State private var composeShown = false
  @State private var chaptersShown = false
  @State private var videoShot: VideoShot?

  init(model: AppModel, player: PlayerModel, video: Video) {
    self.model = model
    self.player = player
    self.video = video
    if model.usesUIFixtures {
      _interactions = StateObject(wrappedValue: VideoInteractionModel(service: model.service,
        stateLoader: { _, _ in VideoOperationState(liked: true, following: true, favorited: true) }))
    } else {
      _interactions = StateObject(wrappedValue: VideoInteractionModel(service: model.service))
    }

    _comments = StateObject(wrappedValue: M4CommentModel(model: model))
    _features = StateObject(wrappedValue: model.playbackFeatures)
  }

  private enum Section: String, CaseIterable {
    case queue = "播放列表"
    case collections = "合集"
    case info = "简介"
    case parts = "分集"
    case related = "相关"
    case comments = "评论"
    case ai = "AI"

    init?(launchTab: String) {
      switch launchTab {
      case "queue": self = .queue
      case "collections": self = .collections
      case "info": self = .info
      case "parts": self = .parts
      case "related": self = .related
      case "comments": self = .comments
      case "ai": self = .ai
      default: return nil
      }
    }
  }

  private var details: VideoDetails? {
    guard let details = model.videoDetails, details.matches(video) else { return nil }
    return details
  }

  private var defaultSection: Section {
    model.playbackQueue.count > 0 ? .queue : (model.usesEpisodicFixture ? .parts : .info)
  }

  var body: some View {
    PlayerPageLayout(showsPanel: !sidebarHidden, immersive: immersive) {
      playerPanel
    } panel: {
      sidePanel
    }
    // The one toolbar above the page (the main window's, or the standalone window's).
    .pageToolbar(title: pageTitle) {
      ToolbarIconGroup {
        if let shareURL { ToolbarShareButton(url: shareURL) }
        PlayerToolbarActions(model: model, sidebarHidden: $sidebarHidden)
      }
    }
    // Keyed by bvid: `Video.id` switches from BV to av when details arrive, which used to
    // re-run this and throw the user back to the default tab.
    .task(id: video.bvid.isEmpty ? video.id : video.bvid) {
      detailLoadError = nil
      userPickedSection = false
      section = model.launchVideoTab.flatMap(Section.init(launchTab:)) ??
        defaultSection
      fixtureTime = model.usesEpisodicFixture ? 152 : 0
      interactions.reset(aid: details?.video.aid)
    }
    .onChange(of: details?.video.aid) { _, aid in interactions.reset(aid: aid) }
    .onChange(of: model.refreshToken) { _, _ in detailLoadError = nil }
    .onChange(of: model.playbackQueue.count) { _, count in
      if count == 0 && section == .queue { section = .info }
    }
    .onChange(of: details?.collections.map(\.id)) { _, _ in
      if model.launchVideoTab == nil, !userPickedSection { section = defaultSection }
    }
    .onChange(of: model.error) { _, error in
      if details == nil, let error { detailLoadError = error }
    }
    .onChange(of: interactions.identityGeneration) { _, _ in
      showingFavorites = false; showingCoin = false; showingTriple = false
    }
    .onChange(of: model.selected?.cid) { _, _ in fixtureTime = 0 }
    .task(id: model.selected?.cid) {
      videoShot = nil
      guard !model.usesUIFixtures, let selected = model.selected, let cid = selected.cid else { return }
      videoShot = try? await model.service.videoShot(bvid: selected.bvid, aid: selected.aid, cid: cid)
    }
    .onDisappear { comments.cancel(); interactions.shutdown(); restoreTemporarySpeed() }
    #if DEBUG
    .task {
      // Screenshot checks of the mini window (`MANPING_UI_MINI_PLAYER`), once per launch.
      guard model.usesUIFixtures, MiniPlayerCoordinator.debugLaunch, !MiniPlayerCoordinator.debugLaunched else { return }
      MiniPlayerCoordinator.debugLaunched = true
      try? await Task.sleep(for: .seconds(1.5))
      model.toggleCompactPlayer()
    }
    .task {
      // Screenshot checks of the stage (`--ui-player-placement detached|fullscreen`), once per launch.
      guard model.usesUIFixtures, let placement = PlayerStageDebug.takePlacement() else { return }
      try? await Task.sleep(for: .seconds(1.5))
      if placement == "fullscreen" { model.togglePlayerFullScreen() } else { model.togglePlaybackWindow() }
    }
    #endif
    .alert(
      "操作结果",
      isPresented: Binding(
        get: { interactions.message != nil },
        set: { if !$0 { interactions.message = nil } }
      )
    ) {
      Button("确定") { interactions.message = nil }
    } message: {
      Text(interactions.message ?? "")
    }
    .confirmationDialog(
      "三连将点赞、投币并收藏此视频。确认执行吗？", isPresented: $showingTriple,
      titleVisibility: .visible
    ) {
      Button("确认三连") {
        guard let aid = details?.video.aid, aid > 0 else { return }
        Task { await interactions.triple(aid: aid) { model.showingLogin = true } }
      }
    }
    // A login request from inside a sheet would be blocked by that sheet: close it first.
    .onChange(of: model.showingLogin) { _, show in if show { showingCoin = false; showingFavorites = false } }
    .sheet(isPresented: $showingCoin) { coinSheet }
    .sheet(isPresented: $showingFavorites) { favoriteSheet }
  }

  private var shareURL: URL? {
    if let aid = details?.video.aid ?? video.aid { return URL(string: "https://www.bilibili.com/video/av\(aid)") }
    if !video.bvid.isEmpty { return URL(string: "https://www.bilibili.com/video/\(video.bvid)") }
    return nil
  }
  private var currentPart: VideoPart? { details?.parts.first { $0.cid == model.selected?.cid } }
  /// "Video · Part" only for multi-part videos whose part title adds something.
  private var pageTitle: String {
    let title = details?.video.title ?? video.title
    guard let part = currentPart, (details?.parts.count ?? 0) > 1, !part.title.isEmpty, part.title != title else { return title }
    return title + " · " + part.title
  }
  /// Offline samples stand in for playback: the page keeps its own time and pause state. The
  /// README demo (Debug only) plays a local file over them, so the page follows the real player.
  private var fixturePlayback: Bool {
    #if DEBUG
    if DemoConfig.playsLocalMedia { return false }
    #endif
    return model.usesUIFixtures
  }
  private var displayTime: Double { fixturePlayback ? fixtureTime : player.time }
  private var displayDuration: Double {
    fixturePlayback ? Double(currentPart?.duration ?? details?.video.duration ?? 0) : player.duration
  }
  private var displayPaused: Bool { fixturePlayback ? fixturePaused : player.paused }
  private var fixtureMedia: Bool { model.usesUIFixtures && !PerformanceOptions.playsLocalMedia }
  /// Paused, a popover open, typing a comment or scrubbing: the controls stay up.
  private var controlsPinned: Bool {
    fixturePlayback || PlaybackTimeline.debugHover != nil || displayPaused || showingVolume ||
      danmakuSettingsShown || networkShown || composeShown || chaptersShown || scrubbing || !features.input.isEmpty
  }
  private var controlsShown: Bool { chrome.visible || controlsPinned }
  /// The picture's shape, from the stream being played (16:9 until it is known).
  private var pictureAspect: CGFloat? { playerAspect(width: model.selectedStream?.width, height: model.selectedStream?.height) }
  private var stageCover: URL? { details?.video.cover ?? model.selected?.cover }
  private var playerPanel: some View {
    // Controls float over the stage so showing them never resizes the GL layer. They fade
    // instead of being removed, so menus and popovers anchored to them stay open.
    // The surface fills the stage: the video is fitted to the picture inside it, the danmaku and
    // the gestures cover the whole stage.
    PlayerSurface(model: player, pictureAspect: stagePictureAspect(pictureAspect))
      .id(ObjectIdentifier(player))
      // Long-press for temporary speed applies to the stage, never to the controls.
      .onLongPressGesture(minimumDuration: 0.4, pressing: { pressing in
        if !pressing { restoreTemporarySpeed() }
      }) {
        player.beginTemporarySpeed()
      }
      // Live Text over the paused picture, under the status layer and the controls.
      .overlay { LiveTextLayer(controller: player.liveText) }
      // An offline sample's artwork stands in for the picture, under the danmaku.
      .background {
        if fixtureMedia {
          Color.clear.overlay { CachedImage(url: details?.video.cover) }.clipped()
            .playerPictureFrame(aspect: stagePictureAspect(pictureAspect)).allowsHitTesting(false)
        }
      }
      .playerStageBackdrop(cover: stageCover)
      // The cover sits under the status layer: loading, errors and retry stay visible over it.
      .overlay {
        if player.audioOnly { AudioOnlyBackdrop(cover: stageCover, title: details?.video.title ?? model.selected?.title ?? "") }
      }
      .overlay {
        if !fixtureMedia {
          PlayerStatusOverlay(player: player, loading: model.selectedStream == nil && detailLoadError == nil) {
            Task { await model.refresh() }
          }
        }
      }
      .overlay(alignment: .topLeading) {
        if fixtureMedia {
          Text("本地预览 · 未加载媒体").font(Theme.Font.caption2).foregroundStyle(.white.opacity(0.65)).padding(14)
        } else if let detailLoadError {
          HStack(spacing: 8) {
            Text(detailLoadError).font(Theme.Font.caption).foregroundStyle(.white).lineLimit(2)
            Button("重试") { self.detailLoadError = nil; Task { await model.refresh() } }.buttonStyle(AppButtonStyle(role: .primary, size: .small))
          }.padding(.horizontal, 12).padding(.vertical, 8)
            .environment(\.colorScheme, .dark).floatingGlassPanel(readingTint: .black.opacity(0.4)).padding(12)
        }
      }
      .overlay(alignment: .bottom) {
        ZStack(alignment: .bottom) {
          if model.appSettings.bool(.bottomProgress) {
            PlaybackProgressBar(clock: player.clock, duration: displayDuration, override: fixturePlayback ? fixtureTime : nil)
              .opacity(controlsShown ? 0 : 1).animation(.easeOut(duration: 0.2), value: controlsShown)
          }
          playerControls.playerChromeFade(controlsShown)
        }
      }
      .overlay(alignment: .topTrailing) {
        if let deadline = model.nextPlaybackDeadline {
          NextPlaybackOverlay(deadline: deadline, onPlay: model.playNext, onCancel: model.cancelNextPlayback)
        }
      }
      .animation(.snappy(duration: 0.3), value: model.nextPlaybackDeadline == nil)
      .reportsStageWidth($stageWidth)
      .tracksPlayerChrome(chrome, pinned: controlsPinned)
      // Playback shortcuts (menu bar, media keys) bring the controls in.
      .onChange(of: player.speed) { _, _ in chrome.activity() }
      .onChange(of: player.volume) { _, _ in chrome.activity() }
      .onChange(of: player.commentsEnabled) { _, _ in chrome.activity() }
      #if DEBUG
      .modifier(DemoPlayerHooks(chrome: chrome, danmakuShown: $danmakuSettingsShown))
      #endif
      .playerStageShape(immersive: immersive)
  }
  private var playableStreams: [MediaStream] {
    model.manifest?.video.filter { ["http", "https"].contains($0.url.scheme ?? "") && $0.url.host != nil } ?? []
  }
  private var playerControls: some View {
    let layout = PlayerPanelLayout(stageWidth: stageWidth)
    return PlayerControlPanel(chrome: chrome) {
      PlaybackTimeline(clock: player.clock, duration: displayDuration, override: fixturePlayback ? fixtureTime : nil,
        preview: videoShot, density: timelineDensity, chapters: timelineChapters, markers: model.aiMarks(for: model.aiMediaKey),
        bufferedAhead: { [player] in player.bufferedAhead }, scrubbing: { scrubbing = $0 }) { position in
        if fixturePlayback { fixtureTime = position } else { player.seek(position) }
      }
      PlayerBarRow(model: model, player: player, layout: layout, page: barPage, cdn: model.cdn,
        danmakuShown: $danmakuSettingsShown, networkShown: $networkShown, volumeShown: $showingVolume,
        composeShown: $composeShown,
        input: {
          AnyView(PlaybackDanmakuInput(features: features) {
            features.send(seconds: displayTime) { model.showingLogin = true }
          })
        },
        extraMenu: { AnyView(debugMenuItems) }) {
        PlayerPlayButton(paused: displayPaused) {
          if fixturePlayback { fixturePaused.toggle() } else { player.togglePause() }
        }
        if model.playbackQueue.count > 0 {
          Button { model.playPrevious() } label: { Image(systemName: "backward.end.fill") }
            .buttonStyle(PlayerControlButtonStyle(size: 32)).disabled(!model.canPlayPrevious)
            .help("上一个（⇧⌘[）").accessibilityLabel("上一个")
        }
        Button { model.playNext() } label: { Image(systemName: "forward.end.fill") }
          .buttonStyle(PlayerControlButtonStyle(size: 32)).disabled(!model.canPlayNext)
          .help("下一个（⇧⌘]）").accessibilityLabel("下一个")
        if layout.showsTime {
          PlayerTimeLabel(clock: player.clock, duration: displayDuration, override: fixturePlayback ? fixtureTime : nil)
            .padding(.horizontal, 4)
        }
        if layout.showsChapter, !timelineChapters.isEmpty {
          PlayerChapterButton(clock: player.clock, chapters: timelineChapters, override: fixturePlayback ? fixtureTime : nil,
            shown: $chaptersShown) { position in
            if fixturePlayback { fixtureTime = position } else { player.seek(position) }
          }
        }
        DanmakuToggleButton(enabled: $player.commentsEnabled) { danmakuSettingsShown = true }
      }
      if let message = features.message {
        Text(message).font(Theme.Font.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      // What the playing queue has to say (e.g. 全部播放 cut a long list short); it stays
      // with the queue until closed here, replaced with the queue or playback ends.
      if let notice = model.playbackNotice {
        HStack(spacing: 6) {
          Label(notice, systemImage: "info.circle").font(Theme.Font.caption)
            .foregroundStyle(.white.opacity(0.75)).lineLimit(2)
          Spacer(minLength: 6)
          Button { model.dismissPlaybackNotice() } label: { Image(systemName: "xmark") }
            .buttonStyle(PlayerControlButtonStyle(size: 22)).help("关闭").accessibilityLabel("关闭提示")
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  /// 画质 and 字幕 come from this page; the rest of the bar is shared (设置 › 控制条).
  private var barPage: PlayerBarPage {
    PlayerBarPage(slots: [
      .quality: .quality(streams: playableStreams, selected: model.selectedStream) { model.changeQuality($0) },
      .subtitle: .subtitle(features: features, player: player, filterAI: model.appSettings.bool(.filterAISubtitle)),
    ], downloadEnabled: model.manifest != nil)
  }
  @ViewBuilder private var debugMenuItems: some View {
    #if DEBUG
    if model.usesUIFixtures && model.playbackQueue.count > 0 {
      Divider()
      Button("模拟播放结束（本地样本）") { player.simulatePlaybackEnd() }
    }
    #endif
  }
  private var timelineChapters: [PlaybackChapter] {
    #if DEBUG
    // Local samples have no chapters; show the ticks and hover titles for screenshot checks.
    if model.usesUIFixtures && player.chapters.isEmpty && displayDuration > 0 {
      return [(0.0, "开场"), (0.22, "第一部分"), (0.51, "第二部分"), (0.83, "结尾")].enumerated().map { index, item in
        PlaybackChapter(index: index, title: item.1, time: displayDuration * item.0)
      }
    }
    #endif
    return PlaybackChapter.preferred(viewPoints: features.viewPoints, engine: player.chapters)
  }
  private var timelineDensity: [Double] {
    #if DEBUG
    if model.usesUIFixtures && displayDuration > 0 {
      return (0..<64).map { index in
        let x = Double(index) / 63
        return min(1, max(0.04, 0.35 + 0.3 * sin(x * 9) + 0.55 * exp(-pow((x - 0.62) / 0.07, 2))))
      }
    }
    #endif
    return player.timeline.density(duration: displayDuration)
  }
  private func restoreTemporarySpeed() {
    player.endTemporarySpeed()
  }

  @State private var uploaderHovered = Self.previewUploaderHover
  private static var previewUploaderHover: Bool {
    #if DEBUG
    DebugUIFixtures.enabled && ProcessInfo.processInfo.environment["MANPING_UPLOADER_HOVER"] == "1"
    #else
    false
    #endif
  }
  private func detailInformation(_ details: VideoDetails) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Button { model.openSpaceKeepingPlayback(details.uploader.mid) } label: {
          HStack(spacing: 10) {
            CachedImage(url: details.uploader.avatar)
              .frame(width: 38, height: 38).clipShape(Circle())
              .overlay(Circle().strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
              Text(details.uploader.name).font(Theme.Font.headline)
              Text("\(count(details.uploader.followers)) 粉丝")
                .font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
            }
          }
          .padding(5)
          .background(uploaderHovered ? Theme.selectedFill(scheme) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain).disabled(details.uploader.mid <= 0)
        .help("进入 UP 主空间").onHover { uploaderHovered = $0 }
        Spacer()
        Button(interactions.following.map { $0 ? "已关注" : "关注" } ?? "关注状态…") {
          guard let aid = details.video.aid, aid > 0 else { return }
          Task { await interactions.follow(mid: details.uploader.mid, aid: aid) { model.showingLogin = true } }
        }.buttonStyle(AppButtonStyle(role: interactions.following == true ? .secondary : .primary, size: .small))
          .disabled(details.uploader.mid <= 0 || interactions.busy || details.video.aid == nil || interactions.following == nil)
      }
      if interactions.stateLoading {
        ProgressView("正在获取互动状态…").font(Theme.Font.caption)
      } else if let error = interactions.stateError {
        VStack(alignment: .leading, spacing: 8) {
          InlineErrorText(message: error)
          HStack {
            Button("重试") { interactions.refreshState() }
            Button("登录") { model.showingLogin = true }
          }.buttonStyle(AppButtonStyle(size: .small))
        }
      }
      FlowLayout(spacing: 14) {
        stat("播放", details.stats.view, icon: "play.rectangle")
        stat("弹幕", details.stats.danmaku, icon: "text.bubble")
        stat("评论", details.stats.reply, icon: "bubble.left")
        stat("分享", details.stats.share, icon: "square.and.arrow.up")
      }.foregroundStyle(Theme.tertiaryText(scheme))
      if details.tagsAvailable {
        if !details.tags.isEmpty {
          FlowLayout(spacing: 6) {
            ForEach(details.tags, id: \.self) { tag in
              Text(tag).font(Theme.Font.caption).lineLimit(1).padding(.horizontal, 10).frame(height: 24)
                .background(Theme.fill(scheme), in: Capsule())
            }
          }
        }
      } else {
        Text("标签暂不可用").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      }
      if let description = details.video.description, !description.isEmpty {
        Text(description).font(Theme.Font.body).lineSpacing(5)
          .foregroundStyle(Theme.text(scheme)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        TranslateLink(text: details.video.title + "\n\n" + description)
      }
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          operation(
            "点赞", value: details.stats.like,
            icon: interactions.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup"
          ) {
            guard let aid = details.video.aid, aid > 0 else { return }
            Task { await interactions.like(aid: aid) { model.showingLogin = true } }
          }
          operation("投币", value: details.stats.coin, icon: "circle.hexagongrid") {
            coinCount = 1
            coinAlsoLike = true
            showingCoin = true
          }
          operation(
            "收藏", value: details.stats.favorite,
            icon: interactions.favorited == true ? "star.fill" : "star"
          ) {
            guard let aid = details.video.aid, aid > 0 else { return }
            Task {
              if await interactions.loadFolders(aid: aid, requiresLogin: { model.showingLogin = true }) { showingFavorites = true }
            }
          }
          Button { showingTriple = true } label: { GlassTileLabel(symbol: "sparkles", value: "三连") }
            .buttonStyle(GlassTileButtonStyle()).help("三连：点赞、投币并收藏").accessibilityLabel("三连")
            .disabled(details.video.aid == nil || interactions.busy)
        }
      }
      HStack(spacing: 16) {
        Text("AV \(details.video.aid.map(String.init) ?? "—")")
        Text("BV \(details.video.bvid)")
      }.font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
        .textSelection(.enabled)
    }.disabled(model.usesUIFixtures)
  }

  private func operation(_ title: String, value: Int, icon: String, action: @escaping () -> Void)
    -> some View
  {
    let active = (title == "点赞" && interactions.liked == true) || (title == "收藏" && interactions.favorited == true)
    return Button(action: action) {
      GlassTileLabel(symbol: icon, value: title == "点赞" && interactions.liked == nil ? "…" : count(value))
    }.buttonStyle(GlassTileButtonStyle(selected: active))
      .help(title).accessibilityLabel(title).accessibilityValue(count(value))
      .disabled(details?.video.aid == nil || interactions.busy ||
      (title == "点赞" && interactions.liked == nil))
  }

  private func stat(_ title: String, _ value: Int, icon: String) -> some View {
    Label("\(title) \(count(value))", systemImage: icon).font(Theme.Font.caption)
  }

  // Source: VideoConnectorViewModel.InitializeSections and VideoPlayerPanel.xaml.
  private var availableSections: [Section] {
    guard let details else { return [.info, .comments] }
    var result: [Section] = [.info, .comments]
    if model.playbackQueue.count > 0 { result.insert(.queue, at: 0) }
    if details.parts.count > 1 { result.append(.parts) }
    if !details.collections.isEmpty { result.append(.collections) }
    if details.relatedAvailable { result.append(.related) }
    result.append(.ai)
    return result
  }
  private func sectionTitle(_ section: Section) -> String {
    switch section {
    case .comments: if let replies = details?.stats.reply, replies > 0 { return "评论 " + count(replies) }
    case .parts: if let parts = details?.parts.count, parts > 1 { return "分集 \(parts)" }
    default: break
    }
    return section.rawValue
  }

  private var sidePanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      AdaptiveSegmentedTabs(options: availableSections.map { ($0, sectionTitle($0)) },
        selection: Binding(get: { section }, set: { section = $0; userPickedSection = true }))
        .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading).frame(height: Theme.pageHeaderHeight)
        #if DEBUG
        .modifier(DemoVideoSection { title in
          if let match = availableSections.first(where: { sectionTitle($0) == title }) { section = match; userPickedSection = true }
        })
        #endif
      Hairline()
      ScrollView {
        Group {
          if let details {
            switch section {
            case .queue: queueSection
            case .collections: collectionsSection(details)
            case .info:
              VStack(alignment: .leading, spacing: 20) {
                detailInformation(details)
                if !timelineChapters.isEmpty {
                  PlaybackChapterList(clock: player.clock, chapters: timelineChapters,
                    override: fixturePlayback ? fixtureTime : nil) { position in
                    if fixturePlayback { fixtureTime = position } else { player.seek(position) }
                  }
                }
              }
            case .parts: partsSection(details)
            case .related: relatedSection(details)
            case .comments: M4EmbeddedComments(comments: comments, model: model,
              target: M4CommentTarget(oid: details.video.aid ?? 0, type: 1),
              total: details.stats.reply > 0 ? Int64(details.stats.reply) : nil, ownerMid: details.video.authorID)
            case .ai: AIPanelView(runtime: model.ai, source: model.aiVideoSource(details))
            }
          } else if let detailLoadError {
            InlineErrorText(message: detailLoadError)
          } else {
            ProgressView("正在加载侧栏…").frame(maxWidth: .infinity).padding(24)
          }
        }.padding(.horizontal, [.parts, .queue, .collections, .related].contains(section) ? 10 : 18)
          .padding(.vertical, 14)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .prefetchOnScroll(enabled: section == .comments && comments.thread == nil && !comments.loading &&
        !comments.isEnd && comments.error == nil && !comments.comments.isEmpty) {
        Task { await comments.loadNext() }
      }
      .aiThreadScrolling(section == .ai)
      .id(section)
      if section == .comments, details != nil {
        Hairline()
        M4CommentComposer(comments: comments, model: model)
      }
      if section == .ai, let details {
        AIPanelComposer(runtime: model.ai, source: model.aiVideoSource(details))
          .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func partsSection(_ details: VideoDetails) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Text("\(details.parts.count) 个分 P").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
        Spacer()
        Text("仅显示序号").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        Toggle("仅显示序号", isOn: $onlyPartNumbers).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
      }
      if onlyPartNumbers {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], spacing: 8) {
          ForEach(details.parts) { part in
            Button { model.openPart(part) } label: {
              Text("\(part.page)").font(Theme.Font.headline.monospacedDigit())
                .frame(maxWidth: .infinity).frame(height: 36)
            }.buttonStyle(ChromeButtonStyle(selected: model.selected?.cid == part.cid, icon: true)).help(part.title)
          }
        }
      } else {
        ForEach(details.parts) { part in
          Button { model.openPart(part) } label: { partThumbnailCard(part, cover: details.video.cover) }
            .buttonStyle(SidebarRowStyle(selected: model.selected?.cid == part.cid))
        }
      }
    }.font(Theme.Font.body).foregroundStyle(Theme.text(scheme))
  }

  private func partThumbnailCard(_ part: VideoPart, cover: URL?) -> some View {
    HStack(alignment: .top, spacing: 10) {
      CachedImage(url: part.cover ?? cover).frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(alignment: .bottomTrailing) { MediaBadge(text: clock(Double(part.duration))).padding(4) }
      VStack(alignment: .leading, spacing: 4) {
        Text(part.title).font(Theme.Font.body).lineLimit(2)
        if let badge = part.badge, !badge.isEmpty {
          Text(badge).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
        }
        Spacer(minLength: 0)
        if part.likeCount != nil || part.coinCount != nil { partStatistics(part) }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }.padding(6).frame(maxWidth: .infinity, alignment: .leading).frame(height: 75)
  }

  private func partStatistics(_ part: VideoPart) -> some View {
    HStack(spacing: 12) {
      if let likes = part.likeCount {
        HStack(spacing: 4) {
          Image(systemName: "hand.thumbsup.fill").font(.system(size: 9))
          Text(count(likes))
        }.help("点赞")
      }
      if let coins = part.coinCount, coins > 0 {
        HStack(spacing: 4) {
          Image(systemName: "circle.grid.cross").font(.system(size: 10))
          Text(count(coins))
        }.help("投币")
      }
    }.font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
  }

  private var queueSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(model.playbackQueue.position) / \(model.playbackQueue.count)").font(Theme.Font.caption.monospacedDigit())
        .foregroundStyle(Theme.tertiaryText(scheme)).padding(.horizontal, 6)
      ForEach(model.playbackQueue.items) { item in
        Button { model.playQueueVideo(item) } label: {
          MediaRow(cover: item.cover, title: item.title, subtitle: item.author)
        }.buttonStyle(SidebarRowStyle(selected: model.playbackQueue.current?.id == item.id))
      }
    }
  }

  private func collectionsSection(_ details: VideoDetails) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(details.collections) { collection in
        Text(collection.title).font(Theme.Font.headline).padding(.horizontal, 6).padding(.top, 4)
        ForEach(collection.episodes) { episode in
          Button {
            model.open(episode)
          } label: {
            MediaRow(cover: episode.cover, title: episode.title, subtitle: episode.author, thumbWidth: 96)
          }.buttonStyle(SidebarRowStyle(selected: details.matches(episode)))
        }
      }
    }.font(Theme.Font.body).foregroundStyle(Theme.text(scheme))
  }

  private func relatedSection(_ details: VideoDetails) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if !details.relatedAvailable {
        Text("相关推荐暂不可用").foregroundStyle(Theme.tertiaryText(scheme)).padding(6)
      } else if details.related.isEmpty {
        Text("还没有相关推荐").foregroundStyle(Theme.tertiaryText(scheme)).padding(6)
      }
      ForEach(details.related) { item in
        Button {
          model.open(item)
        } label: {
          MediaRow(cover: item.cover, title: item.title, subtitle: item.author, meta: "\(count(item.views)) 播放",
            duration: item.duration > 0 ? clock(Double(item.duration)) : nil)
        }.buttonStyle(SidebarRowStyle())
      }
    }.font(Theme.Font.body).foregroundStyle(Theme.text(scheme))
  }

  private var coinSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("投币").font(Theme.Font.section)
      Picker("数量", selection: $coinCount) {
        Text("1 枚").tag(1)
        Text("2 枚").tag(2)
      }.pickerStyle(.segmented)
      Toggle("同时点赞", isOn: $coinAlsoLike)
      HStack {
        Spacer()
        Button("取消") { showingCoin = false }.buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
        Button("确认投币") {
          guard let aid = details?.video.aid, aid > 0 else { return }
          Task {
            await interactions.coin(
              aid: aid, count: coinCount, alsoLike: coinAlsoLike) { model.showingLogin = true }
            if !interactions.busy { showingCoin = false }
          }
        }.buttonStyle(AppButtonStyle(role: .primary)).keyboardShortcut(.defaultAction).disabled(interactions.busy)
      }
    }.padding(24).frame(width: 340)
  }

  private var favoriteSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("收藏到文件夹").font(Theme.Font.section)
      if interactions.folders.isEmpty {
        Text("没有可用的收藏夹").foregroundStyle(Theme.secondaryText(scheme))
      }
      ForEach(interactions.folders) { folder in
        Toggle(
          folder.title,
          isOn: Binding(
            get: { interactions.selectedFolderIDs.contains(folder.id) },
            set: { selected in
              if selected {
                interactions.selectedFolderIDs.insert(folder.id)
              } else {
                interactions.selectedFolderIDs.remove(folder.id)
              }
            }
          )
        ).toggleStyle(.checkbox)
      }
      HStack {
        Spacer()
        Button("取消") { showingFavorites = false }.buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
        Button("保存") {
          guard let aid = details?.video.aid, aid > 0 else { return }
          Task {
            if await interactions.saveFolders(aid: aid, requiresLogin: { model.showingLogin = true }) { showingFavorites = false }
          }
        }.buttonStyle(AppButtonStyle(role: .primary)).keyboardShortcut(.defaultAction).disabled(interactions.busy || interactions.folders.isEmpty)
      }
    }.padding(24).frame(width: 360)
  }

  private func clock(_ value: Double) -> String {
    let value = Int(max(0, value))
    return String(format: "%02d:%02d", value / 60, value % 60)
  }
  private func count(_ value: Int) -> String {
    value >= 10_000 ? String(format: "%.1f 万", Double(value) / 10_000) : String(value)
  }
}
