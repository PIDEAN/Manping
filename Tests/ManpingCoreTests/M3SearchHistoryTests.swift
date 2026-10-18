import BiliProtocol
import Foundation
import GRPCCore
import SwiftProtobuf
import XCTest
@testable import ManpingCore

private final class SearchHistoryStore: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  init(token: AppToken? = AppToken(mid: 123, accessToken: "fixture-search-history", refreshToken: "fixture-refresh", expiresAt: 9_999_999_999)) { self.token = token }
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { lock.withLock { token } }
  func saveToken(_ value: AppToken?) { lock.withLock { token = value } }
  func clear() { saveToken(nil) }
}
private final class SearchHistoryClock: @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 1000
  func now() -> Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
  func advance() { lock.withLock { seconds = 2000 } }
}
private actor SearchHistoryHTTP: AuthTransport {
  var requests: [URLRequest] = []
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let url = request.url!
    let text: String
    switch url.path {
    case "/x/v2/search/trending/ranking": text = #"{"code":0,"data":{"list":[{"position":1,"keyword":"hot","show_name":"Hot title","icon":"https://fixture.invalid/avatar/1"},{"position":2,"keyword":"hot"}]}}"#
    case "/x/v2/search/recommend": text = #"{"code":0,"data":{"list":[{"position":1,"keyword":"recommend","title":"Recommend title"}]}}"#
    case "/api/oauth2/refreshToken": text = #"{"code":0,"data":{"mid":123,"access_token":"fixture-refreshed","refresh_token":"fixture-next","expires_in":3600}}"#
    default: throw URLError(.unsupportedURL)
    }
    return AuthHTTPResponse(body: Data(text.utf8), response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private actor SearchHistoryRPC: BiliRPCTransport {
  struct Call: Sendable { let method: String; let body: Data; let authorization: [String] }
  var calls: [Call] = []
  let pauseMutation: Bool
  let failMutation: Bool
  private var mutationEntered = false
  private var paused: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  init(pauseMutation: Bool = false, failMutation: Bool = false) {
    self.pauseMutation = pauseMutation; self.failMutation = failMutation
  }
  func waitForMutation() async {
    if mutationEntered { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func releaseMutation() { paused?.resume(); paused = nil }
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    calls.append(Call(method: descriptor.fullyQualifiedMethod, body: try request.serializedData(), authorization: Array(metadata[stringValues: "authorization"])))
    let payload: Data
    if request is Bilibili_App_Interfaces_V1_SuggestionResult3Req {
      var reply = Bilibili_App_Interfaces_V1_SuggestionResult3Reply()
      var item = Bilibili_App_Interfaces_V1_ResultItem()
      item.title = "<em>Fixture</em> suggestion"; item.keyword = "fixture"
      reply.list = [item, item]; payload = try reply.serializedData()
    } else if let request = request as? Bilibili_App_Interfaces_V1_CursorReq {
      var reply = Bilibili_App_Interfaces_V1_CursorV2Reply()
      reply.items = [Self.record(request.business)]; reply.cursor.max = 10
      payload = try reply.serializedData()
    } else if request is Bilibili_App_Interfaces_V1_SearchReq {
      var reply = Bilibili_App_Interfaces_V1_SearchReply()
      reply.items = [Self.record("archive")]; reply.page.total = 1
      payload = try reply.serializedData()
    } else if request is Bilibili_App_Interfaces_V1_DeleteReq || request is Bilibili_App_Interfaces_V1_ClearReq {
      mutationEntered = true; observers.forEach { $0.resume() }; observers = []
      if pauseMutation { await withCheckedContinuation { paused = $0 } }
      if failMutation { throw URLError(.badServerResponse) }
      payload = try Bilibili_App_Interfaces_V1_NoReply().serializedData()
    } else { throw BiliRPCError.invalidArgument }
    return try Response(serializedBytes: payload)
  }
  private static func record(_ business: String) -> Bilibili_App_Interfaces_V1_CursorItem {
    var item = Bilibili_App_Interfaces_V1_CursorItem()
    item.kid = 321; item.oid = 789; item.title = "History"; item.business = business; item.viewAt = 1_700_000_000
    if business == "live" { item.cardLive.mid = 123; item.cardLive.name = "Owner" }
    else if business == "article" { item.cardArticle.mid = 123; item.cardArticle.name = "Owner" }
    else { item.cardUgc.cid = 456; item.cardUgc.duration = 90; item.cardUgc.name = "Owner"; item.cardUgc.mid = 123 }
    return item
  }
  func shutdown(grace: Duration) async {}
}

final class M3SearchHistoryTests: XCTestCase, @unchecked Sendable {
  private func auth(http: SearchHistoryHTTP = SearchHistoryHTTP(), store: SearchHistoryStore = SearchHistoryStore(), clock: SearchHistoryClock = SearchHistoryClock()) async throws -> BiliService {
    let service = BiliService(transport: http, credentials: store, now: { clock.now() })
    try await service.restoreCookies(); return service
  }
  func testDiscoveryClosedRoutesPreserveTokenPoliciesAndSchema() async throws {
    let http = SearchHistoryHTTP(); let service = try await auth(http: http)
    let hot = try await service.searchTrending(); let recommend = try await service.searchRecommendations()
    XCTAssertEqual(hot.count, 1); XCTAssertEqual(hot.first?.title, "Hot title")
    XCTAssertEqual(recommend.first?.keyword, "recommend")
    let requests = await http.requests
    func fields(_ request: URLRequest) -> [String: String] {
      Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }
    XCTAssertEqual(requests.map { $0.url!.host! }, ["app.bilibili.com", "app.bilibili.com"])
    XCTAssertEqual(fields(requests[0])["limit"], "30")
    XCTAssertEqual(fields(requests[0])["csrf"], "")
    XCTAssertNil(fields(requests[0])["access_key"])
    XCTAssertEqual(fields(requests[1])["access_key"], "fixture-search-history")
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    XCTAssertNotNil(fields(requests[0])["sign"])
  }
  func testSuggest3AnonymousUsesExactRequestAndDeduplicatesKeyword() async throws {
    let service = try await auth(store: SearchHistoryStore(token: nil))
    let transport = SearchHistoryRPC(); let rpc = LibraryRPCService(auth: service, transport: transport, installationID: "fixture-search")
    let items = try await rpc.suggestions(keyword: "fixture")
    XCTAssertEqual(items, [LibrarySearchSuggestion(title: "Fixture suggestion", keyword: "fixture")])
    let calls = await transport.calls
    XCTAssertEqual(calls.first?.method, "bilibili.app.interface.v1.Search/Suggest3")
    let request = try Bilibili_App_Interfaces_V1_SuggestionResult3Req(serializedBytes: calls[0].body)
    XCTAssertEqual(request.keyword, "fixture"); XCTAssertEqual(request.highlight, 0)
    XCTAssertTrue(calls[0].authorization.isEmpty)
  }
  @MainActor func testHistoryModelUsesLoadedKidAndBusinessForSingleDeleteAndTabClear() async throws {
    let service = try await auth(); let transport = SearchHistoryRPC()
    let rpc = LibraryRPCService(auth: service, transport: transport, installationID: "fixture-history")
    let model = HistoryPageModel(service: service, rpc: rpc)
    await model.load()
    let record = try XCTUnwrap(model.records.first)
    XCTAssertEqual(record.key.kid, 321)
    XCTAssertEqual(record.item.oid, 789)
    // Exact SDK CursorItem adapter uses Kid as the UGC aid; Oid is a separate field.
    if case .video(let video) = record.entry.destination { XCTAssertEqual(video.aid, 321) } else { XCTFail("Video history") }
    model.requestRemove(record); let removed = await model.confirm(); XCTAssertTrue(removed)
    XCTAssertTrue(model.records.isEmpty)
    await model.load(business: .article); model.requestClear()
    let cleared = await model.confirm(); XCTAssertTrue(cleared)
    let calls = await transport.calls
    let deletion = try Bilibili_App_Interfaces_V1_DeleteReq(serializedBytes: calls.first { $0.method.hasSuffix("/Delete") }!.body)
    XCTAssertEqual(deletion.hisInfo.count, 1); XCTAssertEqual(deletion.hisInfo[0].kid, 321); XCTAssertEqual(deletion.hisInfo[0].business, "archive")
    let clear = try Bilibili_App_Interfaces_V1_ClearReq(serializedBytes: calls.first { $0.method.hasSuffix("/Clear") }!.body)
    XCTAssertEqual(clear.business, "article")
    await model.load(business: .live, keyword: "query")
    model.requestClear(); XCTAssertNil(model.confirmation, "Search mode cannot clear a tab")
    let search = try Bilibili_App_Interfaces_V1_SearchReq(serializedBytes: (await transport.calls).last!.body)
    XCTAssertEqual(search.business, "archive"); XCTAssertEqual(search.pn, 1)
    XCTAssertEqual(HistoryDateSection.grouped(model.records).count, 1)
    model.cancelRequests()
  }
  @MainActor func testHistoryIdentityChangeCancelsConfirmationAndLateMutationWithoutDuplicateSend() async throws {
    let service = try await auth(); let transport = SearchHistoryRPC(pauseMutation: true)
    let rpc = LibraryRPCService(auth: service, transport: transport, installationID: "fixture-history")
    let model = HistoryPageModel(service: service, rpc: rpc)
    await model.load(); model.requestRemove(try XCTUnwrap(model.records.first))
    let pending = Task { await model.confirm() }
    await transport.waitForMutation()
    let duplicate = await model.confirm(); XCTAssertFalse(duplicate)
    _ = await service.beginLogin()
    let deadline = Date().addingTimeInterval(2)
    while model.identityVersion == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    await transport.releaseMutation()
    let result = await pending.value; XCTAssertFalse(result)
    XCTAssertGreaterThan(model.identityVersion, 0); XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.confirmation)
    let mutations = (await transport.calls).filter { $0.method.hasSuffix("/Delete") }
    XCTAssertEqual(mutations.count, 1)
    model.cancelRequests()
  }
  @MainActor func testHistoryFailureDoesNotRetryOrRemoveRowsAndExpiryRefreshesBeforeWrite() async throws {
    let service = try await auth(); let transport = SearchHistoryRPC(failMutation: true)
    let rpc = LibraryRPCService(auth: service, transport: transport, installationID: "fixture-history")
    let model = HistoryPageModel(service: service, rpc: rpc)
    await model.load(); model.requestRemove(try XCTUnwrap(model.records.first))
    let failed = await model.confirm(); XCTAssertFalse(failed); XCTAssertEqual(model.records.count, 1)
    let failedCalls = await transport.calls
    XCTAssertEqual(failedCalls.filter { $0.method.hasSuffix("/Delete") }.count, 1)
    model.cancelRequests()
    let clock = SearchHistoryClock(); let http = SearchHistoryHTTP()
    let expiring = AppToken(mid: 123, accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: 1500)
    let refreshedService = try await auth(http: http, store: SearchHistoryStore(token: expiring), clock: clock)
    let refreshedTransport = SearchHistoryRPC()
    let refreshedRPC = LibraryRPCService(auth: refreshedService, transport: refreshedTransport, installationID: "fixture-history")
    let refreshedModel = HistoryPageModel(service: refreshedService, rpc: refreshedRPC)
    await refreshedModel.load(); clock.advance()
    refreshedModel.requestRemove(try XCTUnwrap(refreshedModel.records.first))
    let success = await refreshedModel.confirm(); XCTAssertTrue(success)
    let refreshRequests = await http.requests
    let refreshedCalls = await refreshedTransport.calls
    XCTAssertEqual(refreshRequests.map { $0.url!.path }, ["/api/oauth2/refreshToken"])
    XCTAssertEqual(refreshedCalls.last?.authorization, ["identify_v1 fixture-refreshed"])
    refreshedModel.cancelRequests()
  }
  func testOldHistoryMutationContextRejectedBeforeTransport() async throws {
    let service = try await auth(); let transport = SearchHistoryRPC()
    let rpc = LibraryRPCService(auth: service, transport: transport, installationID: "fixture-history")
    let expected = await service.authSnapshot(); _ = await service.beginLogin()
    do { try await rpc.deleteHistory(HistoryRecordKey(kid: 321, business: .archive), expectedIdentity: expected); XCTFail("Old context") } catch {}
    let calls = await transport.calls
    XCTAssertTrue(calls.isEmpty)
  }
}
