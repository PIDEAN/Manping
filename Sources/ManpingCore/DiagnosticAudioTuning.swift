import Foundation

/// Explicit performance-only overrides. Production output/device negotiation stays unchanged.
public struct DiagnosticAudioTuning: Equatable, Sendable {
  public enum Driver: String, Sendable { case `default`, coreaudio, avfoundation }
  public enum Failure: Error { case arguments }
  public let driver: Driver
  public let audioBufferSeconds: Double?
  public let pauseWaitSeconds: Double?
  public init(arguments: [String]) throws {
    let names = ["--perf-audio-driver", "--perf-audio-buffer", "--perf-cache-pause-wait"]
    func value(_ name: String) throws -> String? {
      let indices = arguments.indices.filter { arguments[$0] == name }
      guard indices.count <= 1 else { throw Failure.arguments }
      guard let index = indices.first else { return nil }
      guard arguments.contains("--perf-fixture"), arguments.indices.contains(index + 1),
        !arguments[index + 1].hasPrefix("--"), !arguments.contains("--perf-scroll") else { throw Failure.arguments }
      return arguments[index + 1]
    }
    let rawDriver = try value(names[0]) ?? "default"
    guard let driver = Driver(rawValue: rawDriver) else { throw Failure.arguments }
    self.driver = driver
    func number(_ name: String, range: ClosedRange<Double>) throws -> Double? {
      guard let raw = try value(name) else { return nil }
      guard let number = Double(raw), number.isFinite, range.contains(number) else { throw Failure.arguments }
      return number
    }
    audioBufferSeconds = try number(names[1], range: 0.1...2)
    pauseWaitSeconds = try number(names[2], range: 0.1...5)
  }
  public static func outputCategory(_ raw: String) -> String {
    ["coreaudio", "avfoundation", "null"].contains(raw) ? raw : raw.isEmpty ? "unavailable" : "other"
  }
}
