import Foundation

/// 小窗 geometry. The window always shows the video's own aspect ratio; the 1…2.4 range only
/// shapes the box the window must fit in, so a portrait video gets a narrow window inside a
/// square box and an ultra-wide one a shallow window inside a 2.4:1 box.
public enum MiniWindowSizing {
  public static let boxRatios: ClosedRange<Double> = 1...2.4
  public static let fallbackAspect = 16.0 / 9

  /// Width ÷ height to lock the window to; unknown or invalid sizes use 16:9.
  public static func aspect(width: Int, height: Int) -> Double {
    guard width > 0, height > 0 else { return fallbackAspect }
    return Double(width) / Double(height)
  }

  /// The window for a video of `aspect` inside a box `boxWidth` wide and
  /// `boxWidth ÷ clamp(aspect, 1…2.4)` tall, scaled down (keeping the aspect) to fit
  /// `maxWidth` × `maxHeight` when those are smaller.
  public static func size(aspect: Double, boxWidth: Double, maxWidth: Double = .infinity,
    maxHeight: Double = .infinity) -> (width: Double, height: Double) {
    let ratio = aspect.isFinite && aspect > 0 ? aspect : fallbackAspect
    let boxRatio = min(boxRatios.upperBound, max(boxRatios.lowerBound, ratio))
    let boxHeight = boxWidth / boxRatio
    var width = ratio >= boxRatio ? boxWidth : boxHeight * ratio
    var height = width / ratio
    let scale = min(1, maxWidth / width, maxHeight / height)
    if scale.isFinite, scale > 0 { width *= scale; height *= scale }
    return (width.rounded(), height.rounded())
  }

  /// The box width a window of this size stands for (the inverse of `size`), used to keep the
  /// window's size class when the video, and so its aspect ratio, changes.
  public static func boxWidth(width: Double, height: Double) -> Double {
    guard width > 0, height > 0 else { return width }
    let boxRatio = min(boxRatios.upperBound, max(boxRatios.lowerBound, width / height))
    return max(width, height * boxRatio)
  }
}
