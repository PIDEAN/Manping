import AppKit
import Combine
import MediaPlayer

/// The root coordinator supplies navigation and cached artwork. This class performs
/// no network requests and never guesses which player owns the current account.
@MainActor final class M7SystemMediaController {
  private var commands: [(MPRemoteCommand, Any)] = []
  private var subscriptions = Set<AnyCancellable>()
  private var artwork: MPMediaItemArtwork?
  private weak var player: PlayerModel?
  private var title = ""
  private var artist = ""
  /// A live stream has no seekable timeline: Control Center shows LIVE instead of a progress bar.
  private var live = false
  func attach(player: PlayerModel, title: String, artist: String, live: Bool = false,
    previous: (@MainActor @Sendable () -> Void)?, next: (@MainActor @Sendable () -> Void)?) {
    clear()
    self.player = player; self.title = title; self.artist = artist; self.live = live
    let center = MPRemoteCommandCenter.shared()
    install(center.playCommand) { [weak player] in player?.requestPlay() }
    install(center.pauseCommand) { [weak player] in player?.set("pause", "yes") }
    install(center.togglePlayPauseCommand) { [weak player] in player?.togglePause() }
    if let previous { install(center.previousTrackCommand, action: previous) }
    else { center.previousTrackCommand.isEnabled = false }
    if let next { install(center.nextTrackCommand, action: next) }
    else { center.nextTrackCommand.isEnabled = false }
    if !live {
      center.changePlaybackPositionCommand.isEnabled = true
      let target = Self.addSeekTarget(center.changePlaybackPositionCommand) { [weak self] position in
        self?.player?.seek(position)
      }
      commands.append((center.changePlaybackPositionCommand, target))
    } else {
      center.changePlaybackPositionCommand.isEnabled = false
    }
    player.clock.$time.combineLatest(player.$duration, player.$paused, player.$speed)
      .sink { [weak self] time, duration, paused, speed in
        // @Published delivers before its property's storage changes.
        self?.publish(time: time, duration: duration, paused: paused, speed: speed)
      }.store(in: &subscriptions)
    publish(time: player.time, duration: player.duration, paused: player.paused, speed: player.speed)
  }
  func updateArtwork(_ image: NSImage) {
    // NSImage is used only to satisfy the MediaPlayer artwork callback; it is an
    // immutable image supplied by the main-actor image cache.
    artwork = Self.makeArtwork(MediaArtworkImage(image), size: image.size)
    if let player { publish(time: player.time, duration: player.duration, paused: player.paused, speed: player.speed) }
  }
  /// MediaPlayer invokes the artwork handler on its own background queue. A closure formed inside
  /// this @MainActor class inherits main-actor isolation and traps the Swift 6 runtime check there,
  /// so build it in a nonisolated context.
  private nonisolated static func makeArtwork(_ immutable: MediaArtworkImage, size: CGSize)
    -> MPMediaItemArtwork
  {
    MPMediaItemArtwork(boundsSize: size) { @Sendable _ in immutable.image }
  }
  func clear() {
    subscriptions.removeAll()
    for (command, target) in commands { command.removeTarget(target); command.isEnabled = false }
    commands.removeAll(); player = nil; artwork = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
  }
  private func install(_ command: MPRemoteCommand, action: @escaping @MainActor @Sendable () -> Void) {
    command.isEnabled = true
    commands.append((command, Self.addTarget(command, action)))
  }
  // MediaPlayer may call command handlers off the main thread; handlers formed in this @MainActor
  // class would inherit main-actor isolation and trap, so build them nonisolated and hop explicitly.
  private nonisolated static func addTarget(
    _ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable () -> Void
  ) -> Any {
    command.addTarget { @Sendable _ in
      Task { @MainActor in action() }
      return .success
    }
  }
  private nonisolated static func addSeekTarget(
    _ command: MPChangePlaybackPositionCommand, _ seek: @escaping @MainActor @Sendable (Double) -> Void
  ) -> Any {
    command.addTarget { @Sendable event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else {
        return .commandFailed
      }
      let position = event.positionTime
      Task { @MainActor in seek(position) }
      return .success
    }
  }
  private func publish(time: Double, duration: Double, paused: Bool, speed: Double) {
    var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, time.isFinite ? time : 0),
      MPMediaItemPropertyPlaybackDuration: max(0, duration.isFinite ? duration : 0),
      MPNowPlayingInfoPropertyPlaybackRate: paused ? 0 : speed,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0]
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    if live {
      info[MPNowPlayingInfoPropertyIsLiveStream] = true
      info[MPMediaItemPropertyPlaybackDuration] = nil
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nil
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
  }
}
private final class MediaArtworkImage: @unchecked Sendable {
  let image: NSImage
  init(_ image: NSImage) { self.image = image }
}
