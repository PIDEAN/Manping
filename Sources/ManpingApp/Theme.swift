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
  static let cornerRadius: CGFloat = Radius.md
  static let controlHeight: CGFloat = 32
  static let compactControlHeight: CGFloat = 28
  static let rowHeight: CGFloat = 34
  /// Gap between the window edge and the floating content panel.
  static let panelInset: CGFloat = 8

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

/// Page-level actions: capsule buttons in four roles. Size `.regular` is 32pt, `.small` 28pt.
/// Primary is accent-tinted Liquid Glass, secondary is regular glass, plain has no surface and
/// accent ink, destructive is a danger wash with a danger hairline.
struct AppButtonStyle: ButtonStyle {
  enum Role { case primary, secondary, plain, destructive }
  enum Size { case regular, small }
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

  private var height: CGFloat { size == .regular ? Theme.controlHeight : Theme.compactControlHeight }

  var body: some View {
    configuration.label
      .font(size == .regular ? Theme.Font.body : Theme.Font.caption)
      .fontWeight(role == .primary ? .semibold : nil)
      .lineLimit(1)
      .padding(.horizontal, iconOnly ? 0 : (size == .regular ? 14 : 12))
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

private struct CardHover: ViewModifier {
  let outset: CGFloat
  let radius: CGFloat
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  func body(content: Content) -> some View {
    // The shadow lives on a background that only exists while hovered, so scrolling grids
    // never pay for an offscreen shadow pass per card.
    content
      .background {
        if hovering {
          RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card(scheme))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
            .padding(-outset)
            .shadow(color: .black.opacity(scheme == .dark ? 0.42 : 0.12), radius: 14, y: 8)
            .transition(.opacity)
        }
      }
      .offset(y: hovering && !reduceMotion ? -2 : 0)
      .onHover { value in withAnimation(.easeOut(duration: 0.16)) { hovering = value } }
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
      }
    }.padding(2).glassEffect(.regular, in: Capsule())
  }

  /// White 16% on the dark track; on the light track a near-opaque white so the thumb still reads.
  private var thumbFill: Color { scheme == .dark ? .white.opacity(0.16) : .white.opacity(0.9) }
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
