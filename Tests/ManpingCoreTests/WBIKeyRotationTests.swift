import Foundation
import XCTest

@testable import ManpingCore

private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_000_000)
  var now: Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class NoCredentials: AuthCredentialStore, @unchecked Sendable {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

/// Serves WBI keys and one signed endpoint; `rejections` answers that many requests with -403.
private actor KeyTransport: AuthTransport {
  var navRequests = 0
  var signedRequests = 0
  var rejections = 0
  func reject(_ count: Int) { rejections = count }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    let url = request.url!
    let body: String
    switch url.path {
    case "/x/web-interface/nav":
      navRequests += 1
      body = #"{"code":-101,"data":{"wbi_img":{"img_url":"https://i.example/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i.example/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#
    case "/x/signed":
      signedRequests += 1
      if rejections > 0 {
        rejections -= 1
        body = #"{"code":-403,"message":"访问权限不足"}"#
      } else {
        body = #"{"code":0,"data":{"ok":true}}"#
      }
    default:
      throw URLError(.badServerResponse)
    }
    return AuthHTTPResponse(body: Data(body.utf8),
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private extension BiliService {
  /// The signed JSON call, reduced to a Sendable answer for the test.
  func signedOK() async throws -> Bool { try await json("/x/signed", signed: true)["ok"] as? Bool ?? false }
  /// The raw-body path callers use to read envelope codes themselves.
  func rawCode() async throws -> Int {
    let body = try await wbiSignedBody("/x/signed", params: [:], expectedIdentity: authSnapshot())
    return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["code"] as? Int ?? -1
  }
}

final class WBIKeyRotationTests: XCTestCase {
  func testKeysAreFetchedAgainAfterTheyExpire() async throws {
    let clock = Clock(), transport = KeyTransport()
    let service = BiliService(transport: transport, credentials: NoCredentials(), now: { clock.now })
    _ = try await service.signedOK()
    _ = try await service.signedOK()
    var fetches = await transport.navRequests
    XCTAssertEqual(fetches, 1, "fresh keys are reused")

    clock.advance(BiliService.wbiKeyLifetime + 1)
    _ = try await service.signedOK()
    fetches = await transport.navRequests
    XCTAssertEqual(fetches, 2, "keys older than their lifetime are fetched again")
  }

  func testRejectedSignatureRefreshesKeysAndRetriesOnce() async throws {
    let clock = Clock(), transport = KeyTransport()
    let service = BiliService(transport: transport, credentials: NoCredentials(), now: { clock.now })
    _ = try await service.signedOK()
    await transport.reject(1)
    let ok = try await service.signedOK()
    XCTAssertTrue(ok)
    let fetches = await transport.navRequests, requests = await transport.signedRequests
    XCTAssertEqual(fetches, 2, "the rejection fetched new keys")
    XCTAssertEqual(requests, 3)

    await transport.reject(1)
    let code = try await service.rawCode()
    XCTAssertEqual(code, 0, "the raw-body path refreshes and retries once too")
    let rawFetches = await transport.navRequests
    XCTAssertEqual(rawFetches, 3)

    await transport.reject(2)
    do {
      _ = try await service.signedOK()
      XCTFail("a second rejection is reported, not retried again")
    } catch BiliError.api(let code, _) {
      XCTAssertEqual(code, -403)
    }
  }
}
