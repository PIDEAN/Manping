import Foundation

// Exact BiliKernel 22fdf8ca ViewLaterClient/MyClient routes. Mutations are
// App-signed, token-bound POSTs; appREST neither attaches cookies nor retries.
extension BiliService {
  public func collectionViewLater(page: Int = 1, expectedIdentity: AuthSnapshot) async throws -> LibraryPage<LibraryEntry> {
    try collectionPage(page)
    let data = try await appObject(.viewLater, fields: ["pn": String(page), "ps": "40"], expectedIdentity: expectedIdentity)
    let raw = try Self.libraryList(data)
    let total = JSONValue.int(data["count"])
    return LibraryPage(items: try raw.map { try Self.collectionVideo($0, addedKey: "add_at") },
      hasMore: page * 40 < total, total: total)
  }

  public func collectionContents(folder: LibraryFolder, page: Int = 1,
    expectedIdentity: AuthSnapshot) async throws -> LibraryPage<LibraryEntry> {
    try collectionPage(page)
    guard folder.id > 0 else { throw BiliError.invalidResponse("Invalid favorite folder identifier") }
    try checkRESTIdentity(expectedIdentity)
    if folder.isSeason {
      let result = try await libraryContents(folder: folder, page: page)
      try checkRESTIdentity(expectedIdentity)
      return result
    }
    let data = try await appObject(.libraryContents, fields: ["media_id": String(folder.id),
      "ps": "20", "pn": String(page)], expectedIdentity: expectedIdentity)
    let raw = try Self.libraryList(data, key: "medias")
    return LibraryPage(items: try raw.filter { JSONValue.int($0["type"]) == 2 }
      .map { try Self.collectionVideo($0, addedKey: "fav_time") },
      hasMore: data["has_more"] as? Bool ?? false,
      total: JSONValue.int((data["info"] as? [String: Any])?["media_count"]))
  }

  public func removeViewLater(aids: [Int64], expectedIdentity: AuthSnapshot) async throws {
    let ids = try collectionIdentifiers(aids)
    _ = try await appREST(.laterDelete, fields: ["aid": ids.map(String.init).joined(separator: ",")],
      expectedIdentity: expectedIdentity)
  }

  public func clearViewLater(expectedIdentity: AuthSnapshot) async throws {
    _ = try await appREST(.laterClear, fields: ["clean_type": "0"], expectedIdentity: expectedIdentity)
  }

  public func removeFavoriteVideos(folderID: Int64, aids: [Int64], expectedIdentity: AuthSnapshot) async throws {
    guard folderID > 0 else { throw BiliError.invalidResponse("Invalid favorite folder identifier") }
    let ids = try collectionIdentifiers(aids)
    _ = try await appREST(.favoriteRemove, fields: ["media_id": String(folderID),
      "resources": ids.map { "\($0):2" }.joined(separator: ",")], expectedIdentity: expectedIdentity)
  }

  public func removeFavoritePGC(seasonID: Int64, expectedIdentity: AuthSnapshot) async throws {
    guard seasonID > 0 else { throw BiliError.invalidResponse("Invalid season identifier") }
    _ = try await appREST(.pgcFavoriteRemove, fields: ["season_id": String(seasonID)],
      expectedIdentity: expectedIdentity)
  }

  // Created folders use list-all. The collected folder endpoint has independent
  // pn/ps pagination, Web WBI signing, cookies, and ForceNoToken in the exact SDK.
  public func collectionFolders(page: Int = 1, expectedIdentity: AuthSnapshot) async throws -> LibraryPage<LibraryFolder> {
    try collectionPage(page)
    try checkRESTIdentity(expectedIdentity)
    guard let mid = expectedIdentity.token?.mid, mid > 0 else { throw AuthFailure.needsLogin }
    let data = try await json("/x/v3/fav/folder/collected/list", params: ["up_mid": String(mid),
      "ps": "20", "pn": String(page)], signed: true)
    try checkRESTIdentity(expectedIdentity)
    let raw = try Self.libraryList(data)
    let total = JSONValue.int(data["count"])
    return LibraryPage(items: try raw.map { try Self.libraryFolder($0, group: "我收藏的") },
      hasMore: data["has_more"] as? Bool ?? (total > 0 ? page * 20 < total : raw.count >= 20), total: total)
  }

  private func collectionIdentifiers(_ values: [Int64]) throws -> [Int64] {
    guard !values.isEmpty, values.allSatisfy({ $0 > 0 }) else {
      throw BiliError.invalidResponse("Invalid collection identifier batch")
    }
    return Array(Set(values)).sorted()
  }
  private func collectionPage(_ page: Int) throws {
    guard (1...1_000_000).contains(page) else { throw BiliError.invalidResponse("Invalid collection page") }
  }
  private static func collectionVideo(_ item: [String: Any], addedKey: String) throws -> LibraryEntry {
    var normalized = item
    if let timestamp = JSONValue.int64(item[addedKey]), timestamp > 0 {
      let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"
      normalized["subtitle"] = formatter.string(from: Date(timeIntervalSince1970: Double(timestamp))) + " 加入"
    }
    return .video(try libraryVideo(normalized))
  }
}
