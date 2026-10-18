import Foundation

/// Seek-bar previews: sprite sheets of small frames plus the time of each frame.
public struct VideoShot: Sendable, Equatable {
  public let sheets: [URL]
  public let columns: Int
  public let rows: Int
  public let frameWidth: Int
  public let frameHeight: Int
  /// Media time (seconds) of each frame, in sheet order.
  public let times: [Double]

  public struct Frame: Sendable, Equatable {
    public let sheet: URL
    /// Pixel rectangle inside the sheet, origin top-left.
    public let x: Int, y: Int, width: Int, height: Int
  }

  /// The last frame at or before `time`.
  public func frame(at time: Double) -> Frame? {
    guard time.isFinite, !times.isEmpty, columns > 0, rows > 0 else { return nil }
    var low = 0, high = times.count - 1
    if time <= times[0] { low = 0 } else {
      while low < high {
        let mid = (low + high + 1) / 2
        if times[mid] <= time { low = mid } else { high = mid - 1 }
      }
    }
    let perSheet = columns * rows
    let sheet = low / perSheet
    guard sheets.indices.contains(sheet) else { return nil }
    let slot = low % perSheet
    return Frame(sheet: sheets[sheet], x: slot % columns * frameWidth, y: slot / columns * frameHeight,
      width: frameWidth, height: frameHeight)
  }

  static func parse(_ data: [String: Any]) -> VideoShot? {
    guard let columns = JSONValue.int64(data["img_x_len"]), let rows = JSONValue.int64(data["img_y_len"]),
      let width = JSONValue.int64(data["img_x_size"]), let height = JSONValue.int64(data["img_y_size"]),
      (1...50).contains(columns), (1...50).contains(rows), (16...640).contains(width), (9...480).contains(height),
      let images = data["image"] as? [String], let index = data["index"] as? [Any] else { return nil }
    let sheets = images.prefix(64).compactMap { raw -> URL? in
      let text = raw.hasPrefix("//") ? "https:" + raw : raw.replacingOccurrences(of: "http://", with: "https://")
      guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
        host.hasSuffix(".hdslb.com") || host.hasSuffix(".bilibili.com") || host.hasSuffix(".biliimg.com") else { return nil }
      return url
    }
    var times = index.compactMap { ($0 as? NSNumber)?.doubleValue }.filter { $0.isFinite && $0 >= 0 }
    // The list starts with a placeholder 0 before the first frame's own 0.
    if times.count > 1, times[0] == 0, times[1] == 0 { times.removeFirst() }
    times = Array(times.prefix(sheets.count * Int(columns * rows)))
    guard !sheets.isEmpty, !times.isEmpty, zip(times, times.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
    return VideoShot(sheets: sheets, columns: Int(columns), rows: Int(rows), frameWidth: Int(width),
      frameHeight: Int(height), times: times)
  }
}

extension BiliService {
  /// Seek previews for a video part; nil when the video has none.
  public func videoShot(bvid: String?, aid: Int64?, cid: Int64) async throws -> VideoShot? {
    guard cid > 0 else { return nil }
    var params = ["cid": String(cid), "index": "1"]
    if let bvid, bvid.hasPrefix("BV") { params["bvid"] = bvid }
    else if let aid, aid > 0 { params["aid"] = String(aid) }
    else { return nil }
    return VideoShot.parse(try await json("/x/player/videoshot", params: params))
  }
}
