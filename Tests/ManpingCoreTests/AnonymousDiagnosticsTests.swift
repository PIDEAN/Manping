import Foundation
import XCTest
@testable import ManpingCore

final class AnonymousDiagnosticsTests: XCTestCase {
  private func request(_ path: String = "/x/web-interface/nav", host: String = "api.bilibili.com", query: String = "") -> URLRequest {
    URLRequest(url: URL(string: "https://\(host)\(path)\(query)")!)
  }
  func testOnlyAuditedPublicGETRoutesAndFieldsPass() {
    let accepted: [(String, String, String)] = [
      ("api.bilibili.com", "/x/frontend/finger/spi", ""),
      ("api.bilibili.com", "/x/web-interface/nav", ""),
      ("api.bilibili.com", "/x/web-interface/wbi/view", "?bvid=BV1234567890&wts=1&w_rid=public-signature"),
      ("api.bilibili.com", "/x/player/wbi/playurl", "?avid=1&cid=2&qn=64&fnval=4048&fourk=1"),
      ("api.live.bilibili.com", "/room/v1/Room/room_init", "?id=1"),
      ("api.live.bilibili.com", "/room/v1/Room/get_info", "?room_id=1"),
      ("api.live.bilibili.com", "/live_user/v1/Master/info", "?uid=1"),
      ("api.live.bilibili.com", "/xlive/app-interface/v2/index/feed", "?page=1&relation_page=1&scale=2&login_event=1&device=phone&appkey=public&build=1&mobi_app=iphone&platform=ios&ts=1&sign=public"),
      ("api.live.bilibili.com", "/xlive/web-room/v2/index/getRoomPlayInfo", "?room_id=1&no_playurl=0&qn=10000&codec=0,1,2&dolby=5&format=0,1,2&only_audio=0&protocol=0,1&mask=1&panorama=1"),
    ]
    for (host, path, query) in accepted {
      var value = request(path, host: host, query: query)
      // buvid4 from finger/spi ends in base64 padding.
      value.setValue("buvid3=device-id; buvid4=device-id-Sw5sDQ==; b_nut=123", forHTTPHeaderField: "Cookie")
      XCTAssertTrue(GETOnlyAuditedTransport.allows(value), path)
    }
  }
  func testMutationsCredentialsUnknownPathsAndRedirectTargetsFailClosed() async {
    let base = Stub()
    let transport = GETOnlyAuditedTransport(base: base)
    var cases: [URLRequest] = []
    for method in ["POST", "HEAD", "PUT"] { var value = request(); value.httpMethod = method; cases.append(value) }
    var body = request(); body.httpBody = Data(); cases.append(body)
    var stream = request(); stream.httpBodyStream = InputStream(data: Data()); cases.append(stream)
    for header in ["Authorization", "Proxy-Authorization", "X-Bili-Ticket", "X-CSRF-Token"] {
      var value = request(); value.setValue("test", forHTTPHeaderField: header); cases.append(value)
    }
    for cookie in ["SESSDATA=test", "bili_jct=test", "DedeUserID=1", "buvid3=x; SESSDATA=test", "buvid3=bad value"] {
      var value = request(); value.setValue(cookie, forHTTPHeaderField: "Cookie"); cases.append(value)
    }
    for query in ["?access_key=test", "?csrf=test", "?access_token=test", "?%61ccess_key=test", "?bvid=BV1234567890&bvid=BV0987654321", "?unknown=1"] {
      cases.append(request("/x/web-interface/wbi/view", query: query))
    }
    for raw in ["http://api.bilibili.com/x/web-interface/nav", "https://api.bilibili.com.evil.invalid/x/web-interface/nav", "https://api.bilibili.com:444/x/web-interface/nav", "https://user@api.bilibili.com/x/web-interface/nav", "https://api.bilibili.com/x/web-interface/nav#fragment", "https://api.bilibili.com/x/v2/history/report", "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo", "https://api.bilibili.com/x/web-interface/%6eav"] {
      cases.append(URLRequest(url: URL(string: raw)!))
    }
    for value in cases {
      do { _ = try await transport.send(value); XCTFail("unsafe request passed") }
      catch { XCTAssertTrue(error is GETOnlyAuditedTransport.Failure) }
    }
    XCTAssertEqual(base.calls, 0)
    XCTAssertEqual(transport.audit.sent, 0)
    XCTAssertEqual(transport.audit.rejected, cases.count)
    XCTAssertEqual(transport.audit.nonGET, 3)
  }
  func testResponseCannotPopulateAccountCookiesAndRedirectsAreRejected() async throws {
    let base = Stub()
    let transport = GETOnlyAuditedTransport(base: base)
    let result = try await transport.send(request())
    XCTAssertNil(result.response.value(forHTTPHeaderField: "Set-Cookie"))
    XCTAssertEqual(transport.audit.sent, 1)
    let redirected = GETOnlyAuditedTransport(base: Stub(status: 302))
    do { _ = try await redirected.send(request()); XCTFail("redirect passed") } catch { }
    let wrongOrigin = GETOnlyAuditedTransport(base: Stub(wrongURL: true))
    do { _ = try await wrongOrigin.send(request()); XCTFail("changed origin passed") } catch { }
  }
  func testCredentialStoreAlwaysRejectsWithoutAnyBackingStore() {
    let store = DenyCredentialStore()
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.loadToken())
    XCTAssertThrowsError(try store.loadAll())
    XCTAssertThrowsError(try store.save([]))
    XCTAssertThrowsError(try store.saveToken(nil))
    XCTAssertThrowsError(try store.clear())
    XCTAssertEqual(store.callCount, 6)
  }
  func testServiceStartsAnonymousWithoutCredentialAccess() async {
    let store = DenyCredentialStore()
    let base = Stub()
    let transport = GETOnlyAuditedTransport(base: base)
    let service = BiliService(transport: transport, credentials: store, webDeviceCookies: true)
    let snapshot = await service.authSnapshot()
    let mid = await service.accountMid()
    XCTAssertEqual(snapshot.state, .needsLogin); XCTAssertNil(snapshot.token); XCTAssertNil(mid)
    XCTAssertEqual(store.callCount, 0); XCTAssertEqual(base.calls, 0)
  }
  func testTargetValidationAndAudioTuningAreStrict() throws {
    XCTAssertEqual(AnonymousPlaybackTarget(bvid: "BV1234567890", live: nil), .video("BV1234567890"))
    XCTAssertEqual(AnonymousPlaybackTarget(bvid: nil, live: "auto"), .live(nil))
    XCTAssertEqual(AnonymousPlaybackTarget(bvid: nil, live: "1"), .live(1))
    for value in ["0", "-1", "+1", "1.0", "", "9223372036854775808", "https://example.invalid/"] {
      XCTAssertNil(AnonymousPlaybackTarget(bvid: nil, live: value))
    }
    XCTAssertNil(AnonymousPlaybackTarget(bvid: "BVbad", live: nil))
    XCTAssertNil(AnonymousPlaybackTarget(bvid: "BV1234567890", live: "1"))
    let tuning = try DiagnosticAudioTuning(arguments: ["--perf-fixture", "--perf-audio-driver", "coreaudio", "--perf-audio-buffer", "2", "--perf-cache-pause-wait", "1"])
    XCTAssertEqual(tuning.driver, .coreaudio); XCTAssertEqual(tuning.audioBufferSeconds, 2); XCTAssertEqual(tuning.pauseWaitSeconds, 1)
    for args in [["--perf-audio-driver", "coreaudio"], ["--perf-fixture", "--perf-audio-driver", "null"], ["--perf-fixture", "--perf-audio-buffer", "nan"], ["--perf-fixture", "--perf-cache-pause-wait", "0"], ["--perf-fixture", "--perf-audio-buffer", "3"], ["--perf-fixture", "--perf-audio-driver", "coreaudio", "--perf-audio-driver", "default"], ["--perf-fixture", "--perf-scroll", "popular", "--perf-audio-driver", "default"]] {
      XCTAssertThrowsError(try DiagnosticAudioTuning(arguments: args))
    }
    XCTAssertEqual(DiagnosticAudioTuning.outputCategory("coreaudio"), "coreaudio")
    XCTAssertEqual(DiagnosticAudioTuning.outputCategory("avfoundation"), "avfoundation")
    XCTAssertEqual(DiagnosticAudioTuning.outputCategory("private-device-name"), "other")
    XCTAssertEqual(DiagnosticAudioTuning.outputCategory(""), "unavailable")
  }

  func testPublicServiceCallGraphRemainsGETOnlyAndNeverTouchesCredentials() async throws {
    struct PublicAPI: AuthTransport {
      func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
        let body: String
        switch request.url!.path {
        case "/x/frontend/finger/spi": body = #"{"code":0,"data":{"b_3":"fixture-device","b_4":"fixture-device"}}"#
        case "/x/web-interface/nav": body = #"{"code":-101,"data":{"wbi_img":{"img_url":"https://i.example/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i.example/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#
        case "/x/web-interface/wbi/view": body = #"{"code":0,"data":{"bvid":"BV1234567890","aid":1,"cid":2,"title":"fixture"}}"#
        case "/x/player/wbi/playurl": body = #"{"code":0,"data":{"dash":{"duration":600,"video":[{"id":64,"codecs":"avc1.640028","base_url":"https://media.example/video","bandwidth":100}],"audio":[{"id":30280,"codecs":"mp4a.40.2","base_url":"https://media.example/audio","bandwidth":50}]}}}"#
        case "/xlive/app-interface/v2/index/feed": body = #"{"code":0,"data":{"card_list":[]}}"#
        case "/room/v1/Room/room_init": body = #"{"code":0,"data":{"room_id":1,"uid":2}}"#
        case "/room/v1/Room/get_info": body = #"{"code":0,"data":{"room_id":1,"uid":2,"title":"fixture","live_status":1}}"#
        case "/live_user/v1/Master/info": body = #"{"code":0,"data":{"info":{"uname":"fixture"}}}"#
        case "/xlive/web-room/v2/index/getRoomPlayInfo": body = #"{"code":0,"data":{"room_id":1,"live_status":1,"playurl_info":{"playurl":{"stream":[]}}}}"#
        default: throw GETOnlyAuditedTransport.Failure.rejected
        }
        return AuthHTTPResponse(body: Data(body.utf8), response: HTTPURLResponse(url: request.url!, statusCode: 200,
          httpVersion: nil, headerFields: ["Set-Cookie": "SESSDATA=test; Domain=.bilibili.com; Path=/"])!)
      }
    }
    let store = DenyCredentialStore()
    let transport = GETOnlyAuditedTransport(base: PublicAPI())
    let service = BiliService(transport: transport, credentials: store, webDeviceCookies: true)
    let initial = await service.authSnapshot()
    let video = try await service.detail("BV1234567890", expectedIdentity: initial)
    let manifest = try await service.playback(video, expectedIdentity: initial)
    XCTAssertEqual(manifest.duration, 600)
    _ = try PlaybackSelector.select(manifest)
    _ = try await service.liveFeed(page: 1, expectedIdentity: initial)
    let room = try await service.liveRoom(1)
    XCTAssertEqual(room.status, .live)
    _ = try await service.livePlayback(roomID: room.roomID)
    let final = await service.authSnapshot()
    let mid = await service.accountMid()
    XCTAssertEqual(final.state, .needsLogin); XCTAssertNil(final.token); XCTAssertNil(mid)
    XCTAssertEqual(final.epoch, initial.epoch); XCTAssertEqual(final.identityRevision, initial.identityRevision)
    XCTAssertEqual(store.callCount, 0)
    XCTAssertEqual(transport.audit.rejected, 0); XCTAssertEqual(transport.audit.nonGET, 0)
    XCTAssertEqual(transport.audit.sent, 9)
  }
  private final class Stub: AuthTransport, @unchecked Sendable {
    let status: Int
    let wrongURL: Bool
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(status: Int = 200, wrongURL: Bool = false) { self.status = status; self.wrongURL = wrongURL }
    func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
      lock.withLock { count += 1 }
      return AuthHTTPResponse(body: Data("{}".utf8), response: HTTPURLResponse(
        url: wrongURL ? URL(string: "https://example.invalid/")! : request.url!, statusCode: status,
        httpVersion: nil, headerFields: ["Set-Cookie": "SESSDATA=test; Domain=.bilibili.com; Path=/"])!)
    }
  }
}
