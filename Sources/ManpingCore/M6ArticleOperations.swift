import Foundation

extension BiliService {
  public func setArticleLiked(id: Int64, liked: Bool, expectedIdentity: AuthSnapshot) async throws {
    guard id > 0 else { throw BiliError.invalidResponse("Invalid article identifier") }
    // Exact ArticleOpeartionClient: type 1 likes; type 2 cancels a like.
    _ = try await appREST(.articleLike, fields: ["id": String(id), "type": liked ? "1" : "2"],
      expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
  }
  public func setArticleFavorited(id: Int64, favorited: Bool, expectedIdentity: AuthSnapshot) async throws {
    guard id > 0 else { throw BiliError.invalidResponse("Invalid article identifier") }
    _ = try await appREST(favorited ? .articleFavoriteAdd : .articleFavoriteDelete,
      fields: ["id": String(id)], expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
  }
  public func sendArticleComment(id: Int64, message: String, root: Int64 = 0, parent: Int64 = 0,
    expectedIdentity: AuthSnapshot) async throws {
    try await sendComment(message: message, oid: id, targetType: 12, root: root, parent: parent,
      expectedIdentity: expectedIdentity)
  }
  public func setArticleCommentLiked(id: Int64, replyID: Int64, liked: Bool,
    expectedIdentity: AuthSnapshot) async throws {
    try await setCommentLiked(oid: id, targetType: 12, replyID: replyID, liked: liked,
      expectedIdentity: expectedIdentity)
  }
}
