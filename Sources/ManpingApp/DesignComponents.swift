import SwiftUI

// Shared page scaffolding. Every page header, sidebar header and paging footer goes
// through these so heights, insets and type match across the app.

/// The 52pt header above a page's content: optional symbol, title, trailing controls.
struct PageHeader<Controls: View>: View {
  let title: String
  var symbol: String? = nil
  var subtitle: String? = nil
  @ViewBuilder var controls: () -> Controls
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 10) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accentText(scheme))
      }
      Text(title).font(Theme.Font.section).lineLimit(1)
      if let subtitle { Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1) }
      Spacer(minLength: 12)
      controls()
    }.foregroundStyle(Theme.text(scheme)).padding(.horizontal, Theme.gridPadding)
      .frame(height: Theme.pageHeaderHeight)
      .overlay(alignment: .bottom) { Hairline() }
  }
}

extension PageHeader where Controls == EmptyView {
  init(title: String, symbol: String? = nil, subtitle: String? = nil) {
    self.init(title: title, symbol: symbol, subtitle: subtitle) { EmptyView() }
  }
}

/// What a page puts in the main window's toolbar: its title, an optional subtitle, page-specific
/// controls (shown before the search field) and its own refresh action. Pages declare it with
/// `.pageToolbar(…)`; the shell draws the one toolbar, so no page draws a header of its own.
struct PageToolbarItem {
  var title: String?
  var subtitle: String?
  /// A badge before the title (「直播中」).
  var leading: AnyView?
  /// In-page tabs, shown right after the title.
  var segments: AnyView?
  var accessory: AnyView?
  var refresh: (() -> Void)?
  var refreshing = false
}

struct PageToolbarKey: PreferenceKey {
  static var defaultValue: PageToolbarItem? { nil }
  static func reduce(value: inout PageToolbarItem?, nextValue: () -> PageToolbarItem?) {
    if let next = nextValue() { value = next }
  }
}

extension View {
  /// Declares this page's toolbar content. `refresh` replaces the shell's default (⌘R) refresh.
  func pageToolbar<Accessory: View>(title: String? = nil, subtitle: String? = nil, leading: AnyView? = nil,
    segments: AnyView? = nil, refreshing: Bool = false, refresh: (() -> Void)? = nil,
    @ViewBuilder accessory: () -> Accessory) -> some View {
    preference(key: PageToolbarKey.self, value: PageToolbarItem(title: title, subtitle: subtitle, leading: leading,
      segments: segments, accessory: AnyView(accessory()), refresh: refresh, refreshing: refreshing))
  }
  func pageToolbar(title: String? = nil, subtitle: String? = nil, segments: AnyView? = nil, refreshing: Bool = false,
    refresh: (() -> Void)? = nil) -> some View {
    preference(key: PageToolbarKey.self, value: PageToolbarItem(title: title, subtitle: subtitle, leading: nil,
      segments: segments, accessory: nil, refresh: refresh, refreshing: refreshing))
  }
}

/// The toolbar's title group: the page's leading badge, title and subtitle. Shared by the main
/// window's toolbar and the standalone playback window's.
struct PageToolbarTitle: View {
  let item: PageToolbarItem?
  let fallback: String
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 8) {
      if let leading = item?.leading { leading.fixedSize() }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(item?.title ?? fallback).font(Theme.Font.title).lineLimit(1)
        if let subtitle = item?.subtitle, !subtitle.isEmpty {
          Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
        }
      }
    }
  }
}

/// A secondary row under the toolbar for a page's filters (partition chips, sort menus).
struct PageFilterBar<Content: View>: View {
  @ViewBuilder var content: () -> Content
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 8) { content() }.foregroundStyle(Theme.text(scheme))
      .padding(.horizontal, Theme.gridPadding).frame(height: 44)
      .overlay(alignment: .bottom) { Hairline() }
  }
}

/// The title row at the top of a secondary sidebar, level with the page header.
struct SidebarHeader<Controls: View>: View {
  let title: String
  @ViewBuilder var controls: () -> Controls
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 6) {
      Text(title).font(Theme.Font.section).lineLimit(1)
      Spacer(minLength: 0)
      controls()
    }.foregroundStyle(Theme.text(scheme)).padding(.leading, 20).padding(.trailing, 12)
      .frame(height: Theme.pageHeaderHeight)
  }
}

extension SidebarHeader where Controls == EmptyView {
  init(title: String) { self.init(title: title) { EmptyView() } }
}

/// A small grouping label inside a sidebar list.
struct SidebarSectionTitle: View {
  let title: String
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Text(title).font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(Theme.tertiaryText(scheme))
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
  }
}

/// Paging footer: spinner while loading, otherwise a "加载更多" button that also auto-loads.
struct LoadMoreFooter: View {
  let isLoading: Bool
  var autoLoad = true
  let load: () -> Void
  var body: some View {
    Group {
      if isLoading { ProgressView().controlSize(.small) }
      else {
        Button("加载更多", action: load).buttonStyle(AppButtonStyle(size: .small))
          .onAppear { if autoLoad { load() } }
      }
    }.frame(maxWidth: .infinity).frame(height: 56)
  }
}

/// Inline error line used inside panels and forms.
struct InlineErrorText: View {
  let message: String
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill").font(Theme.Font.caption)
      .foregroundStyle(Theme.danger(scheme)).lineLimit(3).textSelection(.enabled)
  }
}

/// Drag handle between a resizable sidebar and the content: a hairline with a wider hit area.
struct SidebarResizeHandle: View {
  @Binding var width: Double
  let range: ClosedRange<Double>
  @State private var start: Double?
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Hairline(axis: .vertical)
      .overlay { if hovering || start != nil { Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 2) } }
      .frame(width: 7).contentShape(Rectangle())
      .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value }; if value { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { value in
          if start == nil { start = width }
          width = min(range.upperBound, max(range.lowerBound, (start ?? width) + value.translation.width))
        }
        .onEnded { _ in start = nil })
      .accessibilityLabel("侧栏宽度")
      .accessibilityAdjustableAction { direction in
        width = min(range.upperBound, max(range.lowerBound, width + (direction == .increment ? 20 : -20)))
      }
  }
}

/// Filter chips (sub-partitions, categories): 28pt capsules, tinted when selected.
struct ChipStyle: ButtonStyle {
  var selected = false
  func makeBody(configuration: Configuration) -> some View {
    ChipBody(configuration: configuration, selected: selected)
  }
}

private struct ChipBody: View {
  let configuration: ButtonStyleConfiguration
  let selected: Bool
  @Environment(\.colorScheme) private var scheme
  @State private var hovering = false
  var body: some View {
    configuration.label.font(Theme.Font.caption).fontWeight(selected ? .semibold : .regular).lineLimit(1)
      .padding(.horizontal, 12).frame(height: Theme.compactControlHeight)
      .foregroundStyle(selected ? Theme.accentText(scheme) : Theme.text(scheme))
      .background(Capsule().fill(
        selected ? Theme.selectedFill(scheme)
          : configuration.isPressed ? Theme.fillPressed(scheme) : hovering ? Theme.fillHover(scheme) : Theme.fill(scheme)))
      .contentShape(Capsule())
      .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value } }
  }
}

/// Label for a pull-down menu in page chrome: text plus an up/down chevron, one style app-wide.
struct MenuLabel: View {
  let title: String
  var symbol: String? = nil
  var body: some View {
    HStack(spacing: 5) {
      if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
      Text(title)
      Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.7)
    }
  }
}

extension View {
  /// Applies the app's pull-down menu look; pair with `MenuLabel`.
  func appMenuStyle() -> some View {
    menuStyle(.button).buttonStyle(AppButtonStyle(size: .small)).menuIndicator(.hidden).fixedSize()
  }
}

/// Small round buttons that sit on artwork (remove, select): dark translucent disc, white glyph.
struct ArtworkIconButtonStyle: ButtonStyle {
  var destructive = false
  func makeBody(configuration: Configuration) -> some View {
    ArtworkIconBody(configuration: configuration, destructive: destructive)
  }
}

private struct ArtworkIconBody: View {
  let configuration: ButtonStyleConfiguration
  let destructive: Bool
  @State private var hovering = false
  var body: some View {
    configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(Circle().fill(hovering && destructive ? Theme.danger(.dark) : .black.opacity(configuration.isPressed ? 0.75 : 0.58)))
      .contentShape(Circle())
      .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value } }
  }
}

/// Header button that shows or hides a page's secondary sidebar.
struct SidebarToggleButton: View {
  @Binding var hidden: Bool
  var body: some View {
    Button { withAnimation(.snappy(duration: 0.25)) { hidden.toggle() } } label: {
      Image(systemName: "sidebar.left")
    }.buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true))
      .help(hidden ? "显示侧栏" : "隐藏侧栏").accessibilityLabel(hidden ? "显示侧栏" : "隐藏侧栏")
  }
}

/// Wrapping row of chips (search suggestions, tags).
struct FlowChips<ID: Hashable>: View {
  let items: [(ID, String, String)]
  let action: (String) -> Void
  var body: some View {
    FlowLayout(spacing: 8) {
      ForEach(items, id: \.0) { _, title, value in
        Button(title) { action(value) }.buttonStyle(ChipStyle())
      }
    }
  }
}

/// Minimal left-to-right wrapping layout.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
      x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
    }
    return CGSize(width: proposal.width ?? widest, height: y + row)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing; row = max(row, size.height)
    }
  }
}

/// The tinted square icon at the start of a settings row.
struct SettingIcon: View {
  let symbol: String
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accentText(scheme))
      .frame(width: 30, height: 30).background(Theme.selectedFill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
  }
}

/// Small status capsule ("已配置", "已登录").
struct StatusPill: View {
  let text: String
  var positive = true
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Text(text).font(Theme.Font.caption2.weight(.medium))
      .foregroundStyle(positive ? Theme.success(scheme) : Theme.secondaryText(scheme))
      .padding(.horizontal, 8).frame(height: 20)
      .background((positive ? Theme.success(scheme).opacity(0.14) : Theme.fill(scheme)), in: Capsule())
  }
}

/// Collapsible card header chevron that rotates instead of swapping glyphs.
struct DisclosureChevron: View {
  let expanded: Bool
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiaryText(scheme))
      .rotationEffect(.degrees(expanded ? 180 : 0))
  }
}

// MARK: - Player chrome (always white-on-video, independent of the app theme)

/// Round, white-ink buttons for controls that sit over the video.
struct PlayerControlButtonStyle: ButtonStyle {
  var size: CGFloat = 30
  var active = false
  var prominent = false
  var horizontalPadding: CGFloat = 0
  func makeBody(configuration: Configuration) -> some View {
    PlayerControlBody(configuration: configuration, size: size, active: active, prominent: prominent, horizontalPadding: horizontalPadding)
  }
}

private struct PlayerControlBody: View {
  let configuration: ButtonStyleConfiguration
  let size: CGFloat
  let active: Bool
  let prominent: Bool
  let horizontalPadding: CGFloat
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false
  var body: some View {
    configuration.label.font(.system(size: 13, weight: .medium))
      .foregroundStyle(active ? Theme.onAccent : .white.opacity(isEnabled ? 1 : 0.35))
      .padding(.horizontal, horizontalPadding).frame(minWidth: size, minHeight: size)
      .background(Capsule().fill(
        active ? Theme.accent
          : configuration.isPressed ? .white.opacity(0.26)
          : hovering || prominent ? .white.opacity(prominent ? 0.18 : 0.14) : .clear))
      .contentShape(Capsule())
      .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value && isEnabled } }
  }
}

extension View {
  /// Pull-down menus inside the player control bar.
  func playerMenuStyle() -> some View {
    menuStyle(.button).buttonStyle(PlayerControlButtonStyle(horizontalPadding: 8)).menuIndicator(.hidden).fixedSize()
  }
}

/// Thumbnail + title + meta row used in player side lists (queue, parts, collections, related).
struct MediaRow: View {
  let cover: URL?
  let title: String
  var subtitle: String? = nil
  var meta: String? = nil
  var duration: String? = nil
  var thumbWidth: CGFloat = 112
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      CachedImage(url: cover).frame(width: thumbWidth, height: thumbWidth * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(alignment: .bottomTrailing) { if let duration { MediaBadge(text: duration).padding(4) } }
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(Theme.Font.body).lineLimit(2).multilineTextAlignment(.leading)
        if let subtitle { Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1) }
        if let meta { Text(meta).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
  }
}

// MARK: - Brand graphics (流光)

/// One 流光 streak: a round head on the trailing side that thins to a point on the leading side.
/// `progress` (0…1) sets where the head sits, so the same shape draws a whole streak or the played
/// part of a progress bar.
struct StreakShape: Shape {
  var progress: CGFloat = 1
  /// Tail thickness as a fraction of the head's.
  var tail: CGFloat = 0.18

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let length = rect.width * min(max(progress, 0), 1)
    let radius = rect.height / 2
    guard length > 0, radius > 0 else { return Path() }
    let head = CGPoint(x: rect.minX + max(length - radius, radius), y: rect.midY)
    let tailHalf = radius * tail
    let control = rect.minX + (head.x - rect.minX) * 0.6
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY - tailHalf))
    path.addQuadCurve(to: CGPoint(x: head.x, y: rect.minY), control: CGPoint(x: control, y: rect.minY))
    path.addArc(center: head, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
    path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY + tailHalf), control: CGPoint(x: control, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// A streak in the brand fade: the tail at 25% of `tint`, the head at 100%. `progress` trims it
/// from the trailing side and the fade always spans the visible part.
struct StreakFill: View {
  var progress: CGFloat = 1
  var tint: Color = Theme.accent
  var body: some View {
    GeometryReader { geometry in
      let length = geometry.size.width * min(max(progress, 0), 1)
      StreakShape()
        .fill(LinearGradient(colors: [tint.opacity(0.25), tint], startPoint: .leading, endPoint: .trailing))
        .frame(width: length, height: geometry.size.height)
    }
  }
}

/// The danmaku symbol: three solid streaks drawn on an 18pt grid (menu bar icon, player toggle).
struct DanmakuSymbol: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 18
    return Self.reference.applying(
      CGAffineTransform(translationX: rect.midX - 9 * scale, y: rect.midY - 9 * scale).scaledBy(x: scale, y: scale))
  }

  /// The reference SVG path from docs/DesignSystem.md, traced command for command.
  static let reference: Path = {
    var path = Path()
    // M5,4.6 C9,4.6 12,4 13.6,4 A1.3,1.3 0 0 1 13.6,6.6 C12,6.6 9,5.9 5,5.9 Z
    path.move(to: CGPoint(x: 5, y: 4.6))
    path.addCurve(to: CGPoint(x: 13.6, y: 4), control1: CGPoint(x: 9, y: 4.6), control2: CGPoint(x: 12, y: 4))
    path.addArc(center: CGPoint(x: 13.6, y: 5.3), radius: 1.3, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
    path.addCurve(to: CGPoint(x: 5, y: 5.9), control1: CGPoint(x: 12, y: 6.6), control2: CGPoint(x: 9, y: 5.9))
    path.closeSubpath()
    // M1.5,8.3 C6,8.3 10,7.3 12.6,7.3 A2,2 0 0 1 12.6,11.3 C10,11.3 6,10 1.5,10 Z
    path.move(to: CGPoint(x: 1.5, y: 8.3))
    path.addCurve(to: CGPoint(x: 12.6, y: 7.3), control1: CGPoint(x: 6, y: 8.3), control2: CGPoint(x: 10, y: 7.3))
    path.addArc(center: CGPoint(x: 12.6, y: 9.3), radius: 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
    path.addCurve(to: CGPoint(x: 1.5, y: 10), control1: CGPoint(x: 10, y: 11.3), control2: CGPoint(x: 6, y: 10))
    path.closeSubpath()
    // M6,13 C9,13 12,12.3 14.4,12.3 A1.6,1.6 0 0 1 14.4,15.5 C12,15.5 9,14.6 6,14.6 Z
    path.move(to: CGPoint(x: 6, y: 13))
    path.addCurve(to: CGPoint(x: 14.4, y: 12.3), control1: CGPoint(x: 9, y: 13), control2: CGPoint(x: 12, y: 12.3))
    path.addArc(center: CGPoint(x: 14.4, y: 13.9), radius: 1.6, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
    path.addCurve(to: CGPoint(x: 6, y: 14.6), control1: CGPoint(x: 12, y: 15.5), control2: CGPoint(x: 9, y: 14.6))
    path.closeSubpath()
    return path
  }()
}

/// The loading animation: one streak running left to right along a faint track, looping.
/// With 减弱动态效果 the streak stays in the middle and only breathes.
struct StreakLoadingView: View {
  var width: CGFloat = 120
  var height: CGFloat = 4
  var tint: Color = Theme.accent
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation) { context in
      let period = 1.4
      let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
      let streak = width * 0.45
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.fill(scheme))
        if reduceMotion {
          StreakFill(tint: tint).frame(width: streak).offset(x: (width - streak) / 2)
            .opacity(0.55 + 0.45 * abs(sin(phase * .pi)))
        } else {
          // Eased so the head slows as it enters and leaves the track.
          let eased = 0.5 - cos(phase * .pi) / 2
          StreakFill(tint: tint).frame(width: streak).offset(x: -streak + (width + streak) * eased)
        }
      }.frame(width: width, height: height).clipShape(Capsule())
    }.accessibilityElement().accessibilityLabel("正在加载")
  }
}

#if DEBUG
/// Preview of the brand graphics for design review.
struct BrandGraphicsPreview: View {
  var body: some View {
    VStack(spacing: 20) {
      DanmakuSymbol().fill(Theme.mist).frame(width: 36, height: 36)
      StreakFill(progress: 0.7).frame(width: 240, height: 6)
      StreakLoadingView()
    }.padding(32).background(Color.black)
  }
}

#Preview("流光") { BrandGraphicsPreview() }
#endif
