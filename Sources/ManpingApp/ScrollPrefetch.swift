import SwiftUI

/// Whether the visible bottom is within the preload threshold, and the content height so a page
/// that grows while the end is still visible re-evaluates. The scroll offset itself is not part
/// of the value: scrolling changes it only when the threshold is crossed, not on every frame.
private struct ScrollPrefetchMetrics: Equatable {
  let contentHeight: CGFloat
  let isNearEnd: Bool
}

/// Matches IncrementVerticalScrollControl's 800-point preload threshold.
private struct ScrollPrefetchModifier: ViewModifier {
  let enabled: Bool
  let load: () -> Void
  @State private var isNearEnd = false

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: ScrollPrefetchMetrics.self) { geometry in
        ScrollPrefetchMetrics(contentHeight: geometry.contentSize.height,
          isNearEnd: geometry.contentSize.height > 0 && geometry.contentSize.height - geometry.visibleRect.maxY <= 800)
      } action: { _, value in
        if isNearEnd != value.isNearEnd { isNearEnd = value.isNearEnd }
        if enabled && value.isNearEnd { load() }
      }
      .onChange(of: enabled) { _, value in
        if value && isNearEnd { load() }
      }
  }
}

extension View {
  func prefetchOnScroll(enabled: Bool, load: @escaping () -> Void) -> some View {
    modifier(ScrollPrefetchModifier(enabled: enabled, load: load))
  }
}
