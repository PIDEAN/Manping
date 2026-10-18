import Foundation

extension BiliService {
  public func curatedPlaylist(expectedIdentity: AuthSnapshot) async throws -> [Video] {
    let payload = try await appObject(.curated, fields: [
      "fresh_idx": "1", "ps": "10", "plat": "1", "feed_version": "CLIENT_SELECTED",
      "fresh_type": "0", "web_location": "bilibili-electron",
    ], expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    guard let raw = payload["item"] as? [[String: Any]], !raw.isEmpty else {
      throw BiliError.invalidResponse("精选视频数据为空")
    }
    let videos = try raw.map { item in
      var archive = item
      archive["aid"] = item["id"]
      return try Video.parse(archive)
    }
    var queue = VideoPlaybackQueue()
    try queue.replace(videos)
    return queue.items
  }
}
