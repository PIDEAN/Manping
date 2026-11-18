import Foundation

/// A server history row or a local checkpoint, tied to one account and one part.
public struct PlaybackBookmark: Codable, Equatable, Sendable {
  public let owner: Int64
  public let aid: Int64
  public let cid: Int64
  public let seconds: Int
  public let updated: TimeInterval

  public init(owner: Int64, aid: Int64, cid: Int64, seconds: Int, updated: TimeInterval) {
    self.owner = owner; self.aid = aid; self.cid = cid; self.seconds = seconds; self.updated = updated
  }

  public static func start(_ seconds: Int, duration: Int) -> Double {
    guard seconds > 0, duration <= 0 || seconds < duration else { return 0 }
    return Double(seconds)
  }
}

@MainActor public final class PlaybackBookmarks {
  private let defaults: any PreferencesStore
  private let key = "Manping.playbackBookmarks.v1"
  private var entries: [PlaybackBookmark]

  public init(defaults: any PreferencesStore) {
    self.defaults = defaults
    entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([PlaybackBookmark].self, from: $0) } ?? []
  }

  public func latestPart(owner: Int64, aid: Int64) -> Int64? {
    guard let last = entries.first(where: { $0.owner == owner && $0.aid == aid }), last.seconds > 0 else { return nil }
    return last.cid
  }

  public func start(owner: Int64?, aid: Int64?, cid: Int64?, duration: Int, history: PlaybackBookmark? = nil) -> Double {
    guard let owner, let aid, let cid else { return 0 }
    let local = entries.first { $0.owner == owner && $0.aid == aid && $0.cid == cid }
    if let history, history.owner == owner, history.aid == aid, history.cid == cid,
      local.map({ $0.updated < history.updated }) ?? true {
      return PlaybackBookmark.start(history.seconds, duration: duration)
    }
    return PlaybackBookmark.start(local?.seconds ?? 0, duration: duration)
  }

  public func save(_ entry: PlaybackBookmark) {
    guard entry.owner >= 0, entry.aid > 0, entry.cid > 0 else { return }
    entries.removeAll { $0.owner == entry.owner && $0.aid == entry.aid && $0.cid == entry.cid }
    entries.insert(entry, at: 0)
    if entries.count > 256 { entries.removeLast(entries.count - 256) }
    if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
  }
}
