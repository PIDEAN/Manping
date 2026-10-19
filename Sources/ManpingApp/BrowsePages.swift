import ManpingCore
import SwiftUI

struct VideoPartitionPage: View {
  let service: BiliService
  let open: (Video) -> Void
  var refreshToken = 0
  /// A partition's ranking (排行榜), moved here from the old 流行 sidebar.
  let ranking: (Int) async throws -> BrowseVideoPage

  @StateObject private var directory = BrowsePartitionDirectory()
  @StateObject private var feed = BrowseFeedModel()
  @State private var selectedParentID: Int?
  @State private var selectedChildID: Int?
  @State private var showsRanking = false
  @State private var order: PartitionOrder = .recommended
  @Environment(\.colorScheme) private var scheme

  private var parent: VideoPartition? {
    directory.partitions.first(where: { $0.id == selectedParentID })
  }
  private var child: VideoPartition? {
    parent?.children.first(where: { $0.id == selectedChildID })
  }
  private var requestKey: String? {
    guard let parent else { return nil }
    if showsRanking { return "ranking:\(parent.id)" }
    return "partition:\(parent.id):\(selectedChildID ?? 0):\(String(describing: order))"
  }
  private var requestIdentity: String { "\(requestKey ?? "none"):\(refreshToken)" }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Hairline(axis: .vertical)
      VStack(spacing: 0) {
        if let parent {
          header(parent: parent)
          BrowseVideoResults(feed: feed, open: open).equatable()
        } else if directory.isLoading {
          PageStateView(.loading, title: "正在加载分区…")
        } else if let error = directory.error {
          PageStateView(.error,
            title: "没能加载分区", message: error, icon: "wifi.exclamationmark", actionTitle: "重试"
          ) { directory.load(service: service) }
        } else {
          PageStateView(.empty, title: "分区是空的", message: "服务器没有返回视频分区，稍后刷新试试。")
        }
      }
    }
    .pageToolbar(title: "分区", subtitle: parent.map { showsRanking ? "\($0.title) · 排行榜" : $0.title },
      refreshing: feed.state.isLoading && !feed.state.items.isEmpty, refresh: { feed.refresh() })
    .task(id: refreshToken) { directory.loadIfNeeded(service: service) }
    .onChange(of: directory.partitions.map(\.id)) { _, ids in
      if !ids.contains(selectedParentID ?? -1) {
        selectedParentID = ids.first
        selectedChildID = nil
        order = .recommended
      }
    }
    .onChange(of: parent?.children.map(\.id)) { _, ids in
      if let selectedChildID, !(ids ?? []).contains(selectedChildID) {
        self.selectedChildID = nil
        order = .recommended
      }
    }
    .task(id: requestIdentity) {
      guard let parent, let requestKey else { return }
      let chosenChild = child
      let chosenOrder = order
      if showsRanking {
        feed.activate(key: requestKey, refreshToken: refreshToken) { [parent, ranking] _ in try await ranking(parent.id) }
        return
      }
      feed.activate(key: requestKey, refreshToken: refreshToken) { [service, parent, chosenChild, chosenOrder] cursor in
        try await service.partitionFeed(
          rid: chosenChild?.id ?? parent.id, child: chosenChild != nil,
          order: chosenOrder, cursor: cursor)
      }
    }
    .onChange(of: refreshToken) { _, _ in directory.load(service: service) }
    .onDisappear {
      feed.deactivate()
      directory.cancel()
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        SidebarSectionTitle(title: "全部分区")
        ForEach(directory.partitions, id: \.id) { partition in
          Button {
            selectedParentID = partition.id
            selectedChildID = nil
            showsRanking = false
            order = .recommended
          } label: {
            HStack(spacing: 10) {
              PartitionSymbol(partition: partition)
              Text(partition.title).lineLimit(1)
              Spacer(minLength: 0)
            }.font(Theme.Font.body).padding(.horizontal, 10).frame(height: Theme.rowHeight)
          }.buttonStyle(
            SidebarRowStyle(selected: selectedParentID == partition.id)
          )
        }
        if directory.isLoading {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 12)
        }
        if let error = directory.error, !directory.partitions.isEmpty {
          Text("没能更新分区：\(error)").font(Theme.Font.caption)
            .foregroundStyle(Theme.secondaryText(scheme)).padding(.horizontal, 12)
            .textSelection(.enabled)
          Button("重试") { directory.load(service: service) }
            .buttonStyle(AppButtonStyle(size: .small)).padding(.horizontal, 10)
        }
      }.padding(.horizontal, 10).padding(.bottom, 12)
      }
    }.frame(width: Theme.secondarySidebarWidth)
  }

  private func header(parent: VideoPartition) -> some View {
    PageFilterBar {
      PartitionSymbol(partition: parent)
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          sectionButton("精选", childID: nil)
          Button { selectedChildID = nil; showsRanking = true } label: { Text("排行榜") }
            .buttonStyle(ChipStyle(selected: showsRanking))
          ForEach(parent.children, id: \.id) { child in
            sectionButton(child.title, childID: child.id)
          }
        }.padding(.horizontal, 4)
      }.scrollIndicators(.hidden)
      if selectedChildID != nil && !showsRanking {
        Menu {
          ForEach(Array(PartitionOrder.allCases), id: \.browseTitle) { value in
            Button {
              order = value
            } label: {
              if String(describing: order) == String(describing: value) {
                Label(value.browseTitle, systemImage: "checkmark")
              } else {
                Text(value.browseTitle)
              }
            }
          }
        } label: { MenuLabel(title: order.browseTitle) }.appMenuStyle()
      }
    }
  }

  private func sectionButton(_ title: String, childID: Int?) -> some View {
    Button {
      selectedChildID = childID
      showsRanking = false
      order = .recommended
    } label: {
      Text(title)
    }.buttonStyle(ChipStyle(selected: !showsRanking && selectedChildID == childID))
  }
}

private extension PartitionOrder {
  var browseTitle: String {
    switch self {
    case .recommended: "推荐"
    case .newest: "最新发布"
    case .views: "播放最多"
    case .danmaku: "弹幕最多"
    case .favorites: "收藏最多"
    case .replies: "评论最多"
    }
  }
}

/// Equatable on the feed alone (callers pass `.equatable()`): `open` is always the app model's
/// `open`, so an unrelated AppModel change that re-renders the page does not re-render the grid
/// and its visible cards. The feed's own changes still update it through `@ObservedObject`.
struct BrowseVideoResults: View, Equatable {
  @ObservedObject var feed: BrowseFeedModel
  let open: (Video) -> Void
  private let feedID: ObjectIdentifier

  init(feed: BrowseFeedModel, open: @escaping (Video) -> Void) {
    _feed = ObservedObject(wrappedValue: feed)
    self.open = open
    feedID = ObjectIdentifier(feed)
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.feedID == rhs.feedID }

  var body: some View {
    Group {
      if feed.state.items.isEmpty && feed.state.isLoading {
        PageStateView(.loading, title: "正在加载视频…")
      } else if feed.state.items.isEmpty, let error = feed.state.error {
        PageStateView(.error,
          title: "没能加载视频", message: error, icon: "wifi.exclamationmark", actionTitle: "重试"
        ) { feed.loadNext() }
      } else if feed.state.items.isEmpty {
        PageStateView(title: "这里还没有视频", message: "稍后刷新试试。", icon: "play.rectangle")
      } else {
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)],
            spacing: Theme.gridSpacing
          ) {
            ForEach(feed.state.items) { video in
              VideoCard(video: video) { open(video) }
            }
          }.cardGridContent()
          if let error = feed.state.error {
            VStack(spacing: 10) {
              InlineErrorText(message: "没能加载更多视频：\(error)")
              Button("重试") { feed.loadNext() }.buttonStyle(AppButtonStyle(size: .small))
            }.frame(maxWidth: .infinity).padding(20)
          } else if feed.state.isLoading || feed.state.hasMore {
            LoadMoreFooter(isLoading: feed.state.isLoading, autoLoad: false) { feed.loadNext() }
          }
        }
        .contentMargins(Theme.gridPadding, for: .scrollContent)
        .cardGrid()
        .performanceScrollProbe(page: PerformanceOptions.scrollPage ?? "")
        .prefetchOnScroll(enabled: feed.state.hasMore && !feed.state.isLoading && feed.state.error == nil) {
          feed.loadNext()
        }
      }
    }
  }
}
