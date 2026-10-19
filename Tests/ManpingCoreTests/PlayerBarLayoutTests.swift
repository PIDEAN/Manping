import Foundation
import XCTest

@testable import ManpingCore

final class PlayerBarLayoutTests: XCTestCase {
  // MARK: Catalog and defaults

  func testCatalogHasThirteenNamedItemsAndTheDefaultBar() {
    XCTAssertEqual(PlayerBarItem.allCases.count, 13)
    XCTAssertEqual(Set(PlayerBarItem.allCases.map(\.title)).count, 13, "names must be unique")
    for item in PlayerBarItem.allCases {
      XCTAssertFalse(item.note.isEmpty, item.rawValue)
      XCTAssertFalse(item.symbol.isEmpty, item.rawValue)
    }
    XCTAssertEqual(PlayerBarLayout.defaultItems, [.quality, .speed, .subtitle, .volume, .mini, .fullscreen])
    XCTAssertEqual(PlayerBarLayout.storageKey, "Manping.playerBarItems")
  }

  // MARK: Encoding

  func testMissingOrMalformedStorageGivesDefaults() {
    XCTAssertEqual(PlayerBarLayout.decode(nil), PlayerBarLayout.defaultItems)
    XCTAssertEqual(PlayerBarLayout.decode("quality,speed"), PlayerBarLayout.defaultItems)
    XCTAssertEqual(PlayerBarLayout.decode([1, 2]), PlayerBarLayout.defaultItems)
  }

  func testDecodingDropsUnknownIDsAndRepeats() {
    let stored: [String] = ["volume", "teleport", "mini", "volume", "fullscreen", ""]
    XCTAssertEqual(PlayerBarLayout.decode(stored), [.volume, .mini, .fullscreen])
    XCTAssertEqual(PlayerBarLayout.decode([String]()), [], "an empty bar is a real choice")
  }

  func testEncodingRoundTripsThroughUserDefaults() throws {
    let name = "Manping.PlayerBarFixture." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let items: [PlayerBarItem] = [.danmakuSettings, .quality, .network, .fullscreen]
    defaults.set(PlayerBarLayout.encode(items), forKey: PlayerBarLayout.storageKey)
    XCTAssertEqual(defaults.stringArray(forKey: PlayerBarLayout.storageKey), ["danmakuSettings", "quality", "network", "fullscreen"])
    XCTAssertEqual(PlayerBarLayout.decode(defaults.object(forKey: PlayerBarLayout.storageKey)), items)
  }

  // MARK: Editing

  private let bar: [PlayerBarItem] = [.quality, .speed, .subtitle, .volume, .mini, .fullscreen]

  func testInsertFromPaletteAddsAtIndex() {
    XCTAssertEqual(PlayerBarLayout.applying(.insert(2), item: .screenshot, to: bar),
      [.quality, .speed, .screenshot, .subtitle, .volume, .mini, .fullscreen])
    XCTAssertEqual(PlayerBarLayout.applying(.insert(99), item: .download, to: bar).last, .download)
    XCTAssertEqual(PlayerBarLayout.applying(.insert(-3), item: .download, to: bar).first, .download)
  }

  func testInsertMovesAnItemAlreadyOnTheBar() {
    // Rightwards: the index counts the item's old slot, so it lands just before 小窗.
    XCTAssertEqual(PlayerBarLayout.applying(.insert(4), item: .quality, to: bar),
      [.speed, .subtitle, .volume, .quality, .mini, .fullscreen])
    // Leftwards.
    XCTAssertEqual(PlayerBarLayout.applying(.insert(0), item: .mini, to: bar),
      [.mini, .quality, .speed, .subtitle, .volume, .fullscreen])
    // To the end.
    XCTAssertEqual(PlayerBarLayout.applying(.insert(6), item: .quality, to: bar),
      [.speed, .subtitle, .volume, .mini, .fullscreen, .quality])
    // Dropping right beside itself changes nothing.
    XCTAssertEqual(PlayerBarLayout.applying(.insert(2), item: .subtitle, to: bar), bar)
    XCTAssertEqual(PlayerBarLayout.applying(.insert(3), item: .subtitle, to: bar), bar)
  }

  func testReplaceFromPaletteTakesThePlace() {
    let result = PlayerBarLayout.applying(.replace(3), item: .screenshot, to: bar)
    XCTAssertEqual(result, [.quality, .speed, .subtitle, .screenshot, .mini, .fullscreen])
    XCTAssertFalse(result.contains(.volume), "the replaced item goes back to the list")
  }

  func testReplaceWithinTheBarSwaps() {
    XCTAssertEqual(PlayerBarLayout.applying(.replace(4), item: .quality, to: bar),
      [.mini, .speed, .subtitle, .volume, .quality, .fullscreen])
    XCTAssertEqual(PlayerBarLayout.applying(.replace(1), item: .speed, to: bar), bar, "dropped on itself")
    XCTAssertEqual(PlayerBarLayout.applying(.replace(9), item: .download, to: bar), bar, "out of range")
  }

  func testRemove() {
    XCTAssertEqual(PlayerBarLayout.applying(.remove, item: .volume, to: bar),
      [.quality, .speed, .subtitle, .mini, .fullscreen])
    XCTAssertEqual(PlayerBarLayout.applying(.remove, item: .download, to: bar), bar)
  }

  func testKeyboardMovesAndAdding() {
    XCTAssertEqual(PlayerBarLayout.moving(.speed, by: -1, in: bar).prefix(2), [.speed, .quality])
    XCTAssertEqual(PlayerBarLayout.moving(.speed, by: 1, in: bar)[1...2], [.subtitle, .speed])
    XCTAssertEqual(PlayerBarLayout.moving(.quality, by: -1, in: bar), bar)
    XCTAssertEqual(PlayerBarLayout.moving(.fullscreen, by: 1, in: bar), bar)
    XCTAssertEqual(PlayerBarLayout.adding(.network, to: bar).last, .network)
    XCTAssertEqual(PlayerBarLayout.adding(.mini, to: bar), bar)
  }

  // MARK: Folding

  private let metrics = PlayerBarLayout.Metrics()
  /// Width the right group needs: each item plus one gap.
  private func need(_ items: [PlayerBarItem]) -> Double { items.reduce(0) { $0 + metrics.width(of: $1) + metrics.gap } }
  /// Fixed part of the row besides the items, with the comment field at `input` (nil: none).
  private func fixed(leading: Double, input: Double?) -> Double {
    leading + (input.map { metrics.gap + $0 } ?? 0) + metrics.gap + metrics.spacerMinimum + metrics.gap + metrics.moreWidth
  }

  func testEverythingFitsInAWideRow() {
    let fit = PlayerBarLayout.fit(bar, rowWidth: 1200, leadingWidth: 230, hasInput: true)
    XCTAssertEqual(fit.visible, bar)
    XCTAssertEqual(fit.hidden, [])
    XCTAssertFalse(fit.compactInput)
    XCTAssertEqual(fit.firstVisible, 0)
  }

  func testExactFitKeepsTheCommentField() {
    let row = fixed(leading: 230, input: metrics.inputWidth) + need(bar)
    let fit = PlayerBarLayout.fit(bar, rowWidth: row, leadingWidth: 230, hasInput: true)
    XCTAssertEqual(fit.hidden, [])
    XCTAssertFalse(fit.compactInput)
  }

  func testCommentFieldShrinksBeforeAnythingFolds() {
    // One point short with the full field, but everything fits beside the 「发弹幕」 button.
    let row = fixed(leading: 230, input: metrics.inputWidth) + need(bar) - 1
    let fit = PlayerBarLayout.fit(bar, rowWidth: row, leadingWidth: 230, hasInput: true)
    XCTAssertTrue(fit.compactInput)
    XCTAssertEqual(fit.hidden, [])
    XCTAssertEqual(fit.visible, bar)
  }

  func testFoldsFromTheLeftmostItemAndKeepsTheRightmostLongest() {
    let leading = 230.0
    // Room for exactly the last three (音量、小窗、全屏) beside the compact button.
    let row = fixed(leading: leading, input: metrics.compactInputWidth) + need([.volume, .mini, .fullscreen]) + 10
    let fit = PlayerBarLayout.fit(bar, rowWidth: row, leadingWidth: leading, hasInput: true)
    XCTAssertTrue(fit.compactInput)
    XCTAssertEqual(fit.hidden, [.quality, .speed, .subtitle])
    XCTAssertEqual(fit.visible, [.volume, .mini, .fullscreen])
    XCTAssertEqual(fit.firstVisible, 3)

    // Narrower and narrower: the count only grows and the hidden ones are always a prefix.
    var previous = 0
    for width in stride(from: row, through: 200, by: -7) {
      let fit = PlayerBarLayout.fit(bar, rowWidth: width, leadingWidth: leading, hasInput: true)
      XCTAssertGreaterThanOrEqual(fit.hidden.count, previous)
      XCTAssertEqual(fit.hidden + fit.visible, bar)
      previous = fit.hidden.count
    }
    XCTAssertEqual(previous, bar.count, "a row with no room folds everything")
  }

  func testHiddenCountForAWideTextItem() {
    // 画质 is wider than an icon: a row that fits five icons cannot fit 画质 in their place.
    let items: [PlayerBarItem] = [.quality, .subtitle, .volume, .mini, .fullscreen]
    let row = fixed(leading: 200, input: nil) + need([.subtitle, .volume, .mini, .fullscreen]) + metrics.width(of: .subtitle) + metrics.gap
    let fit = PlayerBarLayout.fit(items, rowWidth: row, leadingWidth: 200, hasInput: false)
    XCTAssertFalse(fit.compactInput, "no comment field to shrink")
    XCTAssertEqual(fit.hidden, [.quality])
    XCTAssertEqual(fit.hidden.count, 1)
  }

  func testCustomWidthsAndEmptyBar() {
    let empty = PlayerBarLayout.fit([], rowWidth: 600, leadingWidth: 200, hasInput: true)
    XCTAssertEqual(empty.visible, [])
    XCTAssertFalse(empty.compactInput)
    let wide = PlayerBarLayout.fit([.network, .volume], rowWidth: 200 + 6 + 6 + 6 + 32 + 38 + 40, leadingWidth: 200,
      hasInput: false, width: { $0 == .network ? 110 : 32 })
    XCTAssertEqual(wide.hidden, [.network])
  }
}
