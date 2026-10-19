import AppKit
import ManpingCore
import SwiftUI

struct M3UserSpacePage: View {
  @ObservedObject var model: AppModel
  let mid: Int64
  @StateObject private var library: LibraryModel
  @StateObject private var dynamics: M3UserDynamicsModel
  @StateObject private var relations: UserRelationsModel
  @ObservedObject private var pins = PinnedUserStore.shared
  @State private var selection = SpacePageSelection()
  @State private var keyword = ""
  @State private var order: SpaceArchiveOrder = .pubdate
  @State private var tid = 0
  @State private var descending = false
  @State private var debugDetailOpened = false
  @State private var regionalSearchRevision: UUID?
  @Environment(\.colorScheme) private var scheme

  init(model: AppModel, mid: Int64) {
    self.model = model; self.mid = mid
    _library = StateObject(wrappedValue: LibraryModel(model: model))
    _dynamics = StateObject(wrappedValue: M3UserDynamicsModel(model: model))
    _relations = StateObject(wrappedValue: UserRelationsModel(service: model.service))
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    if let index = args.firstIndex(of: "--ui-space-tab"), args.indices.contains(index + 1) {
      _selection = State(initialValue: SpacePageSelection(tab: args[index + 1]))
    }
    #endif
  }
  private var profile: LibraryUser? { library.profile?.id == mid ? library.profile : nil }
  private var query: SpaceArchiveQuery { SpaceArchiveQuery(mid: mid, order: order, tid: tid, keyword: selection.submitted) }
  private var loadID: String { "\(mid):\(selection.tab):\(query.contextKey):\(selection.selectedCollection?.id ?? ""):\(descending):\(selection.searchRevision):\(model.refreshToken)" }
  var body: some View {
    VStack(spacing: 0) {
      if selection.tab == "动态" { header; tabs; M3DynamicsResults(dynamics: dynamics, model: model) }
      else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            header
            tabs
            if let collection = selection.selectedCollection { collectionDetail(collection) }
            else if selection.tab == "主页" { home }
            else if selection.tab == "合集和系列" { collectionGrid }
            else { archives }
          }.cardGridContent().padding(Theme.gridPadding).frame(maxWidth: .infinity, alignment: .leading)
        }.cardGrid()
      }
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: profile?.name ?? "UID \(mid)", refresh: refresh) {
        Button { if let profile { pins.toggle(profile) } } label: {
          ToolbarIcon(pins.contains(mid) ? "pin.fill" : "pin")
        }.toolbarIconStyle().disabled(profile == nil).help(pins.contains(mid) ? "取消固定" : "固定")
      }
      .task(id: loadID) { await loadCurrent() }
      .task(id: "\(mid):\(library.identityVersion)") { await library.loadSpaceProfile(mid: mid) }
      .task(id: "\(mid):\(relations.identityVersion)") { await relations.load(mid: mid) }
      .task(id: mid) { applyRegionalSearch() }
      .onChange(of: library.collections) { _, items in
        #if DEBUG
        if DebugUIFixtures.enabled, ProcessInfo.processInfo.arguments.contains("--ui-space-detail"),
          !debugDetailOpened, let first = items.first {
          debugDetailOpened = true; selection.selectedCollection = first
        }
        #endif
      }
      .onChange(of: model.regionalSearchRequest?.revision) { _, _ in applyRegionalSearch() }
      .onDisappear { library.cancel(); library.stopSpaceProfile(); dynamics.cancel(); relations.cancel() }
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .bottom, spacing: 18) {
        CachedImage(url: profile?.avatar).frame(width: 84, height: 84).clipShape(Circle())
          // A ring in the page colour separates the avatar from the banner behind it.
          .overlay(Circle().strokeBorder(Theme.panel(scheme), lineWidth: 3))
          .overlay(alignment: .bottomTrailing) {
            if let type = profile?.officialType, type >= 0 {
              Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(Theme.highlight)
            }
          }
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 8) {
            Text(profile?.name ?? "UID \(mid)").font(Theme.Font.title)
            if let profile {
              Text("Lv\(profile.level)").font(Theme.Font.caption2.weight(.bold)).foregroundStyle(Theme.highlight)
              if profile.isVIP { Text("大会员").font(Theme.Font.caption2).foregroundStyle(Theme.live) }
            }
          }
          if let official = profile?.officialDescription, !official.isEmpty {
            Text(official).font(Theme.Font.caption).foregroundStyle(Theme.highlight)
          }
          Text(profile?.signature ?? "正在加载资料…").font(Theme.Font.body).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(2)
        }
        Spacer()
        M3UserFollowButton(mid: mid, relations: relations, model: model, prominent: true)
        Button { if let profile { pins.toggle(profile) } } label: {
          Label(pins.contains(mid) ? "已固定" : "固定", systemImage: pins.contains(mid) ? "pin.fill" : "pin")
        }.buttonStyle(AppButtonStyle())
      }
      HStack(spacing: 26) {
        stat(profile?.following, "关注", route: model.accountMID == mid ? .following(mid) : nil)
        stat(profile?.followers, "粉丝", route: model.accountMID == mid ? .followers(mid) : nil)
        stat(library.overview?.likes ?? profile?.likes, "获赞")
        stat(library.overview?.plays ?? profile?.plays, "播放")
      }.padding(.leading, 102)
      if let error = library.profileError { InlineErrorText(message: error) }
      if let error = relations.errors[mid] { InlineErrorText(message: error) }
    }.padding(.top, 50).padding(.horizontal, 16).padding(.bottom, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(alignment: .top) {
        ZStack {
          Theme.panel(scheme)
          if let banner = profile?.banner {
            CachedImage(url: banner).frame(height: 210).clipped()
            LinearGradient(colors: [Theme.panel(scheme).opacity(0.2), Theme.panel(scheme)], startPoint: .top, endPoint: .bottom)
          }
        }.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
      }
  }
  @ViewBuilder private func stat(_ value: Int?, _ label: String, route: AppModel.OverlayRoute? = nil) -> some View {
    if let value {
      if let route {
        Button { model.openOverlay(route) } label: { statLabel(value, label) }.buttonStyle(.plain)
      } else { statLabel(value, label) }
    }
  }
  private func statLabel(_ value: Int, _ label: String) -> some View {
    HStack(spacing: 5) { Text(spaceCount(value)).font(Theme.Font.headline); Text(label).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)) }
  }
  private var tabs: some View {
    SegmentedTabs(options: [("主页", "主页"), ("投稿", countTitle("投稿", library.overview?.archiveCount ?? profile?.videos)),
      ("合集和系列", countTitle("合集和系列", library.overview?.collectionCount)), ("动态", "动态")], selection: Binding(
        get: { selection.tab }, set: { selection.tab = $0; selection.selectedCollection = nil }))
  }
  private func countTitle(_ text: String, _ count: Int?) -> String { count.map { "\(text) \($0)" } ?? text }
  private var home: some View {
    VStack(alignment: .leading, spacing: 22) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 20) {
          pinnedSection.frame(minWidth: 260, maxWidth: 340)
          masterpieceSection.frame(minWidth: 500, maxWidth: .infinity)
        }
        VStack(alignment: .leading, spacing: 20) { pinnedSection; masterpieceSection }
      }
      HStack {
        Text("最新投稿").font(Theme.Font.section)
        Spacer()
        Button("查看全部 \(library.overview?.archiveCount ?? library.total) 个投稿 ›") { selection.tab = "投稿" }.buttonStyle(.plain).foregroundStyle(Theme.accentText(scheme))
      }
      videoGrid(Array(library.entries.prefix(4)))
      readState
    }
  }
  @ViewBuilder private var pinnedSection: some View {
    if let pinned = library.overview?.pinned, !pinned.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("置顶视频").font(Theme.Font.section)
        videoGrid(pinned).overlay(alignment: .topLeading) {
          Text("置顶").font(Theme.Font.caption2.bold()).padding(6).background(Theme.highlight, in: Capsule()).padding(8)
        }
      }
    }
  }
  @ViewBuilder private var masterpieceSection: some View {
    if let works = library.overview?.masterpieces, !works.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("代表作").font(Theme.Font.section)
        videoGrid(Array(works.prefix(3)))
      }
    }
  }
  private var archives: some View {
    VStack(alignment: .leading, spacing: 16) {
      if library.spacePage?.provider == .appCursor {
        HStack(spacing: 12) {
          Text("已切换到备用列表：仅支持「最新发布」和「最多播放」，分区筛选和「最多收藏」暂不可用。登录后通常可以恢复。")
            .font(Theme.Font.caption)
          Spacer()
          Button("重试完整列表") { Task { await library.retryFullSpace() } }.buttonStyle(AppButtonStyle(size: .small))
        }.foregroundStyle(Theme.highlight).padding(12).background(Theme.highlight.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
      }
      HStack(spacing: 8) {
        HStack(spacing: 2) {
          ForEach(SpaceArchiveOrder.allCases, id: \.self) { item in
            let supported = (library.spacePage?.availableOrders ?? SpaceArchiveOrder.allCases).contains(item)
            Button(item.title) { order = item }
              .font(Theme.Font.caption.weight(actualOrder == item ? .semibold : .regular))
              .padding(.horizontal, 12).frame(height: 26)
              .background(actualOrder == item ? Theme.fillHover(scheme) : .clear, in: Capsule())
              .foregroundStyle(supported ? Theme.text(scheme) : Theme.tertiaryText(scheme))
              .buttonStyle(.plain).disabled(!supported)
          }
        }.padding(3).background(Theme.fill(scheme), in: Capsule())
        Spacer()
        TextField("在 TA 的投稿中搜索", text: $keyword).textFieldStyle(AppTextFieldStyle()).frame(maxWidth: 240).onSubmit(submit)
        if !selection.submitted.isEmpty { Button("清除") { keyword = ""; selection.submitted = "" } }
        playButton
      }
      HStack(spacing: 8) {
        Button("全部") { tid = 0 }.buttonStyle(ChipStyle(selected: (library.spacePage?.tid ?? tid) == 0))
        ForEach(library.spacePage?.partitions ?? []) { part in
          Button("\(part.name) \(part.count)") { tid = part.id }.buttonStyle(ChipStyle(selected: tid == part.id))
        }
        if library.spacePage?.supportsPartitions == false { Text("分区筛选不可用").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)) }
      }.disabled(library.spacePage?.supportsPartitions == false)
      playNotice
      videoGrid(library.entries)
      readState
    }
  }
  private var actualOrder: SpaceArchiveOrder { library.spacePage?.order ?? order }
  private var playButton: some View {
    Button(library.playAllProgress ? "正在收集…" : "全部播放") { library.playAll(play) }
      .buttonStyle(SpacePlayButtonStyle()).disabled(library.playAllProgress || library.isLoading)
  }
  @ViewBuilder private var playNotice: some View {
    if let notice = library.playAllNotice {
      HStack {
        InlineErrorText(message: notice)
        if !library.partialVideos.isEmpty {
          Button("播放已加载的 \(library.partialVideos.count) 个") { library.playLoaded(play) }.buttonStyle(AppButtonStyle(size: .small))
        }
      }
    }
  }
  private var collectionGrid: some View {
    VStack(alignment: .leading, spacing: 20) {
      ForEach([SpaceCollectionKind.season, .series], id: \.self) { kind in
        let items = library.collections.filter { $0.kind == kind }
        if !items.isEmpty {
          Text(kind == .season ? "合集" : "系列").font(Theme.Font.section)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
            ForEach(items) { collection in
              Button { selection.selectedCollection = collection; descending = false } label: {
                VStack(alignment: .leading, spacing: 8) {
                  ZStack {
                    if kind == .season {
                      RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.fill(scheme)).padding(.horizontal, 10).offset(y: -8)
                      RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.card(scheme)).padding(.horizontal, 5).offset(y: -4)
                    }
                    CachedImage(url: collection.cover).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                  }.overlay(alignment: .bottomTrailing) { Text("\(collection.count) \(kind == .season ? "集" : "个视频")").font(Theme.Font.caption2).padding(6).background(Theme.panel(scheme), in: Capsule()).padding(6) }
                    .overlay(alignment: .topLeading) { if kind == .series { Text("系列").font(Theme.Font.caption2).padding(6).background(Theme.panel(scheme), in: Capsule()).padding(6) } }
                  Text(collection.title).font(Theme.Font.headline).lineLimit(2)
                }.foregroundStyle(Theme.text(scheme)).cardHover()
              }.buttonStyle(.plain)
            }
          }
        }
      }
      readState
    }
  }
  private func collectionDetail(_ collection: SpaceCollection) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Button("‹ 返回合集和系列") { selection.selectedCollection = nil }.buttonStyle(.plain).foregroundStyle(Theme.accentText(scheme))
      HStack(spacing: 16) {
        CachedImage(url: collection.cover).frame(width: 160, height: 90).clipped().clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        VStack(alignment: .leading, spacing: 8) {
          Text(collection.title).font(Theme.Font.title)
          Text("\(collection.kind == .season ? "合集" : "系列") · \(collection.count) 个视频").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
          HStack { playButton; SegmentedTabs(options: [(false, "正序"), (true, "倒序")], selection: $descending) }
        }
      }
      playNotice
      LazyVStack(spacing: 6) {
        ForEach(Array(library.entries.enumerated()), id: \.element.id) { index, entry in
          Button { model.open(entry) } label: {
            HStack(spacing: 12) {
              Text("\(index + 1)").font(Theme.Font.caption.monospacedDigit()).frame(width: 24)
              CachedImage(url: entry.cover).frame(width: 96, height: 54).clipped().clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))
              VStack(alignment: .leading, spacing: 5) { Text(entry.title).font(Theme.Font.headline); Text(entry.subtitle).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)) }
              Spacer()
              if isPlaying(entry) { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accentText(scheme)) }
            }.padding(8).background(isPlaying(entry) ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
          }.buttonStyle(.plain)
        }
      }
      readState
    }
  }
  private func isPlaying(_ entry: LibraryEntry) -> Bool {
    guard case .video(let video) = entry.destination else { return false }
    return model.selected?.id == video.id
  }
  private func videoGrid(_ entries: [LibraryEntry]) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
      ForEach(entries) { entry in
        if case .video(let video) = entry.destination { VideoCard(video: video) { model.open(video) } }
      }
    }
  }
  @ViewBuilder private var readState: some View {
    if let error = library.error {
      PageStateView(.error, title: "没能加载内容", message: error, actionTitle: "重试") { Task { await library.loadNext() } }
    } else if library.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
    else if library.hasMore && selection.tab != "主页" { LoadMoreFooter(isLoading: library.isLoading || library.playAllProgress) { Task { await library.loadNext() } } }
    else if library.entries.isEmpty && library.collections.isEmpty { Text("还没有可显示的内容").font(Theme.Font.body).foregroundStyle(Theme.secondaryText(scheme)).padding() }
  }
  private func loadCurrent() async {
    if selection.tab == "动态" { library.cancel(); await dynamics.load(mid: mid); return }
    dynamics.cancel()
    await library.load(selection.contentMode(mid: mid, order: order, tid: tid, descending: descending))
  }
  private func play(_ handoff: PlaylistHandoff) async {
    do { try await model.openPlaylist(handoff) } catch is CancellationError {} catch { model.error = error.localizedDescription }
  }
  private func refresh() {
    relations.refresh(mid: mid)
    Task { await library.loadSpaceProfile(mid: mid, force: true) }
    Task { await loadCurrent() }
  }
  private func submit() { selection.submit(keyword, library: library) }
  private func applyRegionalSearch() {
    guard let request = model.regionalSearchRequest, request.route == .userSpace(mid), regionalSearchRevision != request.revision else { return }
    regionalSearchRevision = request.revision; keyword = request.keyword; submit()
  }
}

/// Primary actions inside scrolling content use a solid fill, not a floating glass surface.
private struct SpacePlayButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(Theme.Font.body.weight(.semibold)).lineLimit(1)
      .padding(.horizontal, 14).frame(height: Theme.controlHeight)
      .foregroundStyle(isEnabled ? Theme.onAccent : Theme.disabledText(scheme))
      .background(isEnabled ? Theme.accent : Theme.fill(scheme), in: Capsule())
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
  }
}

private func spaceCount(_ value: Int) -> String {
  value >= 10_000 ? String(format: "%.1f 万", Double(value) / 10_000) : String(value)
}

@MainActor private final class M3UserDynamicsModel: ObservableObject {
  @Published private(set) var items: [RPCDynamic] = []
  @Published private(set) var loading = false
  @Published private(set) var hasMore = true
  @Published private(set) var error: String?
  private let service: BiliService
  private let rpc: (any BiliRPCService)?
  private var mid: Int64?
  private var offset = ""
  private var generation = UUID()
  private var flight: Task<Void, Never>?
  private var observer: Task<Void, Never>?
  private var identity: AuthIdentityEvent?

  init(model: AppModel) {
    service = model.service; rpc = try? model.standardRPCService()
    let service = self.service
    observer = Task { [weak self] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let previous = self.identity; self.identity = event
        if let previous, previous.epoch != event.epoch || previous.identityRevision != event.identityRevision,
          let mid = self.mid { await self.load(mid: mid) }
      }
    }
  }
  deinit { observer?.cancel(); flight?.cancel() }
  func cancel() { generation = UUID(); flight?.cancel(); flight = nil; loading = false; mid = nil }
  func load(mid: Int64) async {
    cancel(); self.mid = mid; offset = ""; items = []; error = nil; hasMore = true
    await loadNext()
  }
  func loadNext() async {
    guard !loading, hasMore, let mid else { return }
    let revision = generation; let offset = self.offset
    loading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let snapshot = await service.authSnapshot()
        guard let rpc else { throw BiliError.dependency("无法初始化用户动态服务") }
        let page = try await rpc.dynamics(.userAll(mid: mid, offset: offset))
        let current = await service.authSnapshot()
        try check(revision)
        guard snapshot.epoch == current.epoch, snapshot.identityRevision == current.identityRevision else {
          throw CancellationError()
        }
        var known = Set(items.map(\.id))
        items += page.items.filter { known.insert($0.id).inserted }
        self.offset = page.historyOffset
        hasMore = page.hasMore && !page.historyOffset.isEmpty && page.historyOffset != offset
      } catch is CancellationError {
      } catch {
        guard generation == revision else { return }
        self.error = error.localizedDescription
      }
      guard generation == revision else { return }
      loading = false; flight = nil
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func check(_ revision: UUID) throws {
    try Task.checkCancellation()
    guard generation == revision else { throw CancellationError() }
  }
}

private struct M3DynamicsResults: View {
  @ObservedObject var dynamics: M3UserDynamicsModel
  @ObservedObject var model: AppModel
  var body: some View {
    Group {
      if dynamics.items.isEmpty && dynamics.loading {
        ProgressView("正在加载动态…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if dynamics.items.isEmpty, let error = dynamics.error {
        PageStateView(.error, title: "没能加载动态", message: error, actionTitle: "重试") {
          Task { await dynamics.loadNext() }
        }
      } else if dynamics.items.isEmpty {
        PageStateView(title: "动态是空的", message: "该用户还没有可显示的动态。")
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(dynamics.items, id: \.id) { item in M3DynamicCard(item: item, model: model) }
            if let error = dynamics.error {
              PageStateView(.error, title: "没能加载更多动态", message: error, actionTitle: "重试") {
                Task { await dynamics.loadNext() }
              }
            } else if dynamics.hasMore {
              if dynamics.loading { ProgressView().padding(20) }
              else {
                Button("加载更多") { Task { await dynamics.loadNext() } }
                  .padding(12).buttonStyle(ChromeButtonStyle())
                  .onAppear { Task { await dynamics.loadNext() } }
              }
            }
          }.frame(maxWidth: 760).padding(Theme.gridPadding).frame(maxWidth: .infinity)
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct M3DynamicCard: View {
  let item: RPCDynamic
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(item.timeLabel).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      if !item.text.isEmpty { MomentRichText(text: item.text, emotes: item.emotes) }
      content
      HStack(spacing: 24) {
        Label("\(item.reposts)", systemImage: "arrowshape.turn.up.right")
        Label("\(item.replies)", systemImage: "bubble.right")
        Label("\(item.likes)", systemImage: "hand.thumbsup")
        Spacer()
        Button("查看动态") { openDynamic() }.buttonStyle(AppButtonStyle(role: .plain, size: .small))
      }.font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface(scheme)
  }
  @ViewBuilder private var content: some View {
    switch item.content {
    case .video(let card):
      if case .video(let video) = LibraryEntry.rpcVideo(card).destination {
        VideoCard(video: video) { model.open(video) }.frame(maxWidth: 400)
      }
    case .images(let images):
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(3, max(1, images.count))), spacing: 8) {
        ForEach(Array(images.enumerated()), id: \.offset) { _, url in
          Button { NSWorkspace.shared.open(url) } label: {
            CachedImage(url: url).aspectRatio(1, contentMode: .fit).clipped()
              .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
          }.buttonStyle(.plain).help("查看原图")
        }
      }.frame(maxWidth: 600)
    case .episode(let episode):
      linkedContent(title: episode.title, cover: episode.cover,
        url: URL(string: "https://www.bilibili.com/bangumi/play/ep\(episode.episodeID)"))
    case .article(let article):
      linkedContent(title: article.title, cover: article.covers.first,
        url: URL(string: "https://www.bilibili.com/read/cv\(article.id)"))
    case .forward(let original):
      VStack(alignment: .leading, spacing: 8) {
        Text(original.author.map { "@\($0.name)" } ?? "转发动态").font(Theme.Font.headline)
        MomentRichText(text: original.text, emotes: original.emotes)
        Button("查看原动态") {
          if let url = URL(string: "https://t.bilibili.com/\(original.id)") { NSWorkspace.shared.open(url) }
        }.buttonStyle(ChromeButtonStyle())
      }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    case .unsupported: Text("此类动态可在网页查看").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
    case .text: EmptyView()
    }
  }
  private func linkedContent(title: String, cover: URL?, url: URL?) -> some View {
    Button { if let url { model.openLibraryURL(url) } } label: {
      HStack(spacing: 12) {
        if cover != nil { CachedImage(url: cover).frame(width: 120, height: 76).clipped() }
        Text(title).font(Theme.Font.body).lineLimit(3)
        Spacer()
        Image(systemName: "arrow.up.right.square")
      }.padding(8).background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }.buttonStyle(.plain)
  }
  private func openDynamic() {
    if let url = URL(string: "https://t.bilibili.com/\(item.id)") { NSWorkspace.shared.open(url) }
  }
}
