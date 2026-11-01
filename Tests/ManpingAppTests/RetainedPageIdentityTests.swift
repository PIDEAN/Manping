#if DEBUG
import AppKit
import GRPCCore
import ManpingCore
import SwiftProtobuf
import SwiftUI
import XCTest

@testable import ManpingApp

private struct RetainedPageCredentials: AuthCredentialStore {
  var token: AppToken? = nil
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { token }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private actor RetainedPageIdentityTransport: AuthTransport {
  private var requests: [URLRequest] = []
  private var paused: Set<String> = []
  private var waiters: [(path: String, occurrence: Int, continuation: CheckedContinuation<Void, Never>)] = []
  func pause(_ path: String) { paused.insert(path) }
  func release() { paused = []; let pending = waiters; waiters = []; pending.forEach { $0.continuation.resume() } }
  func release(_ path: String, occurrence: Int) {
    guard let index = waiters.firstIndex(where: { $0.path == path && $0.occurrence == occurrence }) else {
      XCTFail("No suspended request \(path) #\(occurrence)"); return
    }
    waiters.remove(at: index).continuation.resume()
  }
  func count(_ path: String, page: String? = nil) -> Int {
    requests.filter { request in
      guard request.url?.path == path else { return false }
      guard let page else { return true }
      let fields = fields(request)
      return fields["pn"] == page || fields["page"] == page
    }.count
  }
  private func fields(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
      .map { ($0.name, $0.value ?? "") })
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let url = request.url!, fields = fields(request), version = requests.count
    if paused.contains(url.path) {
      let occurrence = count(url.path)
      await withCheckedContinuation { waiters.append((url.path, occurrence, $0)) }
    }
    let payload: Any
    var envelope = "data"
    switch url.path {
    case "/pgc/app/timeline":
      envelope = "result"
      payload = ["data": [["date_ts": 1_791_302_400, "date": "10-7", "episodes": [
        ["season_id": 10, "title": "Timeline \(version)", "episode_id": 111, "published": 1],
      ]]]]
    case "/pgc/season/index/condition":
      payload = ["order": [["field": "3", "name": "追番数"]]]
    case "/pgc/season/index/result":
      payload = ["list": [["season_id": 10, "title": "Index \(version)", "first_ep": ["ep_id": 111]]], "has_next": 0]
    case "/x/article/categories":
      payload = [["id": 1, "name": "Articles \(version)", "children": [["id": 11, "name": "Child"]]]]
    case "/x/article/recommends/plus", "/x/article/recommends":
      let items: [[String: Any]] = fields["pn"] == "1" ? [["id": 100, "title": "Article \(version)",
        "author": ["mid": 700, "name": "Fixture"], "summary": "Account-scoped fixture"]] : []
      payload = url.path.hasSuffix("/plus") ? ["articles": items] as [String: Any] : items
    case "/read/native":
      let state: [String: Any] = ["readInfo": ["id": 100, "title": "Reader \(version)",
        "author": ["mid": 700, "name": "Fixture"], "content": "<p>Retained reader.</p>"]]
      let data = try JSONSerialization.data(withJSONObject: state)
      let html = "<script>window.__INITIAL_STATE__ = \(String(decoding: data, as: UTF8.self));</script>"
      return AuthHTTPResponse(body: Data(html.utf8),
        response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    case "/x/article/viewinfo": payload = ["stats": ["view": version], "like": 0, "favorite": false]
    default: throw URLError(.unsupportedURL)
    }
    return AuthHTTPResponse(body: try JSONSerialization.data(withJSONObject: ["code": 0, envelope: payload]),
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private actor RetainedHistoryRPCTransport: BiliRPCTransport {
  private(set) var requests = 0
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    requests += 1
    // An empty, exhausted history still has an account boundary and needs identity recovery.
    return Response()
  }
  func shutdown(grace: Duration) async {}
}

@MainActor private final class RetainedPageVisibility: ObservableObject {
  @Published var active = true
}

private struct RetainedIdentityPageHarness: View {
  enum Page { case timeline, animeIndex, cinema, articles, reader, history }
  @ObservedObject var visibility: RetainedPageVisibility
  let app: AppModel
  let page: Page
  var body: some View {
    BrowsingPageLayer(active: visibility.active) {
      switch page {
      case .timeline, .animeIndex: AnimePage(model: app, onOpen: { _ in }, onFavorites: {})
      case .cinema: CinemaPage(model: app, onOpen: { _ in }, onFavorites: {})
      case .articles: ArticleBrowserPage(service: app.service, openArticle: { _ in }, onUser: { _ in })
      case .reader: ArticleReaderPage(service: app.service, id: 100, onUser: { _ in }, onVideo: { _ in })
      case .history: M3HistoryPage(model: app)
      }
    }
  }
}

@MainActor final class RetainedPageIdentityTests: XCTestCase {
  private func service(_ transport: RetainedPageIdentityTransport) -> BiliService {
    BiliService(transport: transport, credentials: RetainedPageCredentials())
  }
  private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for retained-page identity work")
    throw URLError(.timedOut)
  }
  private func settle(_ view: NSView? = nil) async throws {
    for _ in 0..<8 { view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
  }

  func testPGCBrowseTimelineAndEveryIndexReloadOnlyIdentityInvalidatedVisiblePages() async throws {
    for category in [nil] + PGCCategory.allCases.map(Optional.some) {
      let transport = RetainedPageIdentityTransport(), service = service(transport)
      let model = PGCBrowseModel(service: service)
      model.setBrowsingPageActive(true)
      if let category { await model.loadIndex(category) } else { await model.loadTimeline() }
      XCTAssertFalse(model.seasons.isEmpty)
      XCTAssertNil(model.error)
      let path = category == nil ? "/pgc/app/timeline" : "/pgc/season/index/result"
      let initial = await transport.count(path)
      let selectedDay = model.selectedDay
      model.setBrowsingPageActive(false); model.setBrowsingPageActive(true)
      try await settle()
      let ordinary = await transport.count(path)
      XCTAssertEqual(ordinary, initial, "ordinary playback return must not reload")
      XCTAssertEqual(model.selectedDay, selectedDay)

      model.setBrowsingPageActive(false)
      _ = await service.beginLogin()
      try await eventually { model.needsIdentityReload }
      XCTAssertTrue(model.seasons.isEmpty)
      XCTAssertTrue(model.days.isEmpty)
      XCTAssertTrue(model.filters.isEmpty)
      try await settle()
      let hidden = await transport.count(path)
      XCTAssertEqual(hidden, initial, "an invalidated hidden source waits until it is visible")
      model.setBrowsingPageActive(true); model.setBrowsingPageActive(true)
      try await eventually { !model.isLoading && !model.seasons.isEmpty }
      let reloaded = await transport.count(path)
      XCTAssertEqual(reloaded, initial * 2, "visibility callbacks must consume invalidation only once")
      XCTAssertFalse(model.needsIdentityReload)
      XCTAssertNil(model.error)
      model.setBrowsingPageActive(false); model.cancel()
    }
  }

  func testPGCBrowseRejectsLateOldIdentityAndDoesNotCancelAVisibilityReloadWhenCoveredAgain() async throws {
    let transport = RetainedPageIdentityTransport(), service = service(transport)
    let model = PGCBrowseModel(service: service)
    model.setBrowsingPageActive(true)
    await transport.pause("/pgc/season/index/result")
    let pending = Task { await model.loadIndex(.movie) }
    try await eventually { await transport.count("/pgc/season/index/result") == 1 }
    model.setBrowsingPageActive(false)
    _ = await service.beginLogin()
    try await eventually { model.needsIdentityReload }
    await transport.release(); await pending.value
    XCTAssertTrue(model.seasons.isEmpty, "the late old-account response cannot refill the retained page")

    await transport.pause("/pgc/season/index/result")
    model.setBrowsingPageActive(true)
    try await eventually { await transport.count("/pgc/season/index/result") == 2 }
    model.setBrowsingPageActive(false)
    await transport.release()
    try await eventually { !model.isLoading && !model.seasons.isEmpty }
    model.setBrowsingPageActive(true)
    try await settle()
    let calls = await transport.count("/pgc/season/index/result")
    XCTAssertEqual(calls, 2, "covering a reload must not cancel it or require another return refresh")
    XCTAssertNil(model.error)
    model.setBrowsingPageActive(false); model.cancel()
  }

  func testArticleBrowserRetriesInterruptedDirectoryOnReturnAndRejectsLateResponse() async throws {
    let transport = RetainedPageIdentityTransport(), service = service(transport)
    let model = ArticleBrowserModel(service: service)
    defer { model.setBrowsingPageActive(false); model.cancel(); Task { await transport.release() } }
    model.setBrowsingPageActive(true)
    await transport.pause("/x/article/categories")
    let pending = Task { await model.initialize(selection: 1) }
    defer { pending.cancel() }
    try await eventually { await transport.count("/x/article/categories") == 1 }
    XCTAssertTrue(model.directoryLoading)
    model.setBrowsingPageActive(false)
    _ = await service.beginLogin()
    try await eventually { model.needsIdentityReload }
    try await settle()
    let hidden = await transport.count("/x/article/categories")
    XCTAssertEqual(hidden, 1, "an interrupted hidden directory waits until the page returns")
    XCTAssertTrue(model.partitions.isEmpty)
    XCTAssertFalse(model.directoryLoading)

    model.setBrowsingPageActive(true); model.setBrowsingPageActive(true)
    try await eventually { await transport.count("/x/article/categories") == 2 }
    XCTAssertTrue(model.directoryLoading)
    await transport.release("/x/article/categories", occurrence: 2)
    try await eventually { !model.directoryLoading && !model.isLoading && !model.articles.isEmpty }
    XCTAssertEqual(model.partitions.map(\.title), ["Articles 2"])
    XCTAssertEqual(model.selectedParent, 1); XCTAssertEqual(model.selectedCategory, 1)
    XCTAssertEqual(model.sort, .recommended)
    XCTAssertFalse(model.needsIdentityReload)
    XCTAssertNil(model.directoryError); XCTAssertNil(model.error)
    let title = model.articles.first?.title

    await transport.release("/x/article/categories", occurrence: 1)
    await pending.value
    XCTAssertEqual(model.partitions.map(\.title), ["Articles 2"], "the late old directory cannot replace the recovered one")
    XCTAssertEqual(model.articles.first?.title, title)
    model.setBrowsingPageActive(false); model.setBrowsingPageActive(true)
    try await settle()
    let directories = await transport.count("/x/article/categories")
    let feeds = await transport.count("/x/article/recommends")
    let recommendations = await transport.count("/x/article/recommends/plus")
    XCTAssertEqual(directories, 2, "ordinary return and duplicate visibility callbacks must not reinitialize")
    XCTAssertEqual(feeds, 1, "only the recovered selection loads a feed")
    XCTAssertEqual(recommendations, 0, "the interrupted initial section must not fall back to recommendations")
  }

  func testArticleBrowserRetriesDirectoryAcrossRepeatedIdentityChanges() async throws {
    let transport = RetainedPageIdentityTransport(), service = service(transport)
    let model = ArticleBrowserModel(service: service)
    defer { model.setBrowsingPageActive(false); model.cancel(); Task { await transport.release() } }
    model.setBrowsingPageActive(true)
    await transport.pause("/x/article/categories")
    let pending = Task { await model.initialize(selection: 1) }
    defer { pending.cancel() }
    try await eventually { await transport.count("/x/article/categories") == 1 }
    model.setBrowsingPageActive(false)
    _ = await service.beginLogin()
    try await eventually { model.needsIdentityReload }
    model.setBrowsingPageActive(true)
    try await eventually { await transport.count("/x/article/categories") == 2 }

    let previous = await service.authSnapshot()
    try await service.restoreCookies()
    let current = await service.authSnapshot()
    XCTAssertEqual(current.epoch, previous.epoch)
    XCTAssertNotEqual(current.identityRevision, previous.identityRevision)
    try await eventually { await transport.count("/x/article/categories") == 3 }
    await transport.release("/x/article/categories", occurrence: 1)
    await pending.value
    await transport.release("/x/article/categories", occurrence: 2)
    try await settle()
    XCTAssertTrue(model.partitions.isEmpty, "neither invalidated directory can publish while the latest request is pending")
    XCTAssertTrue(model.directoryLoading, "old completions cannot clear the new request's loading state")
    XCTAssertTrue(model.articles.isEmpty)
    let earlyFeeds = await transport.count("/x/article/recommends")
    let earlyRecommendations = await transport.count("/x/article/recommends/plus")
    XCTAssertEqual(earlyFeeds + earlyRecommendations, 0)

    await transport.release("/x/article/categories", occurrence: 3)
    try await eventually { !model.directoryLoading && !model.isLoading && !model.articles.isEmpty }
    XCTAssertEqual(model.partitions.map(\.title), ["Articles 3"])
    XCTAssertEqual(model.selectedParent, 1); XCTAssertEqual(model.selectedCategory, 1)
    XCTAssertFalse(model.needsIdentityReload)
    XCTAssertNil(model.directoryError); XCTAssertNil(model.error)
    let directories = await transport.count("/x/article/categories")
    let feeds = await transport.count("/x/article/recommends")
    XCTAssertEqual(directories, 3)
    XCTAssertEqual(feeds, 1)
  }

  func testArticleBrowserIdentityReloadKeepsTheChosenSectionChildAndSort() async throws {
    let transport = RetainedPageIdentityTransport(), service = service(transport)
    let model = ArticleBrowserModel(service: service)
    model.setBrowsingPageActive(true)
    await model.initialize(selection: 1)
    await model.selectChild(11); await model.selectSort(.reads)
    XCTAssertFalse(model.articles.isEmpty)
    let oldTitle = model.articles.first?.title
    let initial = await transport.count("/x/article/recommends")
    model.setBrowsingPageActive(false)
    _ = await service.beginLogin()
    try await eventually { model.needsIdentityReload }
    XCTAssertTrue(model.articles.isEmpty)
    model.setBrowsingPageActive(true); model.setBrowsingPageActive(true)
    try await eventually { !model.isLoading && !model.articles.isEmpty }
    XCTAssertEqual(model.selectedParent, 1); XCTAssertEqual(model.selectedCategory, 11); XCTAssertEqual(model.sort, .reads)
    XCTAssertNotEqual(model.articles.first?.title, oldTitle)
    XCTAssertNil(model.error)
    model.setBrowsingPageActive(false); model.setBrowsingPageActive(true)
    try await settle()
    let calls = await transport.count("/x/article/recommends")
    let directories = await transport.count("/x/article/categories")
    XCTAssertEqual(calls, initial + 1)
    XCTAssertEqual(directories, 1, "a successfully loaded directory must not reinitialize or reset the chosen child and sort")
    model.setBrowsingPageActive(false); model.cancel()
  }

  func testMountedPGCArticleReaderAndHistoryPagesObserveVisibilityWithoutChangingTheRefreshToken() async throws {
    for page in [RetainedIdentityPageHarness.Page.timeline, .animeIndex, .cinema, .articles, .reader, .history] {
      _ = NSApplication.shared
      let transport = RetainedPageIdentityTransport(), rpc = RetainedHistoryRPCTransport()
      let token = AppToken(mid: 123, accessToken: "retained-fixture-access", refreshToken: "retained-fixture-refresh", expiresAt: 9_999_999_999)
      let service = BiliService(transport: transport, credentials: RetainedPageCredentials(token: token))
      try await service.restoreCookies()
      let app = AppModel(probeService: service, observeIdentity: false)
      app.libraryRPCTransport = rpc
      defer { app.shutdown() }
      let visibility = RetainedPageVisibility()
      let suite = "RetainedPageIdentityTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(page == .animeIndex ? "index" : "timeline", forKey: "pgcAnimeLastSection")
      defaults.set("movie", forKey: "pgcCinemaLastCategory")
      let host = NSHostingView(rootView: RetainedIdentityPageHarness(visibility: visibility, app: app, page: page)
        .defaultAppStorage(defaults))
      host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
      let path: String?
      switch page {
      case .timeline: path = "/pgc/app/timeline"
      case .animeIndex, .cinema: path = "/pgc/season/index/result"
      case .articles: path = "/x/article/recommends/plus"
      case .reader: path = "/read/native"
      case .history: path = nil
      }
      let requestCount: () async -> Int = {
        if let path { return await transport.count(path) }
        return await rpc.requests
      }
      try await settle(host)
      try await eventually { await requestCount() > 0 }
      try await settle(host)
      let initial = await requestCount()
      let refreshToken = app.refreshToken
      visibility.active = false
      try await settle(host)
      visibility.active = true
      try await settle(host)
      let ordinary = await requestCount()
      XCTAssertEqual(ordinary, initial, "\(page): ordinary return keeps the loaded page")

      visibility.active = false
      try await settle(host)
      _ = await service.beginLogin()
      try await settle(host)
      let hidden = await requestCount()
      XCTAssertEqual(hidden, initial, "\(page): invalidated source waits under playback")
      visibility.active = true
      try await settle(host)
      let returned = await requestCount()
      XCTAssertEqual(returned, initial * 2, "\(page): returning reloads identity-invalidated data once")
      XCTAssertEqual(app.refreshToken, refreshToken)

      let beforeRestore = await service.authSnapshot()
      try await service.restoreCookies()
      let restored = await service.authSnapshot()
      XCTAssertEqual(restored.epoch, beforeRestore.epoch)
      XCTAssertNotEqual(restored.identityRevision, beforeRestore.identityRevision)
      try await settle(host)
      let visible = await requestCount()
      XCTAssertEqual(visible, initial * 3, "\(page): a revision-only change also reloads an already visible source")
    }
  }
}
#endif
