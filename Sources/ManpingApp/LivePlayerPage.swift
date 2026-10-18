import AppKit
import ManpingCore
import SwiftUI

/// In-app live room: the stream on the left; room information and live chat on the right.
struct LivePlayerPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject var live: LivePlaybackModel
  @ObservedObject private var player: PlayerModel
  @StateObject private var chrome = PlayerChromeState()
  @State private var danmakuSettingsShown = false
  @State private var pictureWidth: CGFloat = 900
  @AppStorage(PlayerPreferences.sidebarHiddenKey) private var sidebarHidden = false
  @State private var volumeShown = false
  @State private var tab: Tab = .chat
  @Environment(\.colorScheme) private var scheme

  init(model: AppModel, live: LivePlaybackModel) {
    self.model = model; self.live = live
    _player = ObservedObject(wrappedValue: live.player)
  }

  private enum Tab: String { case chat = "弹幕", info = "主播" }

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        media.frame(maxWidth: .infinity, maxHeight: .infinity)
        if !sidebarHidden {
          Hairline(axis: .vertical)
          sidePanel.frame(width: min(372, geometry.size.width * 0.4))
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
    }
    // The one toolbar above the page (the main window's, or the standalone window's).
    // A room that never loaded has no known state; the error card speaks for it.
    .pageToolbar(title: live.room?.title ?? "直播间", subtitle: audienceSubtitle,
      leading: chatUnavailable ? nil : AnyView(LiveBadge(status: displayStatus))) {
      if let url = webURL {
        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
          .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("在浏览器中打开")
          .accessibilityLabel("在浏览器中打开")
        ToolbarShareButton(url: url)
      }
      PlayerToolbarActions(model: model, sidebarHidden: $sidebarHidden, windowToggle: false)
    }
  }

  /// The room page; falls back to the requested id while the room is still loading.
  private var webURL: URL? { live.room?.webURL ?? URL(string: "https://live.bilibili.com/\(live.roomID)") }
  /// Viewers right now, only as the chat socket reports them. The room info's `online` is the
  /// popularity figure (人气) and is never shown as people watching.
  private var onlineCount: Int64? { live.online }
  /// The toolbar subtitle: 「N 人在看」 once the live figure arrives, 「人气 N」 until then.
  private var audienceSubtitle: String? {
    if let online = onlineCount { return "\(Self.people(online)) 人在看" }
    if let popularity = live.room?.online, popularity > 0 { return "人气 \(Self.count(popularity))" }
    return nil
  }
  /// The room never loaded, so the chat has nothing to connect to until a retry succeeds.
  private var chatUnavailable: Bool { live.room == nil && live.error != nil && !live.chat.connected }

  private var displayStatus: LiveStatus {
    if live.ended { return live.room.map { $0.status == .live ? .offline : $0.status } ?? .offline }
    return live.room?.status ?? .live
  }

  /// Paused or a popover open: the controls stay up.
  private var controlsPinned: Bool { model.usesUIFixtures || player.paused || volumeShown || danmakuSettingsShown }
  private var controlsShown: Bool { chrome.visible || controlsPinned }

  private var media: some View {
    PlayerSurface(model: player).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
      .overlay { statusOverlay }
      .overlay(alignment: .topLeading) {
        if let message = live.reconnecting {
          Label(message, systemImage: "arrow.triangle.2.circlepath").font(Theme.Font.caption)
            .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 30)
            .environment(\.colorScheme, .dark).floatingGlassPanel(radius: Theme.Radius.lg, readingTint: .black.opacity(0.35))
            .padding(16).transition(.opacity)
        }
      }
      .overlay(alignment: .bottom) { controls.playerChromeFade(controlsShown) }
      .animation(.easeOut(duration: 0.2), value: live.reconnecting)
      .reportsPictureWidth($pictureWidth)
      .tracksPlayerChrome(chrome, pinned: controlsPinned)
      .onChange(of: player.volume) { _, _ in chrome.activity() }
      .onChange(of: player.commentsEnabled) { _, _ in chrome.activity() }
  }

  @ViewBuilder private var statusOverlay: some View {
    if live.ended {
      panel(icon: "moon.zzz.fill", text: live.room?.status == .round ? "主播没有开播，正在轮播往期内容。" : "直播已结束，或主播还没有开播。",
        action: ("刷新", live.refresh))
    } else if let error = live.error {
      panel(icon: "exclamationmark.triangle.fill", text: error, action: ("重新连接", live.refresh))
    } else if live.isLoading || (player.buffering && live.reconnecting == nil) || (live.stream != nil && player.duration <= 0 && player.time <= 0) {
      VStack(spacing: 10) {
        StreakLoadingView(width: 96, tint: Theme.accent)
        Text("正在连接直播…").font(Theme.Font.caption).foregroundStyle(.white.opacity(0.8))
      }.environment(\.colorScheme, .dark).allowsHitTesting(false)
    }
  }

  private func panel(icon: String, text: String, action: (String, () -> Void)) -> some View {
    VStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Theme.highlight)
      Text(text).font(Theme.Font.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9)).frame(maxWidth: 360)
      HStack(spacing: 8) {
        Button(action.0, action: action.1).buttonStyle(AppButtonStyle(role: .primary, size: .small))
        if let url = webURL {
          Button("在浏览器中打开") { NSWorkspace.shared.open(url) }.buttonStyle(AppButtonStyle(size: .small))
        }
      }
    }.padding(18).environment(\.colorScheme, .dark).floatingGlassPanel(readingTint: .black.opacity(0.4))
  }

  private var controls: some View {
    let layout = PlayerPanelLayout(pictureWidth: pictureWidth)
    return PlayerControlPanel(chrome: chrome) {
      HStack(spacing: 6) {
        PlayerPlayButton(paused: player.paused) { player.togglePause() }
          .disabled(live.stream == nil || live.ended)
        Button { live.refresh() } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(PlayerControlButtonStyle(size: 32)).help("重新连接").accessibilityLabel("重新连接")
        DanmakuToggleButton(enabled: $player.commentsEnabled) { danmakuSettingsShown = true }
        if layout.showsTime, live.room != nil {
          LiveElapsedLabel(status: displayStatus, startedAt: live.room?.startedAt).padding(.leading, 6)
        }
        Spacer(minLength: 6)
        if layout.showsSpeed, let stream = live.stream {
          LiveRoutePill(codec: stream.codecName, line: live.currentLineNumber, host: live.currentLineHost)
        }
        if layout.showsQuality { qualityMenu }
        PlayerVolumeButton(player: player, maximum: model.appSettings.number(.maxVolume), shown: $volumeShown)
        PlayerSettingsMenu(player: player, settings: model.settingsModel,
          danmakuShown: $danmakuSettingsShown, networkShown: .constant(false),
          openDanmakuSettings: { model.openSettings(.danmaku) }) {
          Button("弹幕设置…") { danmakuSettingsShown = true }
          if !layout.showsQuality {
            Menu("画质") { qualityItems }
          }
          Divider()
          Button("截取画面") { model.takePlayerScreenshot() }.disabled(!model.canTakeScreenshot)
          if let url = webURL { Button("在浏览器中打开") { NSWorkspace.shared.open(url) } }
          Button(model.playbackDetached ? "回到主窗口" : "在独立窗口播放") { model.togglePlaybackWindow() }
        }
        PlayerWindowButtons(model: model, player: player)
      }
    }
  }

  @ViewBuilder private var qualityItems: some View {
    ForEach(live.playback?.available ?? []) { quality in
      Toggle(quality.title, isOn: Binding(get: { live.stream?.currentQuality == quality.qn },
        set: { if $0 { live.changeQuality(quality.qn) } }))
    }
  }

  private var qualityMenu: some View {
    Menu { qualityItems } label: {
      Text(live.currentQuality?.title ?? "画质").font(.system(size: 12, weight: .semibold)).lineLimit(1)
    }.playerMenuStyle().disabled((live.playback?.available ?? []).isEmpty).help("画质")
  }

  private var sidePanel: some View {
    VStack(spacing: 0) {
      SegmentedTabs(options: [(Tab.chat, Tab.chat.rawValue), (Tab.info, Tab.info.rawValue)], selection: $tab).padding(.horizontal, 16).frame(height: Theme.pageHeaderHeight)
      Hairline()
      switch tab {
      case .chat:
        LiveChatStatusRow(chat: live.chat, online: onlineCount, watched: live.watched, unavailable: chatUnavailable)
        Hairline()
        LiveChatList(chat: live.chat, unavailable: chatUnavailable)
      case .info: ScrollView { information.padding(18).frame(maxWidth: .infinity, alignment: .topLeading) }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var information: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let room = live.room {
        HStack(spacing: 10) {
          CachedImage(url: room.anchorAvatar).frame(width: 40, height: 40).clipShape(Circle())
          VStack(alignment: .leading, spacing: 2) {
            Text(room.anchorName.isEmpty ? "主播" : room.anchorName).font(Theme.Font.headline)
            if !room.area.isEmpty { Text(room.area).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)) }
          }
          Spacer()
          if room.anchorID > 0 {
            Button("空间") { model.openOverlay(.userSpace(room.anchorID)) }.buttonStyle(AppButtonStyle(size: .small))
          }
        }
        Text(room.title).font(.system(size: 16, weight: .bold)).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
          if let online = live.online { row("person.wave.2", "\(Self.count(online)) 人在线") }
          if let watched = live.watched { row("eye", "\(Self.count(watched)) 人看过") }
          if room.online > 0 { row("flame", "人气 \(Self.count(room.online))") }
          if let started = room.startedAt, room.status == .live {
            row("clock", "开播于 " + started.formatted(date: .abbreviated, time: .shortened))
          }
        }.font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        routeSummary
        if !room.description.isEmpty {
          Text(room.description).font(Theme.Font.body).foregroundStyle(Theme.secondaryText(scheme))
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        VStack(alignment: .leading, spacing: 4) {
          (Text("房间号 ") + Text(String(room.roomID)).bold()).textSelection(.enabled)
          if room.shortID > 0 { (Text("短号 ") + Text(String(room.shortID)).bold()).textSelection(.enabled) }
        }.font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
      } else if let error = live.error {
        InlineErrorText(message: error)
      } else {
        ProgressView("正在加载直播间…")
      }
    }.foregroundStyle(Theme.text(scheme))
  }

  /// 「当前线路」: the entry point for the live network details (format, codec, lines, reconnects).
  private var routeSummary: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("当前线路", systemImage: "antenna.radiowaves.left.and.right").font(Theme.Font.caption.weight(.semibold))
        .foregroundStyle(Theme.tertiaryText(scheme))
      if let stream = live.stream {
        Text(([live.currentQuality?.title, stream.label, "\(stream.urls.count) 条线路", "重连 \(live.reconnects) 次"].compactMap { $0 })
          .joined(separator: " · "))
          .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).textSelection(.enabled)
        // The line actually playing (the fastest one at load, or the one a reconnect moved to).
        if let host = live.currentLineHost {
          Text([live.currentLineNumber.map { "线路 \($0)" }, host].compactMap { $0 }.joined(separator: " · "))
            .font(Theme.Font.caption2.monospaced()).foregroundStyle(Theme.tertiaryText(scheme)).textSelection(.enabled)
        }
      } else {
        Text(live.isLoading ? "正在连接…" : "尚未连接").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ symbol: String, _ text: String) -> some View {
    Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
  }

  static func count(_ value: Int64) -> String {
    value >= 10_000 ? String(format: "%.1f 万", Double(value) / 10_000) : String(value)
  }
  /// Audience figures as the live design shows them: 6,145 below 1万, 16.3万 above.
  static func people(_ value: Int64) -> String {
    value >= 10_000 ? count(value) : value.formatted(.number.locale(Locale(identifier: "en_US")))
  }
}

/// The 「直播中」 pill used in the room header and on live cards: solid `live` capsule, dark dot.
struct LiveBadge: View {
  let status: LiveStatus
  var body: some View {
    let live = status == .live
    HStack(spacing: 4) {
      if live { Circle().fill(Theme.onLive).frame(width: 5, height: 5) }
      Text(live ? "直播中" : status.title).font(Theme.Font.caption2.weight(.semibold))
    }.foregroundStyle(live ? Theme.onLive : .white).padding(.horizontal, 7).frame(height: 18)
      .background(live ? Theme.live : Theme.mediaBadge, in: Capsule())
      .fixedSize()
  }
}

/// 「已开播 h:mm:ss」. Owns its own once-a-second TimelineView, so the clock redraws
/// only this label and never the page around it.
private struct LiveElapsedLabel: View {
  let status: LiveStatus
  let startedAt: Date?
  var body: some View {
    Group {
      if status == .live, let startedAt {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text("已开播 " + Self.clock(context.date.timeIntervalSince(startedAt)))
        }
      } else {
        Text(status.title)
      }
    }.font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.86)).lineLimit(1).fixedSize()
  }
  /// h:mm:ss; negative skew between the server and local clocks reads as zero.
  static func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
  }
}

/// 「● 线路 2 · HEVC」 on the panel: the stream is connected; hovering shows the line's host.
private struct LiveRoutePill: View {
  let codec: String
  let line: Int?
  let host: String?
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(Theme.success(.dark)).frame(width: 6, height: 6)
      Text(title).lineLimit(1)
    }.font(Theme.Font.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.86))
      .padding(.horizontal, 10).frame(height: 24)
      .background(.white.opacity(0.12), in: Capsule())
      .fixedSize()
      .help("线路：" + (host ?? "未知"))
  }
  private var title: String {
    let name = PlayerCodec.name(codec.lowercased())
    return line.map { "线路 \($0) · \(name)" } ?? "线路 · \(name)"
  }
}

/// Top of the 弹幕 tab: connection dot, audience now and total viewers.
private struct LiveChatStatusRow: View {
  @ObservedObject var chat: LiveChatModel
  let online: Int64?
  let watched: Int64?
  var unavailable = false
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 8) {
      Circle().fill(chat.connected ? Theme.success(scheme) : Theme.disabledText(scheme)).frame(width: 6, height: 6)
      Text(summary).lineLimit(1)
      Spacer(minLength: 0)
    }.font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
      .padding(.horizontal, 16).padding(.vertical, 10)
      .accessibilityElement(children: .combine)
  }
  private var summary: String {
    var parts = [chat.connected ? "已连接" : unavailable ? "弹幕未连接" : "正在连接弹幕…"]
    if let online { parts.append("\(LivePlayerPage.people(online)) 在线") }
    if let watched { parts.append("\(LivePlayerPage.people(watched)) 看过") }
    return parts.joined(separator: " · ")
  }
}

/// Live chat: newest at the bottom. It follows new lines while the reader is at the bottom;
/// after scrolling up it stays put and offers a 「N 条新弹幕」 pill that jumps back.
struct LiveChatList: View {
  @ObservedObject var chat: LiveChatModel
  var unavailable = false
  @State private var position = ScrollPosition(edge: .bottom)
  @State private var atBottom = true
  /// Lines that arrived while the reader was away from the bottom.
  @State private var unseen = 0
  @Environment(\.colorScheme) private var scheme

  /// Scroll state sampled by `onScrollGeometryChange`.
  private struct Metrics: Equatable {
    var distanceFromBottom: CGFloat
    var contentHeight: CGFloat
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        if chat.lines.isEmpty {
          Text(chat.connected ? "等待新弹幕…" : unavailable ? "直播间加载后会自动连接弹幕" : "新弹幕会显示在这里").font(Theme.Font.caption)
            .foregroundStyle(Theme.tertiaryText(scheme)).padding(.top, 8)
        }
        ForEach(chat.lines) { line in lineView(line).id(line.id) }
      }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
    }.scrollPosition($position)
      .onScrollGeometryChange(for: Metrics.self) { geometry in
        Metrics(distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height)
      } action: { old, new in
        // Only the reader's own scrolling counts. Content that grew or shrank (new or trimmed
        // lines) must not flip the state, or a busy room would keep dropping out of follow mode.
        guard abs(old.contentHeight - new.contentHeight) < 0.5 else { return }
        let near = new.distanceFromBottom <= 32
        if near != atBottom { atBottom = near }
        if near && unseen != 0 { unseen = 0 }
      }
      .onChange(of: chat.lines.last?.id) { old, new in
        guard let new else { return }
        if atBottom {
          position.scrollTo(edge: .bottom)
        } else {
          // Line ids count every received line, including those already trimmed from the list.
          unseen += max(0, new - (old ?? new))
        }
      }
      .overlay(alignment: .bottom) {
        if !atBottom && unseen > 0 {
          Button {
            unseen = 0; atBottom = true
            withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold))
              Text("\(unseen) 条新弹幕").monospacedDigit()
            }.font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.onAccent).padding(.horizontal, 12).frame(height: 28)
              .background(Theme.accent, in: Capsule())
              .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 7, y: 4)
          }.buttonStyle(.plain).padding(.bottom, 14).transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
      }
      .animation(.easeOut(duration: 0.16), value: atBottom)
  }

  @ViewBuilder private func lineView(_ line: LiveChatModel.Line) -> some View {
    switch line.kind {
    case .notice:
      Text(line.text).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        .multilineTextAlignment(.center).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .center)
    case .superChat(let price):
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("醒目留言 · \(line.user)").lineLimit(1)
          Spacer(minLength: 8)
          Text("¥\(price)").monospacedDigit()
        }.font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(Theme.warning(scheme))
        Text(line.text).font(Theme.Font.body).foregroundStyle(Theme.text(scheme))
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.highlight.opacity(scheme == .dark ? 0.16 : 0.2), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.highlight.opacity(0.45), lineWidth: 0.5))
    case .gift:
      Text(line.user.isEmpty ? line.text : line.user + " " + line.text)
        .font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).fixedSize(horizontal: false, vertical: true)
    case .danmaku:
      Text("\(Text(line.user).foregroundStyle(Theme.accentText(scheme)))\(Text("：").foregroundStyle(Theme.tertiaryText(scheme)))\(Text(line.text).foregroundStyle(Theme.text(scheme)))")
        .font(Theme.Font.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
  }
}
