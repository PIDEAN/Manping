import Foundation

public struct PGCOperationState: Sendable, Equatable {
  public let liked: Bool
  public let coined: Bool
  public let favorited: Bool
  public let followed: Bool
  public init(liked: Bool, coined: Bool, favorited: Bool, followed: Bool) {
    self.liked = liked; self.coined = coined; self.favorited = favorited; self.followed = followed
  }
}
extension BiliService {
  public func pgcOperationState(episodeID: Int64, seasonID: Int64, expectedIdentity: AuthSnapshot) async throws -> PGCOperationState {
    guard episodeID > 0, seasonID > 0 else { throw BiliError.invalidResponse("Invalid PGC interaction target") }
    let raw = try await appObject(.pgcOperationState, fields: ["ep_id": String(episodeID)], expectedIdentity: expectedIdentity)
    guard let like = JSONValue.int64(raw["like"]), (0...1).contains(like),
      let favorite = JSONValue.int64(raw["favorite"]), (0...1).contains(favorite),
      let coins = JSONValue.int64(raw["coin_number"]), coins >= 0 else { throw BiliError.invalidResponse("Invalid PGC operation state") }
    let details = try await pgcDetails(PGCSelection(seasonID: seasonID), expectedIdentity: expectedIdentity)
    guard let followed = details.followed else { throw BiliError.invalidResponse("Missing PGC follow state") }
    return PGCOperationState(liked: like == 1, coined: coins > 0, favorited: favorite == 1, followed: followed)
  }
  public func setPGCFollowed(seasonID: Int64, followed: Bool, expectedIdentity: AuthSnapshot) async throws {
    guard seasonID > 0 else { throw BiliError.invalidResponse("Invalid PGC season") }
    _ = try await appREST(followed ? .pgcFollowAdd : .pgcFollowDelete, fields: ["season_id": String(seasonID)], expectedIdentity: expectedIdentity)
  }
  public func setPGCLiked(aid: Int64, liked: Bool, expectedIdentity: AuthSnapshot) async throws {
    guard aid > 0 else { throw BiliError.invalidResponse("Invalid PGC aid") }
    _ = try await appREST(.pgcLike, fields: ["aid": String(aid), "like": liked ? "0" : "1"], expectedIdentity: expectedIdentity)
  }
  public func coinPGC(aid: Int64, count: Int, alsoLike: Bool, expectedIdentity: AuthSnapshot) async throws {
    guard aid > 0, (1...2).contains(count) else { throw BiliError.invalidResponse("Invalid PGC coin selection") }
    var fields = ["aid": String(aid), "multiply": String(count)]
    if alsoLike { fields["select_like"] = "1" }
    _ = try await appREST(.pgcCoin, fields: fields, expectedIdentity: expectedIdentity)
  }
  public func triplePGC(aid: Int64, expectedIdentity: AuthSnapshot) async throws {
    guard aid > 0 else { throw BiliError.invalidResponse("Invalid PGC aid") }
    _ = try await appREST(.pgcTriple, fields: ["aid": String(aid)], expectedIdentity: expectedIdentity)
  }
  public func updatePGCFavorite(aid: Int64, add: [Int64], remove: [Int64], expectedIdentity: AuthSnapshot) async throws {
    guard aid > 0, add.allSatisfy({ $0 > 0 }), remove.allSatisfy({ $0 > 0 }),
      Set(add).isDisjoint(with: Set(remove)), !add.isEmpty || !remove.isEmpty else { throw BiliError.invalidResponse("Invalid PGC favorite selection") }
    var fields = ["resources": "\(aid):2"]
    if !add.isEmpty { fields["add_media_ids"] = Set(add).sorted().map(String.init).joined(separator: ",") }
    if !remove.isEmpty { fields["del_media_ids"] = Set(remove).sorted().map(String.init).joined(separator: ",") }
    _ = try await appREST(.pgcFavorite, fields: fields, expectedIdentity: expectedIdentity)
  }
}
