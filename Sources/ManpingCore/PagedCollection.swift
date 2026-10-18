import Combine
import Foundation

/// A reusable page loader. Reset invalidates late replies even if the transport ignores cancellation.
public struct PageBatch<Item: Sendable>: Sendable {
  public let items: [Item]
  public let hasMore: Bool
  public init(items: [Item], hasMore: Bool) {
    self.items = items
    self.hasMore = hasMore
  }
}

@MainActor public final class PagedCollection<Item: Identifiable & Sendable>: ObservableObject {
  public typealias Loader = @Sendable (Int) async throws -> PageBatch<Item>
  @Published public private(set) var items: [Item] = []
  @Published public private(set) var isLoading = false
  @Published public private(set) var error: String?
  @Published public private(set) var hasMore = true
  private var nextPage = 1
  private var generation = UUID()
  private var task: Task<Void, Never>?
  private var loader: Loader?
  public init() {}

  public func reset(loader: @escaping Loader) async {
    cancel()
    self.loader = loader
    items = []
    error = nil
    nextPage = 1
    hasMore = true
    await loadNext()
  }
  public func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    isLoading = false
  }
  public func loadNext() async {
    guard !isLoading, hasMore, let loader else { return }
    let revision = generation
    let page = nextPage
    isLoading = true
    error = nil
    let request = Task { @MainActor [weak self] in
      do {
        let batch = try await loader(page)
        try Task.checkCancellation()
        guard let self, self.generation == revision else { return }
        var known = Set(self.items.map(\.id))
        self.items.append(contentsOf: batch.items.filter { known.insert($0.id).inserted })
        self.nextPage += 1
        self.hasMore = batch.hasMore && !batch.items.isEmpty
      } catch is CancellationError {
      } catch {
        guard let self, self.generation == revision else { return }
        self.error = error.localizedDescription
      }
      guard let self, self.generation == revision else { return }
      self.isLoading = false
      self.task = nil
    }
    task = request
    await withTaskCancellationHandler {
      await request.value
    } onCancel: {
      request.cancel()
    }
  }
}
