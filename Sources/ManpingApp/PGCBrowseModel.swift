import ManpingCore
import SwiftUI

@MainActor final class PGCBrowseModel: ObservableObject {
  @Published private(set) var filters: [PGCFilter] = []
  @Published private(set) var selection: [String: String] = [:]
  @Published private(set) var seasons: [PGCSeason] = []
  @Published private(set) var days: [PGCTimelineDay] = []
  @Published private(set) var selectedDay: Int64?
  @Published private(set) var isLoading = false
  @Published private(set) var hasMore = false
  @Published private(set) var error: String?
  private let service: BiliService
  private var category: PGCCategory?
  private var expected: AuthSnapshot?
  private var flight: Task<Void, Never>?
  private var identityTask: Task<Void, Never>?
  private var generation = UUID()
  private var page = 1
  private var emptyPages = 0
  init(service: BiliService) {
    self.service = service
    identityTask = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, let expected = self.expected, !Task.isCancelled else { continue }
        if event.epoch != expected.epoch || event.identityRevision != expected.identityRevision {
          self.reset(); self.error = "登录状态已改变，请刷新页面。"
        }
      }
    }
  }
  deinit { identityTask?.cancel(); flight?.cancel() }
  func cancel() { generation = UUID(); flight?.cancel(); flight = nil; isLoading = false }
  private func reset() {
    cancel(); expected = nil; filters = []; selection = [:]; seasons = []; days = []; selectedDay = nil
    page = 1; emptyPages = 0; hasMore = false; error = nil
  }
  func loadTimeline() async {
    reset(); category = nil; isLoading = true
    let revision = generation
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      let snapshot = await service.authSnapshot()
      guard revision == generation, !Task.isCancelled else { return }
      expected = snapshot
      do {
        async let bangumi = service.pgcTimeline(bangumi: true, expectedIdentity: snapshot)
        async let domestic = service.pgcTimeline(bangumi: false, expectedIdentity: snapshot)
        let result = try await PGCTimelineDay.merged([bangumi, domestic])
        try await check(revision, expected: snapshot)
        days = result; selectedDay = result.first(where: \.isToday)?.id ?? result.first?.id
        selectDay(selectedDay)
      } catch is CancellationError {} catch { if generation == revision { self.error = error.localizedDescription } }
      if generation == revision { isLoading = false; flight = nil }
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func selectDay(_ id: Int64?) { selectedDay = id; seasons = days.first { $0.id == id }?.seasons ?? [] }
  func loadIndex(_ category: PGCCategory) async {
    reset(); self.category = category; isLoading = true
    let revision = generation
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      let snapshot = await service.authSnapshot()
      guard revision == generation, !Task.isCancelled else { return }
      expected = snapshot
      do {
        let result = try await service.pgcFilters(category: category, expectedIdentity: snapshot)
        try await check(revision, expected: snapshot)
        filters = result
        selection = Dictionary(uniqueKeysWithValues: result.compactMap { filter in filter.choices.first.map { (filter.id, $0.id) } })
        hasMore = true
      } catch is CancellationError {} catch { if generation == revision { self.error = error.localizedDescription } }
      if generation == revision { isLoading = false; flight = nil }
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    if generation == revision && error == nil { await loadNext() }
  }
  func choose(filter: PGCFilter, value: String) {
    guard selection[filter.id] != value, filter.choices.contains(where: { $0.id == value }) else { return }
    cancel(); selection[filter.id] = value; seasons = []; page = 1; emptyPages = 0; hasMore = true; error = nil
    Task { await loadNext() }
  }
  func refresh() async { if let category { await loadIndex(category) } else { await loadTimeline() } }
  func loadNext() async {
    guard let category, let expected, !isLoading, hasMore else { return }
    let revision = generation; let selected = selection; let filters = filters; let page = page
    isLoading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await service.pgcIndex(category: category, filters: filters, selection: selected, page: page, expectedIdentity: expected)
        try await check(revision, expected: expected)
        var known = Set(seasons.map(\.id))
        let fresh = result.items.filter { known.insert($0.id).inserted }
        seasons += fresh; self.page += 1; emptyPages = fresh.isEmpty ? emptyPages + 1 : 0
        hasMore = result.hasMore && emptyPages < 3
        if result.hasMore && emptyPages >= 3 { self.error = "分页未返回新剧集，请刷新。" }
      } catch is CancellationError {} catch { if generation == revision { self.error = error.localizedDescription } }
      if generation == revision { isLoading = false; flight = nil }
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func check(_ revision: UUID, expected: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    guard generation == revision, current.epoch == expected.epoch, current.identityRevision == expected.identityRevision else { throw CancellationError() }
  }
}
