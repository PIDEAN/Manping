import CoreFoundation
import Foundation

/// mm:ss or h:mm:ss, the format the system prompt asks models to cite.
public enum AITimecode {
  /// Times past this are not plausible for any video; model output beyond it is rejected rather
  /// than formatted (a huge finite Double would trap when converted to Int).
  public static let plausibleLimit: Double = 86_400
  /// The ceiling for model-supplied times: a day, or the media length when that is longer.
  public static func ceiling(duration: Double?) -> Double {
    guard let duration, duration.isFinite, duration > 0 else { return plausibleLimit }
    return max(plausibleLimit, duration + 1)
  }
  /// Whole seconds for display, clamped so no finite or infinite input can trap.
  public static func wholeSeconds(_ seconds: Double, rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Int {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int(min(seconds, 1e12).rounded(rule))
  }
  public static func format(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = wholeSeconds(seconds, rule: .down)
    return total >= 3600
      ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
      : String(format: "%02d:%02d", total / 60, total % 60)
  }
  /// Accepts "mm:ss", "h:mm:ss", "m:ss.f" and plain finite numbers of seconds.
  public static func parse(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      // JSON booleans arrive as NSNumber too; only real numbers are times.
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
      let double = number.doubleValue
      return double.isFinite ? double : nil
    }
    guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if let plain = Double(raw) { return plain.isFinite ? plain : nil }
    let pieces = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard (2...3).contains(pieces.count) else { return nil }
    var total = 0.0
    for (index, piece) in pieces.enumerated() {
      guard let value = Double(piece), value.isFinite, value >= 0 else { return nil }
      if index > 0, value >= 60 { return nil }
      total = total * 60 + value
      guard total.isFinite else { return nil }
    }
    return total
  }
}
