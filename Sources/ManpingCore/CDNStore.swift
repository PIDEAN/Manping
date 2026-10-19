import Foundation

/// Local CDN memory: custom and disabled hosts, nodes learned from real playback (at most 24,
/// expiring after 30 days) and the last benchmark round. Only host names and summary numbers
/// are stored, never media URLs, signatures or cookies.
public final class CDNStore: @unchecked Sendable {
  public struct Learned: Codable, Sendable, Equatable {
    public var host: String
    public var lastSuccess: Date
    public var stalls: Int
  }
  private struct State: Codable {
    var custom: [String] = []
    var disabled: [String] = []
    var learned: [Learned] = []
    var results: [CDNBenchmarkResult] = []
    var resultsAt: Date?
    var resultsNetwork: String?
  }

  private let defaults: UserDefaults
  private let key: String
  private let lock = NSLock()
  private var state: State
  public static let learnedLimit = 24
  public static let learnedLifetime: TimeInterval = 30 * 24 * 3600

  public init(defaults: UserDefaults = .standard, key: String = "Manping.cdnStore.v1") {
    self.defaults = defaults; self.key = key
    state = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
  }

  public var custom: [CDNHost] { lock.withLock { state.custom.compactMap(CDNHost.init) } }
  public var disabled: Set<CDNHost> { lock.withLock { Set(state.disabled.compactMap(CDNHost.init)) } }

  public func learned(now: Date = Date()) -> [CDNHost] {
    lock.withLock {
      state.learned.filter { now.timeIntervalSince($0.lastSuccess) < Self.learnedLifetime }
        .sorted { ($0.stalls, -$0.lastSuccess.timeIntervalSince1970) < ($1.stalls, -$1.lastSuccess.timeIntervalSince1970) }
        .compactMap { CDNHost($0.host) }
    }
  }

  /// Cached benchmark results for `network`, or nothing if the network changed.
  public func results(network: String) -> (results: [CDNBenchmarkResult], at: Date)? {
    lock.withLock {
      guard let at = state.resultsAt, state.resultsNetwork == network, !state.results.isEmpty else { return nil }
      return (state.results, at)
    }
  }

  public func addCustom(_ host: CDNHost) { mutate { if !$0.custom.contains(host.name) { $0.custom.append(host.name) } } }
  public func removeCustom(_ host: CDNHost) { mutate { $0.custom.removeAll { $0 == host.name } } }
  public func setDisabled(_ host: CDNHost, _ disabled: Bool) {
    mutate {
      $0.disabled.removeAll { $0 == host.name }
      if disabled { $0.disabled.append(host.name) }
    }
  }

  public func saveResults(_ results: [CDNBenchmarkResult], network: String, at: Date = Date()) {
    mutate {
      $0.results = results; $0.resultsAt = at; $0.resultsNetwork = network
    }
  }

  public func clearResults() { mutate { $0.results = []; $0.resultsAt = nil } }

  /// Records a node that served real playback; learned nodes join later candidate windows.
  public func learn(_ host: CDNHost, now: Date = Date()) {
    mutate { state in
      if let index = state.learned.firstIndex(where: { $0.host == host.name }) {
        state.learned[index].lastSuccess = now
        state.learned[index].stalls = max(0, state.learned[index].stalls - 1)
      } else {
        state.learned.append(Learned(host: host.name, lastSuccess: now, stalls: 0))
      }
      state.learned = Array(state.learned.filter { now.timeIntervalSince($0.lastSuccess) < Self.learnedLifetime }
        .sorted { $0.lastSuccess > $1.lastSuccess }.prefix(Self.learnedLimit))
    }
  }

  /// Nodes that stall in real playback sink in the learned ranking.
  public func recordStall(_ host: String) {
    mutate { state in
      if let index = state.learned.firstIndex(where: { $0.host == host }) { state.learned[index].stalls += 1 }
    }
  }

  private func mutate(_ change: (inout State) -> Void) {
    let data: Data? = lock.withLock {
      change(&state)
      return try? JSONEncoder().encode(state)
    }
    if let data { defaults.set(data, forKey: key) }
  }
}
