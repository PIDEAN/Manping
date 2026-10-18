import AppKit
import ImageIO
import SwiftUI
import VisionKit

/// Live Text on a paused frame: the frame mpv is showing is analysed with VisionKit, and the
/// system overlay sits exactly over the (aspect-fit) picture, so text can be selected, copied,
/// looked up or translated, and data detectors (links, dates…) work.
@MainActor final class LiveTextController: ObservableObject {
  @Published private(set) var analysis: ImageAnalysis?
  /// Pixel size of the analysed frame, for placing the overlay over the picture.
  @Published private(set) var frameSize: CGSize = .zero
  private var task: Task<Void, Never>?
  private static let analyzer = ImageAnalyzer()

  var isSupported: Bool { ImageAnalyzer.isSupported }

  /// Clears any overlay (playing again, seeking, a new video).
  func clear() {
    task?.cancel(); task = nil
    if analysis != nil { analysis = nil }
  }

  /// Captures the frame on screen and analyses it. After a seek (`from` = the position before
  /// it) it first waits for the new frame to be decoded, so the old picture is never analysed.
  func analyse(_ player: PlayerModel, afterSeekFrom previous: Double? = nil) {
    clear()
    guard isSupported, player.liveTextEnabled else { return }
    task = Task { [weak self, weak player] in
      if let previous {
        let deadline = Date().addingTimeInterval(3)
        while let player, Date() < deadline, !Task.isCancelled,
          abs(player.time - previous) < 0.04 || player.buffering {
          try? await Task.sleep(for: .milliseconds(50))
        }
        // No new frame in time (or still buffering): leave the overlay empty rather than
        // analysing the picture from before the seek.
        guard let player, abs(player.time - previous) >= 0.04, !player.buffering else { return }
      }
      try? await Task.sleep(for: .milliseconds(previous == nil ? 600 : 200))
      guard !Task.isCancelled, let player, player.paused, player.liveTextEnabled else { return }
      let image = await player.captureFrame()
      #if DEBUG
      if let path = ProcessInfo.processInfo.environment["MANPING_LIVETEXT_FRAME"], let image,
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
      }
      #endif
      guard let image, !Task.isCancelled else { return }
      guard let result = try? await Self.analyzer.analyze(image, orientation: .up,
        configuration: ImageAnalyzer.Configuration([.text, .machineReadableCode])),
        !Task.isCancelled, let self, player.paused, player.liveTextEnabled else { return }
      self.frameSize = CGSize(width: image.width, height: image.height)
      self.analysis = result
      #if DEBUG
      FileHandle.standardError.write(Data("live-text frame=\(image.width)x\(image.height) text=\(result.transcript.prefix(80).replacingOccurrences(of: "\n", with: " / "))\n".utf8))
      #endif
    }
  }
}

/// The VisionKit overlay over the player. It covers the whole player but reports the
/// aspect-fit picture rectangle as its contents, so highlights line up with the video.
struct LiveTextOverlay: NSViewRepresentable {
  let analysis: ImageAnalysis
  let frameSize: CGSize

  final class Coordinator: NSObject, ImageAnalysisOverlayViewDelegate {
    var frameSize: CGSize = .zero
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
      let bounds = overlayView.bounds
      guard frameSize.width > 0, frameSize.height > 0, bounds.width > 0, bounds.height > 0 else {
        return CGRect(x: 0, y: 0, width: 1, height: 1)
      }
      // Aspect fit, in unit coordinates of the overlay's bounds.
      let scale = min(bounds.width / frameSize.width, bounds.height / frameSize.height)
      let width = frameSize.width * scale / bounds.width
      let height = frameSize.height * scale / bounds.height
      return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> ImageAnalysisOverlayView {
    let view = ImageAnalysisOverlayView()
    view.delegate = context.coordinator
    view.preferredInteractionTypes = .automatic
    return view
  }
  func updateNSView(_ view: ImageAnalysisOverlayView, context: Context) {
    context.coordinator.frameSize = frameSize
    if view.analysis !== analysis { view.analysis = analysis }
    view.setContentsRectNeedsUpdate()
  }
}

/// Shows the overlay while an analysis of the current paused frame exists.
struct LiveTextLayer: View {
  @ObservedObject var controller: LiveTextController
  var body: some View {
    if let analysis = controller.analysis {
      LiveTextOverlay(analysis: analysis, frameSize: controller.frameSize)
    }
  }
}
