import ManpingCore
import SwiftUI

/// Subtitle tracks; used by the panel menu and, when folded, inside the player settings menu.
struct PlaybackSubtitleItems: View {
  @ObservedObject var features: PlaybackFeaturesModel
  @ObservedObject var player: PlayerModel
  let filterAI: Bool
  var body: some View {
    let visible = DownloadSubtitleTrack.filtered(features.tracks, filterAI: filterAI)
    Toggle("关闭字幕", isOn: Binding(get: { features.selectedTrackID == nil }, set: { if $0 { features.selectSubtitle(nil, player: player) } }))
    ForEach(visible) { track in
      Toggle(track.title, isOn: Binding(get: { features.selectedTrackID == track.id }, set: { if $0 { features.selectSubtitle(track, player: player) } }))
    }
    if let note = Self.emptyNote(features: features, visible: visible) { Text(note) }
  }
  /// What the list says when it has no track to offer (shared with 播放 › 字幕 in the menu bar).
  @MainActor static func emptyNote(features: PlaybackFeaturesModel, visible: [DownloadSubtitleTrack]) -> String? {
    if features.subtitleLoading || features.tracksLoading { return "正在加载字幕…" }
    if !visible.isEmpty { return nil }
    return features.tracks.isEmpty ? "这个视频没有字幕" : "只有 AI 字幕（已在设置中隐藏）"
  }
}

struct PlaybackSubtitleMenu: View {
  @ObservedObject var features: PlaybackFeaturesModel
  @ObservedObject var player: PlayerModel
  let filterAI: Bool
  var body: some View {
    Menu { PlaybackSubtitleItems(features: features, player: player, filterAI: filterAI) } label: {
      Image(systemName: features.selectedTrackID == nil ? "captions.bubble" : "captions.bubble.fill")
    }
      .menuStyle(.button).buttonStyle(PlayerControlButtonStyle(size: 32)).menuIndicator(.hidden).fixedSize()
      .help("字幕").accessibilityLabel("字幕")
      .onChange(of: filterAI) { _, value in
        if value, let id = features.selectedTrackID, features.tracks.first(where: { $0.id == id })?.isAI == true {
          features.selectSubtitle(nil, player: player)
        }
      }
  }
}

/// The comment field on the panel: a capsule with the style menu, the field and send.
struct PlaybackDanmakuInput: View {
  @ObservedObject var features: PlaybackFeaturesModel
  let send: () -> Void
  var body: some View {
    HStack(spacing: 8) {
      Menu {
        Picker("位置", selection: $features.mode) {
          Text("滚动").tag(1); Text("顶部").tag(5); Text("底部").tag(4)
        }
        Toggle("标准字号", isOn: $features.standardSize)
        Picker("颜色", selection: $features.color) {
          Text("白色").tag(UInt32(0xffffff)); Text("红色").tag(UInt32(0xff0000))
          Text("黄色").tag(UInt32(0xffff00)); Text("绿色").tag(UInt32(0x00ff00))
          Text("蓝色").tag(UInt32(0x0000ff)); Text("紫色").tag(UInt32(0x800080))
        }
      } label: { Text("Aa").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85)) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("弹幕样式")
      TextField("发一条友善的弹幕", text: $features.input, prompt: Text("发一条友善的弹幕")).labelsHidden()
        .textFieldStyle(.plain).font(Theme.Font.caption).foregroundStyle(.white).onSubmit(send).disabled(features.sending)
      Button(action: send) {
        if features.sending { ProgressView().controlSize(.mini) }
        else { Image(systemName: "paperplane.fill").font(.system(size: 11)) }
      }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
        .disabled(features.sending || features.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("发送弹幕")
    }.padding(.horizontal, 12).frame(minWidth: 120, maxWidth: 300).frame(height: 30)
      .background(.white.opacity(0.12), in: Capsule())
      .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
      .environment(\.colorScheme, .dark)
  }
}

/// Chapter list that follows the playhead without re-rendering its parent.
struct PlaybackChapterList: View {
  @ObservedObject var clock: PlaybackClock
  let chapters: [PlaybackChapter]
  var override: Double? = nil
  let seek: (Double) -> Void
  @Environment(\.colorScheme) private var scheme
  private var time: Double { override ?? clock.time }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("章节").font(Theme.Font.headline)
      ForEach(chapters) { chapter in
        let nextTime = chapters.first(where: { $0.time > chapter.time })?.time ?? .infinity
        Button { seek(chapter.time) } label: {
          HStack(spacing: 10) {
            Text(String(format: "%02d:%02d", Int(chapter.time) / 60, Int(chapter.time) % 60))
              .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText(scheme))
            Text(chapter.title).font(Theme.Font.body).lineLimit(2)
            Spacer(minLength: 0)
            if time >= chapter.time && time < nextTime { Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(Theme.accentText(scheme)) }
          }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(SidebarRowStyle(selected: time >= chapter.time && time < nextTime))
      }
    }
  }
}

/// Draws the countdown from a fixed deadline; only this view updates while it runs.
struct NextPlaybackOverlay: View {
  let deadline: Date
  let onPlay: () -> Void
  let onCancel: () -> Void
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.1)) { context in
      NextPlaybackPromptView(remaining: max(0, deadline.timeIntervalSince(context.date)), onPlay: onPlay, onCancel: onCancel)
    }
  }
}

/// The 流光 loader while a stream loads or rebuffers, and a persistent error card with 「重试」.
/// Engine error text goes to the log, not the card (`PlayerErrorText`).
struct PlayerStatusOverlay: View {
  @ObservedObject var player: PlayerModel
  let loading: Bool
  let retry: () -> Void
  var body: some View {
    Group {
      if let error = player.error, !error.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(Theme.highlight)
          Text(PlayerErrorText.title(error)).font(Theme.Font.headline).multilineTextAlignment(.center).foregroundStyle(.white)
            .frame(maxWidth: 360)
          if let detail = PlayerErrorText.detail(error) {
            Text(detail).font(Theme.Font.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
              .frame(maxWidth: 360)
          }
          Button("重试", action: retry).buttonStyle(AppButtonStyle(role: .primary, size: .small)).padding(.top, 2)
        }.padding(18).environment(\.colorScheme, .dark)
          .floatingGlassPanel(readingTint: .black.opacity(0.4))
          .onAppear { PlayerErrorText.record(error) }
          .onChange(of: error) { _, value in PlayerErrorText.record(value) }
      } else if loading || player.buffering {
        VStack(spacing: 10) {
          StreakLoadingView(width: 96, tint: Theme.accent)
          Text(loading ? "正在加载视频…" : "正在缓冲…").font(Theme.Font.caption).foregroundStyle(.white.opacity(0.8))
        }.padding(16).environment(\.colorScheme, .dark)
          .allowsHitTesting(false)
      }
    }.animation(.easeOut(duration: 0.2), value: player.buffering)
  }
}

struct NextPlaybackPromptView: View {
  let remaining: Double
  let onPlay: () -> Void
  let onCancel: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(Int(ceil(max(0, remaining)))) 秒后播放下一个").font(Theme.Font.caption).foregroundStyle(.white.opacity(0.75))
      ProgressView(value: max(0, min(8, 8 - remaining)), total: 8).tint(Theme.accent)
      HStack(spacing: 8) {
        Spacer()
        Button("取消", action: onCancel).buttonStyle(PlayerControlButtonStyle(size: 28, prominent: true, horizontalPadding: 12))
        Button("立即播放", action: onPlay).buttonStyle(AppButtonStyle(role: .primary, size: .small))
      }
    }.padding(14).frame(width: 248).foregroundStyle(.white)
      .environment(\.colorScheme, .dark)
      .floatingGlassPanel(readingTint: .black.opacity(0.35))
      .padding(16)
      .transition(.move(edge: .trailing).combined(with: .opacity))
  }
}

/// The panel's first row: track white 22%, buffered white 32%, the played part as a 流光 streak,
/// a white thumb with an accent halo, chapter ticks, and the danmaku energy curve above.
/// Hovering (or scrubbing) shows a preview frame with 「time · chapter」. It is the only
/// panel view observing the clock, so position updates re-render just this row.
struct PlaybackTimeline: View {
  @ObservedObject var clock: PlaybackClock
  let duration: Double
  var override: Double? = nil
  var enabled = true
  /// Seek-bar previews shown while hovering or scrubbing, when the video has them.
  var preview: VideoShot? = nil
  /// Danmaku density (0…1 per bucket); the curve is drawn only when there is one (≥ 20 comments).
  var density: [Double] = []
  var chapters: [PlaybackChapter] = []
  /// Times cited by the AI answer on screen: amber ticks; a click next to one lands exactly on it.
  var markers: [Double] = []
  /// Seconds buffered ahead of the playhead, read on each clock tick.
  var bufferedAhead: () -> Double = { 0 }
  /// Scrubbing started (true) or ended (false); the page keeps the controls up meanwhile.
  var scrubbing: (Bool) -> Void = { _ in }
  let seek: (Double) -> Void
  /// Dragged position as a fraction of the track.
  @State private var scrub: Double?
  /// Where a finished scrub landed, shown until the clock catches up (at most a second).
  @State private var landed: Double?
  @State private var landedAt = Date.distantPast
  /// Hovered position as a fraction of the track.
  @State private var hoverFraction: Double? = PlaybackTimeline.debugHover
  @State private var trackWidth: CGFloat = 1
  /// The hover preview's own size, measured so it can be centred on the pointer.
  @State private var previewSize: CGSize = .zero
  #if DEBUG
  /// `--ui-seek-preview 0.4` pins the hover for screenshot checks.
  static let debugHover: Double? = {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--ui-seek-preview"), index + 1 < args.count,
      let value = Double(args[index + 1]), (0...1).contains(value) else { return nil }
    return value
  }()
  #else
  static let debugHover: Double? = nil
  #endif
  static let curveHeight: CGFloat = 14
  static let trackHeight: CGFloat = 4
  static let hitHeight: CGFloat = 16
  static let chapterGap: CGFloat = 3

  private var total: Double { max(1, duration) }

  var body: some View {
    let time = override ?? clock.time
    let fraction = displayedFraction(time: time)
    let buffered = clamp((time + max(0, bufferedAhead())) / total)
    VStack(spacing: 0) {
      energyCurve.frame(height: Self.curveHeight)
      ZStack(alignment: .leading) {
        // One bar per chapter with a gap between them, as on Bilibili; the hovered chapter brightens.
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.22)).frame(height: Self.trackHeight)
          if let segment = hoveredSegment {
            Rectangle().fill(.white.opacity(0.24))
              .frame(width: trackWidth * (segment.upperBound - segment.lowerBound), height: Self.trackHeight)
              .offset(x: trackWidth * segment.lowerBound)
          }
          Capsule().fill(.white.opacity(0.32)).frame(width: trackWidth * buffered, height: Self.trackHeight)
          StreakFill(progress: fraction).frame(height: Self.trackHeight)
        }
        .frame(height: Self.hitHeight)
        .mask(ChapterSegments(marks: chapterMarks, gap: Self.chapterGap))
        ForEach(markerFractions, id: \.self) { mark in
          RoundedRectangle(cornerRadius: 1.5).fill(Theme.highlight).frame(width: 3, height: 10)
            .shadow(color: Theme.highlight.opacity(0.9), radius: 4)
            .offset(x: trackWidth * mark - 1.5)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        if enabled {
          Circle().fill(.white).frame(width: 14, height: 14)
            .background(Circle().fill(Theme.accent.opacity(0.55)).frame(width: 22, height: 22))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .offset(x: trackWidth * fraction - 7)
        }
      }
      .frame(height: Self.hitHeight)
      .contentShape(Rectangle())
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = max(1, $0) }
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { value in
          guard enabled else { return }
          if scrub == nil { scrubbing(true) }
          scrub = clamp(value.location.x / trackWidth)
        }
        .onEnded { value in
          guard enabled else { return }
          var target = clamp(value.location.x / trackWidth)
          // A click (not a drag) within 6 pt of an AI mark jumps exactly to the cited time.
          if abs(value.translation.width) < 3, let mark = markerFractions.min(by: { abs($0 - target) < abs($1 - target) }),
            abs(mark - target) * trackWidth <= 6 { target = mark }
          scrub = nil; landed = target; landedAt = Date()
          scrubbing(false)
          seek(target * total)
        })
      .onContinuousHover { phase in
        switch phase {
        case .active(let point): hoverFraction = clamp(point.x / trackWidth)
        case .ended: hoverFraction = PlaybackTimeline.debugHover
        }
      }
    }
    .overlay(alignment: .topLeading) { hoverPreview }
    #if DEBUG
    .modifier(DemoSeekHover(fraction: $hoverFraction))
    #endif
    .accessibilityElement()
    .accessibilityLabel("播放进度")
    .accessibilityValue(Self.format(time) + " / " + Self.format(duration))
    .accessibilityAdjustableAction { direction in
      guard enabled else { return }
      seek(min(total, max(0, time + (direction == .increment ? 10 : -10))))
    }
  }

  private func clamp(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }

  private func displayedFraction(time: Double) -> Double {
    if let scrub { return scrub }
    if let landed, Date().timeIntervalSince(landedAt) < 1, abs(landed * total - time) > 1 { return landed }
    return clamp(time / total)
  }

  private var markerFractions: [Double] {
    markers.filter { $0.isFinite && $0 >= 0 && $0 <= total }.map { $0 / total }
  }

  private var chapterMarks: [Double] {
    chapters.map { $0.time / total }.filter { $0 > 0.002 && $0 < 0.998 }
  }

  /// The chapter span under the pointer (fractions of the track), while hovering a chaptered video.
  private var hoveredSegment: ClosedRange<Double>? {
    guard scrub == nil, let hover = hoverFraction, !chapterMarks.isEmpty else { return nil }
    let edges = [0.0] + chapterMarks + [1.0]
    guard let end = edges.firstIndex(where: { $0 > hover }) else { return nil }
    return edges[end - 1]...edges[end]
  }

  @ViewBuilder private var energyCurve: some View {
    if density.count > 1 {
      DanmakuDensityCurve(values: density)
        .fill(LinearGradient(colors: [Theme.highlight.opacity(0.85), Theme.highlight.opacity(0.06)], startPoint: .top, endPoint: .bottom))
        .padding(.bottom, 1)
        .allowsHitTesting(false).accessibilityHidden(true)
    } else {
      Color.clear
    }
  }

  /// 「time · chapter」 above the hovered (or scrubbed) position, with a preview frame when the
  /// video has them.
  @ViewBuilder private var hoverPreview: some View {
    if enabled, duration > 0, let fraction = scrub ?? hoverFraction {
      let target = clamp(fraction) * duration
      let title = chapterTitle(at: target)
      VStack(spacing: 6) {
        if let preview {
          // As on Bilibili: the time on the frame, the chapter title on its own line below.
          VideoShotFrame(shot: preview, time: target).frame(width: 176, height: 99)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(alignment: .bottom) {
              Text(Self.format(target)).font(Theme.Font.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 20).background(.black.opacity(0.55), in: Capsule()).padding(.bottom, 6)
            }
          if let title {
            Text(title).font(Theme.Font.caption2.weight(.medium)).foregroundStyle(.white).lineLimit(1)
              .padding(.horizontal, 8).frame(height: 20).frame(maxWidth: 176).background(.black.opacity(0.62), in: Capsule())
          }
        } else {
          Text([Self.format(target), title].compactMap { $0 }.joined(separator: " · "))
            .font(Theme.Font.caption2.weight(.medium).monospacedDigit()).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 8).frame(height: 20).background(.black.opacity(0.62), in: Capsule())
        }
      }
      .fixedSize()
      .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
      // Placed by offset from its measured size, centred on the pointer and kept within the
      // track, 4pt above it. Explicit alignment guides are not used: SwiftUI drops them for
      // content inside this `if`, which pinned the preview to the panel's bottom-left corner.
      .onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }
      .offset(x: min(max(0, trackWidth * CGFloat(clamp(fraction)) - previewSize.width / 2), max(0, trackWidth - previewSize.width)),
        y: -(previewSize.height + 4))
      .opacity(previewSize == .zero ? 0 : 1)
      // Measured afresh each time it appears, so it never shows for a frame at an old size.
      .onDisappear { previewSize = .zero }
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  private func chapterTitle(at time: Double) -> String? {
    PlaybackChapter.current(chapters, at: time)?.title
  }

  static func format(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
      : String(format: "%02d:%02d", value / 60, value % 60)
  }
}

/// The track cut at chapter starts: one rectangle per chapter with `gap` between neighbours.
struct ChapterSegments: Shape {
  let marks: [Double]
  let gap: CGFloat
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let edges = [0.0] + marks + [1.0]
    for index in 0..<(edges.count - 1) {
      let start = rect.minX + rect.width * edges[index] + (index == 0 ? 0 : gap / 2)
      let end = rect.minX + rect.width * edges[index + 1] - (index == edges.count - 2 ? 0 : gap / 2)
      if end > start { path.addRect(CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)) }
    }
    return path
  }
}

/// 「章节 · 当前章节 ›」 after the time readout; opens the chapter list to jump between chapters.
struct PlayerChapterButton: View {
  @ObservedObject var clock: PlaybackClock
  let chapters: [PlaybackChapter]
  var override: Double? = nil
  @Binding var shown: Bool
  let seek: (Double) -> Void
  var body: some View {
    let title = (PlaybackChapter.current(chapters, at: override ?? clock.time) ?? chapters.first)?.title ?? ""
    Button { shown.toggle() } label: {
      HStack(spacing: 5) {
        Text("章节").foregroundStyle(.white.opacity(0.6))
        Text(title).lineLimit(1).truncationMode(.tail)
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
      }
      .font(Theme.Font.caption).foregroundStyle(.white.opacity(0.9)).frame(maxWidth: 200, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(PlayerControlButtonStyle(size: 28, horizontalPadding: 10))
    .help("章节").accessibilityLabel("章节：" + title)
    .popover(isPresented: $shown, arrowEdge: .top) {
      ScrollView {
        PlaybackChapterList(clock: clock, chapters: chapters, override: override) { seek($0); shown = false }.padding(14)
      }.frame(width: 320).frame(maxHeight: 420)
    }
  }
}

/// The 3pt 流光 line along the bottom edge while the controls are hidden (设置 › 底部进度条).
struct PlaybackProgressBar: View {
  @ObservedObject var clock: PlaybackClock
  let duration: Double
  var override: Double? = nil
  var body: some View {
    let value = min(max(0, override ?? clock.time), max(1, duration)) / max(1, duration)
    ZStack(alignment: .leading) {
      Rectangle().fill(.white.opacity(0.16))
      StreakFill(progress: value.isFinite ? value : 0)
    }.frame(height: 3).allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// One preview frame cropped from its sprite sheet; sheets come from the shared image cache.
struct VideoShotFrame: View {
  let shot: VideoShot
  let time: Double
  @State private var sheet: (url: URL, image: CGImage)?
  var body: some View {
    let frame = shot.frame(at: time)
    ZStack {
      Color.black
      if let frame, let sheet, sheet.url == frame.sheet,
        let cropped = sheet.image.cropping(to: Self.scaled(frame, sheet: sheet.image, shot: shot)) {
        Image(decorative: cropped, scale: 1).resizable().aspectRatio(contentMode: .fill)
      }
    }
    .task(id: frame?.sheet) {
      guard let url = frame?.sheet, sheet?.url != url,
        let image = try? await ImageCache.shared.imageForReader(for: url) else { return }
      sheet = (url, image)
    }
  }
  /// Sheets may be served at another resolution than the declared grid (and the last sheet may
  /// have fewer rows), so scale by the width only.
  private static func scaled(_ frame: VideoShot.Frame, sheet: CGImage, shot: VideoShot) -> CGRect {
    let scale = CGFloat(sheet.width) / CGFloat(shot.columns * shot.frameWidth)
    return CGRect(x: CGFloat(frame.x) * scale, y: CGFloat(frame.y) * scale,
      width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
  }
}

/// 「跳过片头 / 片尾」 while an episode's marked opening or ending plays and automatic skipping is
/// off. Automatic skipping itself runs in `PGCPlaybackModel`, so it also works in the mini window.
struct PlaybackSkipPrompt: View {
  @ObservedObject var clock: PlaybackClock
  let skips: [PlaybackSkip]
  let automatic: Bool
  let skip: (PlaybackSkip) -> Void
  var body: some View {
    let active = PlaybackSkip.active(skips, at: clock.time)
    Group {
      if let active, !automatic {
        Button { skip(active) } label: {
          Label(active.title, systemImage: "forward.end.fill").font(Theme.Font.caption.weight(.semibold))
        }
        .buttonStyle(PlayerControlButtonStyle(size: 32, prominent: true, horizontalPadding: 14))
        .environment(\.colorScheme, .dark)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
      }
    }
    .animation(.snappy(duration: 0.25), value: active)
  }
}

/// Area chart of danmaku density across the timeline.
struct DanmakuDensityCurve: Shape {
  let values: [Double]
  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard values.count > 1 else { return path }
    let step = rect.width / CGFloat(values.count - 1)
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    for (index, value) in values.enumerated() {
      path.addLine(to: CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(min(1, max(0, value))) * rect.height))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// Shown over the (undecoded) video while 只听声音 is on: the cover, softly blurred behind
/// a sharp copy, so the player still reads as "this is playing".
struct AudioOnlyBackdrop: View {
  let cover: URL?
  let title: String
  var body: some View {
    ZStack {
      Color.black
      GeometryReader { geometry in
        CachedImage(url: cover).frame(width: geometry.size.width, height: geometry.size.height)
          .blur(radius: 40).opacity(0.45)
      }
      VStack(spacing: 14) {
        CachedImage(url: cover).aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: 360)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
          .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        Label("只听声音", systemImage: "headphones").font(Theme.Font.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.8))
        if !title.isEmpty {
          Text(title).font(Theme.Font.body).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
      }.padding(24)
    }
    // The blur samples beyond its frame; keep it inside the player.
    .clipped()
    .allowsHitTesting(false)
  }
}
