import ManpingCore
import SwiftUI

@MainActor final class ArticleBrowserModel: ObservableObject {
  // Negative selections are local UI identifiers, never API category IDs.
  @Published private(set) var partitions: [ArticlePartition] = []
  @Published private(set) var selectedParent: Int64 = -1
  @Published private(set) var selectedCategory: Int64?
  @Published private(set) var sort: ArticleSort = .recommended
  @Published private(set) var articles: [ArticleSummary] = []
  @Published private(set) var ranks: [ArticleSummary] = []
  @Published private(set) var isLoading = false
  @Published private(set) var directoryLoading = false
  @Published private(set) var error: String?
  @Published private(set) var directoryError: String?
  @Published private(set) var hasMore = false
  private let service: BiliService
  private var expected: AuthSnapshot?
  private var flight: Task<Void, Never>?
  private var observer: Task<Void, Never>?
  private var generation = UUID()
  private var page = 1
  private var emptyPages = 0
  var children: [ArticlePartition] { partitions.first { $0.id == selectedParent }?.children ?? [] }
  var title: String {
    selectedParent == -1 ? "推荐专栏" : selectedParent == -2 ? "专栏排行榜" :
      partitions.first { $0.id == selectedParent }?.title ?? "专栏"
  }
  init(service: BiliService) {
    self.service = service
    observer = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled, let expected = self.expected else { continue }
        if event.epoch != expected.epoch || event.identityRevision != expected.identityRevision {
          self.cancel(); self.expected = nil; self.articles = []; self.ranks = []; self.hasMore = false
          self.error = "登录状态已改变，请刷新页面。"
        }
      }
    }
  }
  deinit { flight?.cancel(); observer?.cancel() }
  func cancel() { generation = UUID(); flight?.cancel(); flight = nil; isLoading = false; directoryLoading = false }
  func initialize(selection: Int64 = -1) async {
    cancel(); directoryLoading = true; directoryError = nil
    let revision = generation; let snapshot = await service.authSnapshot()
    guard revision == generation, !Task.isCancelled else { return }
    expected = snapshot
    do {
      let result = try await service.articlePartitions(expectedIdentity: snapshot)
      try await check(revision, snapshot)
      partitions = result
    } catch is CancellationError { return }
    catch { if revision == generation { directoryError = error.localizedDescription } }
    guard revision == generation else { return }
    directoryLoading = false
    let valid = selection < 0 || partitions.contains { $0.id == selection }
    await selectParent(valid ? selection : -1)
  }
  func selectParent(_ id: Int64) async {
    guard [-1, -2].contains(id) || partitions.contains(where: { $0.id == id }) else { return }
    cancel(); selectedParent = id; selectedCategory = id >= 0 ? id : nil; sort = .recommended
    await resetFeed()
  }
  func selectChild(_ id: Int64) async {
    guard id == selectedParent || children.contains(where: { $0.id == id }), selectedCategory != id else { return }
    cancel(); selectedCategory = id; await resetFeed()
  }
  func selectSort(_ value: ArticleSort) async {
    guard selectedParent >= 0, sort != value else { return }
    cancel(); sort = value; await resetFeed()
  }
  func refresh() async { cancel(); await resetFeed() }
  private func resetFeed() async {
    articles = []; ranks = []; page = 1; emptyPages = 0; error = nil; hasMore = true
    let revision = generation; let snapshot = await service.authSnapshot()
    guard revision == generation, !Task.isCancelled else { return }
    expected = snapshot
    await loadNext()
  }
  func loadNext() async {
    guard !isLoading, hasMore, let expected else { return }
    let revision = generation; let page = page; let category = selectedCategory; let sort = sort
    let ranking = selectedParent == -2
    isLoading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result: ArticleFeedPage
        if ranking {
          let categories = try await service.articleHotCategories(expectedIdentity: expected)
          var combined: [ArticleSummary] = []; var known = Set<Int64>()
          for category in categories {
            try Task.checkCancellation()
            let values = try await service.articleRanking(categoryID: category.id, expectedIdentity: expected)
            combined += values.filter { known.insert($0.id).inserted }
          }
          // The fixed UI combines all hot categories and sorts by publication time.
          result = ArticleFeedPage(items: combined.sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }, hasMore: false)
        } else {
          result = try await service.articleFeed(categoryID: category, sort: sort, page: page, expectedIdentity: expected)
        }
        try await check(revision, expected)
        var known = Set(articles.map(\.id))
        let fresh = result.items.filter { known.insert($0.id).inserted }
        articles += fresh; self.page += 1
        if page == 1 { ranks = result.ranks }
        emptyPages = fresh.isEmpty ? emptyPages + 1 : 0
        hasMore = result.hasMore && emptyPages < 3
        if result.hasMore && emptyPages >= 3 { self.error = "连续分页未返回新文章，请刷新。" }
      } catch is CancellationError {} catch { if revision == generation { self.error = error.localizedDescription } }
      if revision == generation { isLoading = false; flight = nil }
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func check(_ revision: UUID, _ expected: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    guard revision == generation, current.epoch == expected.epoch,
      current.identityRevision == expected.identityRevision else { throw CancellationError() }
  }
}
