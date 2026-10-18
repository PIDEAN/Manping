import AppKit
import ManpingCore
import SwiftUI

// Source: Controls/Components/VideoCardControl/VideoCardControl.xaml at UI 896a062, restyled to the
// borderless 流光玻璃 card: cover, two-line title, one metadata line; the surface appears on hover.
/// What a card's context menu can do beyond its own tap action, provided once by the main
/// window. Cards outside it (no value in the environment) show only the link items.
struct CardActions {
  var play: @MainActor (Video) -> Void
  var playCompact: @MainActor (Video) -> Void
  var playDetached: @MainActor (Video) -> Void
  var openSpace: @MainActor (Int64) -> Void
  var playLiveCompact: @MainActor (Int64) -> Void

  @MainActor init(model: AppModel) {
    play = { model.open($0) }
    // The menu's choice is this open's mode; 设置 › 打开视频时 does not override it on load.
    playCompact = { model.open($0, mode: .compact) }
    playDetached = { model.open($0, mode: .detached) }
    openSpace = { model.openOverlay(.userSpace($0)) }
    playLiveCompact = { model.openLive($0, mode: .compact) }
  }

  static func webURL(_ video: Video) -> URL? {
    let id = video.bvid.hasPrefix("BV") ? video.bvid : video.aid.map { "av\($0)" } ?? ""
    return id.isEmpty ? nil : URL(string: "https://www.bilibili.com/video/\(id)")
  }
  static func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }
}

extension EnvironmentValues {
  @Entry var cardActions: CardActions? = nil
}

/// The shared video context menu: 播放 / 小窗播放 / 在独立窗口播放 — 拷贝链接 / 在浏览器中打开 —
/// 进入 UP 主空间. `extra` items (such as 删除记录) follow at the end.
struct VideoContextMenu: View {
  let video: Video
  var extra: AnyView?
  @Environment(\.cardActions) private var actions
  var body: some View {
    if let actions {
      Button("播放") { actions.play(video) }
      Button("小窗播放") { actions.playCompact(video) }
      Button("在独立窗口播放") { actions.playDetached(video) }
      Divider()
    }
    if let url = CardActions.webURL(video) {
      Button("拷贝链接") { CardActions.copy(url) }
      Button("在浏览器中打开") { NSWorkspace.shared.open(url) }
    }
    if let actions, let mid = video.authorID, mid > 0 {
      Divider()
      Button("进入 UP 主空间") { actions.openSpace(mid) }
    }
    if let extra {
      Divider()
      extra
    }
  }
}

struct VideoCard: View {
  let video: Video
  var action: () -> Void
  /// Page-specific items appended to the context menu.
  var menuExtra: AnyView? = nil
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: Theme.cardTitleGap) {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
          .overlay { CachedImage(url: video.cover) }
          .overlay(alignment: .topLeading) {
            if let reason = video.recommendationReason, !reason.isEmpty {
              RecommendBadge(text: reason).padding(8).padding(.trailing, 40)
            }
          }
          .overlay(alignment: .bottomTrailing) {
            MediaBadge(text: String(format: "%02d:%02d", video.duration / 60, video.duration % 60)).padding(8)
          }
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        VStack(alignment: .leading, spacing: 4) {
          Text(video.title).font(Theme.Font.headline).foregroundStyle(Theme.text(scheme))
            .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
          Text(metadata).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
        }
      }.contentShape(Rectangle()).cardHover()
    }.buttonStyle(CardPressStyle()).accessibilityLabel("播放 \(video.title)，\(video.author)")
      .contextMenu { VideoContextMenu(video: video, extra: menuExtra) }
  }

  /// 「UP 主 · 播放 · 时间」 on one line; the subtitle stands in for the time when the feed gives one.
  private var metadata: String {
    var parts: [String] = []
    if !video.author.isEmpty { parts.append(video.author) }
    parts.append(video.viewsText ?? Self.plays(video.views))
    if let subtitle = video.subtitle, !subtitle.isEmpty {
      parts.append(subtitle)
    } else if let publishedAt = video.publishedAt, publishedAt > 0 {
      parts.append(Self.relative.localizedString(for: Date(timeIntervalSince1970: Double(publishedAt)), relativeTo: .now))
    }
    return parts.joined(separator: " · ")
  }

  /// 「523 播放」「12.4 万播放」: a space between digits and Chinese, none after 万.
  static func plays(_ value: Int) -> String {
    value >= 10000 ? String(format: "%.1f 万播放", Double(value) / 10000) : "\(value) 播放"
  }

  private static let relative: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.unitsStyle = .short
    return formatter
  }()
}

/// Cards dim slightly while pressed; hover lift comes from `cardHover()`.
struct CardPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.86 : 1)
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
  }
}

/// Whole-page states in three styles (DesignSystem.md section 9): loading shows the 流光 streak,
/// empty shows the page's symbol, error shows an amber triangle and defaults its action to 「重试」.
struct PageStateView: View {
  enum Style { case loading, empty, error }
  let style: Style
  let title: String
  let message: String
  let icon: String
  let actionTitle: String?
  let action: (() -> Void)?
  @Environment(\.colorScheme) private var scheme

  init(_ style: Style = .empty, title: String, message: String = "", icon: String = "tray",
    actionTitle: String? = nil, action: (() -> Void)? = nil) {
    self.style = style
    self.title = title
    self.message = message
    self.icon = icon
    self.actionTitle = actionTitle ?? (style == .error && action != nil ? "重试" : nil)
    self.action = action
  }

  var body: some View {
    VStack(spacing: 10) {
      symbol.padding(.bottom, 4)
      Text(title).font(Theme.Font.section).foregroundStyle(Theme.text(scheme))
      if !message.isEmpty {
        Text(message).font(Theme.Font.body).foregroundStyle(Theme.secondaryText(scheme))
          .multilineTextAlignment(.center).frame(maxWidth: 420).textSelection(.enabled)
      }
      if let actionTitle, let action {
        Button(actionTitle, action: action).buttonStyle(AppButtonStyle()).padding(.top, 6)
      }
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var symbol: some View {
    switch style {
    case .loading:
      StreakLoadingView().frame(height: 48)
    case .empty:
      Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accentText(scheme))
        .frame(width: 48, height: 48).background(Theme.selectedFill(scheme), in: Circle())
    case .error:
      Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20, weight: .medium))
        .foregroundStyle(Theme.highlight)
        .frame(width: 48, height: 48).background(Theme.highlight.opacity(0.16), in: Circle())
    }
  }
}
