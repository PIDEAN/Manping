import Foundation

public enum DiagnosticRedactor {
  public static func sanitize(_ text: String) -> String {
    if text.range(
      of: "(?i)(cookie|authorization|sessdata|bili_jct|qrcode_key)", options: .regularExpression)
      != nil
    {
      return "[credential-bearing diagnostic redacted]"
    }
    return text.replacingOccurrences(
      of: "https?://[^\\s\\\"<>]+", with: "[URL redacted]", options: .regularExpression)
  }
}
