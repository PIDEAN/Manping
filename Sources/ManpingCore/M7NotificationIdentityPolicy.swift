import CryptoKit
import Foundation

public struct M7NotificationConfiguration: Sendable, Equatable {
  public let enabled: Bool
  public let moments: Bool
  /// Followed rooms going live.
  public let live: Bool
  public let identityID: String?
  public let fixture: Bool
  public init(enabled: Bool, moments: Bool, live: Bool = false, identityID: String?, fixture: Bool) {
    self.enabled = enabled; self.moments = moments; self.live = live; self.identityID = identityID; self.fixture = fixture
  }
  public var scope: String? {
    guard enabled, moments || live, !fixture, let identityID, !identityID.isEmpty else { return nil }
    return SHA256.hash(data: Data(identityID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
  }
}

public struct M7NotificationDelivery: Sendable, Equatable {
  public let identifier: String
  public let scope: String
  public let moment: M7MomentNotification
  public init(identifier: String, scope: String, moment: M7MomentNotification) {
    self.identifier = identifier; self.scope = scope; self.moment = moment
  }
}

public protocol M7NotificationDeliveryAdapter: Sendable {
  func pendingIDs() async -> [String]
  func deliveredIDs() async -> [String]
  func removeIDs(_ ids: [String]) async
  func authorize() async throws -> Bool
  func add(_ delivery: M7NotificationDelivery) async throws
}

public enum M7NotificationIdentityPolicy {
  public static let ownedPrefix = "Manping.Moment."
  /// Live-start notifications use ids of the form `live-<room>`.
  public static let liveIDPrefix = "live-"
  public static func prefix(scope: String) -> String { ownedPrefix + scope + "." }
  public static func removalIDs(_ ids: [String], configuration: M7NotificationConfiguration) -> [String] {
    var seen = Set<String>()
    return ids.filter { identifier in
      guard identifier.hasPrefix(ownedPrefix), seen.insert(identifier).inserted else { return false }
      guard let scope = configuration.scope else { return true }
      let own = prefix(scope: scope)
      guard identifier.hasPrefix(own) else { return true }
      // Same account: drop the kinds that were turned off (live ids are "live-<room>").
      let isLive = identifier.dropFirst(own.count).hasPrefix(liveIDPrefix)
      return isLive ? !configuration.live : !configuration.moments
    }
  }
  public static func canOpen(_ delivery: M7NotificationDelivery, configuration: M7NotificationConfiguration) -> Bool {
    guard let scope = configuration.scope, delivery.scope == scope,
      !delivery.moment.id.isEmpty, !delivery.moment.mediaID.isEmpty,
      ["video", "episode", "live"].contains(delivery.moment.page) else { return false }
    // Each kind opens only while its own switch is on.
    let isLive = delivery.moment.page == "live"
    guard isLive ? configuration.live && delivery.moment.id.hasPrefix(liveIDPrefix) : configuration.moments else { return false }
    return delivery.identifier.hasPrefix(prefix(scope: scope) + delivery.moment.id + ".")
  }
}

/// The same identity and late-delivery policy is shared by production UN delivery and fixture adapters.
public actor M7NotificationIdentityController {
  private let adapter: any M7NotificationDeliveryAdapter
  private var configuration = M7NotificationConfiguration(enabled: false, moments: false, identityID: nil, fixture: false)
  private var generation: UInt64 = 0
  public init(adapter: any M7NotificationDeliveryAdapter) { self.adapter = adapter }
  public func configure(_ next: M7NotificationConfiguration) async {
    generation &+= 1; configuration = next
    let expected = generation
    async let pending = adapter.pendingIDs()
    async let delivered = adapter.deliveredIDs()
    let (pendingIDs, deliveredIDs) = await (pending, delivered)
    let ids = pendingIDs + deliveredIDs
    guard generation == expected else { return }
    let removals = M7NotificationIdentityPolicy.removalIDs(ids, configuration: next)
    if !removals.isEmpty { await adapter.removeIDs(removals) }
  }
  public func authorize(expectedScope: String) async throws -> Bool {
    guard configuration.scope == expectedScope, !Task.isCancelled else { return false }
    let expected = generation
    let result = try await adapter.authorize()
    return result && generation == expected && configuration.scope == expectedScope && !Task.isCancelled
  }
  public func deliver(_ moment: M7MomentNotification, expectedScope: String) async throws -> Bool {
    guard configuration.scope == expectedScope, !Task.isCancelled, !moment.id.isEmpty else { return false }
    let expected = generation
    let delivery = M7NotificationDelivery(identifier: M7NotificationIdentityPolicy.prefix(scope: expectedScope)
      + moment.id + "." + UUID().uuidString, scope: expectedScope, moment: moment)
    try await adapter.add(delivery)
    guard generation == expected, configuration.scope == expectedScope, !Task.isCancelled else {
      await adapter.removeIDs([delivery.identifier]); return false
    }
    return true
  }
  public func canOpen(_ delivery: M7NotificationDelivery) -> Bool {
    M7NotificationIdentityPolicy.canOpen(delivery, configuration: configuration)
  }
}
