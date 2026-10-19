import ManpingCore
import SwiftUI

struct ArticleBrowserPage: View {
  @StateObject private var browse: ArticleBrowserModel
  let refreshToken: Int
  let initialSection: Int64
  let openArticle: (ArticleSummary) -> Void
  let onUser: (Int64) -> Void
  @Environment(\.colorScheme) private var scheme
  init(service: BiliService, refreshToken: Int = 0, initialSection: Int64 = -1,
    openArticle: @escaping (ArticleSummary) -> Void, onUser: @escaping (Int64) -> Void) {
    _browse = StateObject(wrappedValue: ArticleBrowserModel(service: service))
    self.refreshToken = refreshToken; self.initialSection = initialSection
    self.openArticle = openArticle; self.onUser = onUser
  }
  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Hairline(axis: .vertical)
      VStack(spacing: 0) {
        if !browse.children.isEmpty { children }
        results
      }
    }
      .pageToolbar(title: "专栏", subtitle: browse.title, refreshing: browse.isLoading,
        refresh: { Task { await browse.refresh() } }) {
        if browse.selectedParent >= 0 {
          Menu {
            ForEach(ArticleSort.allCases, id: \.rawValue) { value in
              Button(value.title) { Task { await browse.selectSort(value) } }
            }
          } label: { MenuLabel(title: browse.sort.title) }.appMenuStyle(toolbar: true)
        }
      }
      .task(id: refreshToken) { await browse.initialize(selection: initialSection) }
      .onDisappear { browse.cancel() }
  }
  private var sidebar: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 2) {
          SidebarSectionTitle(title: "专栏分区")
          section("推荐", id: -1, icon: "sparkles")
          section("排行榜", id: -2, icon: "chart.bar")
          ForEach(browse.partitions) { partition in section(partition.title, id: partition.id, icon: "doc.text") }
          if browse.directoryLoading { ProgressView().padding() }
          if let error = browse.directoryError {
            InlineErrorText(message: error).padding(8)
            Button("重试") { Task { await browse.initialize(selection: browse.selectedParent) } }
              .buttonStyle(AppButtonStyle(size: .small))
          }
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }
    }.frame(width: Theme.secondarySidebarWidth)
  }
  private func section(_ title: String, id: Int64, icon: String) -> some View {
    Button { Task { await browse.selectParent(id) } } label: {
      Label { Text(title) } icon: { Image(systemName: icon).font(.system(size: 13)).frame(width: 18) }.font(Theme.Font.body)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: Theme.rowHeight)
    }.buttonStyle(SidebarRowStyle(selected: browse.selectedParent == id))
  }
  private var children: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        child("推荐", id: browse.selectedParent)
        ForEach(browse.children) { child($0.title, id: $0.id) }
      }.padding(.horizontal, Theme.gridPadding).padding(.vertical, 10)
    }.scrollIndicators(.hidden).overlay(alignment: .bottom) { Hairline() }
  }
  private func child(_ title: String, id: Int64) -> some View {
    Button { Task { await browse.selectChild(id) } } label: {
      Text(title)
    }.buttonStyle(ChipStyle(selected: browse.selectedCategory == id))
  }
  private var results: some View {
    Group {
      if browse.articles.isEmpty && browse.isLoading {
        PageStateView(.loading, title: "正在加载专栏…")
      } else if browse.articles.isEmpty, let error = browse.error {
        PageStateView(.error, title: "没能加载专栏", message: error, icon: "wifi.exclamationmark", actionTitle: "重试") {
          Task { await browse.loadNext() }
        }
      } else if browse.articles.isEmpty {
        PageStateView(title: "这个分区还没有专栏", message: "换个分区或稍后刷新试试。", icon: "doc.text")
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(Array(browse.articles.enumerated()), id: \.element.id) { index, article in
              ArticleCard(article: article, rank: browse.selectedParent == -2 ? index + 1 : nil,
                open: { openArticle(article) }, onUser: onUser)
            }
            if let error = browse.error {
              InlineErrorText(message: error)
              Button("重试") { Task { await browse.loadNext() } }.buttonStyle(AppButtonStyle(size: .small))
            } else if browse.isLoading || browse.hasMore {
              LoadMoreFooter(isLoading: browse.isLoading, autoLoad: false) { Task { await browse.loadNext() } }
            }
          }.padding(Theme.gridPadding).frame(maxWidth: 920).frame(maxWidth: .infinity)
        }.prefetchOnScroll(enabled: browse.hasMore && !browse.isLoading && browse.error == nil) {
          Task { await browse.loadNext() }
        }
      }
    }
  }
}

private struct ArticleCard: View {
  let article: ArticleSummary
  let rank: Int?
  let open: () -> Void
  let onUser: (Int64) -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      if let rank {
        Text(String(rank)).font(.system(size: 20, weight: .bold).monospacedDigit())
          .foregroundStyle(rank <= 3 ? Theme.accentText(scheme) : Theme.tertiaryText(scheme)).frame(width: 30)
      }
      VStack(alignment: .leading, spacing: 10) {
        Button(action: open) {
          VStack(alignment: .leading, spacing: 8) {
            Text(article.title).font(Theme.Font.section).lineLimit(2)
            Text(article.summary).font(Theme.Font.body).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(3)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        HStack(spacing: 8) {
          Button { onUser(article.author.id) } label: {
            HStack(spacing: 6) {
              CachedImage(url: article.author.avatar).frame(width: 22, height: 22).clipShape(Circle())
              Text(article.author.name).lineLimit(1)
            }
          }.buttonStyle(.plain).disabled(article.author.id <= 0)
          if let publishedAt = article.publishedAt {
            Text(Date(timeIntervalSince1970: Double(publishedAt)), style: .relative)
          }
          Spacer(minLength: 4)
          Label("\(article.stats.reads)", systemImage: "eye")
          Label("\(article.stats.likes)", systemImage: "hand.thumbsup")
          Label("\(article.stats.replies)", systemImage: "text.bubble")
        }.font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
      }
      if article.cover != nil {
        Button(action: open) { CachedImage(url: article.cover).frame(width: 150, height: 94).clipped() }
          .buttonStyle(CardPressStyle()).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
      }
    }.padding(16).foregroundStyle(Theme.text(scheme)).cardSurface(scheme)
  }
}
