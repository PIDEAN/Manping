import AppKit
import ManpingCore
import SwiftUI

struct PGCPlayerPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject var playback: PGCPlaybackModel
  @ObservedObject private var player: PlayerModel
  let selection: PGCSelection
  @StateObject private var comments: M4CommentModel
  @ObservedObject private var interactions: PGCInteractionModel
  @StateObject private var features: PlaybackFeaturesModel
  @StateObject private var chrome = PlayerChromeState()
  @State private var danmakuSettingsShown = DanmakuSettingsPopover.debugOpen
  @State private var networkShown = CDNPanel.debugOpen
  @State private var scrubbing = false
  @State private var stageWidth: CGFloat = 900
  @AppStorage(PlayerPreferences.sidebarHiddenKey) private var sidebarHidden = false
  /// Full screen: the picture fills the window; the right column's own setting is kept.
  @Environment(\.immersivePlayback) private var immersive
  @State private var tab: Tab = .info
  @State private var onlyNumbers = false
  @State private var fixturePaused = false
  @State private var volumeShown = false
  @State private var composeShown = false
  @State private var showingCoin = false
  @State private var showingFavorites = false
  @State private var showingTriple = false
  @State private var coinCount = 1
  @State private var coinAlsoLike = false
  @Environment(\.colorScheme) private var scheme
  @State private var videoShot: VideoShot?
  init(model: AppModel, playback: PGCPlaybackModel, selection: PGCSelection) {
    self.model = model; self.playback = playback; self.selection = selection
    _interactions = ObservedObject(wrappedValue: playback.interactions)
    _player = ObservedObject(wrappedValue: playback.player)
    _comments = StateObject(wrappedValue: M4CommentModel(model: model))
    _features = StateObject(wrappedValue: model.playbackFeatures)
    #if DEBUG
    if playback.usesFixtures {
      let args = ProcessInfo.processInfo.arguments
      if let index = args.firstIndex(of: "--ui-video-tab"), index + 1 < args.count {
        let selected: Tab
        switch args[index + 1] {
        case "episodes", "parts": selected = .episodes
        case "comments": selected = .comments
        case "seasons": selected = .seasons
        case "ai": selected = .ai
        default: selected = .info
        }
        _tab = State(initialValue: selected)
      }
    }
    #endif
  }
  private enum Tab: String { case info = "简介", episodes = "分集", seasons = "季度", comments = "评论", ai = "AI" }
  private var tabs: [Tab] {
    var values: [Tab] = [.info, .comments]
    if (playback.details?.episodes.count ?? 0) > 1 { values.append(.episodes) }
    if (playback.details?.seasons.count ?? 0) > 1 { values.append(.seasons) }
    values.append(.ai); return values
  }
  private func tabTitle(_ tab: Tab) -> String {
    switch tab {
    case .comments: if let replies = playback.details?.stats.replies, replies > 0 { return "评论 " + count(replies) }
    case .episodes: if let episodes = playback.details?.episodes.count, episodes > 1 { return "分集 \(episodes)" }
    default: break
    }
    return tab.rawValue
  }
  private var duration: Double { max(1, player.duration > 0 ? player.duration : playback.manifest?.duration ?? Double(playback.episode?.duration ?? 0)) }
  private var time: Double { playback.usesFixtures ? playback.fixturePosition : player.time }
  var body: some View {
    PlayerPageLayout(showsPanel: !sidebarHidden, immersive: immersive) {
      media
    } panel: {
      sidePanel
    }
    // The one toolbar above the page (the main window's, or the standalone window's).
    .pageToolbar(title: toolbarTitle, subtitle: toolbarSubtitle) {
      ToolbarIconGroup {
        if let episode = playback.episode { ToolbarShareButton(url: episode.publicURL) }
        PlayerToolbarActions(model: model, sidebarHidden: $sidebarHidden)
      }
    }
    .task(id: selection) { await playback.ensureLoaded(selection) }
      .onChange(of: playback.episode?.id) { _, _ in
        showingCoin = false; showingFavorites = false; showingTriple = false
        if playback.details != nil && !tabs.contains(tab) { tab = .info }
      }
      .onChange(of: playback.identityVersion) { _, _ in comments.cancel(); tab = .info; showingCoin = false; showingFavorites = false; showingTriple = false }
      .onDisappear { comments.cancel(); restoreTemporarySpeed() }
      .task(id: playback.episode?.cid) {
        videoShot = nil
        guard !playback.usesFixtures, let episode = playback.episode, let cid = episode.cid else { return }
        videoShot = try? await model.service.videoShot(bvid: nil, aid: episode.aid, cid: cid)
      }
      .onChange(of: model.showingLogin) { _, show in if show { showingCoin = false; showingFavorites = false } }
      .sheet(isPresented: $showingCoin) { coinSheet }
      .sheet(isPresented: $showingFavorites) { favoriteSheet }
      .confirmationDialog("三连", isPresented: $showingTriple, titleVisibility: .visible) {
        Button("点赞、投币并收藏") {
          if let aid = playback.episode?.aid { Task { await interactions.triple(aid: aid) { model.showingLogin = true } } }
        }
        Button("取消", role: .cancel) {}
      }
  }
  private var toolbarTitle: String { playback.episode?.title ?? playback.details?.season.title ?? "正在加载剧集…" }
  /// The season's name beside the episode's title.
  private var toolbarSubtitle: String? {
    guard playback.episode != nil, let season = playback.details?.season.title, season != toolbarTitle else { return nil }
    return season
  }
  private var paused: Bool { playback.usesFixtures ? fixturePaused : player.paused }
  /// Paused, a popover open, typing a comment or scrubbing: the controls stay up.
  private var controlsPinned: Bool {
    playback.usesFixtures || paused || volumeShown || danmakuSettingsShown || networkShown || composeShown || scrubbing
      || !features.input.isEmpty
  }
  private var controlsShown: Bool { chrome.visible || controlsPinned }
  /// The picture's shape, from the stream being played (16:9 until it is known).
  private var pictureAspect: CGFloat? { playerAspect(width: playback.selectedStream?.width, height: playback.selectedStream?.height) }
  private var stageCover: URL? { playback.episode?.cover ?? playback.details?.season.cover }
  private var media: some View {
    // The surface fills the stage: the video is fitted to the picture inside it, the danmaku and
    // the gestures cover the whole stage.
    PlayerSurface(model: player, pictureAspect: stagePictureAspect(pictureAspect))
      .onLongPressGesture(minimumDuration: 0.4, pressing: { pressing in
        if !pressing { restoreTemporarySpeed() }
      }) {
        player.beginTemporarySpeed()
      }
      // Live Text over the paused picture, under the status layer and the controls.
      .overlay { LiveTextLayer(controller: player.liveText) }
      // An offline sample's artwork stands in for the picture, under the danmaku.
      .background {
        if playback.usesFixtures, playback.episode != nil {
          Color.clear.overlay { CachedImage(url: stageCover) }.clipped()
            .playerPictureFrame(aspect: stagePictureAspect(pictureAspect)).allowsHitTesting(false)
        }
      }
      .playerStageBackdrop(cover: stageCover)
      // The cover sits under the status layer: loading, errors and retry stay visible over it.
      .overlay {
        if player.audioOnly { AudioOnlyBackdrop(cover: stageCover, title: playback.episode?.title ?? "") }
      }
      .overlay {
        if playback.usesFixtures, playback.episode != nil {
          Text("本地预览 · 未加载媒体").font(Theme.Font.caption2).foregroundStyle(.white.opacity(0.65)).padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
        } else if let error = playback.error, playback.manifest == nil {
          VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(Theme.highlight)
            Text(error).font(Theme.Font.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9)).frame(maxWidth: 360)
            Button("重试") { Task { await playback.load(selection) } }.buttonStyle(AppButtonStyle(role: .primary, size: .small))
          }.padding(18).environment(\.colorScheme, .dark).floatingGlassPanel(readingTint: .black.opacity(0.4))
        } else {
          PlayerStatusOverlay(player: player, loading: playback.isLoading) { Task { await playback.load(selection) } }
        }
      }
      .overlay(alignment: .topTrailing) {
        if let deadline = model.nextPlaybackDeadline {
          NextPlaybackOverlay(deadline: deadline, onPlay: model.playNext, onCancel: model.cancelNextPlayback)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if let skips = playback.manifest?.skips, !skips.isEmpty, !playback.usesFixtures {
          PlaybackSkipPrompt(clock: player.clock, skips: skips,
            automatic: model.appSettings.bool(.autoSkipClips)) { playback.skip($0) }
            .padding(.trailing, 20).padding(.bottom, controlsShown ? 132 : 24)
        }
      }
      .overlay(alignment: .bottom) {
        ZStack(alignment: .bottom) {
          if model.appSettings.bool(.bottomProgress) {
            PlaybackProgressBar(clock: player.clock, duration: duration, override: playback.usesFixtures ? playback.fixturePosition : nil)
              .opacity(controlsShown ? 0 : 1).animation(.easeOut(duration: 0.2), value: controlsShown)
          }
          controls.playerChromeFade(controlsShown)
        }
      }
      .animation(.snappy(duration: 0.3), value: model.nextPlaybackDeadline == nil)
      .animation(.easeOut(duration: 0.2), value: controlsShown)
      .reportsStageWidth($stageWidth)
      .tracksPlayerChrome(chrome, pinned: controlsPinned)
      // Playback shortcuts (menu bar, media keys) bring the controls in.
      .onChange(of: player.speed) { _, _ in chrome.activity() }
      .onChange(of: player.volume) { _, _ in chrome.activity() }
      .onChange(of: player.commentsEnabled) { _, _ in chrome.activity() }
      .playerStageShape(immersive: immersive)
  }
  private func restoreTemporarySpeed() {
    player.endTemporarySpeed()
  }
  private var streams: [MediaStream] { playback.manifest?.video ?? [] }
  private var controls: some View {
    let layout = PlayerPanelLayout(stageWidth: stageWidth)
    return PlayerControlPanel(chrome: chrome) {
      PlaybackTimeline(clock: player.clock, duration: duration, override: playback.usesFixtures ? playback.fixturePosition : nil,
        enabled: playback.manifest != nil || playback.usesFixtures, preview: videoShot,
        density: player.timeline.density(duration: duration), chapters: player.chapters, markers: model.aiMarks(for: model.aiMediaKey),
        bufferedAhead: { [player] in player.bufferedAhead }, scrubbing: { scrubbing = $0 }) { playback.seek($0) }
      PlayerBarRow(model: model, player: player, layout: layout, page: barPage, cdn: model.cdn,
        danmakuShown: $danmakuSettingsShown, networkShown: $networkShown, volumeShown: $volumeShown,
        composeShown: $composeShown,
        input: {
          AnyView(PlaybackDanmakuInput(features: features) {
            features.send(seconds: time) { model.showingLogin = true }
          })
        },
        extraMenu: { AnyView(debugMenuItems) }) {
        PlayerPlayButton(paused: paused) {
          if playback.usesFixtures { fixturePaused.toggle() } else { player.togglePause() }
        }.disabled(playback.manifest == nil && !playback.usesFixtures)
        if model.canPlayPrevious {
          Button { model.playPrevious() } label: { Image(systemName: "backward.end.fill") }
            .buttonStyle(PlayerControlButtonStyle(size: 32)).help("上一个（⇧⌘[）").accessibilityLabel("上一个")
        }
        Button { playback.nextEpisode() } label: { Image(systemName: "forward.end.fill") }
          .buttonStyle(PlayerControlButtonStyle(size: 32)).disabled(!playback.canPlayNext)
          .help("下一个（⇧⌘]）").accessibilityLabel("下一个")
        if layout.showsTime {
          PlayerTimeLabel(clock: player.clock, duration: duration, override: playback.usesFixtures ? playback.fixturePosition : nil)
            .padding(.horizontal, 4)
        }
        DanmakuToggleButton(enabled: $player.commentsEnabled) { danmakuSettingsShown = true }
      }
      if let message = features.message {
        Text(message).font(Theme.Font.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  /// 画质 and 字幕 come from this page; the rest of the bar is shared (设置 › 控制条).
  private var barPage: PlayerBarPage {
    PlayerBarPage(slots: [
      .quality: .quality(streams: streams, selected: playback.selectedStream, enabled: playback.manifest != nil) {
        playback.changeQuality($0)
      },
      .subtitle: .subtitle(features: features, player: player, filterAI: model.appSettings.bool(.filterAISubtitle)),
    ], downloadEnabled: playback.manifest != nil)
  }
  @ViewBuilder private var debugMenuItems: some View {
    #if DEBUG
    if playback.usesFixtures {
      Divider()
      Button("模拟播放结束（本地样本）") { player.simulatePlaybackEnd() }
    }
    #endif
  }
  private var sidePanel: some View {
    VStack(spacing: 0) {
      AdaptiveSegmentedTabs(options: tabs.map { ($0, tabTitle($0)) }, selection: $tab)
        .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading).frame(height: Theme.pageHeaderHeight)
      Hairline()
      ScrollView {
        Group {
          switch tab {
          case .info: information
          case .episodes: episodes
          case .seasons: seasons
          case .comments:
            if let aid = playback.episode?.aid {
              M4EmbeddedComments(comments: comments, model: model, target: M4CommentTarget(oid: aid, type: 1),
                total: playback.details?.stats.replies)
            }
            else { Text("当前分集暂时不能查看评论。").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)) }
          case .ai:
            if let source = model.aiEpisodeSource(playback) { AIPanelView(runtime: model.ai, source: source) }
          }
        }.padding(.horizontal, tab == .info || tab == .comments || tab == .ai ? 18 : 10).padding(.vertical, 14)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }.prefetchOnScroll(enabled: tab == .comments && comments.thread == nil && !comments.loading && !comments.isEnd
        && comments.error == nil && !comments.comments.isEmpty) { Task { await comments.loadNext() } }
      .aiThreadScrolling(tab == .ai)
      if tab == .comments, playback.episode?.aid != nil {
        Hairline()
        M4CommentComposer(comments: comments, model: model)
      }
      if tab == .ai, let source = model.aiEpisodeSource(playback) {
        AIPanelComposer(runtime: model.ai, source: source)
          .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var information: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let details = playback.details {
        descriptor(details)
        if !player.chapters.isEmpty {
          PlaybackChapterList(clock: player.clock, chapters: player.chapters,
            override: playback.usesFixtures ? playback.fixturePosition : nil, seek: playback.seek)
        }
        operations(details)
      } else if let error = playback.error { InlineErrorText(message: error) }
      else { ProgressView("正在加载信息…") }
    }.foregroundStyle(Theme.text(scheme))
  }
  // PgcInfoSection / PgcDescriptorControl: margin 16,12; section spacing 20;
  // descriptor spacing 16; title/alias spacing 4. The source has no rating row.
  private func descriptor(_ details: PGCDetails) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(details.season.title).font(.system(size: 18, weight: .bold)).lineLimit(2)
        let alias = details.alias
        if !alias.isEmpty { Text(alias).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)) }
      }
      statistics(details.stats)
      if !details.description.isEmpty {
        PGCDescriptionText(text: details.description, color: scheme == .dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.2, alpha: 1))
          .frame(maxWidth: .infinity, alignment: .leading)
        TranslateLink(text: details.description)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func statistics(_ stats: PGCStats) -> some View {
    HStack(spacing: 12) {
      if let views = stats.views { statistic(views, symbol: "play.circle", tip: "播放", accent: true) }
      if let replies = stats.replies { statistic(replies, symbol: "bubble.left", tip: "评论") }
      if let danmaku = stats.danmaku { statistic(danmaku, symbol: "list.bullet", tip: "弹幕") }
      if let followers = stats.followers { statistic(followers, symbol: "heart", tip: "追番") }
    }.font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
  }
  private func statistic(_ value: Int64, symbol: String, tip: String, accent: Bool = false) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).foregroundStyle(accent ? Theme.accentText(scheme) : Theme.tertiaryText(scheme))
      Text(count(value))
    }.help(tip).accessibilityLabel("\(tip) \(count(value))")
  }
  private func operations(_ details: PGCDetails) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          interactionButton(value: details.stats.likes, symbol: interactions.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup", title: "点赞", selected: interactions.liked == true) {
            if let aid = playback.episode?.aid { Task { await interactions.like(aid: aid) { model.showingLogin = true } } }
          }
          interactionButton(value: details.stats.coins, symbol: "circle.hexagongrid", title: "投币", selected: interactions.coined == true) { showingCoin = true }
          interactionButton(value: details.stats.favorites, symbol: interactions.favorited == true ? "star.fill" : "star", title: "收藏", selected: interactions.favorited == true) {
            guard let aid = playback.episode?.aid else { return }
            Task { if await interactions.loadFolders(aid: aid, requiresLogin: { model.showingLogin = true }) { showingFavorites = true } }
          }
          Button { showingTriple = true } label: { GlassTileLabel(symbol: "sparkles", value: "三连") }
            .buttonStyle(GlassTileButtonStyle()).help("三连：点赞、投币并收藏").accessibilityLabel("三连")
        }
      }.disabled(interactions.busy || playback.episode?.aid == nil)
      HStack(spacing: 8) {
        Button {
          Task { await interactions.follow(seasonID: details.season.id) { model.showingLogin = true } }
        } label: {
          Label(interactions.followed == true ? "已追" : "追番 / 追剧", systemImage: interactions.followed == true ? "heart.fill" : "heart")
            .frame(maxWidth: .infinity)
        }.buttonStyle(AppButtonStyle(role: interactions.followed == true ? .secondary : .primary))
          .disabled(interactions.busy || interactions.stateLoading)
        Button { model.enqueueDownload() } label: { Label("下载", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity) }
          .buttonStyle(AppButtonStyle()).disabled(playback.manifest == nil)
      }
      if let error = interactions.stateError {
        HStack {
          InlineErrorText(message: error)
          Button("重试") { interactions.refreshState() }.buttonStyle(AppButtonStyle(size: .small))
        }
      }
      if let message = interactions.message { Text(message).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)) }
      VStack(alignment: .leading, spacing: 4) {
        Text("SS\(Text(String(details.season.id)).bold())").textSelection(.enabled)
        if let episode = playback.episode { Text("EP\(Text(String(episode.id)).bold())").textSelection(.enabled) }
      }.font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
    }
  }
  private func interactionButton(value: Int64?, symbol: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) { GlassTileLabel(symbol: symbol, value: value.map(count) ?? title) }
      .buttonStyle(GlassTileButtonStyle(selected: selected)).help(title).accessibilityLabel(title)
  }
  private var coinSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("投币").font(Theme.Font.section)
      Picker("数量", selection: $coinCount) { Text("1 枚").tag(1); Text("2 枚").tag(2) }.pickerStyle(.segmented)
      Toggle("同时点赞", isOn: $coinAlsoLike)
      HStack {
        Spacer()
        Button("取消") { showingCoin = false }.buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
        Button("确认投币") {
          guard let aid = playback.episode?.aid else { return }
          Task { await interactions.coin(aid: aid, count: coinCount, alsoLike: coinAlsoLike) { model.showingLogin = true }; showingCoin = false }
        }.buttonStyle(AppButtonStyle(role: .primary)).keyboardShortcut(.defaultAction).disabled(interactions.busy)
      }
    }.padding(24).frame(width: 340).foregroundStyle(Theme.text(scheme))
  }
  private var favoriteSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("收藏到文件夹").font(Theme.Font.section)
      if interactions.folders.isEmpty { Text("没有可用的收藏夹").foregroundStyle(Theme.secondaryText(scheme)) }
      ForEach(interactions.folders) { folder in
        Toggle(folder.title, isOn: Binding(get: { interactions.selectedFolderIDs.contains(folder.id) }, set: { selected in
          if selected { interactions.selectedFolderIDs.insert(folder.id) } else { interactions.selectedFolderIDs.remove(folder.id) }
        })).toggleStyle(.checkbox)
      }
      HStack {
        Spacer()
        Button("取消") { showingFavorites = false }.buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
        Button("保存") {
          guard let aid = playback.episode?.aid else { return }
          Task { if await interactions.saveFolders(aid: aid, requiresLogin: { model.showingLogin = true }) { showingFavorites = false } }
        }.buttonStyle(AppButtonStyle(role: .primary)).keyboardShortcut(.defaultAction).disabled(interactions.busy || interactions.folders.isEmpty)
      }
    }.padding(24).frame(width: 360).foregroundStyle(Theme.text(scheme))
  }
  private var episodes: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("\(playback.details?.episodes.count ?? 0) 集").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
        Spacer()
        Text("仅显示序号").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        Toggle("仅显示序号", isOn: $onlyNumbers).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
      }.padding(.horizontal, 6)
      if onlyNumbers {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], spacing: 8) {
          ForEach(playback.details?.episodes ?? []) { episode in
            Button { playback.selectEpisode(episode) } label: {
              Text("\(episode.index)").font(Theme.Font.headline.monospacedDigit()).frame(maxWidth: .infinity).frame(height: 36)
            }.buttonStyle(ChromeButtonStyle(selected: playback.episode?.id == episode.id, icon: true)).disabled(playback.isLoading)
          }
        }
      } else { ForEach(playback.details?.episodes ?? []) { episode in episodeButton(episode) } }
    }.font(Theme.Font.body).foregroundStyle(Theme.text(scheme))
  }
  private func episodeButton(_ episode: PGCEpisode) -> some View {
    Button { playback.selectEpisode(episode) } label: {
      HStack(alignment: .top, spacing: 10) {
        CachedImage(url: episode.cover ?? playback.details?.season.cover).frame(width: 112, height: 63)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
          .overlay(alignment: .bottomTrailing) { MediaBadge(text: clock(Double(episode.duration))).padding(4) }
        VStack(alignment: .leading, spacing: 4) {
          Text(episode.title).font(Theme.Font.body).lineLimit(2)
          if let badge = episode.badge, !badge.isEmpty { Text(badge).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)) }
          Spacer(minLength: 0)
          HStack(spacing: 10) {
            if let likes = episode.stats.likes { Label(count(likes), systemImage: "hand.thumbsup.fill") }
            if let coins = episode.stats.coins { Label(count(coins), systemImage: "circle.grid.cross") }
          }.font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }.padding(6).frame(height: 75)
    }.buttonStyle(SidebarRowStyle(selected: playback.episode?.id == episode.id)).disabled(playback.isLoading)
  }
  private var seasons: some View {
    VStack(spacing: 2) {
      ForEach(playback.details?.seasons ?? []) { season in
        Button { Task { await playback.load(PGCSelection(seasonID: season.id)) } } label: {
          HStack(spacing: 12) {
            CachedImage(url: season.cover).frame(width: 54, height: 72)
              .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            Text(season.title).font(Theme.Font.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
          }.padding(6)
        }.buttonStyle(SidebarRowStyle(selected: season.id == playback.details?.season.id)).disabled(playback.isLoading)
      }
    }
  }
  private func clock(_ seconds: Double) -> String { let value = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format: "%02d:%02d", value / 60, value % 60) }
  private func count(_ value: Int64) -> String { value >= 10000 ? String(format: "%.1f 万", Double(value) / 10000) : String(value) }
}

/// NSTextView gives the description a fixed paragraph line height (22pt at the 13pt body size).
private struct PGCDescriptionText: NSViewRepresentable {
  let text: String
  let color: NSColor
  func makeNSView(context: Context) -> NSTextView {
    let view = NSTextView()
    view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
    view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = false
    return view
  }
  func updateNSView(_ view: NSTextView, context: Context) {
    let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 22; paragraph.maximumLineHeight = 22
    view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: paragraph]))
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0, let container = view.textContainer, let layout = view.layoutManager else { return nil }
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
  }
}
