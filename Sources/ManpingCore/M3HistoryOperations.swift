import Combine
import Foundation

public enum HistoryBusiness: String, CaseIterable, Sendable {
  case archive, live, article
  public var title: String {
    switch self { case .archive: "视频"; case .live: "直播"; case .article: "专栏" }
  }
}
public struct HistoryRecordKey: Hashable, Sendable {
  public let kid: Int64
  public let business: HistoryBusiness
  public init(kid: Int64, business: HistoryBusiness) { self.kid = kid; self.business = business }
}
public struct HistoryRecord: Identifiable, Sendable, Equatable {
  public var id: String { "\(key.business.rawValue):\(key.kid)" }
  public let key: HistoryRecordKey
  public let item: RPCHistoryItem
  public var entry: LibraryEntry { .history(item) }
  public init?(item: RPCHistoryItem, business: HistoryBusiness) {
    guard item.id > 0 else { return nil }
    switch (business, item.content) {
    case (.archive, .video), (.live, .live), (.article, .article): break
    default: return nil
    }
    key = HistoryRecordKey(kid: item.id, business: business); self.item = item
  }
}
public struct HistorySearchPage: Sendable {
  public let items: [RPCHistoryItem]
  public let hasMore: Bool
  public let total: Int
}
public struct HistoryDateSection: Identifiable, Sendable {
  public var id: Date { day }
  public let day: Date
  public let records: [HistoryRecord]
  public func title(now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(day, inSameDayAs: now) { return "今天" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "昨天" }
    return day.formatted(date: .abbreviated, time: .omitted)
  }
  public static func grouped(_ records: [HistoryRecord], calendar: Calendar = .current) -> [Self] {
    let groups = Dictionary(grouping: records) { calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0.item.viewedAt))) }
    return groups.keys.sorted(by: >).map { Self(day: $0, records: groups[$0]!.sorted { $0.item.viewedAt > $1.item.viewedAt }) }
  }
}
public enum HistoryConfirmation: Equatable, Sendable {
  case remove(HistoryRecordKey), clear(HistoryBusiness)
}

/// All mutations use the identity that produced the loaded rows, including confirmation time.
@MainActor public final class HistoryPageModel: ObservableObject {
  @Published public private(set) var records: [HistoryRecord] = []
  @Published public private(set) var business: HistoryBusiness = .archive
  @Published public private(set) var keyword = ""
  @Published public private(set) var isLoading = false
  @Published public private(set) var hasMore = false
  @Published public private(set) var busy = false
  @Published public private(set) var error: String?
  @Published public private(set) var confirmation: HistoryConfirmation?
  @Published public private(set) var identityVersion = 0
  private let service: BiliService
  private let rpc: LibraryRPCService?
  private var loadedIdentity: AuthSnapshot?
  private var requestIdentity: AuthSnapshot?
  private var confirmationIdentity: AuthSnapshot?
  private var flight: Task<Void, Never>?
  private var operation: Task<Bool, Never>?
  private var identityTask: Task<Void, Never>?
  private var generation = UUID()
  private var cursor: Int64 = 0
  private var page = 1
  private var emptyPages = 0
  public init(service: BiliService, rpc: LibraryRPCService?) {
    self.service = service; self.rpc = rpc
    identityTask = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let contexts = [self.loadedIdentity, self.requestIdentity, self.confirmationIdentity].compactMap { $0 }
        if contexts.contains(where: { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision }) {
          self.clear(); self.identityVersion &+= 1
          self.error = "登录状态已改变，请刷新历史。"
        }
      }
    }
  }
  deinit { identityTask?.cancel(); flight?.cancel(); operation?.cancel() }
  public func cancelRequests() {
    generation = UUID(); flight?.cancel(); flight = nil; operation?.cancel(); operation = nil
    isLoading = false; busy = false; requestIdentity = nil; cancelConfirmation()
  }
  private func clear() {
    cancelRequests(); records = []; loadedIdentity = nil; cursor = 0; page = 1; emptyPages = 0; hasMore = false
  }
  public func load(business: HistoryBusiness = .archive, keyword: String = "") async {
    clear(); self.business = business; self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    error = nil; hasMore = true; await loadNext()
  }
  public func refresh() async { await load(business: business, keyword: keyword) }
  public func exitSearch() async { await load(business: business) }
  public func loadNext() async {
    guard !isLoading, hasMore, !busy, confirmation == nil else { return }
    let revision = generation; let chosenBusiness = business; let chosenKeyword = keyword
    let nextPage = page; let nextCursor = cursor
    isLoading = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      let expected: AuthSnapshot
      if let loaded = self.loadedIdentity { expected = loaded }
      else { expected = await self.service.authSnapshot() }
      guard self.generation == revision, !Task.isCancelled else { return }
      self.requestIdentity = expected
      do {
        guard let rpc = self.rpc else { throw BiliError.dependency("无法初始化历史服务") }
        let items: [RPCHistoryItem]; let more: Bool; let newCursor: Int64
        if chosenKeyword.isEmpty {
          let result = try await rpc.historyRecords(business: chosenBusiness, max: nextCursor, expectedIdentity: expected)
          items = result.items; more = result.hasMore && result.max > 0 && result.max != nextCursor; newCursor = result.max
        } else {
          let result = try await rpc.historySearchRecords(keyword: chosenKeyword, page: nextPage, expectedIdentity: expected)
          items = result.items; more = result.hasMore; newCursor = nextCursor
        }
        try await self.check(revision, expected: expected)
        let rowBusiness = chosenKeyword.isEmpty ? chosenBusiness : .archive
        var known = Set(self.records.map(\.id))
        let additions = items.compactMap { HistoryRecord(item: $0, business: rowBusiness) }.filter { known.insert($0.id).inserted }
        self.records += additions; self.loadedIdentity = expected; self.cursor = newCursor; self.page += 1
        self.emptyPages = additions.isEmpty ? self.emptyPages + 1 : 0
        self.hasMore = more && self.emptyPages < 3
        if more && self.emptyPages >= 3 { self.error = "分页未返回新历史记录，请刷新。" }
      } catch is CancellationError {} catch {
        guard self.generation == revision else { return }
        self.error = Self.message(error)
      }
      guard self.generation == revision else { return }
      self.isLoading = false; self.flight = nil; self.requestIdentity = nil
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  public func requestRemove(_ record: HistoryRecord) {
    guard !busy, !isLoading, let loadedIdentity, records.contains(where: { $0.id == record.id }) else { return }
    confirmation = .remove(record.key); confirmationIdentity = loadedIdentity
  }
  public func requestClear() {
    guard !busy, !isLoading, keyword.isEmpty, !records.isEmpty, let loadedIdentity else { return }
    confirmation = .clear(business); confirmationIdentity = loadedIdentity
  }
  public func cancelConfirmation() { confirmation = nil; confirmationIdentity = nil }
  private func startConfirmation() -> (UUID, Task<Bool, Never>)? {
    guard !busy, let action = confirmation, let expected = confirmationIdentity else { return nil }
    let revision = generation
    cancelConfirmation(); busy = true; error = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      do {
        try await self.check(revision, expected: expected)
        guard let rpc = self.rpc else { throw BiliError.dependency("无法初始化历史服务") }
        switch action {
        case .remove(let key): try await rpc.deleteHistory(key, expectedIdentity: expected)
        case .clear(let business): try await rpc.clearHistory(business, expectedIdentity: expected)
        }
        try await self.check(revision, expected: expected)
        switch action {
        case .remove(let key): self.records.removeAll { $0.key == key }
        case .clear: self.records = []; self.hasMore = false
        }
        return true
      } catch is CancellationError { return false } catch {
        guard self.generation == revision else { return false }
        self.error = Self.message(error); return false
      }
    }
    operation = task
    return (revision, task)
  }
  /// Capture the approved identity synchronously before SwiftUI dismisses the dialog.
  public func confirmInBackground() {
    guard let (revision, task) = startConfirmation() else { return }
    Task { [weak self] in
      _ = await task.value
      guard let self, self.generation == revision else { return }
      self.busy = false; self.operation = nil
    }
  }
  @discardableResult public func confirm() async -> Bool {
    guard let (revision, task) = startConfirmation() else { return false }
    let success = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    if generation == revision { busy = false; operation = nil }
    return success
  }
  private func check(_ revision: UUID, expected: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    try Task.checkCancellation()
    guard generation == revision, current.epoch == expected.epoch,
      current.identityRevision == expected.identityRevision else { throw CancellationError() }
  }
  private static func message(_ error: Error) -> String {
    switch error {
    case AuthFailure.needsLogin, BiliRPCError.needsLogin: "请先登录账号，再查看或管理历史。"
    default: error.localizedDescription
    }
  }
}
