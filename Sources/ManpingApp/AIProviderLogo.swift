import AppKit
import ManpingCore
import SwiftUI

/// Provider marks from LobeHub's MIT-licensed icon set (see ThirdPartyNotices/LobeHubIcons.md).
/// Mono marks use `currentColor`, which is resolved per appearance so they stay legible.
struct AIProviderLogo: View {
  let provider: AIProvider
  var size: CGFloat = 24
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    if provider == .appleLocal {
      Image(systemName: "apple.logo").font(.system(size: size * (20.0 / 28.0))).frame(width: size, height: size)
        .accessibilityLabel(provider.title)
    } else if let image = AIProviderLogoCache.image(provider, dark: scheme == .dark) {
      Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        .frame(width: size, height: size).accessibilityLabel(provider.title)
    } else {
      Image(systemName: "sparkles").font(.system(size: size * 0.85)).frame(width: size, height: size)
    }
  }
}

@MainActor enum AIProviderLogoCache {
  private static var images: [String: NSImage] = [:]
  static func image(_ provider: AIProvider, dark: Bool) -> NSImage? {
    let key = provider.rawValue + (dark ? ":dark" : ":light")
    if let cached = images[key] { return cached }
    guard let url = Bundle.module.url(forResource: provider.rawValue, withExtension: "svg", subdirectory: "AIProviders"),
      let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let themed = text.replacingOccurrences(of: "currentColor", with: dark ? "#F2F2F2" : "#1A1A1A")
    guard let image = NSImage(data: Data(themed.utf8)) else { return nil }
    images[key] = image
    return image
  }
}
