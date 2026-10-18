import Foundation
import XCTest
@testable import ManpingCore

private final class FinalPGCStore: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  private var cookies: [HTTPCookie]
  init(csrf: Bool = true, expired: Bool = false) {
    token = AppToken(mid: 123, accessToken: "fixture-pgc-access", refreshToken: "fixture-pgc-refresh", expiresAt: expired ? 10 : 9_999_999_999)
    cookies = csrf ? [("SESSDATA", "fixture-pgc-cookie"), ("bili_jct", "fixture-pgc-csrf")].map {
      HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: $0.0, .value: $0.1])!
    } : []
  }
  func load() -> [HTTPCookie] { lock.withLock { cookies } }
  func save(_ cookies: [HTTPCookie]) { lock.withLock { self.cookies = cookies } }
  func loadToken() -> AppToken? { lock.withLock { token } }
  func saveToken(_ token: AppToken?) { lock.withLock { self.token = token } }
  func clear() { lock.withLock { token = nil; cookies = [] } }
}
private actor FinalPGCTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  var pause = false
  var mutationCode = 0
  var malformedState = false
  private var pending: [CheckedContinuation<Void, Never>] = []
  func configure(pause: Bool = false, mutationCode: Int = 0, malformedState: Bool = false) {
    self.pause = pause; self.mutationCode = mutationCode; self.malformedState = malformedState
  }
  func release() { pause = false; let waits = pending; pending = []; waits.forEach { $0.resume() } }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let url = request.url!
    if pause { await withCheckedContinuation { pending.append($0) } }
    let data: Data
    if url.path == "/api/oauth2/refreshToken" {
      data = Data(#"{"code":0,"data":{"mid":123,"access_token":"fixture-refreshed","refresh_token":"fixture-next","expires_in":3600}}"#.utf8)
    } else if request.httpMethod == "POST" {
      data = Data("{\"code\":\(mutationCode),\"data\":{}}".utf8)
    } else if url.path == "/x/v3/fav/folder/created/list-all" {
      data = Data(#"{"code":0,"data":{"list":[{"id":2,"title":"Fixture folder","fav_state":1}]}}"#.utf8)
    } else if malformedState && url.path == "/pgc/season/episode/community" {
      data = Data(#"{"code":0,"data":{"like":1,"favorite":1}}"#.utf8)
    } else {
      let fields = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
      guard let sample = M5PGCFixture.response(path: url.path, parameters: fields) else { throw URLError(.unsupportedURL) }
      data = sample
    }
    return AuthHTTPResponse(body: data, response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private func finalPGCFields(_ request: URLRequest) -> [String: String] {
  let component: URLComponents?
  if let body = request.httpBody {
    component = URLComponents(string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20"))
  } else { component = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) }
  return Dictionary((component?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}
final class FinalPGCInteractionTests: XCTestCase, @unchecked Sendable {
  private func make(_ transport: FinalPGCTransport, store: FinalPGCStore = FinalPGCStore()) async throws -> BiliService {
    let service = BiliService(transport: transport, credentials: store, now: { Date(timeIntervalSince1970: 1000) })
    try await service.restoreCookies(); return service
  }
  @MainActor private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
  func testEpisodeStateUsesEPWhileFollowUsesSeasonAndMutationsUseArchive() async throws {
    let transport = FinalPGCTransport(); let service = try await make(transport); let snapshot = await service.authSnapshot()
    let state = try await service.pgcOperationState(episodeID: 111, seasonID: 10, expectedIdentity: snapshot)
    XCTAssertEqual(state, PGCOperationState(liked: true, coined: true, favorited: true, followed: true))
    try await service.setPGCFollowed(seasonID: 10, followed: true, expectedIdentity: snapshot)
    try await service.setPGCFollowed(seasonID: 10, followed: false, expectedIdentity: snapshot)
    try await service.setPGCLiked(aid: 789, liked: true, expectedIdentity: snapshot)
    try await service.coinPGC(aid: 789, count: 2, alsoLike: true, expectedIdentity: snapshot)
    try await service.triplePGC(aid: 789, expectedIdentity: snapshot)
    try await service.updatePGCFavorite(aid: 789, add: [3, 2, 3], remove: [4], expectedIdentity: snapshot)
    let requests = await transport.requests
    XCTAssertEqual(finalPGCFields(requests[0])["ep_id"], "111")
    XCTAssertEqual(finalPGCFields(requests[1])["season_id"], "10")
    XCTAssertEqual(requests.dropFirst(2).map { $0.url!.path }, ["/pgc/app/follow/add", "/pgc/app/follow/del", "/x/v2/view/like", "/x/v2/view/coin/add", "/x/v2/view/like/triple", "/x/v3/fav/resource/batch-deal"])
    XCTAssertEqual(finalPGCFields(requests[2])["season_id"], "10")
    XCTAssertNil(finalPGCFields(requests[2])["aid"])
    XCTAssertEqual(finalPGCFields(requests[4])["aid"], "789")
    XCTAssertEqual(finalPGCFields(requests[4])["like"], "0")
    XCTAssertEqual(finalPGCFields(requests[5])["multiply"], "2")
    XCTAssertEqual(finalPGCFields(requests[5])["select_like"], "1")
    XCTAssertEqual(finalPGCFields(requests[7])["resources"], "789:2")
    XCTAssertEqual(finalPGCFields(requests[7])["add_media_ids"], "2,3")
    XCTAssertEqual(finalPGCFields(requests[7])["del_media_ids"], "4")
    for request in requests.dropFirst(2) {
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(finalPGCFields(request)["csrf"], "fixture-pgc-csrf")
      XCTAssertEqual(finalPGCFields(request)["access_key"], "fixture-pgc-access")
      XCTAssertNotNil(finalPGCFields(request)["sign"])
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"), "PGC preserves fixed App-token protocol, without Web cookies")
    }
  }
  func testTokenOnlyPGCSignerAndRefreshedTokenDoNotAttachCookie() async throws {
    let transport = FinalPGCTransport(); let service = try await make(transport, store: FinalPGCStore(csrf: false, expired: true))
    let snapshot = await service.authSnapshot()
    try await service.setPGCFollowed(seasonID: 10, followed: true, expectedIdentity: snapshot)
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url!.path }, ["/api/oauth2/refreshToken", "/pgc/app/follow/add"])
    XCTAssertEqual(finalPGCFields(requests[1])["access_key"], "fixture-refreshed")
    XCTAssertNil(finalPGCFields(requests[1])["csrf"])
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
  }
  func testStaleIdentityAndInvalidInputsSendNoMutation() async throws {
    let transport = FinalPGCTransport(); let service = try await make(transport); let snapshot = await service.authSnapshot()
    do { try await service.coinPGC(aid: 1, count: 3, alsoLike: false, expectedIdentity: snapshot); XCTFail() } catch {}
    do { try await service.updatePGCFavorite(aid: 1, add: [2], remove: [2], expectedIdentity: snapshot); XCTFail() } catch {}
    try await service.logout()
    do { try await service.setPGCFollowed(seasonID: 10, followed: true, expectedIdentity: snapshot); XCTFail() } catch is CancellationError {}
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }
  func testMalformedStateAndFailedMutationAreNotSuccess() async throws {
    let transport = FinalPGCTransport(); let service = try await make(transport); let snapshot = await service.authSnapshot()
    await transport.configure(mutationCode: -403, malformedState: true)
    do { _ = try await service.pgcOperationState(episodeID: 111, seasonID: 10, expectedIdentity: snapshot); XCTFail() } catch {}
    do { try await service.setPGCLiked(aid: 789, liked: true, expectedIdentity: snapshot); XCTFail() } catch BiliError.api(let code, _) { XCTAssertEqual(code, -403) }
  }
  @MainActor func testFolderSelectionAndLateMutationAreClearedOnAccountSwitch() async throws {
    for code in [0, -403] {
      let transport = FinalPGCTransport(); let store = FinalPGCStore(); let service = try await make(transport, store: store)
      let model = PGCInteractionModel(service: service, stateLoader: { _, _, snapshot in
        if snapshot.token?.mid == 456 { try await Task.sleep(for: .seconds(60)) }
        return PGCOperationState(liked: true, coined: true, favorited: true, followed: true)
      })
      defer { model.shutdown() }
      model.reset(episodeID: 111, seasonID: 10, aid: 789)
      try await wait { model.liked == true }
      let loaded = await model.loadFolders(aid: 789); XCTAssertTrue(loaded)
      XCTAssertEqual(model.selectedFolderIDs, [2])
      await transport.configure(pause: true, mutationCode: code)
      let pending = Task { await model.like(aid: 789) }
      while await transport.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
      store.save([])
      store.saveToken(AppToken(mid: 456, accessToken: "fixture-pgc-B", refreshToken: "fixture-pgc-B-refresh", expiresAt: 9_999_999_999))
      try await service.restoreCookies()
      try await wait { model.identityGeneration > 0 && model.stateLoading }
      XCTAssertNil(model.liked); XCTAssertNil(model.coined); XCTAssertNil(model.followed); XCTAssertNil(model.favorited)
      XCTAssertTrue(model.folders.isEmpty); XCTAssertTrue(model.selectedFolderIDs.isEmpty)
      await transport.release(); await pending.value
      XCTAssertNil(model.liked); XCTAssertNil(model.message)
      let saved = await model.saveFolders(aid: 789); XCTAssertFalse(saved)
      let requests = await transport.requests; XCTAssertEqual(requests.count, 2)
      XCTAssertEqual(finalPGCFields(requests[1])["access_key"], "fixture-pgc-access")
    }
  }
  @MainActor func testEpisodeResetRejectsLateFollowCompletionAndClearsFolderSelection() async throws {
    let transport = FinalPGCTransport(); let service = try await make(transport)
    let model = PGCInteractionModel(service: service, stateLoader: { _, _, _ in PGCOperationState(liked: false, coined: false, favorited: false, followed: false) })
    defer { model.shutdown() }
    model.reset(episodeID: 111, seasonID: 10, aid: 789)
    try await wait { model.followed == false }
    await transport.configure(pause: true)
    let pending = Task { await model.follow(seasonID: 10) }
    while await transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    model.reset(episodeID: 222, seasonID: 20, aid: 999)
    try await wait { model.followed == false && !model.busy }
    await transport.release(); await pending.value
    XCTAssertEqual(model.followed, false); XCTAssertNil(model.message)
    let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(finalPGCFields(requests[0])["season_id"], "10")
  }
  @MainActor func testFollowDoesNotRequireAnArchiveID() async throws {
    let transport = FinalPGCTransport(); let service = try await make(transport)
    let model = PGCInteractionModel(service: service, stateLoader: { _, _, _ in PGCOperationState(liked: false, coined: false, favorited: false, followed: false) })
    defer { model.shutdown() }
    model.reset(episodeID: 111, seasonID: 10, aid: nil)
    try await wait { model.followed == false }
    await model.follow(seasonID: 10)
    XCTAssertEqual(model.followed, true)
    let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(finalPGCFields(requests[0])["season_id"], "10")
  }
}
