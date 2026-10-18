import ManpingCore
import SwiftUI

/// 首页: 推荐 / 热门 / 排行榜 (the tabs live in the toolbar). Per-partition rankings are on 分区.
struct PopularPage: View {
  @ObservedObject var model: AppModel
  @StateObject private var feed = BrowseFeedModel()
  @Environment(\.colorScheme) private var scheme
  private var kind: BrowseKind {
    switch model.popularTab {
    case .recommended: .recommended
    case .popular: .popular
    case .ranking: .ranking
    }
  }
  private var requestKey: String { kind.rawValue }
  var body: some View {
    BrowseVideoResults(feed: feed, open: model.open)
      .pageToolbar(title: "首页", refreshing: feed.state.isLoading && !feed.state.items.isEmpty, refresh: { feed.refresh() }) {
        Button { model.playCuratedList() } label: {
          Label("播放精选", systemImage: "play.square.stack")
        }.buttonStyle(AppButtonStyle(size: .small)).disabled(model.curatedLoading)
          .help("把推荐里的精选视频排成一个列表连续播放")
        if model.curatedLoading {
          Button { model.cancelCuratedPlaylist() } label: { Image(systemName: "xmark") }
            .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("停止加载精选")
        }
      }
      .task(id: "\(requestKey):\(model.refreshToken)") {
        let selectedKind = kind; let service = model.service
        feed.activate(key: requestKey, refreshToken: model.refreshToken) { [model, selectedKind, service] cursor in
          if PerformanceOptions.requested {
            return BrowseVideoPage(items: PerformanceFixtures.videos, nextCursor: nil)
          }
          switch selectedKind {
          case .recommended: return try await service.recommend(cursor: cursor)
          case .popular:
            return try await RPCBrowseSource(rpc: model.standardRPCService()).popularFeed(cursor: cursor)
          case .ranking:
            return try await RPCBrowseSource(rpc: model.standardRPCService()).rankingFeed(region: 0)
          }
        }
      }.onDisappear { feed.deactivate() }
  }
}

/// Kept as the name used by browse sidebars; renders the shared sidebar row.
struct SecondaryNavigationStyle: ButtonStyle {
  var selected = false
  func makeBody(configuration: Configuration) -> some View {
    SidebarRowStyle(selected: selected).makeBody(configuration: configuration)
  }
}

struct PartitionSymbol: View {
  let partition: VideoPartition
  private var symbol: String {
    switch partition.id {
    case 1: "play.square.fill"
    case 3: "headphones"
    case 129: "fan.fill"
    case 4: "gamecontroller.fill"
    case 36: "lightbulb.fill"
    case 188: "cloud.fill"
    case 223: "car.fill"
    case 234: "figure.run"
    case 160: "duffle.bag.fill"
    case 211: "fork.knife"
    case 217: "pawprint.fill"
    case 119: "face.smiling.fill"
    case 155: "tshirt.fill"
    default: "play.rectangle.fill"
    }
  }
  private var color: Color {
    Theme.partitionPalette[abs(partition.id) % Theme.partitionPalette.count]
  }
  var body: some View {
    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
      .frame(width: 18, height: 18).background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
  }
}
