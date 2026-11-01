#if DEBUG
import AppKit
import SwiftUI
import XCTest

@testable import ManpingApp

@MainActor private final class BrowsingLayerProbe {
  var appearances = 0
  var disappearances = 0
  var loads = 0
  var tab = "主页"
  var toolbar: String?
  var enabled = true
  var active = true
  var chooseTab: ((String) -> Void)?
  weak var rows: BrowsingLayerRows?
}

@MainActor private final class BrowsingLayerRows: ObservableObject {
  let id = UUID()
  let items = Array(0..<150)
}

private struct StatefulBrowsingPage: View {
  let probe: BrowsingLayerProbe
  @StateObject private var rows = BrowsingLayerRows()
  @State private var tab = "主页"
  @Environment(\.isEnabled) private var enabled
  @Environment(\.browsingPageActive) private var active

  var body: some View {
    ScrollView {
      LazyVStack {
        Text(tab)
        ForEach(rows.items, id: \.self) { Text("Row \($0)").frame(height: 40) }
      }.frame(maxWidth: .infinity)
    }
    .pageToolbar(title: "Browsing \(tab)")
    .task { probe.loads += 1 }
    .onAppear {
      probe.appearances += 1; probe.rows = rows
      probe.chooseTab = { tab = $0 }
    }
    .onDisappear { probe.disappearances += 1; probe.chooseTab = nil }
    .onChange(of: tab, initial: true) { _, value in probe.tab = value }
    .onChange(of: enabled, initial: true) { _, value in probe.enabled = value }
    .onChange(of: active, initial: true) { _, value in probe.active = value }
  }
}

@MainActor private final class BrowsingLayerState: ObservableObject {
  @Published var active = true
  @Published var playbackToolbar = true
  @Published var source = 0
}

private struct BrowsingLayerHarness: View {
  @ObservedObject var state: BrowsingLayerState
  let probe: BrowsingLayerProbe
  var body: some View {
    ZStack {
      BrowsingPageLayer(active: state.active) { StatefulBrowsingPage(probe: probe) }
        .id(state.source)
      if !state.active {
        if state.playbackToolbar { Color.clear.pageToolbar(title: "Playback") }
        else { Color.clear }
      }
    }
    .overlayPreferenceValue(PageToolbarKey.self) { item in
      Color.clear.onChange(of: item?.title, initial: true) { _, title in probe.toolbar = title }
    }
  }
}

@MainActor final class BrowsingPageLayerTests: XCTestCase {
  private func host(_ content: some View, size: CGSize = CGSize(width: 800, height: 600)) -> NSHostingView<some View> {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: content)
    host.frame = CGRect(origin: .zero, size: size)
    return host
  }

  private func settle(_ view: NSView) async throws {
    for _ in 0..<8 {
      view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func scrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
  }

  func testPlaybackCoverRetainsStateObjectTaskTabAndNativeScrollOffset() async throws {
    let state = BrowsingLayerState(), probe = BrowsingLayerProbe()
    let host = host(BrowsingLayerHarness(state: state, probe: probe))
    try await settle(host)
    let scroll = try XCTUnwrap(scrollView(in: host))
    let rows = try XCTUnwrap(probe.rows)
    probe.chooseTab?("投稿")
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 900))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await settle(host)
    let offset = scroll.contentView.bounds.origin
    let viewport = scroll.contentView.bounds.size
    XCTAssertGreaterThan(offset.y, 500)
    XCTAssertEqual(probe.tab, "投稿")
    XCTAssertEqual(probe.loads, 1)
    XCTAssertEqual(probe.toolbar, "Browsing 投稿")

    for _ in 0..<5 {
      state.active = false
      try await settle(host)
      XCTAssertFalse(probe.active)
      XCTAssertFalse(probe.enabled)
      XCTAssertEqual(probe.toolbar, "Playback")
      // Mirrors the sidebar sliding away and the native full-screen window growing.
      host.frame.size = CGSize(width: 1440, height: 1000)
      try await settle(host)
      XCTAssertEqual(scroll.contentView.bounds.size, viewport)
      XCTAssertEqual(scroll.contentView.bounds.origin, offset)
      XCTAssertTrue(probe.rows === rows)
      XCTAssertEqual(probe.appearances, 1)
      XCTAssertEqual(probe.disappearances, 0)
      XCTAssertEqual(probe.loads, 1)
      host.frame.size = CGSize(width: 800, height: 600)
      state.active = true
      try await settle(host)
      XCTAssertTrue(probe.active && probe.enabled)
      XCTAssertEqual(probe.tab, "投稿")
      XCTAssertEqual(probe.toolbar, "Browsing 投稿")
      XCTAssertEqual(scroll.contentView.bounds.origin, offset)
    }
  }

  func testPlaceholderCannotPublishTheHiddenBrowsingToolbar() async throws {
    let state = BrowsingLayerState(), probe = BrowsingLayerProbe()
    let host = host(BrowsingLayerHarness(state: state, probe: probe))
    try await settle(host)
    state.playbackToolbar = false
    state.active = false
    try await settle(host)
    XCTAssertNil(probe.toolbar, "a mini/detached placeholder uses the shell's fallback, not hidden tabs or actions")
    XCTAssertEqual(probe.appearances, 1)
    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.toolbar, "Browsing 主页")
  }

  func testChangingBrowsingDestinationDisposesTheOldPageInsteadOfCachingAStack() async throws {
    let state = BrowsingLayerState(), probe = BrowsingLayerProbe()
    let host = host(BrowsingLayerHarness(state: state, probe: probe))
    try await settle(host)
    weak let previous = probe.rows
    probe.chooseTab?("投稿")
    try await settle(host)
    state.source += 1
    try await settle(host)
    XCTAssertNil(previous)
    XCTAssertEqual(probe.tab, "主页", "non-playback navigation still creates its destination normally")
    XCTAssertEqual(probe.appearances, 2)
    XCTAssertEqual(probe.disappearances, 1)
    XCTAssertEqual(probe.loads, 2)
  }

  func testCoveringACardGridStopsItsHoverTracker() async throws {
    let state = BrowsingLayerState(), probe = BrowsingGridProbe()
    let host = host(BrowsingGridHarness(state: state, probe: probe))
    try await settle(host)
    let grid = try XCTUnwrap(probe.grid)
    let card = CardHoverState()
    grid.contentMoved(to: .zero)
    grid.report(card, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    grid.pointer(.active(CGPoint(x: 10, y: 10)))
    XCTAssertTrue(card.hovered)
    state.active = false
    try await settle(host)
    XCTAssertFalse(card.hovered)
    XCTAssertFalse(grid.paused, "hidden motion must not leave a settling loop running")
    state.active = true
    try await settle(host)
    XCTAssertFalse(card.hovered, "an old pointer location must not lift a card on return")
  }

  func testHiddenFooterAndScrollGeometryCannotAutoLoad() async throws {
    let state = BrowsingLayerState()
    state.active = false
    let loads = BrowseLoadProbe()
    let host = host(BrowsePrefetchHarness(state: state, loads: loads))
    try await settle(host)
    XCTAssertEqual(loads.count, 0)
    loads.enabled = true
    loads.height = 120
    try await settle(host)
    XCTAssertEqual(loads.count, 0, "hidden geometry and enabled changes must not request another page")
    state.active = true
    try await settle(host)
    XCTAssertEqual(loads.count, 1, "returning must re-evaluate prefetch without a geometry or enabled change")
  }

  func testLoadMoreFooterResumesAfterInFlightPageCompletesWhileHidden() async throws {
    let state = BrowsingLayerState(), probe = FooterPaginationProbe()
    let host = host(FooterPaginationHarness(state: state, probe: probe))
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)
    XCTAssertTrue(probe.loading)
    state.active = false
    try await settle(host)
    probe.completePage(hasMore: true)
    try await settle(host)
    XCTAssertEqual(probe.requests, 1, "a button appearing under playback cannot continue paging")
    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 2, "the retained footer re-evaluates on return without another appearance")
    try await settle(host)
    XCTAssertEqual(probe.requests, 2)
    probe.completePage(hasMore: false)
    try await settle(host)
    state.active = false
    try await settle(host)
    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 2, "an exhausted footer cannot restart even if it remains mounted")
  }

  func testLoadMoreFooterReturningBeforeCompletionDoesNotDuplicateTheInFlightPage() async throws {
    let state = BrowsingLayerState(), probe = FooterPaginationProbe()
    let host = host(FooterPaginationHarness(state: state, probe: probe))
    try await settle(host)
    state.active = false
    try await settle(host)
    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)
    probe.completePage(hasMore: true)
    try await settle(host)
    XCTAssertEqual(probe.requests, 2, "normal automatic paging must still continue after a visible completion")
    probe.completePage(hasMore: false)
    try await settle(host)
    XCTAssertEqual(probe.requests, 2)
  }

  func testLoadMoreFooterClaimsTheRequestBeforeTheParentPublishesLoading() async throws {
    let state = BrowsingLayerState(), probe = FooterPaginationProbe()
    probe.acknowledgeLoading = false
    let host = host(FooterPaginationHarness(state: state, probe: probe))
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)
    for _ in 0..<3 {
      state.active = false
      try await settle(host)
      state.active = true
      try await settle(host)
    }
    XCTAssertEqual(probe.requests, 1, "visibility and appearance must share the same pending request claim")
    probe.loading = true; probe.acknowledgeLoading = true
    try await settle(host)
    probe.completePage(hasMore: true)
    try await settle(host)
    XCTAssertEqual(probe.requests, 2)
  }

  func testLoadMoreFooterReturnStillRequiresAutoLoadAndMorePages() async throws {
    for autoLoad in [false, true] {
      let state = BrowsingLayerState(), probe = FooterPaginationProbe()
      state.active = false
      probe.autoLoad = autoLoad; probe.hasMore = !autoLoad
      let host = host(FooterPaginationHarness(state: state, probe: probe))
      try await settle(host)
      XCTAssertEqual(probe.requests, 0)
      state.active = true
      try await settle(host)
      XCTAssertEqual(probe.requests, 0)
    }
  }

  func testMessagePaginationSentinelResumesAfterInFlightPageCompletesWhileHidden() async throws {
    let state = BrowsingLayerState(), probe = BrowsingPaginationProbe()
    let host = host(MessagePaginationHarness(state: state, probe: probe))
    defer { probe.completePage() }
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)
    XCTAssertTrue(probe.loading)
    state.active = false
    try await settle(host)
    probe.completePage()
    try await settle(host)
    XCTAssertEqual(probe.count, 1)
    XCTAssertFalse(probe.loading)
    XCTAssertEqual(probe.requests, 1, "a late response cannot start another hidden sentinel request")
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)

    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 2, "the unchanged sentinel count must be retried when browsing returns")
    probe.completePage()
    try await settle(host)
    XCTAssertEqual(probe.count, 2)
    XCTAssertFalse(probe.hasMore)
    state.active = false
    try await settle(host)
    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 2, "an exhausted list has no sentinel to restart")
  }

  func testMessagePaginationSentinelReturningBeforeCompletionKeepsTheInFlightPage() async throws {
    let state = BrowsingLayerState(), probe = BrowsingPaginationProbe()
    let host = host(MessagePaginationHarness(state: state, probe: probe))
    defer { probe.completePage() }
    try await settle(host)
    state.active = false
    try await settle(host)
    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 1, "returning cannot duplicate a page that is still loading")
    probe.completePage()
    try await settle(host)
    XCTAssertEqual(probe.count, 1, "visibility changes must not cancel the in-flight message request")
    XCTAssertEqual(probe.requests, 2, "the next count-driven sentinel must still load after completion")
    probe.completePage()
    try await settle(host)
    XCTAssertEqual(probe.count, 2)
    XCTAssertEqual(probe.requests, 2)
  }

  func testMessagePaginationSentinelAppearingWhileHiddenWaitsForBrowsingToReturn() async throws {
    let state = BrowsingLayerState(), probe = BrowsingPaginationProbe()
    state.active = false
    probe.hasMore = false
    let host = host(MessagePaginationHarness(state: state, probe: probe))
    defer { probe.completePage() }
    try await settle(host)
    probe.count = 1
    probe.hasMore = true
    try await settle(host)
    probe.count = 2
    try await settle(host)
    XCTAssertEqual(probe.requests, 0, "a newly created or updated hidden sentinel must not load")
    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)
    XCTAssertTrue(probe.loading)
    probe.completePage()
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)
  }

  func testScrollPrefetchResumesAfterInFlightPageCompletesWhileHidden() async throws {
    let state = BrowsingLayerState(), probe = BrowsingPaginationProbe()
    let host = host(ScrollPaginationHarness(state: state, probe: probe))
    defer { probe.completePage() }
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)
    XCTAssertTrue(probe.loading)
    state.active = false
    try await settle(host)
    probe.completePage()
    try await settle(host)
    XCTAssertEqual(probe.count, 1)
    XCTAssertFalse(probe.loading)
    XCTAssertTrue(probe.hasMore)
    XCTAssertEqual(probe.requests, 1, "hidden enabled and geometry changes cannot continue paging")
    try await settle(host)
    XCTAssertEqual(probe.requests, 1)

    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 2, "returning must retry the near-end prefetch suppressed while hidden")
    probe.completePage()
    try await settle(host)
    XCTAssertEqual(probe.count, 2)
    XCTAssertFalse(probe.hasMore)
    XCTAssertEqual(probe.requests, 2)
    state.active = false
    try await settle(host)
    state.active = true
    try await settle(host)
    XCTAssertEqual(probe.requests, 2, "returning cannot prefetch an exhausted list")
  }

  func testScrollPrefetchReturnStillRequiresEnabledAndNearEnd() async throws {
    for (enabled, height) in [(false, CGFloat(100)), (true, CGFloat(4000))] {
      let state = BrowsingLayerState(), loads = BrowseLoadProbe()
      state.active = false
      loads.enabled = enabled; loads.height = height
      let host = host(BrowsePrefetchHarness(state: state, loads: loads))
      try await settle(host)
      state.active = true
      try await settle(host)
      XCTAssertEqual(loads.count, 0, "returning must respect both enabled and the near-end threshold")
    }
  }
}

@MainActor private final class FooterPaginationProbe: ObservableObject {
  @Published var loading = false
  @Published var hasMore = true
  @Published var autoLoad = true
  var acknowledgeLoading = true
  private(set) var requests = 0
  func load() {
    // Count the raw footer callbacks, without a model's own in-flight guard masking duplicates.
    requests += 1
    if acknowledgeLoading { loading = true }
  }
  func completePage(hasMore: Bool) { self.hasMore = hasMore; loading = false }
}

private struct FooterPaginationHarness: View {
  @ObservedObject var state: BrowsingLayerState
  @ObservedObject var probe: FooterPaginationProbe
  var body: some View {
    BrowsingPageLayer(active: state.active) {
      LoadMoreFooter(isLoading: probe.loading, autoLoad: probe.autoLoad, hasMore: probe.hasMore) { probe.load() }
    }
  }
}

@MainActor private final class BrowsingPaginationProbe: ObservableObject {
  @Published var count = 0
  @Published var loading = false
  @Published var hasMore = true
  private(set) var requests = 0
  private var response: CheckedContinuation<Void, Never>?

  func loadNext() async {
    guard !loading, hasMore else { return }
    requests += 1; loading = true
    // Hold a response across visibility changes and honor cancellation like MessagesModel.
    await withCheckedContinuation { response = $0 }
    guard !Task.isCancelled else { loading = false; return }
    count += 1; hasMore = count < 2; loading = false
  }
  func completePage() { response?.resume(); response = nil }
}

private struct MessagePaginationHarness: View {
  @ObservedObject var state: BrowsingLayerState
  @ObservedObject var probe: BrowsingPaginationProbe
  var body: some View {
    BrowsingPageLayer(active: state.active) {
      ScrollView {
        if probe.hasMore {
          M6MessagePaginationSentinel(count: probe.count) { await probe.loadNext() }
        }
      }
    }
  }
}

private struct ScrollPaginationHarness: View {
  @ObservedObject var state: BrowsingLayerState
  @ObservedObject var probe: BrowsingPaginationProbe
  var body: some View {
    BrowsingPageLayer(active: state.active) {
      ScrollView { Color.clear.frame(height: 100 + CGFloat(probe.count) * 10) }
        .prefetchOnScroll(enabled: probe.hasMore && !probe.loading) { Task { await probe.loadNext() } }
    }
  }
}

@MainActor private final class BrowsingGridProbe {
  weak var grid: CardGridHover?
}

private struct BrowsingGridCapture: View {
  let probe: BrowsingGridProbe
  @Environment(\.cardGridHover) private var grid
  var body: some View { Color.clear.onAppear { probe.grid = grid } }
}

private struct BrowsingGridHarness: View {
  @ObservedObject var state: BrowsingLayerState
  let probe: BrowsingGridProbe
  var body: some View {
    BrowsingPageLayer(active: state.active) {
      ScrollView { BrowsingGridCapture(probe: probe).frame(height: 1000) }.cardGrid()
    }
  }
}

@MainActor private final class BrowseLoadProbe: ObservableObject {
  @Published var enabled = false
  @Published var height: CGFloat = 100
  var count = 0
}

private struct BrowsePrefetchHarness: View {
  @ObservedObject var state: BrowsingLayerState
  @ObservedObject var loads: BrowseLoadProbe
  var body: some View {
    BrowsingPageLayer(active: state.active) {
      ScrollView {
        Color.clear.frame(height: loads.height)
        // Prefetch-driven pages use a manual footer, so there is only one automatic trigger.
        LoadMoreFooter(isLoading: false, autoLoad: false) { loads.count += 1 }
      }.prefetchOnScroll(enabled: loads.enabled) { loads.count += 1 }
    }
  }
}
#endif
