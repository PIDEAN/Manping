import AppKit
import CoreImage
import SwiftUI

// The playback stage (DesignSystem.md §11): the video page, the episode page and the live room
// put the picture in one rounded, always-dark container that sits on the window's backdrop 12 pt
// from the window edges, the toolbar and the right panel. Around the picture the stage shows a
// still, blurred and darkened copy of the cover, so letterboxing reads as part of the picture
// instead of a black hole. Full screen drops the radius, the margins and the edge.

// MARK: - Page layout

/// The stage beside the right panel. The stage stays the first child whatever the panel and full
/// screen do, so the player surface inside it is never rebuilt.
struct PlayerPageLayout<Stage: View, Panel: View>: View {
  /// The right panel is on (显示 / 隐藏右侧栏).
  let showsPanel: Bool
  /// Full screen: the stage fills the window, without the panel.
  let immersive: Bool
  @ViewBuilder var stage: Stage
  @ViewBuilder var panel: Panel
  var body: some View {
    GeometryReader { geometry in
      let inset = immersive ? 0 : Theme.stageInset
      HStack(spacing: inset) {
        stage.frame(maxWidth: .infinity, maxHeight: .infinity)
        if showsPanel && !immersive {
          panel.frame(width: min(372, (geometry.size.width - inset * 3) * 0.4))
            .playerSidePanelSurface()
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }.padding(inset)
    }
  }
}

extension View {
  /// The player surface fills the stage, over the stage backdrop made from `cover`. The surface
  /// fits the video to the picture's shape itself (`PlayerSurface.pictureAspect`), while the
  /// danmaku, the gestures and the overlays use the whole stage.
  func playerStageBackdrop(cover: URL?) -> some View {
    modifier(PlayerStageFill(cover: cover))
  }

  /// Sizes a layer that belongs to the picture itself (an offline sample's artwork)
  /// to the picture: as large as fits at `aspect`, centred, as the surface places the video.
  func playerPictureFrame(aspect: CGFloat) -> some View {
    aspectRatio(aspect, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The stage's edge, applied after every overlay so the controls and the 3 pt progress line
  /// are cut by the same rounded corners. Full screen has no radius and no edge.
  func playerStageShape(immersive: Bool) -> some View {
    modifier(PlayerStageShape(immersive: immersive))
  }

  /// The right panel beside the stage: a `panel` surface with the `lg` radius and a hairline edge.
  func playerSidePanelSurface() -> some View {
    modifier(PlayerSidePanelSurface())
  }
}

/// Width / height of a stream, nil when the manifest does not say.
func playerAspect(width: Int?, height: Int?) -> CGFloat? {
  guard let width, let height, width > 0, height > 0 else { return nil }
  return CGFloat(width) / CGFloat(height)
}

/// The picture's width / height on a stage: the stream's, or 16:9 until it is known.
func stagePictureAspect(_ aspect: CGFloat?) -> CGFloat { aspect ?? 16 / 9 }

private struct PlayerStageFill: ViewModifier {
  let cover: URL?
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // A background never takes part in layout: the filled cover cannot grow the stage.
      .background { PlayerStageBackdrop(cover: cover) }
  }
}

private struct PlayerStageShape: ViewModifier {
  let immersive: Bool
  @Environment(\.colorScheme) private var scheme
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: immersive ? 0 : Theme.Radius.lg, style: .continuous)
    content
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(Theme.stageStroke(scheme), lineWidth: 0.5).opacity(immersive ? 0 : 1).allowsHitTesting(false)
      }
  }
}

private struct PlayerSidePanelSurface: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
    content
      .background(Theme.panel(scheme))
      .clipShape(shape)
      .overlay { shape.strokeBorder(Theme.separator(scheme), lineWidth: 0.5).allowsHitTesting(false) }
  }
}

// MARK: - Backdrop

/// The stage around the picture: the cover enlarged, blurred, a little more saturated and darkened
/// to 35%, with a vignette that deepens towards the stage's edge. It is one still image made once
/// per cover (never sampled from the video), and plain `stage` colour without a cover or at the
/// strongest power-saving step (Low Power Mode or serious thermal pressure) with 「进一步省电」 on.
struct PlayerStageBackdrop: View {
  let cover: URL?
  @ObservedObject private var power = PowerState.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var ambient: Ambient?

  private struct Ambient: Equatable {
    let url: URL
    let image: CGImage
    static func == (lhs: Ambient, rhs: Ambient) -> Bool { lhs.url == rhs.url && lhs.image === rhs.image }
  }

  var body: some View {
    Theme.stage
      .overlay {
        if !power.constrained, let ambient, ambient.url == cover {
          Image(decorative: ambient.image, scale: 1).resizable().interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .transition(.opacity)
        }
      }
      .overlay {
        EllipticalGradient(colors: [Theme.stage.opacity(0), Theme.stage.opacity(0.35), Theme.stage.opacity(0.85)],
          center: .center, startRadiusFraction: 0.3, endRadiusFraction: 0.78)
      }
      .clipped()
      .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: ambient)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .task(id: cover) { await load() }
  }

  private func load() async {
    guard let cover else { ambient = nil; return }
    if ambient?.url == cover { return }
    if let cached = StageAmbientRenderer.cached(cover) { ambient = Ambient(url: cover, image: cached); return }
    let source: CGImage?
    if let fixture = StageAmbientRenderer.fixtureSource(cover) {
      source = fixture
    } else {
      source = try? await ImageCache.shared.imageForReader(for: cover)
    }
    guard let source, !Task.isCancelled else { return }
    let rendered = await Task.detached(priority: .utility) { StageAmbientRenderer.render(source) }.value
    guard let rendered, !Task.isCancelled else { return }
    StageAmbientRenderer.store(rendered, for: cover)
    ambient = Ambient(url: cover, image: rendered)
  }
}

/// Makes the backdrop image: a small copy of the cover (128 px wide) blurred by about 60 pt of a
/// typical stage, saturation × 1.25, brightness × 0.35. Scaled up on screen it stays smooth.
enum StageAmbientRenderer {
  private static let width: CGFloat = 128
  /// About 60 pt on a 900 pt stage, at 128 px across.
  private static let sigma: Double = 8.5

  nonisolated static func render(_ image: CGImage) -> CGImage? {
    let input = CIImage(cgImage: image)
    guard input.extent.width >= 1, input.extent.height >= 1 else { return nil }
    let scale = width / input.extent.width
    let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let extent = small.extent.integral
    let dim = 0.35
    let output = small.clampedToExtent()
      .applyingGaussianBlur(sigma: sigma)
      .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25])
      .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: dim, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: dim, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: dim, w: 0),
      ])
      .cropped(to: extent)
    return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: extent)
  }

  // A few recent covers, so going back to a page does not redo the work.
  @MainActor private static var recent: [(url: URL, image: CGImage)] = []
  @MainActor static func cached(_ url: URL) -> CGImage? { recent.first { $0.url == url }?.image }
  @MainActor static func store(_ image: CGImage, for url: URL) {
    recent.removeAll { $0.url == url }
    recent.append((url, image))
    if recent.count > 6 { recent.removeFirst(recent.count - 6) }
  }

  /// Offline samples draw their artwork locally (as `CachedImage` does).
  @MainActor static func fixtureSource(_ url: URL) -> CGImage? {
    guard DebugUIFixtures.enabled, url.host == "fixture.invalid" else { return nil }
    let index = Int(url.lastPathComponent) ?? 0
    if PerformanceOptions.requested, url.pathComponents.contains("cover"), let cover = PerformanceArtwork.cover(index) {
      return cover.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    let renderer = ImageRenderer(content: DebugFixtureImage(index: index).frame(width: 320, height: 180))
    return renderer.cgImage
  }
}

#if DEBUG
/// `--ui-player-placement detached|fullscreen` (screenshot checks): the offline video page moves
/// its picture to the standalone window or full screen once, after it first appears.
@MainActor enum PlayerStageDebug {
  private static var taken = false
  static func takePlacement() -> String? {
    let args = ProcessInfo.processInfo.arguments
    guard !taken, let index = args.firstIndex(of: "--ui-player-placement"), index + 1 < args.count,
      ["detached", "fullscreen"].contains(args[index + 1]) else { return nil }
    taken = true
    return args[index + 1]
  }
}
#endif
