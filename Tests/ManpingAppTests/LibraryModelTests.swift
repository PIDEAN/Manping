#if DEBUG
import ManpingCore
import XCTest

@testable import ManpingApp

private struct LibraryNoCredentials: AuthCredentialStore {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private actor LibraryIdentityTransport: AuthTransport {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  func release() { released = true; continuation?.resume(); continuation = nil }
  private(set) var searches = 0
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    let url = request.url!
    let data: [String: Any]
    switch url.path {
    case "/x/web-interface/nav":
      data = ["wbi_img": ["img_url": "https://fixture.invalid/00000000000000000000000000000000.png",
        "sub_url": "https://fixture.invalid/11111111111111111111111111111111.png"]]
    case "/x/web-interface/wbi/search/type":
      searches += 1
      let version = searches
      if version > 1 && !released { await withCheckedContinuation { continuation = $0 } }
      data = ["result": [["id": version, "title": "Account \(version)"]], "numPages": 1, "numResults": 1]
    default: throw URLError(.notConnectedToInternet)
    }
    return AuthHTTPResponse(body: try JSONSerialization.data(withJSONObject: ["code": 0, "data": data]),
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class LibraryModelTests: XCTestCase {
  func testRetainedLibraryClearsOldAccountRowsAndReloadsOnIdentityVersionChange() async throws {
    let transport = LibraryIdentityTransport()
    let service = BiliService(transport: transport, credentials: LibraryNoCredentials())
    let library = LibraryModel(service: service)
    for _ in 0..<20 { await Task.yield() }
    await library.load(.search("Account scoped", .article, .relevance))
    XCTAssertEqual(library.entries.map(\.title), ["Account 1"])
    let version = library.identityVersion
    _ = await service.beginLogin()
    // A retained hidden page does not call cancel(); its normal identity observer stays alive.
    for _ in 0..<200 {
      if library.identityVersion > version { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertGreaterThan(library.identityVersion, version)
    XCTAssertTrue(library.entries.isEmpty, "old account rows must disappear before the next request finishes")
    await transport.release()
    for _ in 0..<200 {
      if !library.isLoading && library.entries.first?.title == "Account 2" { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(library.entries.map(\.title), ["Account 2"])
    XCTAssertNil(library.error)
    library.cancel()
  }
}
#endif
