import AppKit
import SwiftUI

// Source: BiliCopilot.UI/App.xaml and Controls/RootLayout.xaml at UI 896a062.
enum AppTheme: String, CaseIterable {
  case system = "跟随系统"
  case light = "浅色"
  case dark = "深色"

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

// 流光玻璃: cool ink layers (backdrop → panel → card), translucent fills for interaction states,
// one accent, and Liquid Glass reserved for chrome that floats over content. Every value here
// comes from docs/DesignSystem.md sections 3–6; views never spell a hex value or `Color(red:…)`.
enum Theme {
  static let accent = color(0x2EC0F7)
  /// Ink on top of an accent fill (7.9:1 against the accent).
  static let onAccent = color(0x04202C)
  /// Live status and unread counts; the same in both appearances.
  static let live = color(0xFF4F95)
  static let onLive = color(0x2A0614)
  /// Energy curve, highlighted comments, ratings and membership.
  static let highlight = color(0xFFB13B)
  static let onHighlight = color(0x2A1800)
  /// Default danmaku colour and the player's primary button.
  static let mist = color(0xF6F3EE)
  /// The main window's toolbar across the top of the content (back / forward, title, search).
  static let toolbarHeight: CGFloat = 60
  /// Toolbar controls (navigation group, search field, refresh).
  static let toolbarControlHeight: CGFloat = 36
  static let pageHeaderHeight: CGFloat = 52
  /// The main window's glass sidebar; below `sidebarCollapseWidth` it becomes an icon rail.
  static let sidebarWidth: CGFloat = 232
  static let sidebarRailWidth: CGFloat = 68
  static let sidebarCollapseWidth: CGFloat = 1000
  static let secondarySidebarWidth: CGFloat = 232
  static let gridMinimum: CGFloat = 220
  static let gridSpacing: CGFloat = 20
  static let gridPadding: CGFloat = 24
  /// Cover-to-title gap on borderless cards.
  static let cardTitleGap: CGFloat = 10
  static let controlHeight: CGFloat = 32
  static let compactControlHeight: CGFloat = 28
  static let rowHeight: CGFloat = 34
  /// Gap between the window edge and the floating content panel.
  static let panelInset: CGFloat = 8
  /// The playback page: the gap between the stage, the window edges, the toolbar and the right
  /// panel, and between the stage's edges and its control panel (DesignSystem.md §11).
  static let stageInset: CGFloat = 12

  /// Four radii plus capsule: badges, rows and fields, covers and cards, panels.
  enum Radius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
  }

  enum Font {
    static let largeTitle = SwiftUI.Font.system(size: 26, weight: .bold)
    static let title = SwiftUI.Font.system(size: 20, weight: .bold)
    static let section = SwiftUI.Font.system(size: 15, weight: .semibold)
    static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
    static let body = SwiftUI.Font.system(size: 13)
    static let caption = SwiftUI.Font.system(size: 12)
    static let caption2 = SwiftUI.Font.system(size: 11)
  }

  // MARK: Layers
  static func backdrop(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x0E1118 : 0xEEF1F6) }
  static func panel(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x151924 : 0xF7F8FB) }
  static func card(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x1C2130 : 0xFFFFFF) }
  /// Menus and controls raised above a fill.
  static func raised(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x252B3B : 0xFFFFFF) }

  // MARK: Interaction fills (translucent so they read on any layer)
  static func fill(_ scheme: ColorScheme) -> Color { ink(scheme, dark: 0.06, light: 0.04) }
  static func fillHover(_ scheme: ColorScheme) -> Color { ink(scheme, dark: 0.10, light: 0.07) }
  static func fillPressed(_ scheme: ColorScheme) -> Color { ink(scheme, dark: 0.14, light: 0.11) }
  static func selectedFill(_ scheme: ColorScheme) -> Color { accent.opacity(scheme == .dark ? 0.18 : 0.16) }
  static func separator(_ scheme: ColorScheme) -> Color { ink(scheme, dark: 0.08, light: 0.08) }

  // MARK: Text
  static func text(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0xEEF1F6 : 0x161A22) }
  static func secondaryText(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0xA3ABBA : 0x4F5766) }
  static func tertiaryText(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x858E9F : 0x646C7C) }
  static func disabledText(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x5E6676 : 0xA3A9B4) }
  /// Accent used as text or icon colour; the raw accent is too light on the light panel.
  static func accentText(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x6FD0F5 : 0x0A6E9E) }

  // MARK: Status
  static func danger(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0xFF7A72 : 0xC7372A) }
  static func success(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x3CCB7F : 0x1E7F4A) }
  static func warning(_ scheme: ColorScheme) -> Color { scheme == .dark ? highlight : color(0xA35F00) }
  static func scrim(_ scheme: ColorScheme) -> Color { .black.opacity(scheme == .dark ? 0.36 : 0.18) }

  // MARK: Media (artwork and video, independent of the appearance)
  /// Duration and count badges on artwork.
  static let mediaBadge = Color.black.opacity(0.72)
  /// The playback stage under the picture: near black, in both appearances.
  static let stage = color(0x05070B)
  /// The stage's 0.5 pt edge: white 6% on the dark window, black 8% on the light one.
  static func stageStroke(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.08) }
  /// Partition symbol tints; rotated by partition id.
  static let partitionPalette: [Color] = [
    color(0xA98BFF), color(0x2EC0F7), live, color(0x3CCB9F), highlight, color(0x5B8CFF), color(0xFF8A4C),
  ]

  /// The window background, resolved per appearance so light mode never shows a dark frame.
  static let backdropNSColor = NSColor(name: "ManpingBackdrop") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0x0E / 255, green: 0x11 / 255, blue: 0x18 / 255, alpha: 1)
      : NSColor(srgbRed: 0xEE / 255, green: 0xF1 / 255, blue: 0xF6 / 255, alpha: 1)
  }

  static let hoverAnimation = Animation.easeOut(duration: 0.12)

  private static func ink(_ scheme: ColorScheme, dark: Double, light: Double) -> Color {
    scheme == .dark ? Color.white.opacity(dark) : Color.black.opacity(light)
  }
  private static func color(_ hex: Int) -> Color {
    Color(.sRGB,
      red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }
}

// MARK: - Buttons

/// The general chrome button: transparent until hovered, a translucent fill when hovered,
/// one step darker when pressed, accent tint when selected. `icon` gives it a resting fill.
/// Rows use the `sm` radius; round icon buttons pass `capsule`.
struct ChromeButtonStyle: ButtonStyle {
  var selected = false
  var fullWidth = false
  var icon = false
  var capsule = false

  func makeBody(configuration: Configuration) -> some View {
    ChromeButtonBody(configuration: configuration, selected: selected, fullWidth: fullWidth, icon: icon, capsule: capsule)
  }
}

private struct ChromeButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let selected: Bool
  let fullWidth: Bool
  let icon: Bool
  let capsule: Bool
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  private var shape: AnyShape {
    capsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
  }

  var body: some View {
    configuration.label
      .foregroundStyle(
        isEnabled ? (selected ? Theme.accentText(scheme) : Theme.text(scheme)) : Theme.disabledText(scheme)
      )
      .fontWeight(selected ? .semibold : nil)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background(shape.fill(fill))
      .contentShape(shape)
      .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value } }
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
  }

  private var fill: Color {
    guard isEnabled else { return icon ? Theme.fill(scheme) : .clear }
    if configuration.isPressed { return selected ? Theme.accent.opacity(0.26) : Theme.fillPressed(scheme) }
    if selected { return Theme.selectedFill(scheme) }
    if hovering { return Theme.fillHover(scheme) }
    return icon ? Theme.fill(scheme) : .clear
  }
}

/// Page-level actions: capsule buttons in four roles. Size `.regular` is 32pt, `.small` 28pt,
/// `.toolbar` 36pt (the toolbar's control height, level with the refresh button).
/// Primary is accent-tinted Liquid Glass, secondary is regular glass, plain has no surface and
/// accent ink, destructive is a danger wash with a danger hairline.
struct AppButtonStyle: ButtonStyle {
  enum Role { case primary, secondary, plain, destructive }
  enum Size { case regular, small, toolbar }
  var role: Role = .secondary
  var size: Size = .regular
  var iconOnly = false

  func makeBody(configuration: Configuration) -> some View {
    AppButtonBody(configuration: configuration, role: role, size: size, iconOnly: iconOnly)
  }
}

private struct AppButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let role: AppButtonStyle.Role
  let size: AppButtonStyle.Size
  let iconOnly: Bool
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  private var height: CGFloat {
    switch size {
    case .regular: Theme.controlHeight
    case .small: Theme.compactControlHeight
    case .toolbar: Theme.toolbarControlHeight
    }
  }

  var body: some View {
    configuration.label
      .font(size == .small ? Theme.Font.caption : Theme.Font.body)
      .fontWeight(role == .primary ? .semibold : nil)
      .lineLimit(1)
      .padding(.horizontal, iconOnly ? 0 : (size == .small ? 12 : 14))
      .frame(width: iconOnly ? height : nil, height: height)
      .foregroundStyle(foreground)
      .background(Capsule().fill(wash))
      .overlay {
        if role == .destructive && isEnabled {
          Capsule().strokeBorder(Theme.danger(scheme).opacity(0.4), lineWidth: 1)
        }
      }
      .glassEffect(glass, in: Capsule())
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed && glass != .identity ? 0.97 : 1)
      .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value } }
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
  }

  private var glass: Glass {
    guard isEnabled else { return .identity }
    switch role {
    case .primary: return .regular.tint(Theme.accent).interactive()
    case .secondary: return .regular.interactive()
    case .plain, .destructive: return .identity
    }
  }

  private var foreground: Color {
    guard isEnabled else { return Theme.disabledText(scheme) }
    switch role {
    case .primary: return Theme.onAccent
    case .destructive: return Theme.danger(scheme)
    case .secondary: return Theme.text(scheme)
    case .plain: return iconOnly ? (hovering ? Theme.text(scheme) : Theme.secondaryText(scheme)) : Theme.accentText(scheme)
    }
  }

  /// The flat layer under (or instead of) the glass: disabled, plain-hover and destructive states.
  private var wash: Color {
    let pressed = configuration.isPressed
    guard isEnabled else { return role == .plain ? .clear : Theme.fill(scheme) }
    switch role {
    case .primary, .secondary: return .clear
    case .plain: return pressed ? Theme.fillPressed(scheme) : hovering ? Theme.fillHover(scheme) : .clear
    case .destructive: return Theme.danger(scheme).opacity(pressed ? 0.24 : hovering ? 0.18 : 0.12)
    }
  }
}

/// A row in any secondary sidebar: 34pt, `sm` radius, accent tint when selected.
struct SidebarRowStyle: ButtonStyle {
  var selected = false
  func makeBody(configuration: Configuration) -> some View {
    ChromeButtonStyle(selected: selected, fullWidth: true).makeBody(configuration: configuration)
  }
}

// MARK: - Surfaces

extension View {
  /// The solid card surface for list-style cards, settings groups and panels inside content.
  func cardSurface(_ scheme: ColorScheme, radius: CGFloat = Theme.Radius.md) -> some View {
    background(Theme.card(scheme))
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
  }

  /// A floating Liquid Glass panel for transient overlays (comment panel, confirmation, prompts).
  /// `readingTint` lays the panel colour into the glass so long text stays legible over busy grids.
  func floatingGlassPanel(radius: CGFloat = Theme.Radius.lg, readingTint: Color? = nil) -> some View {
    glassEffect(readingTint.map { Glass.regular.tint($0) } ?? .regular,
      in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }

  /// Hover affordance for cards. Borderless cards (`outset` 8) gain a `card` surface that reaches
  /// past their edges with the `lg` radius; cards that already have a surface pass `outset: 0`.
  /// The shadow exists only while hovered.
  func cardHover(outset: CGFloat = 8, radius: CGFloat = Theme.Radius.lg) -> some View {
    modifier(CardHover(outset: outset, radius: radius))
  }
}

extension EnvironmentValues {
  /// True while the enclosing card grid scrolls; cards then hold their resting look.
  @Entry var cardHoverPaused = false
  /// Set by `cardGrid()` on its scroll view; `cardGridContent()` hands it to the cards.
  @Entry var cardGridHover: CardGridHover? = nil
  /// The tracker cards report to; nil outside a grid's `cardGridContent()`.
  @Entry var cardGridTracker: CardGridHover? = nil
}

extension View {
  /// Apply to the ScrollView of a card grid, together with `cardGridContent()` on the view
  /// inside it that holds the cards.
  ///
  /// - Card hover is tracked once, on the scroll view, instead of by a hover region on every
  ///   card. A hover region inside scrolling content makes SwiftUI hit-test hover again on every
  ///   frame the content moves under a resting pointer, and enter and leave each card it passes;
  ///   at 120 Hz that took about a quarter of the main thread even with the lift paused. The
  ///   scroll view does not move, so its one region is idle while the content scrolls. Cards
  ///   report their frames within the content, which scrolling does not change, and the
  ///   tracker lifts the card under the pointer.
  /// - While it scrolls, no card lifts; the card under the pointer lifts once scrolling ends.
  ///   Scrolling is the scroll view's own phase, or the content moving within the last 0.15 s:
  ///   that holds for every input (trackpad, wheel without gesture phases, momentum, keys,
  ///   code), including ones that report no phase.
  /// - Buttons inside get no focus-effect view unless keyboard navigation is on (System
  ///   Settings › Keyboard). With it off, macOS never moves keyboard focus to a button, so no
  ///   ring could show; yet each button would still add an AppKit view as its cell appears,
  ///   and every added view makes the window redo its titlebar drag region, walking all focus
  ///   responders. With keyboard navigation on, buttons keep the system focus ring.
  func cardGrid() -> some View { modifier(CardGridModifier()) }

  /// Apply to the one view inside a `cardGrid()` scroll view that contains its cards (the grid,
  /// or the stack around several grids). Without it, cards track hover themselves.
  func cardGridContent() -> some View { modifier(CardGridContentModifier()) }
}

private struct CardGridModifier: ViewModifier {
  @State private var hover = CardGridHover()
  @State private var keyboardNavigation = NSApp.isFullKeyboardAccessEnabled
  func body(content: Content) -> some View {
    content
      .environment(\.cardHoverPaused, hover.paused)
      .environment(\.cardGridHover, hover)
      .coordinateSpace(.named(CardGridHover.viewport))
      .onContinuousHover(coordinateSpace: .named(CardGridHover.viewport)) { hover.pointer($0) }
      .focusEffectDisabled(!keyboardNavigation)
      .onScrollPhaseChange { _, phase in hover.scrollPhase(phase.isScrolling) }
      .onDisappear { hover.stop() }
      // The setting is changed in System Settings, so re-read it whenever the app comes back.
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        let enabled = NSApp.isFullKeyboardAccessEnabled
        if keyboardNavigation != enabled { keyboardNavigation = enabled }
      }
  }
}

private struct CardGridContentModifier: ViewModifier {
  @Environment(\.cardGridHover) private var grid
  func body(content: Content) -> some View {
    if let grid {
      // One geometry read per frame for the whole grid: where the content sits in the viewport.
      content
        .coordinateSpace(.named(CardGridHover.content))
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(CardGridHover.viewport)).origin } action: { origin in
          grid.contentMoved(to: origin)
        }
        .environment(\.cardGridTracker, grid)
    } else {
      content
    }
  }
}

/// One card's hover state, owned by the card and set by its grid's tracker.
@MainActor @Observable final class CardHoverState {
  var hovered = false
}

/// The pointer and scroll state of one card grid. Only `paused` is observed (by the grid and
/// its cards); pointer moves and frame reports invalidate no view unless the lifted card
/// changes, and then only the two cards involved.
@MainActor @Observable final class CardGridHover {
  /// The scroll view's bounds (the pointer) and the scrolling content's bounds (the cards).
  nonisolated static let viewport = "cardGridViewport"
  nonisolated static let content = "cardGridContent"
  /// How long the content must hold still before it counts as settled.
  private static let settle = 0.15
  /// Scroll diagnostics with the pointer over the grid stand in for a scroll gesture.
  private(set) var paused = PerformanceOptions.pointerOver
  @ObservationIgnored private var phaseScrolling = false
  @ObservationIgnored private var moving = false
  @ObservationIgnored private var lastMotion = 0.0
  @ObservationIgnored private var origin: CGPoint?
  @ObservationIgnored private var pointer: CGPoint?
  /// Cards by identity. Entries are weak, so a cell the grid discards drops out without an
  /// onDisappear per cell; the latest report wins where frames overlap (items replaced in place).
  private struct Tracked { weak var card: CardHoverState?; var frame: CGRect; var order: Int }
  @ObservationIgnored private var frames: [ObjectIdentifier: Tracked] = [:]
  @ObservationIgnored private var reports = 0
  @ObservationIgnored private weak var lifted: CardHoverState?
  @ObservationIgnored private var resolveScheduled = false

  /// The pointer in the scroll view's bounds.
  func pointer(_ phase: HoverPhase) {
    if PerformanceCounters.enabled { PerformanceCounters.cardHoverEvents += 1 }
    switch phase {
    case .active(let location): pointer = location
    case .ended: pointer = nil
    }
    resolve()
  }

  /// A card's frame in the content, which scrolling leaves alone.
  func report(_ card: CardHoverState, frame: CGRect) {
    reports += 1
    frames[ObjectIdentifier(card)] = Tracked(card: card, frame: frame, order: reports)
    if frames.count > 256 { frames = frames.filter { $0.value.card != nil } }
    // Cards report one after another; decide once they all have.
    if !paused { scheduleResolve() }
  }

  /// Where the content sits in the scroll view. A change means it is scrolling (or laying out
  /// again) under the pointer, whatever drives it: trackpad, wheel, momentum, keys or code.
  func contentMoved(to origin: CGPoint) {
    defer { self.origin = origin }
    guard let previous = self.origin, previous != origin else { return }
    lastMotion = CACurrentMediaTime()
    guard !moving else { return }
    moving = true
    updatePaused()
    awaitSettle(Self.settle)
  }

  func scrollPhase(_ scrolling: Bool) {
    phaseScrolling = scrolling
    updatePaused()
  }

  func stop() {
    phaseScrolling = false; moving = false
    pointer = nil
    updatePaused()
    resolve()
  }

  private func awaitSettle(_ delay: Double) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, self.moving else { return }
      let still = CACurrentMediaTime() - self.lastMotion
      if still >= Self.settle {
        self.moving = false
        self.updatePaused()
      } else {
        self.awaitSettle(Self.settle - still)
      }
    }
  }

  private func updatePaused() {
    let value = PerformanceOptions.pointerOver || phaseScrolling || moving
    guard value != paused else { return }
    // The lifted card settles (or the one under the pointer lifts) with the usual hover motion.
    withAnimation(CardHover.animation) { paused = value }
    resolve()
  }

  private func scheduleResolve() {
    guard !resolveScheduled else { return }
    resolveScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.resolveScheduled = false
      self.resolve()
    }
  }

  private func card(at point: CGPoint) -> CardHoverState? {
    var best: Tracked?
    for entry in frames.values where entry.card != nil && entry.frame.contains(point) {
      if entry.order > best?.order ?? 0 { best = entry }
    }
    return best?.card
  }

  private func resolve() {
    // The pointer in content coordinates.
    let point = pointer.flatMap { pointer in origin.map { CGPoint(x: pointer.x - $0.x, y: pointer.y - $0.y) } }
    var target: CardHoverState?
    if !paused, let point {
      target = card(at: point)
    }
    if PerformanceCounters.enabled {
      PerformanceCounters.pointerOnCard = point.map { card(at: $0) != nil } ?? false
      PerformanceCounters.cardLifted = target != nil
    }
    guard target !== lifted else { return }
    withAnimation(CardHover.animation) {
      lifted?.hovered = false
      target?.hovered = true
    }
    lifted = target
    if PerformanceCounters.enabled, target != nil { PerformanceCounters.cardHoverLifts += 1 }
  }
}

/// Whether a card inside is lifted, for accessories drawn around the card (a remove button)
/// that should follow the card's hover without a hover region of their own.
struct CardHoveredPreference: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct CardHover: ViewModifier {
  static let animation = Animation.easeOut(duration: 0.16)
  let outset: CGFloat
  let radius: CGFloat
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.cardHoverPaused) private var paused
  @Environment(\.cardGridTracker) private var grid
  @State private var state = CardHoverState()
  private var hovering: Bool { state.hovered && !paused }
  func body(content: Content) -> some View {
    // The shadow lives on a background that only exists while hovered, so scrolling grids
    // never pay for an offscreen shadow pass per card.
    tracked(content
      .background {
        if hovering {
          RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card(scheme))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
            .padding(-outset)
            .shadow(color: .black.opacity(scheme == .dark ? 0.42 : 0.12), radius: 14, y: 8)
            .transition(.opacity)
        }
      }
      .offset(y: hovering && !reduceMotion ? -2 : 0))
      .preference(key: CardHoveredPreference.self, value: hovering)
      #if DEBUG
      .modifier(DemoHoverProbe(hovering: Binding(get: { state.hovered }, set: { state.hovered = $0 })))
      #endif
  }

  /// Inside a card grid the card only reports where it is; elsewhere it keeps its own region.
  /// Measured outside the lift's offset, which moves the drawing but not the frame.
  @ViewBuilder private func tracked(_ content: some View) -> some View {
    if let grid {
      content
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CardGridHover.content)) } action: { frame in
          grid.report(state, frame: frame)
        }
    } else {
      content.onHover { value in
        guard state.hovered != value else { return }
        withAnimation(Self.animation) { state.hovered = value }
      }
    }
  }
}

/// A 0.5pt separator line in the shared separator colour.
struct Hairline: View {
  var axis: Axis = .horizontal
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Rectangle().fill(Theme.separator(scheme))
      .frame(width: axis == .vertical ? 0.5 : nil, height: axis == .horizontal ? 0.5 : nil)
  }
}

/// Duration / count overlay on artwork: dark 72% plate, `xs` radius, 11pt semibold tabular digits.
struct MediaBadge: View {
  let text: String
  var systemImage: String?
  var body: some View {
    HStack(spacing: 4) {
      if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
      Text(text).font(Theme.Font.caption2.weight(.semibold).monospacedDigit())
    }.foregroundStyle(.white)
      .padding(.horizontal, 6).frame(height: 18)
      .background(Theme.mediaBadge, in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
  }
}

/// Recommendation reason on artwork: white 18% capsule with a white 28% hairline.
struct RecommendBadge: View {
  let text: String
  var body: some View {
    Text(text).font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
      .padding(.horizontal, 7).frame(height: 18)
      .background(.white.opacity(0.18), in: Capsule())
      .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
  }
}

/// Rating on a poster: solid `highlight` capsule.
struct ScoreBadge: View {
  let score: Double
  var body: some View {
    Text(String(format: "%.1f", score)).font(Theme.Font.caption2.weight(.bold).monospacedDigit())
      .foregroundStyle(Theme.onHighlight).padding(.horizontal, 6).frame(height: 18)
      .background(Theme.highlight, in: Capsule())
      .fixedSize()
  }
}

/// Unread count: `live` capsule, 18pt high.
struct UnreadBadge: View {
  let count: Int
  var body: some View {
    Text(count > 99 ? "99+" : String(count)).font(Theme.Font.caption2.weight(.bold).monospacedDigit())
      .foregroundStyle(Theme.onLive).padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
      .background(Theme.live, in: Capsule())
      .fixedSize()
  }
}

// MARK: - Segmented controls

/// Two to five mutually exclusive options: a capsule glass track, the selected item filled.
struct SegmentedTabs<Value: Hashable>: View {
  let options: [(Value, String)]
  @Binding var selection: Value
  /// Options that did not fit, behind 「⋯」 at the end of the track (`AdaptiveSegmentedTabs`).
  var overflow: [(Value, String)] = []
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var thumb

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.0) { value, title in
        let selected = value == selection
        Button {
          withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { selection = value }
        } label: {
          Text(title).font(Theme.Font.caption).fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? Theme.text(scheme) : Theme.secondaryText(scheme))
            .padding(.horizontal, 14).frame(height: 26)
            .background {
              if selected {
                Capsule().fill(thumbFill)
                  .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.10), radius: 1.5, y: 1)
                  .matchedGeometryEffect(id: "thumb", in: thumb)
              }
            }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
          .demoAnchor("tab.\(title)")
      }
      if !overflow.isEmpty {
        Menu {
          ForEach(overflow, id: \.0) { value, title in
            Button(title) { withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { selection = value } }
          }
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.secondaryText(scheme)).frame(width: 34, height: 26).contentShape(Capsule())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
          .help(overflow.map(\.1).joined(separator: "、")).accessibilityLabel("更多分段").demoAnchor("tab.more")
      }
    }.padding(2).glassEffect(.regular, in: Capsule())
  }

  /// White 16% on the dark track; on the light track a near-opaque white so the thumb still reads.
  private var thumbFill: Color { scheme == .dark ? .white.opacity(0.16) : .white.opacity(0.9) }
}

/// `SegmentedTabs` that never runs out of room: when the whole track is wider than what it is
/// given, the trailing options move behind 「⋯」 at its end, as few as needed. The selected option
/// always stays on the track (it takes the last visible place), so every option, the last one
/// included, stays one click away.
struct AdaptiveSegmentedTabs<Value: Hashable>: View {
  let options: [(Value, String)]
  @Binding var selection: Value
  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(Array(stride(from: options.count, through: 1, by: -1)), id: \.self) { count in
        let split = Self.split(options, visible: count, selection: selection)
        SegmentedTabs(options: split.shown, selection: $selection, overflow: split.folded)
      }
    }
  }
  /// The first `visible` options, with the selection swapped into the last place when it would be folded.
  static func split(_ options: [(Value, String)], visible: Int, selection: Value) -> (shown: [(Value, String)], folded: [(Value, String)]) {
    guard visible < options.count else { return (options, []) }
    var shown = Array(options.prefix(visible))
    if !shown.contains(where: { $0.0 == selection }), let selected = options.first(where: { $0.0 == selection }), !shown.isEmpty {
      shown[shown.count - 1] = selected
    }
    let folded = options.filter { option in !shown.contains { $0.0 == option.0 } }
    return (shown, folded)
  }
}

// MARK: - Text input

/// The one text field look: 32pt, `sm` radius, translucent fill, hairline, accent ring on focus.
struct AppTextFieldStyle: TextFieldStyle {
  var height: CGFloat = Theme.controlHeight
  @Environment(\.colorScheme) private var scheme
  @FocusState private var focused: Bool

  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration.textFieldStyle(.plain).font(Theme.Font.body).focused($focused)
      .padding(.horizontal, 10).frame(height: height)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(Theme.fill(scheme)))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
          .strokeBorder(focused ? Theme.accent : Theme.separator(scheme), lineWidth: focused ? 1 : 0.5)
      )
      .animation(Theme.hoverAnimation, value: focused)
  }
}
