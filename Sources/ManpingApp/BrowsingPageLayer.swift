import SwiftUI

extension EnvironmentValues {
  /// Retained browsing pages keep their data tasks, but stop viewport-driven work under playback.
  @Entry var browsingPageActive = true
}

/// Keeps the source page mounted without letting playback's sidebar or full-screen layout
/// resize its scroll view and clamp its offset. Only browsing pages belong in this layer.
struct BrowsingPageLayer<Content: View>: View {
  let active: Bool
  @ViewBuilder var content: () -> Content
  @State private var viewport: CGSize?

  var body: some View {
    let active = active
    GeometryReader { geometry in
      let size = active ? geometry.size : viewport ?? geometry.size
      content()
        .frame(width: size.width, height: size.height)
    }
    .onGeometryChange(for: CGSize?.self) { active ? $0.size : nil } action: { size in
      if let size { viewport = size }
    }
    .environment(\.browsingPageActive, active)
    .opacity(active ? 1 : 0)
    .allowsHitTesting(active)
    .disabled(!active)
    .scrollDisabled(!active)
    .accessibilityHidden(!active)
    .transformPreference(PageToolbarKey.self) { if !active { $0 = nil } }
  }
}
