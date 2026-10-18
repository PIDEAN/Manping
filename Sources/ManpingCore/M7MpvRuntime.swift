import Foundation

/// Public mpv properties shared by embedded libmpv and JSON IPC.
public enum MpvRuntimePlan {
  public static func properties(_ settings: MacSettings) -> [(String, String)] {
    var result = [
      ("audio-exclusive", settings.bool(.audioExclusive) ? "yes" : "no"),
      ("hr-seek", settings.text(.preciseSeek)),
      ("demuxer-cache-dir", settings.text(.diskCacheDirectory)),
      ("demuxer-cache-unlink-files", "immediate"),
      ("cache-on-disk", settings.bool(.diskCache) ? "yes" : "no"),
    ]
    if !settings.bool(.diskCache) { result.removeAll { $0.0 == "demuxer-cache-dir" } }
    return result
  }
  public static func seek(_ seconds: Double, precise: Bool) -> [String]? {
    guard seconds.isFinite else { return nil }
    return ["seek", String(max(0, seconds)), precise ? "absolute+exact" : "absolute+keyframes"]
  }
  public static func ipcData(command: [String], requestID: Int) throws -> Data {
    guard !command.isEmpty, command.count <= 32, command.allSatisfy({
      $0.utf8.count <= 131_072 && !$0.contains("\0")
    }), requestID >= 0 else { throw BiliError.invalidResponse("Invalid mpv IPC command") }
    var result = try JSONSerialization.data(withJSONObject: ["command": command, "request_id": requestID])
    result.append(10)
    return result
  }
}
