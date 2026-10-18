import Combine
import Foundation
import ManpingCore

/// The user's danmaku shield (comment types, smart-shield level, keywords and `/regex/` rules),
/// kept outside the settings catalog like the display area. It is the one source that the
/// settings window's 屏蔽 section, the player's danmaku panel and every player read. Editors send
/// single changes (`DanmakuFilterEdit`), applied to the latest rules, so one editor never writes
/// back an older copy over what the other just added.
@MainActor final class DanmakuFilterStore: ObservableObject {
  static let shared = DanmakuFilterStore()
  /// UserDefaults key (unchanged from earlier builds).
  static let key = "Manping.danmakuFilter"
  @Published private(set) var filter: DanmakuFilter
  /// Re-filters the open players after a change (set by `AppModel`).
  var onChange: (() -> Void)?

  private init() {
    if let data = PerformanceEnvironment.defaults.data(forKey: Self.key),
      let stored = try? JSONDecoder().decode(DanmakuFilter.self, from: data) {
      var local = stored; local.account = nil
      filter = local
    } else {
      filter = DanmakuFilter()
    }
  }

  func apply(_ edit: DanmakuFilterEdit) {
    var next = filter.applying(edit)
    next.account = nil
    guard next != filter else { return }
    filter = next
    if let data = try? JSONEncoder().encode(next) { PerformanceEnvironment.defaults.set(data, forKey: Self.key) }
    onChange?()
  }
}
