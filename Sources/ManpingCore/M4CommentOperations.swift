import Foundation

extension BiliService {
  public func setCommentLiked(oid: Int64, targetType: Int32, replyID: Int64, liked: Bool,
    expectedIdentity: AuthSnapshot) async throws {
    try validateM4CommentTarget(oid: oid, type: targetType)
    guard replyID > 0 else { throw BiliError.invalidResponse("Invalid reply identifier") }
    // Exact SDK spells this field `od`; the API contract is `oid`.
    _ = try await appREST(.replyLike, fields: ["oid": String(oid), "type": String(targetType),
      "rpid": String(replyID), "action": liked ? "1" : "0"], expectedIdentity: expectedIdentity)
  }
  public func sendComment(message: String, oid: Int64, targetType: Int32, root: Int64 = 0,
    parent: Int64 = 0, expectedIdentity: AuthSnapshot) async throws {
    try validateM4CommentTarget(oid: oid, type: targetType)
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      message.count <= 1000, root >= 0, parent >= 0, root > 0 || parent == 0 else {
      throw BiliError.invalidResponse("Invalid comment message or reply target")
    }
    _ = try await appREST(.replyAdd, fields: ["message": message, "oid": String(oid),
      "type": String(targetType), "plat": "3", "root": String(root), "parent": String(parent)],
      expectedIdentity: expectedIdentity)
  }
  private func validateM4CommentTarget(oid: Int64, type: Int32) throws {
    guard oid > 0, [1, 11, 12, 14, 17, 33].contains(type) else {
      throw BiliError.invalidResponse("Invalid comment target")
    }
  }
}
