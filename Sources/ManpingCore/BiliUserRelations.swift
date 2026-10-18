import CoreFoundation
import Foundation

public enum BiliUserRelation: String, Sendable, Equatable {
  case unfollowed, following, mutual, unknown

  public var isFollowing: Bool? {
    switch self {
    case .unfollowed: false
    case .following, .mutual: true
    case .unknown: nil
    }
  }

  // Exact SDK RelationshipAdapter: an unrecognized attribute is not unfollowed.
  static func parse(_ payload: [String: Any]) -> Self {
    let attribute: Int64?
    if let number = payload["attribute"] as? NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.compare(NSNumber(value: number.int64Value)) == .orderedSame else { return .unknown }
      attribute = number.int64Value
    } else if let string = payload["attribute"] as? String { attribute = Int64(string) }
    else { attribute = nil }
    return switch attribute {
    case 0: .unfollowed
    case 2: .following
    case 6: .mutual
    default: .unknown
    }
  }
}

extension BiliService {
  public func libraryRelationship(mid: Int64, expectedIdentity: AuthSnapshot? = nil)
    async throws -> BiliUserRelation {
    guard mid > 0 else { throw BiliError.invalidResponse("Invalid user identifier") }
    let payload = try await appObject(.relationship, fields: ["fid": String(mid)],
      expectedIdentity: expectedIdentity)
    return BiliUserRelation.parse(payload)
  }
}
