import Foundation

public enum AnonymousPlaybackTarget: Equatable, Sendable {
  case video(String)
  case live(Int64?)
  public init?(bvid: String?, live: String?) {
    guard (bvid == nil) != (live == nil) else { return nil }
    if let bvid {
      guard bvid.range(of: #"^BV[A-Za-z0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
      self = .video(bvid)
    } else if let live {
      if live == "auto" { self = .live(nil); return }
      guard !live.isEmpty, live.utf8.allSatisfy({ (48...57).contains($0) }),
        let id = Int64(live), id > 0 else { return nil }
      self = .live(id)
    } else { return nil }
  }
}
