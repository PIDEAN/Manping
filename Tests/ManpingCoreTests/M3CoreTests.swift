#if DEBUG
import BiliProtocol
import Foundation
import GRPCCore
import SwiftProtobuf
import XCTest
@testable import ManpingCore

private final class M3Store: AuthCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: AppToken?
  init(authenticated: Bool) {
    token = authenticated ? AppToken(mid: 123, accessToken: "fixture-m3", refreshToken: "fixture-refresh",
                                    expiresAt: 9_999_999_999) : nil
  }
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { lock.withLock { token } }
  func saveToken(_ value: AppToken?) { lock.withLock { token = value } }
  func clear() { saveToken(nil) }
}
private actor M3Transport: AuthTransport {
  var requests: [URLRequest] = []
  var rejection: Data?
  init(rejection: Data? = nil) { self.rejection = rejection }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    let url = request.url!
    let parameters = Dictionary(uniqueKeysWithValues:
      (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    let body: Data
    if url.path == "/x/web-interface/nav" {
      body = Data(#"{"code":0,"data":{"wbi_img":{"img_url":"https://i.example/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i.example/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#.utf8)
    } else if let rejection { body = rejection }
    else if let fixture = M3Fixture.response(path: url.path, parameters: parameters) { body = fixture }
    else { throw URLError(.badServerResponse) }
    return AuthHTTPResponse(body: body,
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
private actor M3RecordingRPC: BiliRPCTransport {
  let fixture = M3FixtureRPCTransport()
  var methods: [String] = []
  var requests: [Data] = []
  var authorized: [Bool] = []
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    methods.append(descriptor.fullyQualifiedMethod)
    requests.append(try request.serializedData())
    authorized.append(metadata[stringValues: "authorization"].contains { $0.contains("fixture-m3") })
    return try await fixture.unary(request, response: response, descriptor: descriptor, metadata: metadata)
  }
  func shutdown(grace: Duration) async {}
}
private func m3Service(_ transport: M3Transport, authenticated: Bool = true) async throws -> BiliService {
  let service = BiliService(transport: transport, credentials: M3Store(authenticated: authenticated),
                            now: { Date(timeIntervalSince1970: 1000) })
  try await service.restoreCookies()
  return service
}
private func m3Fields(_ request: URLRequest) -> [String: String] {
  Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    .map { ($0.name, $0.value ?? "") })
}

final class M3CoreTests: XCTestCase, @unchecked Sendable {
  func testSearchTypesOrdersAndPagingUseWBI() async throws {
    let transport = M3Transport(); let service = try await m3Service(transport, authenticated: false)
    for type in LibrarySearchType.allCases {
      let page = try await service.librarySearch("test & 中文", type: type, order: .newest)
      XCTAssertEqual(page.items.count, 1); XCTAssertTrue(page.hasMore)
      XCTAssertEqual(page.total, 1)
      let second = try await service.librarySearch("test", type: type, page: 2)
      XCTAssertFalse(second.hasMore)
    }
    let requests = await transport.requests
    let fields = m3Fields(requests[1])
    XCTAssertEqual(fields["keyword"], "test & 中文")
    XCTAssertEqual(fields["order"], "pubdate"); XCTAssertNotNil(fields["w_rid"])
    XCTAssertNil(fields["access_key"])
    let sortParameters = LibrarySearchOrder.allCases.map(\.rawValue)
    XCTAssertEqual(sortParameters, ["totalrank", "click", "dm", "pubdate"])
  }
  func testProfileDoesNotAttachAppToken() async throws {
    let transport = M3Transport(); let service = try await m3Service(transport)
    let user = try await service.libraryProfile(mid: 123)
    XCTAssertEqual(user.id, 123); XCTAssertEqual(user.videos, 8)
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.path, "/x/web-interface/card")
    XCTAssertNil(m3Fields(request)["access_key"])
  }
  func testFollowingGroupsAndFollowersUseExactSignedRoutes() async throws {
    let transport = M3Transport(); let service = try await m3Service(transport)
    let groups = try await service.libraryFollowGroups()
    let following = try await service.libraryFollowing(group: 0, page: 2)
    XCTAssertEqual(groups.first?.id, 0)
    XCTAssertEqual(following.items.first?.id, 123)
    let fans = try await service.libraryFollowers(mid: 456, page: 2)
    XCTAssertFalse(fans.hasMore)
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url!.path }, ["/x/relation/tags", "/x/relation/tag", "/x/relation/followers"])
    XCTAssertEqual(m3Fields(requests[1])["mid"], "123")
    XCTAssertEqual(m3Fields(requests[1])["tagid"], "0")
    XCTAssertEqual(m3Fields(requests[2])["vmid"], "456")
    for request in requests {
      XCTAssertEqual(m3Fields(request)["access_key"], "fixture-m3")
      XCTAssertNotNil(m3Fields(request)["sign"]); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
  }
  func testFavoriteIndexAndContentsIncludeUGCCollections() async throws {
    let transport = M3Transport(); let service = try await m3Service(transport)
    let folders = try await service.libraryFolders()
    XCTAssertEqual(folders.map(\.id), [11, 22]); XCTAssertTrue(folders[1].isSeason)
    let video = try await service.libraryContents(folder: folders[0])
    XCTAssertEqual(video.items.first?.id, "av789"); XCTAssertFalse(video.hasMore)
    let season = try await service.libraryContents(folder: folders[1])
    XCTAssertEqual(season.items.first?.id, "av789"); XCTAssertFalse(season.hasMore)
    let requests = await transport.requests
    XCTAssertEqual(m3Fields(requests[0])["up_mid"], "123")
    XCTAssertEqual(m3Fields(requests[1])["type"], "2")
    let collected = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("collected/list") == true })
    XCTAssertNotNil(m3Fields(collected)["w_rid"]); XCTAssertNil(m3Fields(collected)["access_key"])
    let last = try XCTUnwrap(requests.last)
    XCTAssertEqual(m3Fields(last)["season_id"], "22"); XCTAssertEqual(m3Fields(last)["page_size"], "30")
    XCTAssertEqual(m3Fields(last)["access_key"], "fixture-m3")
    XCTAssertNotNil(m3Fields(last)["sign"])
  }
  func testPGCResultEnvelopeAndStatus() async throws {
    let transport = M3Transport(); let service = try await m3Service(transport)
    let anime = try await service.libraryPGC(cinema: false, status: 2)
    let cinema = try await service.libraryPGC(cinema: true, status: 3)
    XCTAssertEqual(anime.items.first?.title, "Fixture series")
    XCTAssertEqual(cinema.items.first?.subtitle, "全 12 集")
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url!.path }, ["/pgc/app/follow/v2/bangumi", "/pgc/app/follow/v2/cinema"])
    XCTAssertEqual(m3Fields(requests[0])["status"], "2")
    XCTAssertEqual(m3Fields(requests[1])["status"], "3")
    XCTAssertEqual(m3Fields(requests[0])["ps"], "20"); XCTAssertEqual(m3Fields(requests[0])["pn"], "1")
  }
  func testAccountReadsNeedTokenAndBadArgumentsNeverSend() async throws {
    let transport = M3Transport(); let service = try await m3Service(transport, authenticated: false)
    do { _ = try await service.libraryPGC(cinema: false); XCTFail("Requires App token") } catch AuthFailure.needsLogin {}
    do { _ = try await service.libraryFollowGroups(); XCTFail("Requires App token") } catch AuthFailure.needsLogin {}
    do { _ = try await service.libraryProfile(mid: 0); XCTFail("Invalid mid") } catch BiliError.invalidResponse {}
    do { _ = try await service.libraryPGC(cinema: false, page: 0); XCTFail("Invalid page") } catch BiliError.invalidResponse {}
    do { _ = try await service.librarySearch(""); XCTFail("Empty search") } catch BiliError.invalidResponse {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testMalformedAndRejectedLibraryResponsesFail() async throws {
    for body in [#"{"code":0,"data":{}}"#, #"{"code":-403}"#] {
      let transport = M3Transport(rejection: Data(body.utf8)); let service = try await m3Service(transport)
      do { _ = try await service.libraryPGC(cinema: false); XCTFail("Malformed response") } catch is BiliError {}
    }
    XCTAssertThrowsError(try BiliService.libraryVideo(["title": "Missing identifier"]))
    XCTAssertThrowsError(try BiliService.libraryUser(["mid": 0, "name": "bad"]))
    let video = try BiliService.libraryVideo(["id": 789, "title": "<em>A</em>", "duration": "1:30", "upper": ["mid": 123, "name": "Owner"]])
    XCTAssertEqual(video.title, "A"); XCTAssertEqual(video.duration, 90); XCTAssertEqual(video.authorID, 123)
  }
  func testRPCSpaceAndHistorySearchRecordsUseExactMessagesAndBoundIdentity() async throws {
    let auth = try await m3Service(M3Transport()); let transport = M3RecordingRPC()
    let service = LibraryRPCService(auth: auth, transport: transport, installationID: "fixture-installation")
    let videos = try await service.userVideos(mid: 456, keyword: "space", page: 2)
    let identity = await auth.authSnapshot()
    let history = try await service.historySearchRecords(keyword: "history", page: 3, expectedIdentity: identity)
    XCTAssertEqual(videos.items.first?.id, "av789"); XCTAssertFalse(videos.hasMore)
    XCTAssertEqual(history.items.first.map { LibraryEntry.history($0).subtitle }, "已观看 30 秒")
    let methods = await transport.methods
    XCTAssertEqual(methods, ["bilibili.app.interface.v1.Space/SearchArchive", "bilibili.app.interface.v1.History/Search"])
    let requests = await transport.requests
    let space = try Bilibili_App_Interfaces_V1_SearchArchiveReq(serializedBytes: requests[0])
    XCTAssertEqual(space.mid, 456); XCTAssertEqual(space.ps, 20); XCTAssertEqual(space.pn, 2)
    let search = try Bilibili_App_Interfaces_V1_SearchReq(serializedBytes: requests[1])
    XCTAssertEqual(search.business, "archive"); XCTAssertEqual(search.pn, 3)
    let authorized = await transport.authorized
    XCTAssertEqual(authorized, [true, true])
  }
  func testAnonymousUserSpaceDoesNotSendTokenAndHistoryStillNeedsLogin() async throws {
    let auth = try await m3Service(M3Transport(), authenticated: false)
    let transport = M3RecordingRPC()
    let service = LibraryRPCService(auth: auth, transport: transport, installationID: "fixture")
    let videos = try await service.userVideos(mid: 456)
    XCTAssertEqual(videos.items.first?.id, "av789")
    let identity = await auth.authSnapshot()
    do { _ = try await service.historySearchRecords(keyword: "private", expectedIdentity: identity); XCTFail("Login required") }
    catch BiliRPCError.needsLogin {}
    let methods = await transport.methods
    let authorized = await transport.authorized
    XCTAssertEqual(methods.count, 1); XCTAssertEqual(authorized, [false])
  }
  func testHistoryTabsMapNativeURIsToOfficialWebDestinations() async throws {
    let auth = try await m3Service(M3Transport())
    let service = NativeBiliRPCService(auth: auth, transport: M3FixtureRPCTransport(), installationID: "fixture")
    for (business, expected) in [("article", "https://www.bilibili.com/read/cv77"), ("live", "https://live.bilibili.com/88")] {
      let page = try await service.history(business: business, max: 0)
      let item = try XCTUnwrap(page.items.first)
      let entry = LibraryEntry.history(item)
      XCTAssertEqual(entry.destination, .web(URL(string: expected)!))
    }
  }
}
#endif
