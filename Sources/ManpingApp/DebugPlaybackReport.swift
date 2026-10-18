#if DEBUG
import AppKit
import ManpingCore
import Combine
import Foundation

/// Debug-only: samples the real playback path once per second and writes a JSON report,
/// so real-network playback (quality, codec, decoder, CDN, stalls) can be verified without
/// screenshots. Scripted `actions` ("t:action[=value]" separated by ",") exercise the same
/// model entry points the UI uses. The report never contains media URLs or credentials.
@MainActor enum DebugPlaybackReport {
  private static var timer: Timer?
  private static var samples: [[String: Any]] = []
  /// objectWillChange emissions since the last sample: each one re-renders every observing view.
  private static var appChanges = 0, playerChanges = 0, cdnChanges = 0
  private static var observations: [AnyCancellable] = []

  static func start(model: AppModel, path: String, seconds: Double, actions: String) {
    samples = []
    let started = Date()
    observations = [
      model.objectWillChange.sink { _ in appChanges += 1 },
      model.cdn.objectWillChange.sink { _ in cdnChanges += 1 },
    ]
    var observedPlayer: ObjectIdentifier?
    for action in actions.split(separator: ",") {
      let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2, let at = Double(parts[0]) else { continue }
      Timer.scheduledTimer(withTimeInterval: at, repeats: false) { _ in
        MainActor.assumeIsolated { perform(parts[1], model: model) }
      }
    }
    DanmakuMotionProbe.enable()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      MainActor.assumeIsolated {
        let elapsed = Date().timeIntervalSince(started)
        if observedPlayer != ObjectIdentifier(model.player) {
          observedPlayer = ObjectIdentifier(model.player)
          observations.append(model.player.objectWillChange.sink { _ in playerChanges += 1 })
        }
        var sample = snapshot(model: model, elapsed: elapsed)
        sample["appChanges"] = appChanges; sample["playerChanges"] = playerChanges; sample["cdnChanges"] = cdnChanges
        appChanges = 0; playerChanges = 0; cdnChanges = 0
        samples.append(sample)
        if elapsed >= seconds {
          timer?.invalidate()
          let report: [String: Any] = ["samples": samples, "final": samples.last ?? [:]]
          if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
          }
          // An error alert is window-modal and makes terminate(_:) a no-op; exit directly.
          model.shutdown()
          exit(0)
        }
      }
    }
  }

  private static func perform(_ action: String, model: AppModel) {
    let parts = action.split(separator: "=", maxSplits: 1).map(String.init)
    switch parts[0] {
    case "seek": if let value = parts.dropFirst().first.flatMap(Double.init) { model.player.seek(value) }
    case "pause": model.player.togglePause()
    case "screenshot": model.takePlayerScreenshot()
    case "audio-only": model.player.setAudioOnly(parts.dropFirst().first != "0")
    case "quality":
      if let qn = parts.dropFirst().first.flatMap(Int.init),
        let stream = model.manifest?.video.first(where: { $0.quality == qn }) { model.changeQuality(stream) }
    case "codec":
      if let prefix = parts.dropFirst().first,
        let stream = model.manifest?.video.first(where: { $0.quality == model.selectedStream?.quality && $0.codec.hasPrefix(prefix) }) {
        model.changeQuality(stream)
      }
    case "cdn": if let host = parts.dropFirst().first { model.cdn.select(host: host) }
    case "cdn-auto": model.cdn.select(host: nil)
    case "cdn-probe": model.cdn.reprobe()
    case "speed": if let value = parts.dropFirst().first.flatMap(Double.init) { model.player.setSpeed(value) }
    case "next": model.playNext()
    // Live rooms.
    case "cdn-stall": model.cdn.debugSimulateStall()
    case "proxy-media": if let mode = parts.dropFirst().first.flatMap(MediaRoute.init(rawValue:)) { model.setProxyMediaRoute(mode) }
    case "live-quality": if let qn = parts.dropFirst().first.flatMap(Int.init) { model.livePlayback?.changeQuality(qn) }
    case "live-refresh": model.livePlayback?.refresh()
    // Simulates a dropped stream: mpv stops, the watchdog must notice and reconnect.
    case "live-break": model.player.command(["stop"])
    // Simulates an upstream failure: the stream errors out like a dead CDN edge.
    case "live-fail": model.player.command(["loadfile", "http://127.0.0.1:9/dead.flv"])
    default: break
    }
  }

  private static func snapshot(model: AppModel, elapsed: Double) -> [String: Any] {
    let player = model.player
    var sample: [String: Any] = [
      "t": (elapsed * 10).rounded() / 10,
      "time": player.time.isFinite ? player.time : -1,
      "duration": player.duration.isFinite ? player.duration : -1,
      "paused": player.paused,
      "hwdec": player.hardware,
      "status": player.status,
      "error": player.error ?? model.error ?? "",
      "qn": model.livePlayback?.stream?.currentQuality ?? (model.pgcPlayback?.selectedStream ?? model.selectedStream)?.quality ?? 0,
      "codec": model.livePlayback?.stream?.label ?? (model.pgcPlayback?.selectedStream ?? model.selectedStream)?.codec ?? "",
      "proxy": ["status": model.cdn.proxyStatus, "active": model.cdn.proxyActive, "mode": model.cdn.mediaRoute.rawValue,
        "pool": model.cdn.proxiedPoolHosts, "results": model.cdn.results.filter { MediaRelay.isProxyKey($0.host) }
          .map { "\($0.host):\($0.ok ? String(format: "%.1f", $0.mbps) : ($0.error ?? "fail"))" }] as [String: Any],
      "live": model.livePlayback.map { live -> [String: Any] in
        ["status": live.room?.status.title ?? "", "ended": live.ended, "reconnecting": live.reconnecting ?? "",
         "reconnects": live.reconnects, "chat": live.chat.lines.count, "chatConnected": live.chat.connected, "chatEvents": live.chatEvents, "chatBuvid": live.chatHasBuvid,
         "watched": live.watched ?? -1, "online": live.online ?? -1, "lines": live.stream?.urls.count ?? 0, "error": live.error ?? "",
         "available": live.playback?.available.map(\.qn) ?? []]
      } ?? [:],
      // Login state only; never the account name or id.
      "signedIn": model.account != "登录",
      "available": (model.pgcPlayback?.manifest ?? model.manifest)?.video.map { "\($0.quality):\($0.codec.prefix(4))" } ?? [],
      "cacheSeconds": player.metrics["demuxer-cache-duration"] ?? -1,
      "drops": player.metrics["frame-drop-count"] ?? -1,
      "decoderDrops": player.metrics["decoder-frame-drop-count"] ?? -1,
      "fps": player.metrics["estimated-vf-fps"] ?? -1,
      "mistimed": player.metrics["mistimed-frame-count"] ?? -1,
      "displayUpdates": player.displayUpdates,
      "displayFps": player.metrics["display-fps"] ?? -1,
      "vsyncJitter": player.metrics["vsync-jitter"] ?? -1,
      "videoMbps": (player.metrics["video-bitrate"] ?? 0) / 1_000_000,
      "media": player.mediaEvidence,
      "cdnActive": model.cdn.activeHost ?? "",
      "cdnPool": model.cdn.poolHosts,
      "cdnResults": model.cdn.results.prefix(10).map { "\($0.host):\($0.ok ? String(format: "%.1f", $0.mbps) : ($0.error ?? "fail")):\($0.stage.rawValue)" },
      "relayMbps": (model.cdn.snapshot.combinedMbps * 10).rounded() / 10,
      "relayHosts": model.cdn.snapshot.hosts.filter { $0.totalBytes > 0 }.map { "\($0.host):\(String(format: "%.1f", $0.recentMbps)):\($0.totalBytes / 1024)KB:f\($0.failures)" },
      "relayHedges": model.cdn.snapshot.hedgedRequests,
      "dmMotion": DanmakuMotionProbe.drain(),
      "dmRender": DanmakuView.diagnosticEvidence.filter { $0.key.hasPrefix("frame") },
      "dmPeakUs": DanmakuView.drainFramePeak(),
      "dmClock": { let d = player.danmakuClock.drainDiagnostics(); return ["samples": d.samples, "resets": d.resets, "maxErrorMs": Int(d.maxError * 1000)] }(),
      "relayRetries": model.cdn.snapshot.retries,
      "cdnEvents": model.cdn.events.suffix(8).map(\.text),
      "stalls": model.cdn.stalls,
      "buffering": player.buffering,
      "bufferAhead": player.bufferedAhead,
    ]
    if let video = model.selected { sample["video"] = video.bvid }
    return sample
  }
}
#endif
