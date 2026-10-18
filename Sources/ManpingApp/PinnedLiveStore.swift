import ManpingCore
import Foundation
import SwiftUI

// Public room metadata only. Opening a pin always uses the canonical webpage.
struct PinnedLiveRoom: Codable, Identifiable, Equatable {
  let id: Int64
  let title: String
  let cover: URL?
  var webURL: URL? {
    guard id > 0 else { return nil }
    return URL(string: "https://live.bilibili.com/\(id)")
  }
}

@MainActor final class PinnedLiveStore: ObservableObject {
  static let shared = PinnedLiveStore()
  @Published private(set) var rooms: [PinnedLiveRoom] = []
  private let defaults: UserDefaults
  private let key = "pinnedLiveRooms.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode([PinnedLiveRoom].self, from: data) {
      var known = Set<Int64>()
      rooms = decoded.filter { $0.id > 0 && known.insert($0.id).inserted }.map {
        PinnedLiveRoom(id: $0.id, title: $0.title, cover: Self.publicCover($0.cover))
      }
    }
  }
  func contains(_ roomID: Int64) -> Bool { rooms.contains { $0.id == roomID } }
  func toggle(_ room: LiveRoom) {
    guard room.id > 0 else { return }
    if contains(room.id) { rooms.removeAll { $0.id == room.id } }
    else { rooms.append(PinnedLiveRoom(id: room.id, title: room.title, cover: Self.publicCover(room.cover))) }
    if let data = try? JSONEncoder().encode(rooms) { defaults.set(data, forKey: key) }
  }
  private static func publicCover(_ url: URL?) -> URL? {
    guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
    parts.query = nil; parts.fragment = nil
    return parts.url
  }
}
