import ManpingCore
import Foundation
@preconcurrency import UserNotifications

/// Read-only polling; authentication remains in the injected fetcher. OS delivery is created lazily.
@MainActor final class M7NotificationCoordinator {
  typealias Fetch = @Sendable () async throws -> [M7MomentNotification]
  private let fetch: Fetch
  /// Followed rooms that are live right now, as `page: "live"` notifications keyed by room.
  private let liveFetch: Fetch?
  private let defaults: any PreferencesStore
  private let didOpen: ((String, String) -> Void)?
  private let report: ((String) -> Void)?
  private var adapter: (any M7NotificationDeliveryAdapter)?
  private var identityController: M7NotificationIdentityController?
  private var pollTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var configuration: M7NotificationConfiguration?
  private enum PollError: Error { case timeout }

  init(defaults: any PreferencesStore = PerformanceEnvironment.defaults, adapter: (any M7NotificationDeliveryAdapter)? = nil,
    fetch: @escaping Fetch, liveFetch: Fetch? = nil, didOpen: ((String, String) -> Void)? = nil,
    report: ((String) -> Void)? = nil) {
    self.defaults = defaults; self.adapter = adapter; self.fetch = fetch; self.liveFetch = liveFetch
    self.didOpen = didOpen; self.report = report
    if let adapter { identityController = M7NotificationIdentityController(adapter: adapter) }
  }

  func configure(enabled: Bool, momentEnabled: Bool, liveEnabled: Bool = false, identityID: String?, fixture: Bool) {
    let next = M7NotificationConfiguration(enabled: enabled, moments: momentEnabled, live: liveEnabled && liveFetch != nil,
      identityID: identityID, fixture: fixture)
    guard configuration != next else { return }
    generation &+= 1; pollTask?.cancel(); pollTask = nil; configuration = next
    // Fixtures and a bare executable must never construct UNUserNotificationCenter.
    if fixture {
      if let identityController {
        let expected = generation
        pollTask = Task { [weak self] in
          guard let self, isCurrent(expected) else { return }
          await identityController.configure(next)
        }
      }
      return
    }
    if identityController == nil {
      guard Bundle.main.bundleIdentifier != nil else {
        if enabled { report?("系统通知需要从 .app 包启动应用。") }
        return
      }
      let delivery = M7UNNotificationDeliveryAdapter(open: { [weak self] value in self?.open(value) },
        canPresent: { [weak self] value in self?.canOpen(value) ?? false })
      adapter = delivery; identityController = M7NotificationIdentityController(adapter: delivery)
    }
    guard let identityController else { return }
    let expectedGeneration = generation
    pollTask = Task { [weak self] in
      guard let self, isCurrent(expectedGeneration) else { return }
      // Enumeration removes notifications from previous processes before authorization or polling.
      await identityController.configure(next)
      guard isCurrent(expectedGeneration), let scope = next.scope else { return }
      do {
        let allowed = try await identityController.authorize(expectedScope: scope)
        guard isCurrent(expectedGeneration) else { return }
        guard allowed else { report?("通知未获系统授权，请在系统设置中允许通知。"); return }
      } catch {
        guard isCurrent(expectedGeneration) else { return }
        report?("无法请求系统通知授权。"); return
      }
      // Both loops are children of this task: cancelling it (or a new generation) ends them.
      async let moments: Void = next.moments ? momentLoop(scope: scope, generation: expectedGeneration) : ()
      async let live: Void = next.live ? liveLoop(scope: scope, generation: expectedGeneration) : ()
      _ = await (moments, live)
    }
  }

  private func momentLoop(scope: String, generation expected: UInt64) async {
    let key = "Manping.notificationMomentIDs." + scope
    repeat {
      await poll(key: key, scope: scope, generation: expected)
      guard isCurrent(expected) else { return }
      do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
    } while isCurrent(expected)
  }

  private func liveLoop(scope: String, generation expected: UInt64) async {
    let key = "Manping.notificationLiveIDs." + scope
    // Who is live is a fresh question every launch: the first check is a silent baseline.
    defaults.removeObject(forKey: key)
    repeat {
      await pollLive(key: key, scope: scope, generation: expected)
      guard isCurrent(expected) else { return }
      do { try await Task.sleep(for: .seconds(3 * 60)) } catch { return }
    } while isCurrent(expected)
  }

  func stop() {
    generation &+= 1; pollTask?.cancel(); pollTask = nil
    configuration = M7NotificationConfiguration(enabled: false, moments: false, identityID: nil, fixture: configuration?.fixture ?? false)
    guard let identityController, configuration?.fixture == false else { return }
    let disabled = configuration!
    let expected = generation
    pollTask = Task { [weak self] in
      guard let self, isCurrent(expected) else { return }
      await identityController.configure(disabled)
    }
  }
  private func isCurrent(_ expected: UInt64) -> Bool { generation == expected && !Task.isCancelled }
  private func open(_ delivery: M7NotificationDelivery) {
    // A queued delegate callback is checked against current MainActor state before any navigation.
    guard canOpen(delivery) else { return }
    didOpen?(delivery.moment.page, delivery.moment.mediaID)
  }
  private func canOpen(_ delivery: M7NotificationDelivery) -> Bool {
    guard let configuration else { return false }
    return M7NotificationIdentityPolicy.canOpen(delivery, configuration: configuration)
  }
  private func pollLive(key: String, scope: String, generation expected: UInt64) async {
    guard let identityController, let liveFetch else { return }
    do {
      let rooms = try await withThrowingTaskGroup(of: [M7MomentNotification].self) { group in
        group.addTask { try await liveFetch() }
        group.addTask { try await Task.sleep(for: .seconds(10)); throw PollError.timeout }
        defer { group.cancelAll() }
        return try await group.next() ?? []
      }
      guard isCurrent(expected) else { return }
      let plan = M7LiveNotificationPolicy.plan(rooms, previousIDs: (defaults.object(forKey: key) as? [String]))
      for (index, room) in plan.notifications.enumerated() {
        guard isCurrent(expected) else { return }
        if index > 0 { try await Task.sleep(for: .seconds(1)); guard isCurrent(expected) else { return } }
        guard try await identityController.deliver(room, expectedScope: scope), isCurrent(expected) else { return }
      }
      guard isCurrent(expected) else { return }
      defaults.set(plan.rememberedIDs, forKey: key)
    } catch is CancellationError { return }
    catch {
      // Live checks are frequent; a transient failure waits quietly for the next one.
      return
    }
  }
  private func poll(key: String, scope: String, generation expected: UInt64) async {
    guard let identityController else { return }
    do {
      let fetch = self.fetch
      let moments = try await withThrowingTaskGroup(of: [M7MomentNotification].self) { group in
        group.addTask { try await fetch() }
        group.addTask { try await Task.sleep(for: .seconds(10)); throw PollError.timeout }
        defer { group.cancelAll() }
        return try await group.next() ?? []
      }
      guard isCurrent(expected) else { return }
      let plan = M7MomentNotificationPolicy.plan(moments, previousIDs: (defaults.object(forKey: key) as? [String]) ?? [])
      for (index, moment) in plan.notifications.enumerated() {
        guard isCurrent(expected) else { return }
        if index > 0 { try await Task.sleep(for: .seconds(1)); guard isCurrent(expected) else { return } }
        guard try await identityController.deliver(moment, expectedScope: scope), isCurrent(expected) else { return }
      }
      guard isCurrent(expected) else { return }
      defaults.set(plan.rememberedIDs, forKey: key)
    } catch is CancellationError { return }
    catch {
      guard isCurrent(expected) else { return }
      report?("视频动态通知检查失败，将在下次轮询重试。")
    }
  }
}

@MainActor private final class M7UNNotificationDeliveryAdapter: NSObject, M7NotificationDeliveryAdapter, UNUserNotificationCenterDelegate {
  private let center: UNUserNotificationCenter
  private let open: (M7NotificationDelivery) -> Void
  private let canPresent: (M7NotificationDelivery) -> Bool
  init(open: @escaping (M7NotificationDelivery) -> Void, canPresent: @escaping (M7NotificationDelivery) -> Bool) {
    center = .current(); self.open = open; self.canPresent = canPresent; super.init(); center.delegate = self
  }
  func pendingIDs() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
  func deliveredIDs() async -> [String] { await center.deliveredNotifications().map { $0.request.identifier } }
  func removeIDs(_ ids: [String]) async {
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }
  func authorize() async throws -> Bool {
    let status = await center.notificationSettings().authorizationStatus
    if status == .notDetermined { return try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    return status == .authorized || status == .provisional
  }
  func add(_ delivery: M7NotificationDelivery) async throws {
    let content = UNMutableNotificationContent()
    content.title = delivery.moment.title; content.body = delivery.moment.publisher; content.sound = .default
    content.userInfo = ["page": delivery.moment.page, "mediaID": delivery.moment.mediaID,
      "identityScope": delivery.scope, "momentID": delivery.moment.id]
    try await center.add(UNNotificationRequest(identifier: delivery.identifier, content: content, trigger: nil))
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    // Do not present a late notification from an account which has already been replaced.
    let completion = NotificationPresentationCompletion(completionHandler)
    let delivery = Self.delivery(notification.request)
    Task { @MainActor [weak self] in
      guard let self else { completion.finish([]); return }
      completion.finish(canPresent(delivery) ? [.banner, .sound] : [])
    }
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    let delivery = Self.delivery(response.notification.request)
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      Task { @MainActor [weak self] in self?.open(delivery) }
    }
    completionHandler()
  }
  nonisolated private static func delivery(_ request: UNNotificationRequest) -> M7NotificationDelivery {
    let values = request.content.userInfo
    return M7NotificationDelivery(identifier: request.identifier, scope: values["identityScope"] as? String ?? "",
      moment: M7MomentNotification(id: values["momentID"] as? String ?? "", title: "", publisher: "",
        page: values["page"] as? String ?? "", mediaID: values["mediaID"] as? String ?? ""))
  }
}

/// UN permits its escaping completion to be called from any queue. The box owns
/// it once while the main actor checks the current account before presentation.
private final class NotificationPresentationCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var action: ((UNNotificationPresentationOptions) -> Void)?
  init(_ action: @escaping (UNNotificationPresentationOptions) -> Void) { self.action = action }
  func finish(_ options: UNNotificationPresentationOptions) {
    lock.lock(); let callback = action; action = nil; lock.unlock()
    callback?(options)
  }
}
