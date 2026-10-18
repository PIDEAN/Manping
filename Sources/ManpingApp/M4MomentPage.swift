import ManpingCore
import SwiftUI

struct M4MomentPage: View {
  @ObservedObject var model: AppModel
  @StateObject private var feed: MomentFeedModel
  @StateObject private var comments: M4CommentModel
  @AppStorage("moment.sidebarWidth") private var sidebarWidth = 240.0
  @AppStorage("moment.sidebarHidden") private var sidebarHidden = false
  @State private var commentsPresented = false
  @State private var commentTask: Task<Void, Never>?
  @State private var initialized = false
  @Environment(\.colorScheme) private var scheme
  init(model: AppModel) {
    self.model = model
    _feed = StateObject(wrappedValue: MomentFeedModel(model: model))
    _comments = StateObject(wrappedValue: M4CommentModel(model: model))
  }
  var body: some View {
    HStack(spacing: 0) {
      if feed.section == .comprehensive && !sidebarHidden {
        VStack(spacing: 0) {
          sidebar
        }.frame(width: min(400, max(180, sidebarWidth))).transition(.move(edge: .leading).combined(with: .opacity))
        SidebarResizeHandle(width: $sidebarWidth, range: 180...400)
      }
      VStack(spacing: 0) {
        results
        if let error = feed.mutationError {
          InlineErrorText(message: error).padding(.horizontal, Theme.gridPadding).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Hairline() }
        }
      }
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: "动态", segments: AnyView(sectionTabs),
        refresh: { closeComments(); Task { await feed.refresh() } }) {
        if feed.section == .comprehensive { SidebarToggleButton(hidden: $sidebarHidden) }
      }
      .overlay {
        if commentsPresented {
          ZStack(alignment: .trailing) {
            Theme.scrim(scheme).opacity(0.4).contentShape(Rectangle()).onTapGesture(perform: closeComments)
            M4CommentPanel(comments: comments, model: model, close: closeComments).padding(12)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
      }
      .animation(.snappy(duration: 0.28), value: commentsPresented)
      .task(id: model.refreshToken) {
        if initialized { await feed.refresh() }
        else {
          initialized = true
          await feed.start(section: fixtureLaunchTarget == nil ? nil : .comprehensive)
          if fixtureLaunchTarget == "moment:comments", let first = feed.items.first {
            openComments(first)
          }
        }
      }
      .onChange(of: feed.identityVersion) { _, _ in closeComments() }
      .onDisappear { feed.cancel(); closeComments() }
      .onExitCommand { if commentsPresented { closeComments() } }
  }
  private var sectionTabs: some View {
    SegmentedTabs(options: MomentFeedSection.allCases.map { ($0, $0.rawValue) }, selection: Binding(
      get: { feed.section }, set: { section in closeComments(); Task { await feed.select(section: section) } }))
  }
  private var sidebar: some View {
    ScrollView {
      VStack(spacing: 2) {
        Button { closeComments(); Task { await feed.selectUser(nil) } } label: {
          HStack(spacing: 10) {
            Image(systemName: "square.stack").font(.system(size: 13)).frame(width: 24)
            Text("全部动态").font(Theme.Font.body)
            Spacer()
          }.padding(.horizontal, 10).frame(height: 38)
        }.buttonStyle(SidebarRowStyle(selected: feed.selectedUserID == nil))
        ForEach(feed.users) { user in
          Button { closeComments(); Task { await feed.selectUser(user.id) } } label: {
            HStack(spacing: 10) {
              CachedImage(url: user.avatar).frame(width: 24, height: 24).clipShape(Circle())
              Text(user.name).font(Theme.Font.body).lineLimit(1)
              Spacer(minLength: 4)
              if user.hasUnread && !feed.readUsers.contains(user.id) { Circle().fill(Theme.live).frame(width: 7, height: 7) }
            }.padding(.horizontal, 10).frame(height: 38)
          }.buttonStyle(SidebarRowStyle(selected: feed.selectedUserID == user.id))
        }
      }.padding(.horizontal, 10).padding(.bottom, 12)
    }
  }
  private var results: some View {
    Group {
      if feed.items.isEmpty && feed.loading {
        PageStateView(.loading, title: "正在加载动态…")
      } else if feed.items.isEmpty, let error = feed.error {
        PageStateView(.error, title: "没能加载动态", message: error, actionTitle: "重试") {
          Task { await feed.loadNext() }
        }
      } else if feed.items.isEmpty {
        PageStateView(title: "动态是空的", message: "关注的 UP 主发布新内容后会出现在这里。", icon: "person.2")
      } else {
        ScrollView {
          if feed.section == .video {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
              ForEach(feed.items, id: \.id) { item in
                MomentVideoCard(item: item, feed: feed, model: model) { openComments(item) }
              }
            }.padding(Theme.gridPadding)
          } else {
            LazyVStack(spacing: 12) {
              ForEach(feed.items, id: \.id) { item in
                MomentFullCard(item: item, feed: feed, model: model) { openComments(item) }
              }
            }.frame(maxWidth: 760).padding(Theme.gridPadding).frame(maxWidth: .infinity)
          }
          if let error = feed.error {
            PageStateView(.error, title: "没能加载更多动态", message: error, actionTitle: "重试") { Task { await feed.loadNext() } }
          } else if feed.loading || feed.hasMore {
            LoadMoreFooter(isLoading: feed.loading) { Task { await feed.loadNext() } }
          }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func openComments(_ item: RPCDynamic) {
    guard let target = M4CommentTarget(dynamic: item) else { return }
    commentTask?.cancel(); commentsPresented = true
    commentTask = Task { await comments.select(target) }
  }
  private func closeComments() {
    commentTask?.cancel(); commentTask = nil; comments.cancel(); commentsPresented = false
  }
  private var fixtureLaunchTarget: String? {
    #if DEBUG
    guard model.usesUIFixtures else { return nil }
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--ui-page"), arguments.indices.contains(index + 1),
      ["moment:all", "moment:comments"].contains(arguments[index + 1]) else { return nil }
    return arguments[index + 1]
    #else
    return nil
    #endif
  }
}
