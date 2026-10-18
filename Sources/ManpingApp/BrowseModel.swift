import ManpingCore
import SwiftUI

enum BrowseKind: String, Hashable {
  case recommended
  case popular
  case ranking
}

struct BrowseFeedState {
  var items: [Video] = []
  var nextCursor: String?
  var isLoading = false
  var hasMore = true
  var error: String?
  var consecutiveEmptyPages = 0
}

/// Keeps each section's cursor while rejecting responses from a previous selection.
@MainActor final class BrowseFeedModel: ObservableObject {
  typealias Loader = (String?) async throws -> BrowseVideoPage

  @Published private(set) var state = BrowseFeedState()
  private var states: [String: BrowseFeedState] = [:]
  private var refreshTokens: [String: Int] = [:]
  private var key: String?
  private var loader: Loader?
  private var request: Task<Void, Never>?
  private var generation = UUID()
  private final class WeakFeed {
    weak var value: BrowseFeedModel?
    init(_ value: BrowseFeedModel) { self.value = value }
  }
  private static var diagnosticFeeds: [WeakFeed] = []
  init() {
    if PerformanceOptions.requested { Self.diagnosticFeeds.append(WeakFeed(self)) }
  }
  static var diagnosticLiveCount: Int {
    diagnosticFeeds.removeAll { $0.value == nil }
    return diagnosticFeeds.count
  }

  func activate(key newKey: String, refreshToken: Int, loader newLoader: @escaping Loader) {
    if key != newKey {
      cancel()
      if let key { states[key] = state }
      key = newKey
      state = states[newKey] ?? BrowseFeedState()
    }
    loader = newLoader
    if refreshTokens[newKey] != refreshToken {
      refreshTokens[newKey] = refreshToken
      reset()
    } else if state.items.isEmpty && state.error == nil && state.hasMore {
      loadNext()
    }
  }

  func refresh() {
    reset()
  }

  func cancel() {
    generation = UUID()
    request?.cancel()
    request = nil
    state.isLoading = false
  }
  /// A disappearing view must release its saved request closure as well as its task.
  /// reset() still uses cancel() so refreshing keeps the active loader.
  func deactivate() {
    cancel()
    loader = nil
  }

  func loadNext() {
    guard !state.isLoading, state.hasMore, let key, let loader else { return }
    let revision = generation
    let cursor = state.nextCursor
    state.isLoading = true
    state.error = nil
    request = Task { @MainActor [weak self] in
      do {
        let page = try await loader(cursor)
        try Task.checkCancellation()
        guard let self, self.generation == revision, self.key == key else { return }
        var known = Set(self.state.items.map(\.id))
        let additions = page.items.filter { known.insert($0.id).inserted }
        self.state.items.append(contentsOf: additions)
        self.state.consecutiveEmptyPages = additions.isEmpty ? self.state.consecutiveEmptyPages + 1 : 0
        let next = page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.state.nextCursor = next
        self.state.hasMore = next != nil && next != "" && next != cursor
        if self.state.hasMore && self.state.consecutiveEmptyPages >= 3 {
          self.state.error = "连续分页没有返回新视频，可重试继续加载。"
          self.state.consecutiveEmptyPages = 0
        }
      } catch is CancellationError {
      } catch {
        guard let self, self.generation == revision, self.key == key else { return }
        self.state.error = error.localizedDescription
      }
      guard let self, self.generation == revision, self.key == key else { return }
      self.state.isLoading = false
      self.request = nil
      self.states[key] = self.state
      if self.state.items.isEmpty && self.state.hasMore && self.state.error == nil {
        self.loadNext()
      }
    }
  }

  private func reset() {
    cancel()
    state = BrowseFeedState()
    if let key { states[key] = state }
    loadNext()
  }
}

@MainActor final class BrowsePartitionDirectory: ObservableObject {
  @Published private(set) var partitions: [VideoPartition] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  private var loaded = false
  private var request: Task<Void, Never>?
  private var generation = UUID()

  func loadIfNeeded(service: BiliService) {
    guard !loaded, !isLoading else { return }
    load(service: service)
  }

  func load(service: BiliService) {
    cancel()
    let revision = generation
    isLoading = true
    error = nil
    request = Task { @MainActor [weak self] in
      do {
        let result = try await service.videoPartitions()
        try Task.checkCancellation()
        guard let self, self.generation == revision else { return }
        self.partitions = result
        self.loaded = true
      } catch is CancellationError {
      } catch {
        guard let self, self.generation == revision else { return }
        self.error = error.localizedDescription
      }
      guard let self, self.generation == revision else { return }
      self.isLoading = false
      self.request = nil
    }
  }

  func cancel() {
    generation = UUID()
    request?.cancel()
    request = nil
    isLoading = false
  }
}
