import Foundation

/// Navigation owns the suspended session; rendering and mpv remain separate owners.
public struct PlaybackBrowsingState: Equatable, Sendable {
  public struct Binding: Equatable, Sendable {
    public let player: UUID
    public let media: String
    public let generation: UUID
    public let epoch: UInt64
    public let revision: UInt64
    public init(player: UUID, media: String, generation: UUID, epoch: UInt64, revision: UInt64) {
      self.player = player; self.media = media; self.generation = generation
      self.epoch = epoch; self.revision = revision
    }
  }
  public struct Suspension: Equatable, Sendable {
    public let binding: Binding
    public let depth: Int
    public let wasPlaying: Bool
  }
  public private(set) var suspension: Suspension?
  public private(set) var isBrowsing = false
  public init() {}
  public var allowsAutomaticAdvance: Bool { !isBrowsing }
  public enum PresentationChange: Sendable { case externalWindow, nativeFullScreen, playbackFullScreen }
  /// Native full-screen transitions keep the current page; explicit picture placement ends browsing.
  public mutating func presentationChanged(_ change: PresentationChange, binding: Binding) -> Bool? {
    switch change {
    case .nativeFullScreen: return nil
    case .externalWindow, .playbackFullScreen: return finishForPlacement(binding: binding)
    }
  }
  public struct EntryEffects: Equatable, Sendable {
    public let cancelNextPlayback: Bool
    public let pause: Bool
  }
  /// A nested page never overwrites the original playback intention or return depth.
  @discardableResult public mutating func enter(binding: Binding, depth: Int, playing: Bool) -> EntryEffects {
    if !isBrowsing {
      isBrowsing = true
      suspension = Suspension(binding: binding, depth: depth, wasPlaying: playing)
    }
    return EntryEffects(cancelNextPlayback: true, pause: true)
  }
  /// nil means a nested return; false means return without permission to resume.
  public mutating func returnToPlayback(binding: Binding, depth: Int, playbackVisible: Bool) -> Bool? {
    guard isBrowsing, playbackVisible else { return nil }
    let resume = suspension.map { $0.binding == binding && $0.depth == depth && $0.wasPlaying } ?? false
    reset()
    return resume
  }
  /// Moving the picture to another window ends suspension, preserving the captured intent.
  public mutating func finishForPlacement(binding: Binding) -> Bool? {
    guard isBrowsing else { return nil }
    let resume = suspension.map { $0.binding == binding && $0.wasPlaying } ?? false
    reset()
    return resume
  }
  /// Identity or queue invalidation revokes auto-resume while leaving the overlay visible.
  public mutating func invalidate() { suspension = nil }
  public mutating func reset() { suspension = nil; isBrowsing = false }
}
