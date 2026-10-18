import Foundation

extension BiliService {
  public func pgcDetails(_ selection: PGCSelection, expectedIdentity: AuthSnapshot) async throws -> PGCDetails {
    try await regionAware { try await unroutedPGCDetails(selection, expectedIdentity: expectedIdentity) }
  }
  private func unroutedPGCDetails(_ selection: PGCSelection, expectedIdentity: AuthSnapshot) async throws -> PGCDetails {
    guard selection.valid else { throw BiliError.invalidResponse("Invalid PGC selection") }
    var fields = ["autoplay": "0", "is_show_all_series": "0"]
    if let seasonID = selection.seasonID { fields["season_id"] = String(seasonID) }
    if let episodeID = selection.episodeID { fields["ep_id"] = String(episodeID) }
    let payload = try await appObject(.pgcDetails, fields: fields, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    return try PGCDetails.parse(payload)
  }
  public func pgcPlayback(_ episode: PGCEpisode, quality: Int? = nil, expectedIdentity: AuthSnapshot) async throws -> PlaybackManifest {
    try await regionAware { try await unroutedPGCPlayback(episode, quality: quality, expectedIdentity: expectedIdentity) }
  }
  private func unroutedPGCPlayback(_ episode: PGCEpisode, quality: Int?, expectedIdentity: AuthSnapshot) async throws -> PlaybackManifest {
    guard episode.id > 0, episode.seasonID > 0, episode.seasonType > 0, let cid = episode.cid, cid > 0 else {
      throw BiliError.invalidResponse("该剧集尚未提供可播放的媒体信息。")
    }
    let payload = try await appObject(.pgcPlayback, fields: [
      "fnver": "0", "cid": String(cid), "fourk": "1", "fnval": "4048", "qn": String(quality ?? 64), "oType": "json",
      "module": "bangumi", "season_type": String(episode.seasonType), "ep_id": String(episode.id),
    ], expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    return try PlaybackManifest.parse(payload)
  }
}
