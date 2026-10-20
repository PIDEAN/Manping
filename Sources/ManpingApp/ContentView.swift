import AppKit
import ManpingCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var model: AppModel
  var diagnosticTheme: AppTheme? = nil
  var body: some View {
    ShellContent(model: model).preferredColorScheme(
      diagnosticTheme?.colorScheme ?? model.theme.colorScheme
    )
    .tint(Theme.accent)
    .appDialogs(model: model, inDetachedWindow: false)
    // Drop a Bilibili link (from Safari's address bar, a chat, a .webloc) to open it here.
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first else { return false }
      return model.openLink(url.absoluteString)
    }
    #if DEBUG
    // README animations: `MANPING_DEMO_SCENE` with `--ui-fixture` (docs/media/README.md).
    .task { DemoDirector.startIfRequested(model: model) }
    #endif
  }
}

extension View {
  /// Download options, login and error alerts follow playback: while the player lives in its
  /// own window (and the main window may be hidden) they are presented there instead.
  func appDialogs(model: AppModel, inDetachedWindow: Bool) -> some View {
    modifier(AppDialogs(model: model, inDetachedWindow: inDetachedWindow))
  }
}

private struct AppDialogs: ViewModifier {
  @ObservedObject var model: AppModel
  let inDetachedWindow: Bool
  private var active: Bool { model.playbackDetached == inDetachedWindow }
  func body(content: Content) -> some View {
    content
      .sheet(isPresented: Binding(get: { active && model.showingDownloadOptions }, set: { model.showingDownloadOptions = $0 })) {
        M7DownloadOptionsSheet(model: model)
      }
      .sheet(isPresented: Binding(get: { active && model.showingLogin && !model.showingDownloadOptions }, set: { model.showingLogin = $0 })) {
        LoginView(model: model)
      }
      .alert("出了点问题", isPresented: Binding(get: { active && model.error != nil }, set: { if !$0 { model.error = nil } })) {
        Button("确定") { model.error = nil }
      } message: {
        Text(model.error ?? "")
      }
  }
}
/// The main window: a floating glass sidebar (发现 / 我的 / account) and the content column with
/// one toolbar on top. The sidebar becomes an icon rail below 1000 pt and hides with ⌃⌘S. The
/// playback page (video, episode, live room) slides it away, since 返回 leads back; there ⌃⌘S
/// floats it over the page until a click elsewhere or leaving the page.
private struct ShellContent: View {
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var suggestions: SearchSuggestionModel
  @ObservedObject private var pins = PinnedUserStore.shared
  @ObservedObject private var livePins = PinnedLiveStore.shared
  @ObservedObject private var shell = ShellSidebarState.shared
  @AppStorage(ShellPreferences.sidebarHiddenKey) private var storedSidebarHidden = false
  @State private var fixtureSidebarHidden = false
  private var sidebarHidden: Bool {
    DebugUIFixtures.usesLiveSceneMemory ? fixtureSidebarHidden : storedSidebarHidden
  }
  @State private var showingAccount = false
  init(model: AppModel) {
    self.model = model
    _suggestions = StateObject(wrappedValue: SearchSuggestionModel(model: model))
  }
  private enum SidebarMode: Equatable { case full, rail, hidden }
  var body: some View {
    GeometryReader { geometry in
      let playbackPage = model.showsPlaybackPage
      let mode: SidebarMode = sidebarHidden || playbackPage ? .hidden
        : geometry.size.width < Theme.sidebarCollapseWidth ? .rail : .full
      // Full screen on the playback page: only the picture, the danmaku and the controls. The
      // views keep their places in the hierarchy, so the player and its surface stay the same.
      let immersive = model.immersiveMainPlayback
      HStack(spacing: 0) {
        if mode != .hidden && !immersive {
          sidebar(rail: mode == .rail)
            .frame(width: (mode == .rail ? Theme.sidebarRailWidth : Theme.sidebarWidth) - Theme.panelInset)
            .padding([.leading, .top, .bottom], Theme.panelInset)
            .transition(sidebarTransition)
        }
        // Without the sidebar the window buttons sit over the toolbar's leading edge.
        contentColumn(leadingInset: mode == .hidden ? 72 : 0, immersive: immersive, playbackPage: playbackPage)
      }
      // ⌃⌘S on the playback page: the sidebar over the page; a click anywhere else puts it away.
      .overlay(alignment: .leading) {
        if playbackPage && shell.peeking && !immersive {
          ZStack(alignment: .leading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { shell.peeking = false }
            sidebar(rail: false)
              .frame(width: Theme.sidebarWidth - Theme.panelInset)
              .padding([.leading, .top, .bottom], Theme.panelInset)
              .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.16), radius: 18, x: 4)
              .transition(sidebarTransition)
          }
        }
      }
      // Outside the stage the playback page shows the window's backdrop, as the stage's frame.
      .background(immersive ? Theme.stage : playbackPage ? Theme.backdrop(scheme) : Theme.panel(scheme))
      .animation(reduceMotion ? .easeOut(duration: 0.25) : .snappy(duration: 0.25), value: mode)
      .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25), value: shell.peeking)
      .onChange(of: playbackPage, initial: true) { _, value in
        if shell.suppressed != value { shell.suppressed = value }
        if !value && shell.peeking { shell.peeking = false }
      }
      .onChange(of: immersive) { _, value in if value && shell.peeking { shell.peeking = false } }
    }.ignoresSafeArea(.container, edges: .top)
    .environment(\.cardActions, CardActions(model: model))
      .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) {
        _ in
        if DebugUIFixtures.usesLiveSceneMemory {
          fixtureSidebarHidden = PerformanceEnvironment.defaults.bool(
            forKey: ShellPreferences.sidebarHiddenKey)
        }
      }
  }
  /// Slides in from the leading edge; 减弱动态效果 only fades.
  private var sidebarTransition: AnyTransition {
    reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity)
  }

  // MARK: Sidebar

  private func sidebar(rail: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // The window's buttons sit in this band.
      Color.clear.frame(height: 40)
      brand(rail: rail)
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          sectionTitle("发现", rail: rail)
          ForEach(model.visibleDestinations(AppModel.Destination.discover), id: \.self) { item(for: $0, rail: rail) }
          sectionTitle("我的", rail: rail)
          ForEach(model.visibleDestinations(AppModel.Destination.mine), id: \.self) { item(for: $0, rail: rail) }
        }.padding(.horizontal, 8).padding(.bottom, 8)
      }.scrollIndicators(.never)
      Hairline().padding(.horizontal, 12)
      accountRow(rail: rail).padding(8)
    }
    .foregroundStyle(Theme.text(scheme))
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
  }
  /// The only place the brand mark appears: icon 24 pt and 满屏 (15 bold, tracking +2).
  private func brand(rail: Bool) -> some View {
    HStack(spacing: 8) {
      if let url = Bundle.module.url(forResource: "StoreLogo", withExtension: "png"), let logo = NSImage(contentsOf: url) {
        Image(nsImage: logo).resizable().frame(width: 24, height: 24)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      if !rail { Text("满屏").font(.system(size: 15, weight: .bold)).kerning(2) }
    }.frame(maxWidth: .infinity, alignment: rail ? .center : .leading)
      .padding(.horizontal, rail ? 0 : 18).frame(height: 36).accessibilityElement(children: .combine)
      .accessibilityLabel("满屏")
  }
  @ViewBuilder private func sectionTitle(_ title: String, rail: Bool) -> some View {
    if rail { Hairline().padding(.horizontal, 10).padding(.vertical, 10) }
    else { SidebarSectionTitle(title: title) }
  }
  private func item(for destination: AppModel.Destination, rail: Bool) -> some View {
    let selected = model.currentDestination == destination && (model.selected == nil || model.browsingBesidePlayback)
    let unread = destination == .page(.message) ? model.unreadMessageCount : 0
    return Button { shell.peeking = false; model.go(to: destination) } label: {
      HStack(spacing: 10) {
        Image(systemName: destination.symbol).font(.system(size: 14)).frame(width: 20)
        if !rail {
          Text(destination.title).font(Theme.Font.body).lineLimit(1)
          Spacer(minLength: 0)
          if unread > 0 { UnreadBadge(count: unread) }
        }
      }
      .padding(.horizontal, rail ? 0 : 10)
      .frame(maxWidth: .infinity, alignment: rail ? .center : .leading).frame(height: 32)
      .overlay(alignment: .topTrailing) {
        if rail && unread > 0 { Circle().fill(Theme.live).frame(width: 7, height: 7).offset(x: -10, y: 6) }
      }
      .contentShape(Rectangle())
    }.buttonStyle(SidebarRowStyle(selected: selected)).demoAnchor("sidebar.\(destination.title)")
      .help(destination.title)
      .accessibilityLabel(unread > 0 ? "\(destination.title)，\(unread) 条未读" : destination.title)
  }
  private func accountRow(rail: Bool) -> some View {
    Button { showingAccount.toggle() } label: {
      HStack(spacing: 10) {
        avatar(size: 28)
        if !rail {
          VStack(alignment: .leading, spacing: 1) {
            Text(model.account).font(Theme.Font.headline).lineLimit(1)
            if let level = model.accountLevel {
              Text("Lv\(min(6, max(0, level)))").font(Theme.Font.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.accentText(scheme))
            } else if model.accountMID == nil {
              Text("点按登录").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
            }
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.tertiaryText(scheme))
        }
      }.padding(.horizontal, rail ? 0 : 6).frame(maxWidth: .infinity, alignment: rail ? .center : .leading)
        .frame(height: 44).contentShape(Rectangle())
    }.buttonStyle(SidebarRowStyle()).help(model.account)
      .popover(isPresented: $showingAccount, arrowEdge: .trailing) { accountMenu }
  }
  private func avatar(size: CGFloat) -> some View {
    Group {
      if model.accountAvatar != nil {
        CachedImage(url: model.accountAvatar)
      } else {
        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(Theme.tertiaryText(scheme))
      }
    }.frame(width: size, height: size).clipShape(Circle())
      .overlay(Circle().strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
  }
  private var accountMenu: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(model.account).font(Theme.Font.headline).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 8)
      if let mid = model.accountMID {
        accountItem("我的空间", icon: "person.crop.circle", route: .userSpace(mid))
        accountItem("我的关注", icon: "person.2", route: .following(mid))
        accountItem("我的粉丝", icon: "person.2.fill", route: .followers(mid))
      }
      if !pins.users.isEmpty || !livePins.rooms.isEmpty {
        Hairline().padding(.vertical, 4).padding(.horizontal, 6)
        SidebarSectionTitle(title: "固定的 UP 主与直播间")
      }
      ForEach(pins.users) { user in
        accountItem(user.name, icon: "pin", route: .userSpace(user.id))
      }
      ForEach(livePins.rooms) { room in
        Button { showingAccount = false; model.openLiveRoom(room.id) } label: {
          Label(room.title, systemImage: "dot.radiowaves.left.and.right").font(Theme.Font.body).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 32)
        }.buttonStyle(SidebarRowStyle())
      }
      Hairline().padding(.vertical, 4).padding(.horizontal, 6)
      if model.accountMID == nil {
        menuAction("登录…", icon: "qrcode") { model.showingLogin = true }
      } else {
        menuAction("退出登录", icon: "rectangle.portrait.and.arrow.right") { model.logout() }
      }
    }.padding(6).frame(width: 240).foregroundStyle(Theme.text(scheme))
  }
  private func accountItem(_ title: String, icon: String, route: AppModel.OverlayRoute) -> some View {
    menuAction(title, icon: icon) { model.openOverlay(route) }
  }
  private func menuAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button { showingAccount = false; action() } label: {
      Label(title, systemImage: icon).font(Theme.Font.body).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 32)
    }.buttonStyle(SidebarRowStyle())
  }

  // MARK: Content and toolbar

  private func contentColumn(leadingInset: CGFloat, immersive: Bool, playbackPage: Bool) -> some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: immersive ? 0 : Theme.toolbarHeight)
      pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.immersivePlayback, immersive)
    }
    // Pages describe their toolbar with `.pageToolbar(…)`; it is drawn once, here.
    .overlayPreferenceValue(PageToolbarKey.self, alignment: .top) { item in
      if !immersive { toolbar(item, leadingInset: leadingInset, divided: !playbackPage) }
    }
  }
  private var showsHomeTabs: Bool {
    model.page == .popular && model.currentOverlay == nil && !model.mainShowsPlayer
  }
  /// `divided`: a hairline under the toolbar; the playback page's stage and panel keep their own
  /// 12 pt gap below it instead.
  private func toolbar(_ item: PageToolbarItem?, leadingInset: CGFloat, divided: Bool) -> some View {
    HStack(spacing: 12) {
      navigationButtons
      PageToolbarTitle(item: item, fallback: model.toolbarTitle).layoutPriority(-1)
      if showsHomeTabs {
        SegmentedTabs(options: AppModel.PopularTab.allCases.map { ($0, $0.rawValue) },
          selection: Binding(get: { model.popularTab }, set: { model.selectPopularTab($0) })).fixedSize()
      } else if let segments = item?.segments {
        segments.fixedSize()
      }
      Spacer(minLength: 8)
      if let accessory = item?.accessory {
        HStack(spacing: 8) { accessory }.fixedSize()
      }
      searchBox.frame(minWidth: 180, idealWidth: 300, maxWidth: 300)
      refreshButton(item)
    }
    .foregroundStyle(Theme.text(scheme))
    .padding(.leading, 16 + leadingInset).padding(.trailing, 16)
    .frame(height: Theme.toolbarHeight)
    .overlay(alignment: .bottom) { Hairline().opacity(divided ? 1 : 0) }
  }
  private var navigationButtons: some View {
    HStack(spacing: 0) {
      Button { model.goBack() } label: {
        Image(systemName: "chevron.backward").font(.system(size: 14, weight: .medium))
          .frame(width: 34, height: Theme.toolbarControlHeight)
      }.disabled(!model.canGoBack).help("返回（⌘[）")
      Button { model.goForward() } label: {
        Image(systemName: "chevron.forward").font(.system(size: 14, weight: .medium))
          .frame(width: 34, height: Theme.toolbarControlHeight)
      }.disabled(!model.canGoForward).help("前进（⌘]）")
    }.buttonStyle(ChromeButtonStyle(capsule: true)).padding(.horizontal, 2)
      .glassEffect(.regular.interactive(), in: Capsule())
  }
  private func refreshButton(_ item: PageToolbarItem?) -> some View {
    Button {
      if let refresh = item?.refresh { refresh() } else { Task { await model.refresh() } }
    } label: {
      Group {
        if item?.refreshing == true { ProgressView().controlSize(.small) }
        else { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)) }
      }.frame(width: Theme.toolbarControlHeight, height: Theme.toolbarControlHeight)
    }.buttonStyle(ChromeButtonStyle(capsule: true)).disabled(item?.refreshing == true)
      .glassEffect(.regular.interactive(), in: Circle()).help("刷新（⌘R）")
  }
  private var searchBox: some View {
    M3SearchBox(suggestions: suggestions, text: $model.search, suggestionsEnabled: model.appSettings.bool(.searchSuggestions),
      currentScopeName: currentScopeName, focusRequest: model.searchFocusRequest, hotRequest: model.hotSearchRequest) { keyword, scope in
        if scope == .current { model.submitRegionalSearch(keyword) }
        else { model.search = keyword; model.submitSearch() }
      }
  }
  private var currentScopeName: String? {
    switch model.currentOverlay {
    case .userSpace: "当前 UP 主"
    case .history: "历史记录"
    default: nil
    }
  }
  @ViewBuilder private var pageContent: some View {
    if model.usesUIFixtures && !model.fixtureReady {
      PageStateView(.loading, title: "正在准备本地样本…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.mainShowsPlayer && model.playbackElsewhere {
      // The picture plays in the mini window or the standalone window; the page waits here
      // until the user browses elsewhere (playback then keeps going beside the main window).
      let mini = model.compactPlayer
      VStack(spacing: 12) {
        Image(systemName: mini ? "pip" : "macwindow").font(.system(size: 20, weight: .medium))
          .foregroundStyle(Theme.accentText(scheme))
          .frame(width: 48, height: 48).background(Theme.selectedFill(scheme), in: Circle()).padding(.bottom, 4)
        Text(mini ? "正在小窗中播放" : "正在独立窗口中播放").font(Theme.Font.section)
        HStack(spacing: 8) {
          Button("回到主窗口") { if mini { model.toggleCompactPlayer() } else { model.togglePlaybackWindow() } }
            .buttonStyle(AppButtonStyle(role: .primary))
          Button("停止播放") { model.closePlayer() }.buttonStyle(AppButtonStyle())
        }.padding(.top, 6)
      }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(Theme.text(scheme))
    } else if model.mainShowsPlayer, let selected = model.selected {
      VideoDetailPage(model: model, player: model.player, video: selected).id(ObjectIdentifier(model.player))
    } else if let route = model.currentOverlay {
      switch route {
      case .search(let term): M3SearchPage(model: model, term: term)
      case .favorites: M3FavoritesPage(model: model)
      case .viewLater: M3ViewLaterPage(model: model)
      case .history: M3HistoryPage(model: model)
      case .userSpace(let mid): M3UserSpacePage(model: model, mid: mid).id(mid)
      case .following(let mid): M3FollowingPage(model: model, mid: mid).id(mid)
      case .followers(let mid): M3FollowersPage(model: model, mid: mid).id(mid)
      case .pgc(let selection):
        if let playback = model.pgcPlayback {
          PGCPlayerPage(model: model, playback: playback, selection: selection).id(ObjectIdentifier(playback.player))
        }
      case .article(let id):
        ArticleReaderPage(service: model.service, id: id, rpc: try? model.standardRPCService(), onUser: { model.openOverlay(.userSpace($0)) }, onVideo: model.open, onArticle: { model.openOverlay(.article($0)) }, onLogin: { model.showingLogin = true },
          aiContent: { detail in AnyView(AIPanelStack(runtime: model.ai, source: .article(AIArticleInfo(detail: detail)))) }).id(id)
      case .video: PageStateView(.loading, title: "正在打开视频", message: "正在获取视频详情与播放地址。")
      case .live:
        if let live = model.livePlayback {
          LivePlayerPage(model: model, live: live).id(ObjectIdentifier(live.player))
        }
      }
    } else {
      switch model.page {
      case .popular: PopularPage(model: model)
      case .moment: M4MomentPage(model: model)
      case .video:
        VideoPartitionPage(service: model.service, open: model.open, refreshToken: model.refreshToken,
          ranking: { [model] region in try await RPCBrowseSource(rpc: model.standardRPCService()).rankingFeed(region: region) })
      case .anime: AnimePage(model: model, onOpen: model.openPGC) { model.openPGCFavorites(cinema: false) }
      case .cinema: CinemaPage(model: model, onOpen: model.openPGC) { model.openPGCFavorites(cinema: true) }
      case .live: M5LivePage(model: model)
      case .article:
        ArticleBrowserPage(service: model.service, refreshToken: model.refreshToken,
          initialSection: ProcessInfo.processInfo.arguments.contains("article:ranking") ? -2 : ProcessInfo.processInfo.arguments.contains("article:partition") ? 1 : -1,
          openArticle: { model.openOverlay(.article($0.id)) }, onUser: { model.openOverlay(.userSpace($0)) })
      case .message:
        M6MessagePage(model: model, onUser: { model.openOverlay(.userSpace($0)) }, onVideo: { model.open(Video(bvid: $0, title: "视频")) })
      case .downloads: M7DownloadsPage(model: model)
      }
    }
  }
}

extension AppModel {
  /// The main window's content is a playback page: the video page, an episode or a live room
  /// (including the moment it opens), not the placeholder shown while the picture plays in the
  /// mini window or the standalone window. Mirrors `ShellContent.pageContent`.
  var showsPlaybackPage: Bool {
    if usesUIFixtures && !fixtureReady { return false }
    if mainShowsPlayer && playbackElsewhere { return false }
    if mainShowsPlayer && selected != nil { return true }
    switch currentOverlay {
    case .pgc, .live, .video: return true
    default: return false
    }
  }
}

/// The main window's sidebar as the shell lays it out, shared with the window buttons and ⌃⌘S.
@MainActor final class ShellSidebarState: ObservableObject {
  static let shared = ShellSidebarState()
  /// The playback page keeps the sidebar out of the layout (the 隐藏侧边栏 preference is untouched).
  @Published var suppressed = false
  /// ⌃⌘S on the playback page: the sidebar floats over the page for now.
  @Published var peeking = false
}

/// Shell preferences kept outside the settings catalog.
enum ShellPreferences {
  /// ⌃⌘S 显示 / 隐藏侧边栏.
  static let sidebarHiddenKey = "Manping.sidebarHidden"
}

/// The standalone playback window: the same toolbar as the main window's playback page (title,
/// the page's actions, 在独立窗口播放, 右侧栏) without 返回 / 前进 and search, then the page.
struct DetachedPlaybackContent: View {
  @ObservedObject var model: AppModel
  var body: some View {
    DetachedPlaybackLayout(model: model)
      .preferredColorScheme(model.theme.colorScheme).tint(Theme.accent)
      .environment(\.cardActions, CardActions(model: model))
      .persistentAppStorage()
      .appDialogs(model: model, inDetachedWindow: true)
  }
}

private struct DetachedPlaybackLayout: View {
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    // In full screen only the picture, the danmaku and the controls remain.
    let immersive = model.playbackWindowFullScreen
    VStack(spacing: 0) {
      Color.clear.frame(height: immersive ? 0 : Theme.toolbarHeight)
      page.frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.immersivePlayback, immersive)
    }
    .overlayPreferenceValue(PageToolbarKey.self, alignment: .top) { item in
      if !immersive {
        HStack(spacing: 12) {
          PageToolbarTitle(item: item, fallback: "").layoutPriority(-1)
          Spacer(minLength: 8)
          if let accessory = item?.accessory { HStack(spacing: 8) { accessory }.fixedSize() }
        }
        .foregroundStyle(Theme.text(scheme))
        // The window's buttons sit at the leading edge of this band.
        .padding(.leading, 16 + 72).padding(.trailing, 16)
        .frame(height: Theme.toolbarHeight)
      }
    }
    // The same stage and panel as the main window's playback page, on the window's backdrop.
    .background(immersive ? Theme.stage : Theme.backdrop(scheme))
    .ignoresSafeArea(.container, edges: .top)
  }
  @ViewBuilder private var page: some View {
    if let video = model.selected {
      VideoDetailPage(model: model, player: model.player, video: video).id(ObjectIdentifier(model.player))
    } else if let playback = model.pgcPlayback, let selection = model.pgcSelection {
      PGCPlayerPage(model: model, playback: playback, selection: selection).id(ObjectIdentifier(playback.player))
    } else if let live = model.livePlayback {
      LivePlayerPage(model: model, live: live).id(ObjectIdentifier(live.player))
    }
  }
}
