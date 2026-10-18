import SwiftUI

private struct ScrollPrefetchMetrics: Equatable {
  let contentHeight: CGFloat
  let visibleBottom: CGFloat
  var isNearEnd: Bool { contentHeight > 0 && contentHeight - visibleBottom <= 800 }
}

/// Matches IncrementVerticalScrollControl's 800-point preload threshold.
private struct ScrollPrefetchModifier: ViewModifier {
  let enabled: Bool
  let load: () -> Void
  @State private var metrics = ScrollPrefetchMetrics(contentHeight: 0, visibleBottom: 0)

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: ScrollPrefetchMetrics.self) { geometry in
        ScrollPrefetchMetrics(
          contentHeight: geometry.contentSize.height, visibleBottom: geometry.visibleRect.maxY)
      } action: { _, value in
        metrics = value
        if enabled && value.isNearEnd { load() }
      }
      .onChange(of: enabled) { _, value in
        if value && metrics.isNearEnd { load() }
      }
  }
}

extension View {
  func prefetchOnScroll(enabled: Bool, load: @escaping () -> Void) -> some View {
    modifier(ScrollPrefetchModifier(enabled: enabled, load: load))
  }
}
