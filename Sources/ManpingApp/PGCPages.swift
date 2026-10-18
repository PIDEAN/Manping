import ManpingCore
import SwiftUI

struct AnimePage: View {
  let model: AppModel
  let onOpen: (PGCSelection) -> Void
  let onFavorites: () -> Void
  var body: some View { PGCDiscoveryPage(model: model, cinema: false, onOpen: onOpen, onFavorites: onFavorites) }
}
struct CinemaPage: View {
  let model: AppModel
  let onOpen: (PGCSelection) -> Void
  let onFavorites: () -> Void
  var body: some View { PGCDiscoveryPage(model: model, cinema: true, onOpen: onOpen, onFavorites: onFavorites) }
}
private struct PGCDiscoveryPage: View {
  @ObservedObject var model: AppModel
  let cinema: Bool
  let onOpen: (PGCSelection) -> Void
  let onFavorites: () -> Void
  @StateObject private var browse: PGCBrowseModel
  @AppStorage("pgcAnimeLastSection") private var animeSection = "timeline"
  @AppStorage("pgcCinemaLastCategory") private var cinemaCategory = "movie"
  @Environment(\.colorScheme) private var scheme
  @State private var diagnosticApplied = false
  init(model: AppModel, cinema: Bool, onOpen: @escaping (PGCSelection) -> Void, onFavorites: @escaping () -> Void) {
    self.model = model; self.cinema = cinema; self.onOpen = onOpen; self.onFavorites = onFavorites
    _browse = StateObject(wrappedValue: PGCBrowseModel(service: model.service))
  }
  private var timeline: Bool { !cinema && animeSection != "index" }
  private var category: PGCCategory { cinema ? (PGCCategory(rawValue: cinemaCategory).flatMap { $0 == .anime ? nil : $0 } ?? .movie) : .anime }
  private var key: String { "\(cinema):\(timeline):\(category.rawValue):\(model.refreshToken)" }
  private var title: String {
    timeline ? (browse.days.first { $0.id == browse.selectedDay }?.title ?? "番剧时间线") : category.title
  }
  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Hairline(axis: .vertical)
      VStack(spacing: 0) {
        if !timeline && !browse.filters.isEmpty { filterBar }
        results
      }
    }
      .pageToolbar(title: cinema ? "影视" : "番剧", subtitle: title, refreshing: browse.isLoading,
        refresh: { Task { await browse.refresh() } }) {
        Button(action: onFavorites) { Label(cinema ? "我的追剧" : "我的追番", systemImage: "bookmark") }
          .buttonStyle(AppButtonStyle(size: .small))
      }
      .onAppear { applyDiagnosticSelection() }
      .task(id: key) { if timeline { await browse.loadTimeline() } else { await browse.loadIndex(category) } }
      .onDisappear { browse.cancel() }
  }
  private func applyDiagnosticSelection() {
    guard !diagnosticApplied else { return }
    diagnosticApplied = true
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--ui-page"), index + 1 < args.count else { return }
    switch args[index + 1] {
    case "anime" where !cinema: animeSection = "timeline"
    case "anime:index" where !cinema: animeSection = "index"
    case "cinema" where cinema: cinemaCategory = PGCCategory.movie.rawValue
    case "cinema:tv" where cinema: cinemaCategory = PGCCategory.tv.rawValue
    case "cinema:documentary" where cinema: cinemaCategory = PGCCategory.documentary.rawValue
    default: break
    }
    #endif
  }
  private var sidebar: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          if cinema {
            ForEach([PGCCategory.movie, .tv, .documentary], id: \.self) { item in
              secondaryRow(item.title, symbol: item == .movie ? "film" : item == .tv ? "tv" : "globe", selected: category == item) {
                cinemaCategory = item.rawValue
              }
            }
          } else {
            secondaryRow("时间线", symbol: "calendar", selected: timeline) { animeSection = "timeline" }
            secondaryRow("番剧索引", symbol: "line.3.horizontal.decrease", selected: !timeline) { animeSection = "index" }
            if timeline {
              SidebarSectionTitle(title: "更新日")
              ForEach(browse.days) { day in
                Button { browse.selectDay(day.id) } label: {
                  HStack(spacing: 8) {
                    Text(day.title).font(Theme.Font.body)
                    Text(day.isToday ? "今天" : Date(timeIntervalSince1970: Double(day.timestamp)).formatted(.dateTime.weekday(.wide)))
                      .font(Theme.Font.caption).foregroundStyle(day.isToday ? Theme.accentText(scheme) : Theme.tertiaryText(scheme))
                    Spacer()
                    Text("\(day.seasons.count)").font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
                  }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
                }.buttonStyle(SidebarRowStyle(selected: browse.selectedDay == day.id))
              }
            }
          }
          if browse.isLoading && browse.seasons.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(12) }
        }.padding(.horizontal, 10).padding(.bottom, 12).foregroundStyle(Theme.text(scheme))
      }
    }.frame(width: Theme.secondarySidebarWidth)
  }
  private func secondaryRow(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
        Text(title).font(Theme.Font.body)
        Spacer()
      }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
    }.buttonStyle(SecondaryNavigationStyle(selected: selected))
  }
  private var filterBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(browse.filters) { filter in
          PGCIndexFilterRow(filter: filter, selectedValue: browse.selection[filter.id]) { value in
            browse.choose(filter: filter, value: value)
          }
        }
      }.padding(.horizontal, Theme.gridPadding).padding(.vertical, 10).foregroundStyle(Theme.text(scheme))
    }.scrollIndicators(.hidden).overlay(alignment: .bottom) { Hairline() }
  }
  private var results: some View {
    Group {
      if browse.seasons.isEmpty && browse.isLoading {
        PageStateView(.loading, title: "正在加载剧集…")
      } else if browse.seasons.isEmpty, let error = browse.error {
        PageStateView(.error, title: "没能加载剧集", message: error, icon: "wifi.exclamationmark", actionTitle: "重试") { Task { await browse.refresh() } }
      } else if browse.seasons.isEmpty {
        PageStateView(title: timeline ? "这一天没有更新" : "没有符合条件的剧集", message: timeline ? "看看其他日子的更新。" : "换个筛选条件试试。", icon: "sparkles.tv")
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 20)], spacing: 24) {
            ForEach(browse.seasons) { season in PGCSeasonCard(season: season) { onOpen(season.selection) } }
          }.padding(Theme.gridPadding)
          if let error = browse.error {
            InlineErrorText(message: error).padding(12)
            Button("重试") { Task { await browse.loadNext() } }.buttonStyle(AppButtonStyle(size: .small))
          } else if browse.isLoading || browse.hasMore {
            LoadMoreFooter(isLoading: browse.isLoading, autoLoad: false) { Task { await browse.loadNext() } }
          }
        }.prefetchOnScroll(enabled: !timeline && browse.hasMore && !browse.isLoading && browse.error == nil) { Task { await browse.loadNext() } }
      }
    }
  }
}
private struct PGCIndexFilterRow: View {
  let filter: PGCFilter
  let selectedValue: String?
  let onSelect: (String) -> Void

  var body: some View {
    Menu {
      Picker(filter.title, selection: Binding(get: { selectedValue ?? "" }, set: { onSelect($0) })) {
        ForEach(filter.choices) { choice in Text(choice.title).tag(choice.id) }
      }.pickerStyle(.inline).labelsHidden()
    } label: {
      MenuLabel(title: "\(filter.title)：\(filter.choices.first { $0.id == selectedValue }?.title ?? "全部")")
    }.appMenuStyle().accessibilityLabel(filter.title)
  }
}
struct PGCSeasonCard: View {
  let season: PGCSeason
  let open: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Button(action: open) {
      // A borderless 3:4 poster card; the grid cell sets the width.
      VStack(alignment: .leading, spacing: Theme.cardTitleGap) {
        Color.clear.aspectRatio(3 / 4, contentMode: .fit).frame(maxWidth: .infinity)
          .overlay { CachedImage(url: season.cover).allowsHitTesting(false) }
          .overlay(alignment: .topLeading) {
            if let badge = season.badge, !badge.isEmpty { RecommendBadge(text: badge).padding(8) }
          }
          .overlay(alignment: .bottomTrailing) {
            if let score = season.score { ScoreBadge(score: score).padding(8) }
          }
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        VStack(alignment: .leading, spacing: 4) {
          Text(season.title).font(Theme.Font.headline).foregroundStyle(Theme.text(scheme))
            .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
          Text(season.subtitle.isEmpty ? " " : season.subtitle).font(Theme.Font.caption)
            .foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
        }
      }.contentShape(Rectangle()).cardHover()
    }.buttonStyle(CardPressStyle()).accessibilityLabel("播放 \(season.title)")
  }
}
