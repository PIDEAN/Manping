import Foundation

public enum DanmakuGlyphStyle: String, Sendable, CaseIterable {
  case automatic, outline, shadow
  public func resolved(maximumFPS: Int) -> Self {
    self == .automatic ? (maximumFPS <= 60 ? .outline : .shadow) : self
  }
}

public enum DanmakuMotion {
  /// Keep windowed motion unchanged up to 1280 pt. On low-refresh panels, cap the stage
  /// portion of the crawl at 160 pt per media second (8 s at speed 1); text width still
  /// contributes its own travel. One factor for all scrolling lines preserves lane spacing.
  public static func scrollingDurationScale(stageWidth: Double, maximumFPS: Int) -> Double {
    guard maximumFPS <= 60, stageWidth.isFinite, stageWidth > 1280 else { return 1 }
    return stageWidth / 1280
  }
}
