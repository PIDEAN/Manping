import ManpingCore
import Foundation
import SwiftUI

// Only public profile fields are persisted; account credentials never enter this store.
struct PinnedUser: Codable, Identifiable, Equatable {
  let id: Int64
  let name: String
  let avatar: URL?
}

@MainActor final class PinnedUserStore: ObservableObject {
  static let shared = PinnedUserStore()
  @Published private(set) var users: [PinnedUser] = []
  private let defaults: UserDefaults
  private let key = "pinnedUsers.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode([PinnedUser].self, from: data) {
      var known = Set<Int64>()
      users = decoded.filter { $0.id > 0 && known.insert($0.id).inserted }.map {
        PinnedUser(id: $0.id, name: $0.name, avatar: Self.publicAvatar($0.avatar))
      }
    }
  }
  func contains(_ mid: Int64) -> Bool { users.contains { $0.id == mid } }
  func toggle(_ user: LibraryUser) {
    guard user.id > 0 else { return }
    if contains(user.id) { users.removeAll { $0.id == user.id } }
    else { users.append(PinnedUser(id: user.id, name: user.name, avatar: Self.publicAvatar(user.avatar))) }
    if let data = try? JSONEncoder().encode(users) { defaults.set(data, forKey: key) }
  }
  private static func publicAvatar(_ url: URL?) -> URL? {
    guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
    parts.query = nil; parts.fragment = nil
    return parts.url
  }
}
