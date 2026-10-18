import Foundation

public struct PlaybackQueueIdentity: Sendable, Equatable {
  public let epoch: UInt64
  public let revision: UInt64
  public init(_ snapshot: AuthSnapshot) {
    epoch = snapshot.epoch; revision = snapshot.identityRevision
  }
}

/// One bounded playlist. Replacing it is atomic; stale EOF callbacks cannot advance it.
public struct VideoPlaybackQueue: Sendable, Equatable {
  public private(set) var items: [Video] = []
  public private(set) var index = 0
  public private(set) var generation = UUID()
  public private(set) var identity: PlaybackQueueIdentity?
  public init() {}
  public var current: Video? { items.indices.contains(index) ? items[index] : nil }
  public var count: Int { items.count }
  public var position: Int { current == nil ? 0 : index + 1 }
  public var canGoNext: Bool { index + 1 < count }
  public var canGoPrevious: Bool { index > 0 && current != nil }

  public mutating func replace(_ videos: [Video], identity: PlaybackQueueIdentity? = nil) throws {
    guard !videos.isEmpty else { throw BiliError.invalidResponse("播放列表为空") }
    var known = Set<String>()
    for video in videos {
      let validAV = video.aid.map { $0 > 0 } ?? false
      let validBV = video.bvid.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil
      guard (validAV || validBV), video.aid == nil || validAV else {
        throw BiliError.invalidResponse("播放列表包含无效视频")
      }
    }
    items = videos.filter { known.insert($0.id).inserted }
    index = 0; self.identity = identity; generation = UUID()
  }
  @discardableResult public mutating func next(afterEOF expected: UUID? = nil) -> Video? {
    guard expected == nil || expected == generation, canGoNext else { return nil }
    index += 1; generation = UUID(); return current
  }
  @discardableResult public mutating func previous() -> Video? {
    guard canGoPrevious else { return nil }
    index -= 1; generation = UUID(); return current
  }
  @discardableResult public mutating func select(id: String) -> Video? {
    guard let next = items.firstIndex(where: { $0.id == id }) else { return nil }
    index = next; generation = UUID(); return current
  }
  @discardableResult public mutating func invalidate(epoch: UInt64, revision: UInt64) -> Bool {
    guard let identity, identity.epoch != epoch || identity.revision != revision else { return false }
    clear(); return true
  }
  public mutating func clear() {
    items = []; index = 0; identity = nil; generation = UUID()
  }
}
