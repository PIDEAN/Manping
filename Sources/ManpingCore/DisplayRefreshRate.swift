import Foundation

/// CVDisplayLink periods are seconds as a rational, not rounded integer screen rates.
public enum DisplayRefreshRate {
  public static func hertz(periodValue: Int64, timeScale: Int32, fallback: Int) -> Double {
    if periodValue > 0, timeScale > 0 {
      let rate = Double(timeScale) / Double(periodValue)
      if rate.isFinite, (1...1000).contains(rate) { return rate }
    }
    return (1...1000).contains(fallback) ? Double(fallback) : 60
  }
}
