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
  @State private var tab = "投稿"
  @State private var keyword = ""
  @State private var submitted = ""
  @State private var showingProfile = false
  @State private var showingSearch = false
  @State private var regionalSearchRevision: UUID?
  @Environment(\.colorScheme) private var scheme

  init(model: AppModel, mid: Int64) {
    self.model = model; self.mid = mid
    _library = StateObject(wrappedValue: LibraryModel(model: model))
    _dynamics = StateObject(wrappedValue: M3UserDynamicsModel(model: model))
    _relations = StateObject(wrappedValue: UserRelationsModel(service: model.service))
  }
  private var profile: LibraryUser? {
    if let user = library.profile, user.id == mid { return user }
    if let user = dynamics.profile, user.id == mid { return user }
    return nil
  }
  var body: some View {
    VStack(spacing: 0) {
      if showingSearch && submitted.isEmpty {
        HStack(spacing: 8) {
          TextField("搜索这位 UP 主的投稿", text: $keyword, prompt: Text("搜索这位 UP 主的投稿")).labelsHidden().textFieldStyle(AppTextFieldStyle()).onSubmit(submit)
          Button("搜索", action: submit).buttonStyle(AppButtonStyle(role: .primary))
        }.frame(maxWidth: 560).padding(.horizontal, Theme.gridPadding).padding(.top, 16)
      }
      if tab == "动态" && submitted.isEmpty {
        M3DynamicsResults(dynamics: dynamics, model: model)
      } else { LibraryResults(library: library, model: model) }
      if let error = relations.errors[mid], mid != relations.selfID {
        HStack(spacing: 8) {
          InlineErrorText(message: error)
          Spacer()
          Button("重试") { relations.refresh(mid: mid) }.buttonStyle(AppButtonStyle(size: .small))
        }.padding(.horizontal, Theme.gridPadding).padding(.vertical, 8).overlay(alignment: .top) { Hairline() }
      }
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: profile?.name ?? "UID \(mid)", subtitle: submitted.isEmpty ? nil : "搜索「\(submitted)」",
        segments: submitted.isEmpty ? AnyView(tabs) : nil, refresh: refresh) { headerControls }
      .task(id: "\(mid):\(tab):\(submitted):\(model.refreshToken)") {
        if tab == "动态" && submitted.isEmpty {
          library.cancel(); await dynamics.load(mid: mid)
        } else {
          dynamics.cancel(); await library.load(.space(mid, submitted))
        }
      }
      .task(id: "\(mid):\(relations.identityVersion)") { await relations.load(mid: mid) }
      .task(id: mid) { applyRegionalSearch() }
      .onChange(of: model.regionalSearchRequest?.revision) { _, _ in applyRegionalSearch() }
      .onDisappear { library.cancel(); dynamics.cancel(); relations.cancel() }
  }
  private var tabs: some View {
    SegmentedTabs(options: [("投稿", "投稿"), ("动态", "动态")], selection: Binding(
      get: { tab }, set: { tab = $0; showingSearch = false }))
  }
  private func refresh() {
    relations.refresh(mid: mid)
    Task {
      if tab == "动态" && submitted.isEmpty { await dynamics.load(mid: mid) }
      else { await library.refresh() }
    }
  }
  @ViewBuilder private var headerControls: some View {
    if !submitted.isEmpty {
      Button(action: exitSearch) { Label("退出搜索", systemImage: "xmark") }.toolbarActionStyle()
    }
    ToolbarIconGroup {
      Button { showingProfile.toggle() } label: { ToolbarGroupIcon("person.text.rectangle") }
        .help("UP 主资料").accessibilityLabel("UP 主资料")
        .popover(isPresented: $showingProfile, arrowEdge: .bottom) {
          M3UserProfileFlyout(user: profile, mid: mid, isSignedInAccount: model.accountMID == mid) { route in
            showingProfile = false
            model.openOverlay(route)
          }.padding(16).frame(width: 352)
        }
      if submitted.isEmpty {
        Button { showingSearch.toggle(); tab = "投稿" } label: { ToolbarGroupIcon("magnifyingglass") }
          .help("搜索投稿").accessibilityLabel("搜索投稿")
      }
      Button { if let profile { pins.toggle(profile) } } label: {
        ToolbarGroupIcon(pins.contains(mid) ? "pin.fill" : "pin")
          .foregroundStyle(pins.contains(mid) ? Theme.accentText(scheme) : Theme.text(scheme))
      }.disabled(profile == nil).help(pins.contains(mid) ? "从账号菜单取消固定" : "固定到账号菜单")
        .accessibilityLabel(pins.contains(mid) ? "取消固定" : "固定")
    }
    M3UserFollowButton(mid: mid, relations: relations, model: model)
  }
  private func submit() {
    let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    submitted = query; tab = "投稿"; showingSearch = false
  }
  private func exitSearch() { keyword = ""; submitted = ""; showingSearch = false }
  private func applyRegionalSearch() {
    guard let request = model.regionalSearchRequest, request.route == .userSpace(mid),
      regionalSearchRevision != request.revision else { return }
    regionalSearchRevision = request.revision
    keyword = request.keyword
    if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { exitSearch() }
    else { submit() }
  }
}

private struct M3UserProfileFlyout: View {
  let user: LibraryUser?
  let mid: Int64
  /// This is the signed-in account's own space. Only then are 粉丝 and 关注 links: the lists of
  /// other users are not read (they are often private and only their first pages are public),
  /// so their figures are plain numbers.
  var isSignedInAccount = false
  /// Opens the signed-in account's follower or following list.
  var open: (AppModel.OverlayRoute) -> Void = { _ in }
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let user {
        HStack(spacing: 12) {
          CachedImage(url: user.avatar).frame(width: 48, height: 48).clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
              if user.isVIP, let badge = profileAsset("vip") {
                Image(nsImage: badge).resizable().scaledToFit().frame(width: 16, height: 16)
              }
            }
          ForEach([(user.followers, "粉丝"), (user.following, "关注"), (user.likes, "获赞")], id: \.1) { value in
            let route: AppModel.OverlayRoute? = !isSignedInAccount ? nil
              : value.1 == "粉丝" ? .followers(mid) : value.1 == "关注" ? .following(mid) : nil
            let figure = VStack(spacing: 4) {
              Text(profileCount(value.0)).font(Theme.Font.headline).foregroundStyle(Theme.text(scheme))
              Text(value.1).font(Theme.Font.caption).foregroundStyle(route == nil ? Theme.secondaryText(scheme) : Theme.accentText(scheme))
            }.frame(maxWidth: .infinity).padding(.vertical, 4)
            if let route {
              Button { open(route) } label: { figure }.buttonStyle(ChromeButtonStyle()).help("查看\(value.1)列表")
            } else {
              figure.accessibilityElement(children: .combine)
            }
          }
        }
        HStack(spacing: 8) {
          Text(user.name).font(Theme.Font.body.weight(.semibold))
          if let level = profileAsset("level_\(min(6, max(0, user.level)))", directory: "Level") {
            Image(nsImage: level).resizable().scaledToFit().frame(width: 24, height: 12)
              .accessibilityLabel("等级 \(user.level)")
          }
          Text("\(mid)").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
            .textSelection(.enabled).padding(.horizontal, 4).padding(.vertical, 2)
            .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
        }
        Text(user.signature.isEmpty ? "还没有个人简介" : user.signature).font(Theme.Font.caption)
          .foregroundStyle(Theme.secondaryText(scheme)).lineLimit(2)
      } else { ProgressView("正在加载用户资料…") }
    }.foregroundStyle(Theme.text(scheme))
  }
}

private func profileCount(_ value: Int) -> String {
  if value >= 100_000_000 { return String(format: "%.1f 亿", Double(value) / 100_000_000) }
  if value >= 10_000 { return String(format: "%.1f 万", Double(value) / 10_000) }
  return String(value)
}

private func profileAsset(_ name: String, directory: String? = nil) -> NSImage? {
  guard let path = Bundle.module.path(forResource: name, ofType: "png", inDirectory: directory) else { return nil }
  return NSImage(contentsOfFile: path)
}

@MainActor private final class M3UserDynamicsModel: ObservableObject {
  @Published private(set) var items: [RPCDynamic] = []
  @Published private(set) var profile: LibraryUser?
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
    cancel(); self.mid = mid; offset = ""; items = []; profile = nil; error = nil; hasMore = true
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
        if profile == nil {
          let user = try await service.libraryProfile(mid: mid)
          try check(revision); profile = user
        }
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
