import Foundation

/// One live playback recovery burst. Sustained healthy playback clears nonterminal retries.
/// Once terminal, only explicit refresh or quality change reopens the burst; automatic
/// timer/error/EOF/chat events cannot reset it.
public struct LiveReconnectBudget: Sendable {
  public private(set) var attempts = 0
  public private(set) var terminal = false
  private var healthySince: Double?
  private var lastProgress: Double?
  public init() {}
  public mutating func reset() {
    attempts = 0; terminal = false; healthySince = nil; lastProgress = nil
  }
  /// Samples use monotonic uptime. Missing ticks, a frozen clock or pause break the window.
  public mutating func recordProgress(at now: Double, advancing: Bool, paused: Bool) {
    guard !terminal else { return }
    guard now.isFinite, advancing, !paused else {
      healthySince = nil; lastProgress = nil; return
    }
    if let lastProgress, now >= lastProgress, now - lastProgress <= 2.5 {
      if let healthySince, now - healthySince >= 20 { reset(); return }
    } else { healthySince = now }
    lastProgress = now
  }
  /// An upstream LIVE notification may reopen a normally ended room, but cannot forgive
  /// an exhausted recovery burst even when PREPARING marked the room ended afterwards.
  public func shouldRestartRoom(after event: LiveChatEvent, roomEnded: Bool) -> Bool {
    guard case .liveStarted = event else { return false }
    return roomEnded && !terminal
  }
  public mutating func nextDelay() -> Double? {
    guard !terminal else { return nil }
    guard attempts < 8 else { terminal = true; return nil }
    healthySince = nil; lastProgress = nil
    attempts += 1
    return min(16, pow(2, Double(attempts - 1)))
  }
}
