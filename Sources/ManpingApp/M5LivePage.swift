import ManpingCore
import SwiftUI

struct M5LivePage: View {
  @ObservedObject var model: AppModel
  @StateObject private var discovery: LiveDiscoveryModel
  @AppStorage("m5LiveMainWidth") private var mainWidth = 240.0
  @AppStorage("m5LiveChildWidth") private var childWidth = 200.0
  @AppStorage("m5LiveSidebarHidden") private var sidebarHidden = false
  @State private var showsFollowing = false
  @Environment(\.colorScheme) private var scheme
  private var showsChildren: Bool { !sidebarHidden && !discovery.children.isEmpty }
  init(model: AppModel) {
    self.model = model; _discovery = StateObject(wrappedValue: LiveDiscoveryModel(model: model))
  }
  var body: some View {
    HStack(spacing: 0) {
      if !sidebarHidden {
        mainSidebar.frame(width: min(360, max(180, mainWidth))).transition(.move(edge: .leading).combined(with: .opacity))
        SidebarResizeHandle(width: $mainWidth, range: 180...360)
      }
      if showsChildren {
        childSidebar.frame(width: min(320, max(150, childWidth)))
        SidebarResizeHandle(width: $childWidth, range: 150...320)
      }
      VStack(spacing: 0) {
        if !discovery.tags.isEmpty && !discovery.isRecommendation { tagBar }
        results
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: "直播", subtitle: discovery.title, refreshing: discovery.isLoading && !discovery.rooms.isEmpty,
        refresh: { Task { await discovery.refresh() } }) { headerControls }
      .task(id: model.refreshToken) {
        await discovery.start()
        #if DEBUG
        let arguments = CommandLine.arguments
        if model.usesUIFixtures, let index = arguments.firstIndex(of: "--ui-live-area"),
          arguments.indices.contains(index + 1), let areaID = Int64(arguments[index + 1]),
          let group = discovery.partitions.first(where: { $0.children.contains(where: { $0.id == areaID }) }) {
          await discovery.selectMain(group.id)
          await discovery.selectArea(areaID)
          if let sortIndex = arguments.firstIndex(of: "--ui-live-sort"), arguments.indices.contains(sortIndex + 1),
            let tag = discovery.tags.first(where: { $0.sortType == arguments[sortIndex + 1] }) {
            await discovery.selectTag(tag)
          }
        }
        #endif
      }
      .onChange(of: discovery.identityVersion) { _, _ in showsFollowing = false }
      .onDisappear { showsFollowing = false; discovery.stop() }
  }
  private var mainSidebar: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 2) {
          SidebarSectionTitle(title: "直播分区")
          sidebarRow(title: "推荐直播", icon: "sparkles", selected: discovery.isRecommendation) {
            Task { await discovery.selectMain(nil) }
          }
          ForEach(discovery.partitions) { partition in
            sidebarRow(title: partition.title == "推荐" ? "推荐分区" : partition.title,
              icon: nil, selected: discovery.mainID == partition.id) {
                Task { await discovery.selectMain(partition.id) }
              }
          }
          if discovery.isLoadingAreas { ProgressView().padding(12) }
          if let error = discovery.areaError {
            InlineErrorText(message: error).padding(8)
            pageButton("重试", icon: "arrow.clockwise") { Task { await discovery.reloadAreas() } }
          }
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }
    }
  }
  private var childSidebar: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 2) {
          SidebarSectionTitle(title: discovery.selectedMain?.title ?? "子分区")
          ForEach(discovery.children) { partition in
            Button { Task { await discovery.selectArea(partition.id) } } label: {
              HStack(spacing: 8) {
                CachedImage(url: partition.cover).frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
                Text(partition.title).font(Theme.Font.body).lineLimit(1)
                Spacer(minLength: 0)
              }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
            }.buttonStyle(SidebarRowStyle(selected: discovery.areaID == partition.id))
          }
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }
    }
  }
  private var tagBar: some View {
    PageFilterBar {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(discovery.tags) { tag in
            Button(tag.title) { Task { await discovery.selectTag(tag) } }
              .buttonStyle(ChipStyle(selected: discovery.selectedTag == tag))
          }
        }
      }
    }
  }
  @ViewBuilder private var headerControls: some View {
      SidebarToggleButton(hidden: $sidebarHidden)
      if discovery.isRecommendation && !discovery.following.isEmpty {
        Button { showsFollowing.toggle() } label: {
          Label("关注的直播间", systemImage: "dot.radiowaves.left.and.right")
        }.toolbarActionStyle().popover(isPresented: $showsFollowing, arrowEdge: .bottom) {
          ScrollView {
            VStack(spacing: 2) { ForEach(discovery.following) { room in M5FollowLiveRow(room: room, play: { showsFollowing = false; model.openLiveRoom($0) },
              watch: { showsFollowing = false; model.openLive($0) }) } }.padding(6)
          }.frame(width: 320, height: min(420, CGFloat(discovery.following.count) * 80 + 16))
        }
      }
  }
  private var results: some View {
    Group {
      if discovery.rooms.isEmpty {
        if discovery.isLoading || discovery.isLoadingAreas {
          PageStateView(.loading, title: "正在加载直播间…")
        } else {
          PageStateView(discovery.error == nil ? .empty : .error, title: discovery.error == nil ? "这个分区没有人在直播" : "没能加载直播间",
            message: discovery.error ?? "换个分区或稍后刷新试试。",
            icon: discovery.error == nil ? "video" : "wifi.exclamationmark", actionTitle: discovery.error == nil ? "刷新" : "重试") {
              Task { await discovery.refresh() }
            }
        }
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
            ForEach(discovery.rooms) { room in
              M5LiveCard(room: room, recommendation: discovery.isRecommendation, play: model.openLiveRoom, watch: model.openLive) { mid in model.openOverlay(.userSpace(mid)) }
                .onAppear {
                  if room.id == discovery.rooms.last?.id, discovery.error == nil { Task { await discovery.loadNext() } }
                }
            }
          }.cardGridContent().padding(Theme.gridPadding)
          if let error = discovery.error {
            VStack(spacing: 10) {
              InlineErrorText(message: error)
              pageButton("重试", icon: "arrow.clockwise") { Task { await discovery.loadNext() } }
            }.padding(16)
          } else if discovery.hasMore {
            LoadMoreFooter(isLoading: discovery.isLoading, autoLoad: false) { Task { await discovery.loadNext() } }
          }
        }.cardGrid()
      }
    }
  }
  /// A row of the partition list: only the fixed entry (推荐直播) has an icon, the data rows do not.
  private func sidebarRow(title: String, icon: String?, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let icon { Image(systemName: icon).font(.system(size: 13)).frame(width: 18) }
        Text(title).font(Theme.Font.body).lineLimit(1)
        Spacer(minLength: 0)
      }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
    }.buttonStyle(SidebarRowStyle(selected: selected)).disabled(discovery.isLoadingAreas)
  }
  private func pageButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
    M3CollectionButton(title: title, icon: icon, action: action)
  }
}
