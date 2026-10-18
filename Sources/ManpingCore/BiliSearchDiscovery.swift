import Foundation

public struct LibrarySearchSuggestion: Identifiable, Sendable, Equatable {
  public var id: String { keyword }
  public let title: String
  public let keyword: String
  public init(title: String, keyword: String) { self.title = title; self.keyword = keyword }
}
public struct SearchDiscoveryItem: Identifiable, Sendable, Equatable {
  public var id: String { keyword }
  public let position: Int
  public let title: String
  public let keyword: String
  public let icon: URL?
  public init(position: Int, title: String, keyword: String, icon: URL? = nil) {
    self.position = position; self.title = title; self.keyword = keyword; self.icon = icon
  }
}
extension BiliService {
  public func searchRecommendations() async throws -> [SearchDiscoveryItem] {
    try Self.discoveryItems(await appObject(.searchRecommend), hot: false)
  }
  public func searchTrending() async throws -> [SearchDiscoveryItem] {
    try Self.discoveryItems(await appObject(.searchTrending, fields: ["limit": "30"]), hot: true)
  }
  private static func discoveryItems(_ payload: [String: Any], hot: Bool) throws -> [SearchDiscoveryItem] {
    guard let list = payload["list"] as? [[String: Any]], list.count <= 500 else {
      throw BiliError.invalidResponse("Invalid search discovery list")
    }
    var known = Set<String>()
    return list.compactMap { item in
      guard let keyword = item["keyword"] as? String, !keyword.isEmpty,
        known.insert(keyword).inserted else { return nil }
      let title = item[hot ? "show_name" : "title"] as? String ?? keyword
      return SearchDiscoveryItem(position: JSONValue.int(item["position"]),
        title: libraryPlain(title), keyword: keyword, icon: JSONValue.url(item["icon"]))
    }
  }
}
