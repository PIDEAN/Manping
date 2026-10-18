import ManpingCore
import Combine
import Foundation

/// Subtitles and danmaku sending for the media that plays now. `AppModel` points it at each
/// new video, part or episode (`follow`), wherever the picture is (main window, mini window,
/// standalone window), so it never depends on a playback page being on screen. An account
/// change (sign-in, sign-out, switch) reloads it for the same media under the new identity.
@MainActor final class PlaybackFeaturesModel: ObservableObject {
  @Published var input = ""
  @Published var color: UInt32 = 0xffffff
  @Published var mode = 1
  @Published var standardSize = true
  @Published private(set) var sending = false
  @Published private(set) var tracks: [DownloadSubtitleTrack] = []
  @Published private(set) var selectedTrackID: String?
  @Published private(set) var subtitleLoading = false
  /// The track list for the current media is being read.
  @Published private(set) var tracksLoading = false
  @Published var message: String?
  private let service: BiliService
  private let fixtures: Bool
  private var identity: AuthSnapshot?
  private var aid: Int64?
  private var cid: Int64?
  private var generation = 0
  private var metadataTask: Task<Void, Never>?
  private var sendTask: Task<Void, Never>?
  private var subtitleTask: Task<Void, Never>?
  private var identityTask: Task<Void, Never>?
  private var subtitleDirectory: URL?
  private var subtitlePlayer: PlayerModel?
  init(service: BiliService, fixtures: Bool) {
    self.service = service; self.fixtures = fixtures
    identityTask = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard !Task.isCancelled else { return }
        self?.identityChanged(event)
      }
    }
  }
  deinit { metadataTask?.cancel(); sendTask?.cancel(); subtitleTask?.cancel(); identityTask?.cancel() }

  /// The media now playing (nil when none, or not yet known). The same media keeps its state.
  func follow(aid: Int64?, cid: Int64?) {
    guard aid != self.aid || cid != self.cid || (identity == nil && metadataTask == nil) else { return }
    reset(clearInput: aid != self.aid || cid != self.cid)
    self.aid = aid; self.cid = cid
    load(reselecting: nil, on: nil)
  }

  func send(seconds: Double, requestLogin: @escaping () -> Void) {
    guard !sending else { return }
    guard let aid, let cid, aid > 0, cid > 0 else { message = "视频信息还没有加载完成，暂时不能发送弹幕。"; return }
    guard let identity else { message = "正在读取登录状态，请稍后再发送。"; return }
    if identity.state != .appAuthorized && !fixtures { requestLogin(); return }
    let draft: VideoDanmakuDraft
    do { draft = try VideoDanmakuDraft(aid: aid, cid: cid, text: input, seconds: seconds,
      color: color, standardSize: standardSize, mode: mode) }
    catch { message = error.localizedDescription; return }
    sending = true; message = nil
    let current = generation
    let usesFixtures = fixtures
    sendTask = Task { [weak self, service] in
      do {
        if !usesFixtures { try await service.sendVideoDanmaku(draft, expectedIdentity: identity) }
        else { try await Task.sleep(for: .milliseconds(80)) }
        guard let self, !Task.isCancelled, current == self.generation else { return }
        self.input = ""; self.sending = false
        self.message = self.fixtures ? "本地样本：已验证发送动作，未向真实账号发送。" : "弹幕已发送"
      } catch is CancellationError {} catch {
        guard let self, current == self.generation, !Task.isCancelled else { return }
        self.sending = false; self.message = "没能发送弹幕：\(error.localizedDescription)"
      }
    }
  }
  func selectSubtitle(_ track: DownloadSubtitleTrack?, player: PlayerModel) {
    // Clicking the track that is already loading must not restart (and cancel) the download.
    if let track, subtitleLoading, selectedTrackID == track.id { return }
    subtitleTask?.cancel(); subtitleTask = nil
    // The chosen track is shown as selected right away; it is cleared again only on failure.
    player.clearSubtitle(); clearSubtitleFile(); selectedTrackID = nil; subtitleLoading = false
    subtitlePlayer = player
    guard let track else { return }
    guard let identity else { message = "字幕信息还在加载，请稍后再选。"; return }
    selectedTrackID = track.id
    let current = generation
    subtitleLoading = true
    subtitleTask = Task { [weak self, service] in
      do {
        let cues = try await service.downloadSubtitleCues(track: track, expectedIdentity: identity)
        try Task.checkCancellation()
        guard let self, current == self.generation else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Manping-Subtitle-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("subtitle.srt")
        do { try DownloadExport.subtitleSRT(cues).write(to: destination, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        self.subtitleDirectory = directory; self.selectedTrackID = track.id; self.subtitleLoading = false
        if !self.fixtures { player.loadSubtitle(url: destination, title: track.title) }
      } catch is CancellationError {} catch {
        guard let self, current == self.generation, !Task.isCancelled else { return }
        self.subtitleLoading = false; self.selectedTrackID = nil
        self.message = "没能加载字幕：\(error.localizedDescription)"
      }
    }
  }
  /// No media: clears the tracks, the shown subtitle and any draft.
  func shutdown() {
    reset(clearInput: true)
    aid = nil; cid = nil
  }

  // MARK: Loading

  /// Reads the identity and the subtitle tracks for the followed media. After an account
  /// change the track that was showing is chosen again when the new identity still offers it.
  private func load(reselecting trackID: String?, on player: PlayerModel?) {
    let current = generation
    tracksLoading = aid != nil && cid != nil
    metadataTask = Task { [weak self, service] in
      let snapshot = await service.authSnapshot()
      guard let self, !Task.isCancelled, current == self.generation else { return }
      self.identity = snapshot
      guard let aid = self.aid, let cid = self.cid, aid > 0, cid > 0 else { self.tracksLoading = false; return }
      do {
        let result = try await service.downloadSubtitleTracks(aid: aid, cid: cid, expectedIdentity: snapshot)
        guard !Task.isCancelled, current == self.generation else { return }
        self.tracks = result; self.tracksLoading = false
        if let trackID, let player, let track = result.first(where: { $0.id == trackID }) {
          self.selectSubtitle(track, player: player)
        }
      } catch is CancellationError {
        // A newer identity or media restarts the load; nothing to report.
      } catch {
        guard current == self.generation, !Task.isCancelled else { return }
        self.tracksLoading = false
        self.message = "没能获取字幕信息：\(error.localizedDescription)"
      }
    }
  }

  /// Sign-in, sign-out or an account switch: requests made for the old identity are dropped
  /// and the same media loads again for the new one.
  private func identityChanged(_ event: AuthIdentityEvent) {
    if let identity, identity.epoch == event.epoch, identity.identityRevision == event.identityRevision { return }
    guard aid != nil || cid != nil else { identity = nil; return }
    let reselect = selectedTrackID, player = subtitlePlayer
    reset(clearInput: false)
    load(reselecting: reselect, on: player)
  }

  /// Cancels every request and clears what belongs to the previous media or identity; the
  /// followed media itself is kept.
  private func reset(clearInput: Bool) {
    generation &+= 1; metadataTask?.cancel(); sendTask?.cancel(); subtitleTask?.cancel()
    metadataTask = nil; sendTask = nil; subtitleTask = nil
    subtitlePlayer?.clearSubtitle(); subtitlePlayer = nil; clearSubtitleFile()
    identity = nil; tracks = []; message = nil
    if clearInput { input = "" }
    sending = false; subtitleLoading = false; tracksLoading = false; selectedTrackID = nil
  }
  private func clearSubtitleFile() {
    if let directory = subtitleDirectory { try? FileManager.default.removeItem(at: directory) }
    subtitleDirectory = nil
  }
}
