import Foundation

public enum PlaybackNavigationAction: Sendable, Equatable {
  case part(VideoPart)
  case playlistNext
  case playlistPrevious
  case video(Video)
  case none
}

/// Source: VideoConnectorViewModel.Methods.cs FindNextVideo/FindPrevVideo at UI 896a062.
/// Queue actions are returned to its owner, which preserves identity and advances the existing queue.
public enum PlaybackNavigation {
  public static func next(details: VideoDetails, current: Video, playlist: [Video]?, playlistIndex: Int?,
    endWithPlaylist: Bool, autoNextRelated: Bool) -> PlaybackNavigationAction {
    guard details.matches(current) else { return .none }
    if let index = partIndex(details: details, current: current), index + 1 < details.parts.count {
      return .part(details.parts[index + 1])
    }
    if let playlist {
      if !playlist.isEmpty {
        guard let index = validPlaylistIndex(playlist, supplied: playlistIndex, current: current) else { return .none }
        if index + 1 < playlist.count { return .playlistNext }
      }
      if endWithPlaylist { return .none }
    }
    // The original season section selects the group containing this video, not all groups combined.
    if let group = details.collections.first(where: { $0.episodes.contains { sameVideo($0, current) } }),
      let index = group.episodes.firstIndex(where: { sameVideo($0, current) }), index + 1 < group.episodes.count {
      return .video(group.episodes[index + 1])
    }
    if autoNextRelated, let first = details.related.first { return .video(first) }
    return .none
  }

  public static func previous(details: VideoDetails, current: Video, playlist: [Video]?, playlistIndex: Int?,
    endWithPlaylist: Bool, autoNextRelated: Bool) -> PlaybackNavigationAction {
    guard details.matches(current) else { return .none }
    if let index = partIndex(details: details, current: current), index > 0 {
      return .part(details.parts[index - 1])
    }
    if let playlist {
      if !playlist.isEmpty {
        guard let index = validPlaylistIndex(playlist, supplied: playlistIndex, current: current) else { return .none }
        if index > 0 { return .playlistPrevious }
      }
      if endWithPlaylist { return .none }
    }
    if let group = details.collections.first(where: { $0.episodes.contains { sameVideo($0, current) } }),
      let index = group.episodes.firstIndex(where: { sameVideo($0, current) }), index > 0 {
      return .video(group.episodes[index - 1])
    }
    // Recommendations only participate in forward navigation in the source implementation.
    return .none
  }

  private static func partIndex(details: VideoDetails, current: Video) -> Int? {
    guard let cid = current.cid ?? details.video.cid else { return nil }
    return details.parts.firstIndex { $0.cid == cid }
  }
  private static func validPlaylistIndex(_ videos: [Video], supplied: Int?, current: Video) -> Int? {
    if let supplied {
      return videos.indices.contains(supplied) && sameVideo(videos[supplied], current) ? supplied : nil
    }
    return videos.firstIndex { sameVideo($0, current) }
  }
  private static func sameVideo(_ lhs: Video, _ rhs: Video) -> Bool {
    if let aid = lhs.aid, let other = rhs.aid { return aid == other }
    return !lhs.bvid.isEmpty && lhs.bvid == rhs.bvid
  }
}
