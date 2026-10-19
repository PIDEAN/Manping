import Foundation

public struct DiagnosticArguments {
  public enum Failure: Error { case invalid(String) }
  public let values: [String: String]
  public let flags: Set<String>
  public var video: URL? { values["--diagnose"].flatMap { try? Self.mediaURL($0) } }
  public var audio: URL? { values["--audio"].flatMap { try? Self.mediaURL($0) } }
  public var seconds: Double { values["--seconds"].flatMap(Double.init) ?? 12 }
  public var requested: Bool { video != nil || values["--diagnose-bvid"] != nil }
  public init(_ arguments: [String]) throws {
    let valued: Set<String> = [
      "--diagnose", "--diagnose-bvid", "--audio", "--shader", "--preset",
      "--report", "--seconds", "--hwdec-mode", "--headroom-cap", "--codec", "--quality",
      "--sigmoid-upscaling",
    ]
    let toggles: Set<String> = [
      "--verbose", "--pause-probe", "--stall-main", "--stress", "--sdr",
      "--login", "--fixed-viewport", "--danmaku-probe", "--glyph-probe",
      // Production output choice (EDR for HDR sources only) instead of EDR for every source.
      "--edr-hdr-only",
    ]
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var index = 1
    while index < arguments.count {
      let key = arguments[index]
      if valued.contains(key) {
        guard index + 1 < arguments.count, !arguments[index + 1].isEmpty,
          !arguments[index + 1].hasPrefix("--"), values[key] == nil
        else { throw Failure.invalid(key) }
        values[key] = arguments[index + 1]
        index += 2
      } else if toggles.contains(key) {
        flags.insert(key)
        index += 1
      } else {
        throw Failure.invalid("Unknown diagnostic option")
      }
    }
    for key in ["--diagnose", "--audio"] {
      if let value = values[key] { _ = try Self.mediaURL(value) }
    }
    if let value = values["--seconds"] {
      guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
        throw Failure.invalid("--seconds")
      }
    }
    if let mode = values["--hwdec-mode"],
      !["no", "videotoolbox", "videotoolbox-copy"].contains(mode)
    {
      throw Failure.invalid("--hwdec-mode")
    }
    if let value = values["--sigmoid-upscaling"], !["yes", "no"].contains(value) {
      throw Failure.invalid("--sigmoid-upscaling")
    }
    if values["--diagnose"] != nil && values["--diagnose-bvid"] != nil {
      throw Failure.invalid("Conflicting sources")
    }
    if let bvid = values["--diagnose-bvid"],
      bvid.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) == nil
    {
      throw Failure.invalid("--diagnose-bvid")
    }
    self.values = values
    self.flags = flags
  }
  public static func mediaURL(_ value: String) throws -> URL {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw Failure.invalid("Empty media")
    }
    if let scheme = URLComponents(string: value)?.scheme {
      guard let url = URL(string: value), !value.contains("\n"), !value.contains("\r") else {
        throw Failure.invalid("Media URL")
      }
      if scheme.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil,
        url.password == nil
      {
        return url
      }
      if scheme.lowercased() == "file", url.isFileURL, !url.path.isEmpty,
        url.host == nil || url.host == "" || url.host == "localhost"
      {
        return url
      }
      throw Failure.invalid("Media scheme")
    }
    return URL(fileURLWithPath: value)
  }
  public static func viewportPoints(scale: Double) -> (width: Double, height: Double) {
    let scale = scale.isFinite && scale > 0 ? scale : 1
    return (1280 / scale, 720 / scale)
  }
}
