import ManpingCore
import Foundation
import SwiftUI

@MainActor final class LiveDiscoveryModel: ObservableObject {
  @Published private(set) var partitions: [LivePartition] = []
  @Published private(set) var mainID: Int64?
  @Published private(set) var areaID: Int64?
  @Published private(set) var tags: [LiveTag] = []
  @Published private(set) var selectedTag: LiveTag?
  @Published private(set) var rooms: [LiveRoom] = []
  @Published private(set) var following: [LiveRoom] = []
  @Published private(set) var isLoading = false
  @Published private(set) var isLoadingAreas = false
  @Published private(set) var hasMore = false
  @Published private(set) var error: String?
  @Published private(set) var areaError: String?
  @Published private(set) var identityVersion = 0
  private let service: BiliService
  private var identityTask: Task<Void, Never>?
  private var flight: Task<Void, Never>?
  private var generation = UUID()
  private var loadedIdentity: AuthSnapshot?
  private var pendingIdentity: AuthSnapshot?
  private var active = false
  private var nextPage = 1
  private var selectedChildren: [Int64: Int64] = [:]
  private var areaTags: [String: [LiveTag]] = [:]
  private var areaSelections: [String: LiveTag] = [:]
  private struct CachedRooms {
    let rooms: [LiveRoom]
    let following: [LiveRoom]
    let nextPage: Int
    let hasMore: Bool
  }
  private var cache: [String: CachedRooms] = [:]

  init(model: AppModel) {
    service = model.service
    let service = self.service
    identityTask = Task { [weak self] in
      var previous: AuthIdentityEvent?
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let expected = self.pendingIdentity ?? self.loadedIdentity
        let changed = (previous.map { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision } ?? false)
          || (expected.map { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision } ?? false)
        previous = event
        if changed {
          self.cancel(); self.loadedIdentity = nil
          self.partitions = []; self.rooms = []; self.following = []; self.tags = []; self.selectedTag = nil
          self.mainID = nil; self.areaID = nil; self.hasMore = false; self.error = nil; self.areaError = nil
          self.cache = [:]; self.areaTags = [:]; self.areaSelections = [:]; self.selectedChildren = [:]
          self.identityVersion += 1
          if self.active { await self.initialize() }
        }
      }
    }
  }
  deinit { identityTask?.cancel(); flight?.cancel() }
  var selectedMain: LivePartition? { partitions.first { $0.id == mainID } }
  var children: [LivePartition] { selectedMain?.children ?? [] }
  var selectedArea: LivePartition? { children.first { $0.id == areaID } }
  var isRecommendation: Bool { mainID == nil }
  var title: String { selectedArea?.title ?? (isRecommendation ? "推荐直播" : selectedMain?.title ?? "直播") }
  private var areaKey: String {
    guard let area = selectedArea else { return "feed" }
    return "area:\(area.parentID ?? 0):\(area.id)"
  }
  private var listKey: String { isRecommendation ? "feed" : "\(areaKey):\(selectedTag?.sortType ?? "")" }

  func start() async {
    active = true
    if loadedIdentity == nil || partitions.isEmpty { await initialize() }
    else { await refresh() }
  }
  func stop() { active = false; cancel() }
  func cancel() {
    generation = UUID(); flight?.cancel(); flight = nil; pendingIdentity = nil
    isLoading = false; isLoadingAreas = false
  }
  private func initialize() async {
    cancel(); let revision = generation
    isLoadingAreas = true; areaError = nil; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      let expected = await service.authSnapshot()
      pendingIdentity = expected
      do {
        let groups = try await service.livePartitions(expectedIdentity: expected)
        try await check(revision, identity: expected)
        var known = Set<Int64>(); partitions = groups.filter { known.insert($0.id).inserted }
      } catch is CancellationError {
        if generation == revision { isLoadingAreas = false; pendingIdentity = nil; flight = nil }
        return
      } catch { if generation == revision { areaError = error.localizedDescription } }
      do {
        try await check(revision, identity: expected)
        loadedIdentity = expected; isLoadingAreas = false
        // The upstream starts on the synthetic recommendation section.
        mainID = nil; areaID = nil; tags = []; selectedTag = nil
        rooms = []; following = []; nextPage = 1; hasMore = true
        await fetchNext(revision: revision, identity: expected)
      } catch is CancellationError {
      } catch { if generation == revision { self.error = error.localizedDescription } }
      if generation == revision { pendingIdentity = nil; isLoadingAreas = false; isLoading = false; flight = nil }
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func reloadAreas() async { await initialize() }
  func refresh() async {
    guard let expected = loadedIdentity else { await initialize(); return }
    cancel(); let revision = generation
    cache[listKey] = nil
    rooms = []; if isRecommendation { following = [] }
    nextPage = 1; hasMore = isRecommendation || selectedArea != nil; error = nil
    guard hasMore else { return }
    await runLoad(revision: revision, identity: expected)
  }
  func selectMain(_ id: Int64?) async {
    guard loadedIdentity != nil, id != mainID,
      id == nil || partitions.contains(where: { $0.id == id }) else { return }
    saveCurrent(); cancel(); mainID = id
    if let id {
      let remembered = selectedChildren[id]
      areaID = children.first(where: { $0.id == remembered })?.id ?? children.first?.id
      if let areaID { selectedChildren[id] = areaID }
    } else { areaID = nil }
    await restoreOrLoad()
  }
  func selectArea(_ id: Int64) async {
    guard loadedIdentity != nil, id != areaID, children.contains(where: { $0.id == id }) else { return }
    saveCurrent(); cancel(); areaID = id
    if let mainID { selectedChildren[mainID] = id }
    await restoreOrLoad()
  }
  func selectTag(_ tag: LiveTag) async {
    guard loadedIdentity != nil, selectedTag != tag, tags.contains(tag) else { return }
    saveCurrent(); cancel(); selectedTag = tag; areaSelections[areaKey] = tag
    await restoreOrLoad(preserveTag: true)
  }
  private func restoreOrLoad(preserveTag: Bool = false) async {
    if !preserveTag {
      tags = areaTags[areaKey] ?? []
      selectedTag = areaSelections[areaKey]
    }
    error = nil
    if let saved = cache[listKey] {
      rooms = saved.rooms; following = saved.following
      nextPage = saved.nextPage; hasMore = saved.hasMore
    } else {
      rooms = []; following = []; nextPage = 1; hasMore = isRecommendation || selectedArea != nil
      await loadNext()
    }
  }
  private func saveCurrent() {
    guard !isLoading, nextPage > 1 else { return }
    cache[listKey] = CachedRooms(rooms: rooms, following: following, nextPage: nextPage, hasMore: hasMore)
  }
  func loadNext() async {
    guard !isLoading, !isLoadingAreas, hasMore, let expected = loadedIdentity else { return }
    await runLoad(revision: generation, identity: expected)
  }
  private func runLoad(revision: UUID, identity: AuthSnapshot) async {
    guard !isLoading, generation == revision else { return }
    isLoading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await fetchNext(revision: revision, identity: identity)
      if generation == revision { isLoading = false; flight = nil }
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func fetchNext(revision: UUID, identity: AuthSnapshot) async {
    guard hasMore, generation == revision, !Task.isCancelled else { return }
    isLoading = true; error = nil
    let page = nextPage
    do {
      try await check(revision, identity: identity)
      let incoming: [LiveRoom]
      let continuation: Int
      let more: Bool
      if isRecommendation {
        let batch = try await service.liveFeed(page: page, expectedIdentity: identity)
        try await check(revision, identity: identity)
        incoming = batch.rooms; continuation = batch.nextPage; more = batch.hasMore
        var known = Set(following.map(\.id)); following += batch.following.filter { known.insert($0.id).inserted }
      } else {
        guard let area = selectedArea else { throw CancellationError() }
        let batch = try await service.livePartitionRooms(area: area, tag: selectedTag, page: page, expectedIdentity: identity)
        try await check(revision, identity: identity)
        incoming = batch.rooms; continuation = batch.nextPage; more = batch.hasMore
        if !batch.tags.isEmpty {
          var known = Set<Int64>(); tags = batch.tags.filter { known.insert($0.id).inserted }
          areaTags[areaKey] = tags
          if selectedTag == nil { selectedTag = tags.first; if let selectedTag { areaSelections[areaKey] = selectedTag } }
        }
      }
      var known = Set(rooms.map(\.id)); let appended = incoming.filter { known.insert($0.id).inserted }
      rooms += appended; nextPage = continuation
      hasMore = more && !appended.isEmpty && continuation > page
    } catch is CancellationError {
    } catch { if generation == revision { self.error = error.localizedDescription } }
    if generation == revision { isLoading = false; saveCurrent() }
  }
  private func check(_ revision: UUID, identity: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    guard generation == revision, current.epoch == identity.epoch,
      current.identityRevision == identity.identityRevision else { throw CancellationError() }
    try Task.checkCancellation()
  }
}
