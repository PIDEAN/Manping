import Foundation
import ManpingCore

/// Shared by the page and its model checks so search changes one routing context.
@MainActor struct SpacePageSelection {
  var tab = "主页"
  var submitted = ""
  var selectedCollection: SpaceCollection?
  private(set) var searchRevision = UUID()

  init(tab: String = "主页", selectedCollection: SpaceCollection? = nil) {
    self.tab = tab; self.selectedCollection = selectedCollection
  }

  mutating func submit(_ keyword: String, library: LibraryModel) {
    // Invalidate playback and paging before SwiftUI starts the replacement task.
    library.cancel()
    submitted = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    selectedCollection = nil
    tab = "投稿"
    // Repeating the same query must still restart the cancelled library context.
    searchRevision = UUID()
  }

  func contentMode(mid: Int64, order: SpaceArchiveOrder, tid: Int, descending: Bool) -> LibraryModel.Mode {
    if let selectedCollection { return .collection(selectedCollection, descending) }
    if tab == "合集和系列" { return .collections(mid) }
    return .space(tab == "主页" ? SpaceArchiveQuery(mid: mid) :
      SpaceArchiveQuery(mid: mid, order: order, tid: tid, keyword: submitted))
  }
}
