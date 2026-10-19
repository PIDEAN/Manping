import Combine
import Foundation
import ManpingCore
import QuartzCore

/// 只看 3 分钟 依次播放 at the playback layer: owned by `AppModel`, so it keeps working whether
/// the picture is in the main window, the separate window or 小窗, and whether or not the AI
/// panel is on screen. The rules live in `AIClipPlaybackMachine`; this class feeds it the
/// player's clock and carries out its seeks and pauses. While it runs, 连续播放 and automatic
/// 跳过片头片尾 hold off (`AppModel` asks `isActive`).
@MainActor final class ClipPlaybackController: ObservableObject {
  @Published private(set) var phase: AIClipPlaybackMachine.Phase = .idle
  private var media: String?
  /// The answer being played; the clip card shows progress only for its own answer.
  @Published private(set) var turnID: String?
  @Published private(set) var clipCount = 0
  private var machine = AIClipPlaybackMachine()
  private weak var player: PlayerModel?
  private var observation: AnyCancellable?
  private var seekObservation: AnyCancellable?
  private var watchdog: Task<Void, Never>?
  private var currentMedia: () -> String? = { nil }
  private var activePlayer: () -> PlayerModel? = { nil }
  private var seekMedia: (Double) -> Void = { _ in }

  var isActive: Bool { machine.isActive }
  func isPlaying(turn id: String) -> Bool { machine.isActive && turnID == id }

  func configure(currentMedia: @escaping () -> String?, activePlayer: @escaping () -> PlayerModel?, seek: @escaping (Double) -> Void) {
    self.currentMedia = currentMedia; self.activePlayer = activePlayer; seekMedia = seek
  }

  /// Plays a validated result on the media it belongs to; anything else is ignored.
  func start(_ result: AIClipsResult, media: String, turnID: String) {
    guard result.valid, activePlayer()?.browsingSuspended != true, currentMedia() == media, let player = activePlayer() else { return }
    stop(.stopped)
    let actions = machine.start(clips: result.clips.map { AITimeRange(start: $0.start, end: $0.end) }, media: media,
      position: player.time, now: CACurrentMediaTime())
    guard machine.isActive else { return }
    self.player = player; self.media = media; self.turnID = turnID; clipCount = machine.clips.count
    // Act after the clock finished publishing (a seek inside the publication would re-enter it).
    observation = player.clock.$time.sink { [weak self] time in
      DispatchQueue.main.async { self?.tick(time) }
    }
    // Seeks are reported synchronously, so the machine can tell its own (issued just now from
    // `perform`) from the user's: dragging, ←/→, a chapter or a timestamp, however small.
    seekObservation = player.seekRequests.sink { [weak self] target in self?.seekRequested(target) }
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        self.check()
      }
    }
    perform(actions)
    publish()
  }

  /// Leaves the mode (the 停止 button, another video, the player closing).
  func stop(_ reason: AIClipPlaybackMachine.Exit = .stopped) {
    guard machine.isActive else { return }
    machine.stop(reason)
    finish()
  }

  private func tick(_ time: Double) {
    guard machine.isActive else { return }
    guard let player, activePlayer() === player else { stop(.mediaChanged); return }
    perform(machine.tick(time: time, media: currentMedia(), now: CACurrentMediaTime()))
    if machine.isActive { publish() } else { finish() }
  }
  private func seekRequested(_ target: Double) {
    guard machine.isActive, machine.seekRequested(to: target) else { return }
    finish()
  }
  private func check() {
    guard machine.isActive else { return }
    guard let player, activePlayer() === player, currentMedia() == media else { stop(.mediaChanged); return }
    machine.check(now: CACurrentMediaTime())
    if machine.isActive { publish() } else { finish() }
  }
  private func perform(_ actions: [AIClipPlaybackMachine.Action]) {
    for action in actions {
      switch action {
      case .seek(let seconds): seekMedia(seconds)
      case .play: if player?.paused == true { player?.set("pause", "no") }
      case .pause: if player?.paused == false { player?.set("pause", "yes") }
      }
    }
  }
  private func finish() {
    observation = nil; seekObservation = nil; watchdog?.cancel(); watchdog = nil; player = nil
    publish()
  }
  private func publish() {
    if phase != machine.phase { phase = machine.phase }
    if !machine.isActive {
      media = nil
      if turnID != nil { turnID = nil }
    }
  }
}
