import ManpingCore
import Foundation

/// The signed-in account's Bilibili shield list, cached per account and refreshed every six hours
/// (or on demand). Read-only: rules are edited on Bilibili. Players read `shield` when they
/// build their danmaku filter; `onChange` re-applies it to the players that are open.
@MainActor final class DanmakuShieldSync: ObservableObject {
  static let shared = DanmakuShieldSync()
  @Published private(set) var shield: DanmakuAccountShield?
  @Published private(set) var syncing = false
  @Published private(set) var message: String?
  @Published private(set) var signedIn = false
  var onChange: (() -> Void)?
  private var service: BiliService?
  private var mid: Int64?
  private var task: Task<Void, Never>?
  /// Next scheduled refresh (six hours after a sync, 30 minutes after a failure).
  private var schedule: Task<Void, Never>?
  private static let refreshInterval: TimeInterval = 6 * 3600
  private static func key(_ mid: Int64) -> String { "Manping.danmakuAccountShield.\(mid)" }

  /// Called whenever the account changes (nil when signed out).
  func configure(service: BiliService, mid: Int64?) {
    guard mid != self.mid || self.service !== service else { return }
    task?.cancel(); task = nil; schedule?.cancel(); schedule = nil; syncing = false; message = nil
    // Signing out forgets the previous account's cached list as well.
    if mid == nil, let previous = self.mid { PerformanceEnvironment.defaults.removeObject(forKey: Self.key(previous)) }
    self.service = service; self.mid = mid; signedIn = mid != nil
    if let mid, let data = PerformanceEnvironment.defaults.data(forKey: Self.key(mid)),
      let cached = try? JSONDecoder().decode(DanmakuAccountShield.self, from: data) {
      update(cached, store: false)
    } else {
      update(nil, store: false)
    }
    if let mid {
      if shield.map({ Date().timeIntervalSince($0.syncedAt) > Self.refreshInterval }) ?? true { sync(expectedMid: mid) }
      else if let shield { scheduleRefresh(after: Self.refreshInterval - Date().timeIntervalSince(shield.syncedAt)) }
    }
  }

  func sync() { if let mid { schedule?.cancel(); schedule = nil; sync(expectedMid: mid) } }

  func setEnabled(_ enabled: Bool) {
    guard var next = shield, next.enabled != enabled else { return }
    next.enabled = enabled
    update(next, store: true)
  }

  private func sync(expectedMid: Int64) {
    guard let service, task == nil else { return }
    syncing = true; message = nil
    task = Task { [weak self] in
      let identity = await service.authSnapshot()
      do {
        var fetched = try await service.danmakuAccountShield(expectedIdentity: identity)
        guard let self, !Task.isCancelled, self.mid == expectedMid else { return }
        // The switch may have changed while the request ran: keep its current value.
        fetched.enabled = self.shield?.enabled ?? true
        self.update(fetched, store: true)
        self.message = fetched.skipped > 0 ? "已跳过 \(fetched.skipped) 条无效或过慢的正则" : nil
        self.syncing = false; self.task = nil
        self.scheduleRefresh(after: Self.refreshInterval)
      } catch {
        guard let self, !Task.isCancelled, self.mid == expectedMid else { return }
        // A failed sync keeps the cached list and tries again later.
        self.message = "同步失败：\(error.localizedDescription)"
        self.syncing = false; self.task = nil
        self.scheduleRefresh(after: 30 * 60)
      }
    }
  }

  private func scheduleRefresh(after seconds: TimeInterval) {
    schedule?.cancel()
    guard let mid else { return }
    schedule = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(60, seconds)))
      guard let self, !Task.isCancelled, self.mid == mid else { return }
      self.schedule = nil
      self.sync(expectedMid: mid)
    }
  }

  private func update(_ next: DanmakuAccountShield?, store: Bool) {
    if store, let mid, let next, let data = try? JSONEncoder().encode(next) {
      PerformanceEnvironment.defaults.set(data, forKey: Self.key(mid))
    }
    guard next != shield else { return }
    shield = next
    onChange?()
  }
}
