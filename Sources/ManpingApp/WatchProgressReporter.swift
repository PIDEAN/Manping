import ManpingCore
import Foundation

/// Writes the watch position to the account's history like the original client: every 30 s
/// while playing, and once more when the video is switched or closed. Paused players and
/// position zero are not reported; nothing is sent while signed out or when the user turned
/// the setting off. Debug playback reports never write to the account.
@MainActor final class WatchProgressReporter {
  struct Item: Equatable {
    let aid: Int64
    let cid: Int64
    var episode: Int64?
    var season: Int64?
  }

  private let service: BiliService
  private let enabled: () -> Bool
  private weak var player: PlayerModel?
  private var item: Item?
  private var timer: Timer?
  private var lastSent: (item: Item, seconds: Int)?

  init(service: BiliService, enabled: @escaping () -> Bool) {
    self.service = service; self.enabled = enabled
  }

  /// Starts reporting for the media now loaded in `player`, closing out the previous one.
  func begin(_ next: Item, player: PlayerModel) {
    if item != next { flush() }
    item = next; self.player = player
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.send(requirePlaying: true) }
    }
  }

  /// Reports the final position (paused or not) and stops.
  func flush() {
    send(requirePlaying: false)
    timer?.invalidate(); timer = nil
    item = nil; player = nil
  }

  private func send(requirePlaying: Bool) {
    guard let item, let player, enabled() else { return }
    let position = player.time
    guard position.isFinite, position >= 1, !requirePlaying || !player.paused else { return }
    let seconds = Int(position)
    if let lastSent, lastSent.item == item, lastSent.seconds == seconds { return }
    lastSent = (item, seconds)
    let service = self.service
    let episode = item.episode.flatMap { id in item.season.map { (id: id, season: $0) } }
    Task {
      // Bound to the identity checked for sign-in: a report that is late for an account switch
      // is dropped instead of being written to the new account.
      _ = try? await service.reportProgressForCurrentAccount(aid: item.aid, cid: item.cid, seconds: seconds, episode: episode)
    }
  }
}
