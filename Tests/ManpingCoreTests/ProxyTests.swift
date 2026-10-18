import CryptoKit
import Foundation
import Network
import XCTest

@testable import ManpingCore

final class ProxyTests: XCTestCase {
  // MARK: Shadowsocks key derivation (vectors computed independently with Python hashlib/hmac)

  func testKeyDerivationMatchesIndependentVectors() {
    XCTAssertEqual(ShadowsocksTunnel.evpBytesToKey("barfoo!", keySize: 32).hex,
      "b3adc47839e047eb228870526dc8fc30b347287ffca3045dcea06b3fdf090acb")
    XCTAssertEqual(ShadowsocksTunnel.evpBytesToKey("barfoo!", keySize: 16).hex, "b3adc47839e047eb228870526dc8fc30")
    let sub32 = ShadowsocksTunnel.subkey(master: ShadowsocksTunnel.evpBytesToKey("barfoo!", keySize: 32),
      salt: Data(0..<32), size: 32)
    XCTAssertEqual(sub32.withUnsafeBytes { Data($0) }.hex, "6e62f41174d7879ffea269ebf7805b730f62002e2b461f4dcb2a21dfb6f6423e")
    let sub16 = ShadowsocksTunnel.subkey(master: ShadowsocksTunnel.evpBytesToKey("barfoo!", keySize: 16),
      salt: Data(0..<16), size: 16)
    XCTAssertEqual(sub16.withUnsafeBytes { Data($0) }.hex, "9cd21fb890a57fbe98653cbadd4d047c")
  }

  func testAEADChunksRoundTripAcrossTheChunkLimitForEveryCipher() throws {
    for cipher in ShadowsocksTunnel.Cipher.allCases {
      let key = ShadowsocksTunnel.subkey(master: ShadowsocksTunnel.evpBytesToKey("pw", keySize: cipher.keySize),
        salt: Data(repeating: 7, count: cipher.keySize), size: cipher.keySize)
      var encoder = SSAEAD(key: key, cipher: cipher)
      let payload = Data((0..<40_000).map { UInt8($0 % 253) })
      let sealed = try encoder.encryptChunks(payload)
      XCTAssertEqual(sealed.count, payload.count + 3 * (2 + 16 + 16), "40000 bytes need three 0x3FFF chunks")
      var decoder = SSAEAD(key: key, cipher: cipher)
      XCTAssertEqual(try Self.decryptChunks(sealed, with: &decoder), payload, cipher.rawValue)
      let wrong = ShadowsocksTunnel.subkey(master: ShadowsocksTunnel.evpBytesToKey("other", keySize: cipher.keySize),
        salt: Data(repeating: 7, count: cipher.keySize), size: cipher.keySize)
      var intruder = SSAEAD(key: wrong, cipher: cipher)
      XCTAssertThrowsError(try Self.decryptChunks(sealed, with: &intruder), "a wrong password must not decrypt")
    }
  }

  // MARK: End to end through the built-in tunnel

  func testTunnelCarriesLargeAndConcurrentRequestsByHostName() async throws {
    let origin = try await TestOrigin.start()
    defer { origin.stop() }
    let server = try await TestShadowsocksServer.start(password: "s3cret", cipher: .chacha20, loopbackPort: origin.port)
    defer { server.stop() }
    let runtime = ProxyRuntime()
    var settings = ProxySettings()
    settings.kind = .shadowsocks; settings.host = "127.0.0.1"; settings.port = Int(server.port); settings.cipher = .chacha20
    try runtime.apply(settings, secret: "s3cret")
    XCTAssertTrue(runtime.status.running)
    let session = URLSession(configuration: try XCTUnwrap(runtime.configuration(.ephemeral)))
    defer { session.invalidateAndCancel() }

    // A name only the proxy side knows: the tunnel must pass the host name, not resolve it here.
    let big = URL(string: "http://origin.proxy-test.invalid:\(origin.port)/bytes/8000000")!
    let (data, response) = try await session.data(from: big)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(data.count, 8_000_000)
    XCTAssertTrue(data == TestOrigin.body(8_000_000), "bytes arrive intact through the AEAD tunnel")
    XCTAssertTrue(server.requestedHosts.contains("origin.proxy-test.invalid"))

    let sizes = (0..<16).map { 200_000 + $0 * 37_001 }
    try await withThrowingTaskGroup(of: Bool.self) { group in
      for size in sizes {
        group.addTask {
          let (body, _) = try await session.data(from: URL(string: "http://origin.proxy-test.invalid:\(origin.port)/bytes/\(size)")!)
          return body == TestOrigin.body(size)
        }
      }
      for try await ok in group { XCTAssertTrue(ok) }
    }
    XCTAssertGreaterThanOrEqual(server.connections, 17)
  }

  func testWrongPasswordFailsInsteadOfGoingDirect() async throws {
    let origin = try await TestOrigin.start()
    defer { origin.stop() }
    let server = try await TestShadowsocksServer.start(password: "right", cipher: .aes256gcm, loopbackPort: origin.port)
    defer { server.stop() }
    let runtime = ProxyRuntime()
    var settings = ProxySettings()
    settings.kind = .shadowsocks; settings.host = "127.0.0.1"; settings.port = Int(server.port); settings.cipher = .aes256gcm
    try runtime.apply(settings, secret: "wrong")
    var configuration = try XCTUnwrap(runtime.configuration(.ephemeral))
    configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    // Loopback targets bypass proxies in CFNetwork; CDN hosts never are, so use a name that only
    // the proxy side resolves.
    do {
      _ = try await session.data(from: URL(string: "http://origin.proxy-test.invalid:\(origin.port)/bytes/1000")!)
      XCTFail("a wrong password must not reach the origin")
    } catch {}
    XCTAssertGreaterThan(server.connections, 0, "the request went to the proxy")
    XCTAssertTrue(server.requestedHosts.isEmpty, "the server could not decrypt the target")
    XCTAssertEqual(origin.served, 0, "nothing reached the origin")
    configuration = .ephemeral
  }

  func testUnreachableTunnelServerFailsClosed() async throws {
    let origin = try await TestOrigin.start()
    defer { origin.stop() }
    let runtime = ProxyRuntime()
    var settings = ProxySettings()
    // Port 9 on loopback refuses: the proxy server is down.
    settings.kind = .shadowsocks; settings.host = "127.0.0.1"; settings.port = 9
    try runtime.apply(settings, secret: "x")
    let configuration = try XCTUnwrap(runtime.configuration(.ephemeral))
    configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await session.data(from: URL(string: "http://origin.proxy-test.invalid:\(origin.port)/bytes/10")!)
      XCTFail("a dead proxy must not fall back to a direct connection")
    } catch {
      // A direct attempt would fail to resolve the name; the proxied one fails at the proxy.
      XCTAssertNotEqual((error as? URLError)?.code, .cannotFindHost, "\(error)")
    }
    XCTAssertEqual(origin.served, 0)
  }

  func testSettingsValidationAndSignature() {
    var settings = ProxySettings()
    XCTAssertFalse(settings.isConfigured)
    settings.kind = .socks5; settings.host = "proxy.example.com"; settings.port = 1080
    XCTAssertTrue(settings.isConfigured)
    for bad in ["http://proxy.example.com", "proxy example.com", "a/b", ""] {
      XCTAssertFalse(ProxySettings.validHost(bad), bad)
    }
    XCTAssertTrue(ProxySettings.validHost("203.0.113.5"))
    XCTAssertTrue(ProxySettings.validHost("[2001:db8::1]"))
    // Only connection fields and the password change the signature; routing modes do not.
    let base = settings.connectionSignature(secret: "a")
    var routed = settings; routed.media = .concurrent; routed.region = .always
    XCTAssertEqual(routed.connectionSignature(secret: "a"), base)
    XCTAssertNotEqual(settings.connectionSignature(secret: "b"), base)
    XCTAssertFalse(base.contains("a|") && base.hasSuffix("|a"), "the password itself never appears")
    let defaults = UserDefaults(suiteName: "proxy-\(UUID().uuidString)")!
    settings.save(to: defaults)
    XCTAssertEqual(ProxySettings.load(from: defaults), settings)
  }

  // MARK: Region routing for API requests

  private func regionService(region: RegionRoute, directLimited: Bool = true) async -> (BiliService, RouteFake, RouteFake) {
    let direct = RouteFake(limited: directLimited)
    let proxied = RouteFake(limited: false)
    let service = BiliService(transport: direct, credentials: EmptyCredentials())
    await service.setProxy(proxied, region: region)
    return (service, direct, proxied)
  }

  func testAutoRegionRetriesThroughTheProxyAndStaysThereForAWhile() async throws {
    let (service, direct, proxied) = await regionService(region: .auto)
    let video = Video(bvid: "", title: "大陆版权", cid: 456, aid: 789)
    let manifest = try await service.playback(video)
    XCTAssertEqual(manifest.video.first?.quality, 64)
    XCTAssertEqual(direct.playurlRequests, 1, "tried direct first")
    XCTAssertEqual(proxied.playurlRequests, 1, "then once through the proxy")
    let retries = await service.regionRetries
    XCTAssertEqual(retries, 1)
    _ = try await service.playback(video)
    XCTAssertEqual(direct.playurlRequests, 1, "the next request skips the failing direct attempt")
    XCTAssertEqual(proxied.playurlRequests, 2)
  }

  func testAutoRegionLeavesUnrestrictedRequestsDirect() async throws {
    let (service, direct, proxied) = await regionService(region: .auto, directLimited: false)
    _ = try await service.playback(Video(bvid: "", title: "普通视频", cid: 456, aid: 789))
    XCTAssertEqual(direct.playurlRequests, 1)
    XCTAssertEqual(proxied.playurlRequests, 0)
  }

  func testAlwaysRoutesEveryRequestAndOffNeverDoes() async throws {
    let (always, alwaysDirect, alwaysProxied) = await regionService(region: .always)
    _ = try await always.playback(Video(bvid: "", title: "x", cid: 456, aid: 789))
    XCTAssertEqual(alwaysDirect.totalRequests, 0, "nothing goes direct in always mode")
    XCTAssertGreaterThan(alwaysProxied.totalRequests, 0)

    let (off, offDirect, offProxied) = await regionService(region: .off)
    do {
      _ = try await off.playback(Video(bvid: "", title: "x", cid: 456, aid: 789))
      XCTFail("region-limited content stays limited when the proxy is off")
    } catch BiliError.api(let code, _) {
      XCTAssertEqual(code, -10403)
    }
    XCTAssertEqual(offDirect.playurlRequests, 1)
    XCTAssertEqual(offProxied.totalRequests, 0)
  }

  func testRemovingTheProxyStopsRegionRouting() async throws {
    let (service, direct, proxied) = await regionService(region: .always)
    await service.setProxy(nil, region: .always)
    do { _ = try await service.playback(Video(bvid: "", title: "x", cid: 456, aid: 789)) } catch {}
    XCTAssertEqual(proxied.totalRequests, 0)
    XCTAssertEqual(direct.playurlRequests, 1)
  }

  func testAlwaysRoutesTheDeviceCookieFetchThroughTheProxy() async throws {
    // F8: the finger/spi device id request follows the same routing as every other request.
    let direct = RouteFake(limited: false)
    let proxied = RouteFake(limited: false)
    let service = BiliService(transport: direct, credentials: EmptyCredentials(), webDeviceCookies: true)
    await service.setProxy(proxied, region: .always)
    _ = try await service.data(URL(string: "https://api.bilibili.com/x/web-interface/zone")!)
    XCTAssertEqual(direct.totalRequests, 0, "nothing goes direct in always mode, device cookies included")
    XCTAssertEqual(proxied.totalRequests, 2, "finger/spi, then the request itself")

    let offDirect = RouteFake(limited: false)
    let offProxied = RouteFake(limited: false)
    let off = BiliService(transport: offDirect, credentials: EmptyCredentials(), webDeviceCookies: true)
    await off.setProxy(offProxied, region: .off)
    _ = try await off.data(URL(string: "https://api.bilibili.com/x/web-interface/zone")!)
    XCTAssertEqual(offDirect.totalRequests, 2)
    XCTAssertEqual(offProxied.totalRequests, 0)
  }

  // MARK: Tunnel rebuild notices

  func testStaleTunnelRebuildNoticeCannotRepointTheProxy() throws {
    // F6: a rebuild notice arrives after the tunnel released its lock; one for an older
    // configuration, or for a port that is no longer the live entry, must be ignored.
    let runtime = ProxyRuntime()
    var settings = ProxySettings()
    settings.kind = .shadowsocks; settings.host = "127.0.0.1"; settings.port = 9
    try runtime.apply(settings, secret: "new-pw")
    func socksPort() -> Int? {
      runtime.configuration(.ephemeral)?.connectionProxyDictionary?[kCFNetworkProxiesSOCKSPort as String] as? Int
    }
    let live = try XCTUnwrap(socksPort())
    XCTAssertNotEqual(live, 9)
    let revision = runtime.currentRevision
    let old = ShadowsocksTunnel.Config(server: "127.0.0.1", port: 9, password: "old-pw", cipher: settings.cipher)
    runtime.tunnelRebuilt(old, port: 4242)
    XCTAssertEqual(socksPort(), live, "an old configuration's entry is never published")
    let current = try XCTUnwrap(ProxyRuntime.tunnelConfig(settings, secret: "new-pw"))
    runtime.tunnelRebuilt(current, port: 4242)
    XCTAssertEqual(socksPort(), live, "a port that is not the live entry is never published")
    XCTAssertEqual(runtime.currentRevision, revision)
    runtime.tunnelRebuilt(current, port: UInt16(live))
    XCTAssertEqual(runtime.currentRevision, revision + 1, "the current configuration's live entry is accepted")
    XCTAssertEqual(socksPort(), live)
  }

  // MARK: Helpers

  static func decryptChunks(_ sealed: Data, with decoder: inout SSAEAD) throws -> Data {
    var out = Data()
    var index = sealed.startIndex
    while index < sealed.endIndex {
      let header = try decoder.open(Data(sealed[index..<index + 18]))
      let length = Int(header[header.startIndex]) << 8 | Int(header[header.startIndex + 1])
      index += 18
      out += try decoder.open(Data(sealed[index..<index + length + 16]))
      index += length + 16
    }
    return out
  }
}

extension Data {
  fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: Test servers

/// HTTP origin on loopback: `GET /bytes/<n>` returns n deterministic bytes.
final class TestOrigin: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "test.origin")
  private let lock = NSLock()
  private var count = 0
  let port: UInt16
  var served: Int { lock.withLock { count } }

  static func body(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

  private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

  static func start() async throws -> TestOrigin {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    let handler = TestHandlerBox()
    // NWListener refuses to start (EINVAL) without a connection handler.
    listener.newConnectionHandler = { connection in handler.handle?(connection) ?? connection.cancel() }
    let port = try await TestListener.ready(listener, queue: DispatchQueue(label: "test.origin.start"))
    let origin = TestOrigin(listener: listener, port: port)
    handler.handle = { [weak origin] connection in origin?.handle(connection) }
    return origin
  }
  func stop() { listener.cancel() }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    func read(_ buffer: Data) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
        guard let self else { return }
        var buffer = buffer
        if let data { buffer.append(data) }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
          if done || error != nil { connection.cancel() } else { read(buffer) }
          return
        }
        let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let size = Int(line.split(separator: " ").dropFirst().first?.split(separator: "/").last ?? "") ?? 0
        self.lock.withLock { self.count += 1 }
        let head = Data("HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: head + TestOrigin.body(size), completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    read(Data())
  }
}

/// Minimal Shadowsocks AEAD server for tests: decrypts the client stream, connects every target
/// (by name or address) to the loopback origin, and encrypts the replies.
final class TestShadowsocksServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "test.ss")
  private let master: Data
  private let cipher: ShadowsocksTunnel.Cipher
  /// nil: connect to the real target (live tests); otherwise every target goes to this loopback port.
  private let loopbackPort: UInt16?
  private let lock = NSLock()
  private var hosts: [String] = []
  private var accepted = 0
  let port: UInt16
  var requestedHosts: [String] { lock.withLock { hosts } }
  var connections: Int { lock.withLock { accepted } }

  private init(listener: NWListener, port: UInt16, password: String, cipher: ShadowsocksTunnel.Cipher, loopbackPort: UInt16?) {
    self.listener = listener; self.port = port; self.cipher = cipher; self.loopbackPort = loopbackPort
    master = ShadowsocksTunnel.evpBytesToKey(password, keySize: cipher.keySize)
  }

  static func start(password: String, cipher: ShadowsocksTunnel.Cipher, loopbackPort: UInt16?, port fixed: UInt16? = nil) async throws -> TestShadowsocksServer {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: fixed.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
    let listener = try NWListener(using: parameters)
    let handler = TestHandlerBox()
    listener.newConnectionHandler = { connection in handler.handle?(connection) ?? connection.cancel() }
    let port = try await TestListener.ready(listener, queue: DispatchQueue(label: "test.ss.start"))
    let server = TestShadowsocksServer(listener: listener, port: port, password: password, cipher: cipher, loopbackPort: loopbackPort)
    handler.handle = { [weak server] connection in server?.handle(connection) }
    return server
  }
  func stop() { listener.cancel() }

  private final class Pipe: @unchecked Sendable {
    var buffer = Data()
    var decoder: SSAEAD?
    var encoder: SSAEAD?
    var pending: Int?
    var origin: NWConnection?
    var plain = Data()
  }

  private func handle(_ client: NWConnection) {
    lock.withLock { accepted += 1 }
    let pipe = Pipe()
    client.start(queue: queue)
    func pumpClient() {
      client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
        guard let self else { return }
        if let data { pipe.buffer.append(data) }
        do { try self.decrypt(pipe) } catch { client.cancel(); pipe.origin?.cancel(); return }
        if pipe.origin == nil, let (target, targetPort) = Self.target(&pipe.plain) {
          self.lock.withLock { self.hosts.append(target) }
          let origin = self.loopbackPort.map { NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: $0)!, using: .tcp) }
            ?? NWConnection(host: NWEndpoint.Host(target), port: NWEndpoint.Port(rawValue: targetPort)!, using: .tcp)
          pipe.origin = origin
          origin.start(queue: self.queue)
          self.pumpOrigin(origin, client: client, pipe: pipe)
        }
        if let origin = pipe.origin, !pipe.plain.isEmpty {
          let chunk = pipe.plain; pipe.plain = Data()
          origin.send(content: chunk, completion: .contentProcessed { _ in })
        }
        if done || error != nil { return }
        pumpClient()
      }
    }
    pumpClient()
  }

  private func pumpOrigin(_ origin: NWConnection, client: NWConnection, pipe: Pipe) {
    origin.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
      guard let self else { return }
      var out = Data()
      if pipe.encoder == nil {
        let salt = Data((0..<self.cipher.keySize).map { _ in UInt8.random(in: 0...255) })
        pipe.encoder = SSAEAD(key: ShadowsocksTunnel.subkey(master: self.master, salt: salt, size: self.cipher.keySize), cipher: self.cipher)
        out += salt
      }
      if let data, !data.isEmpty { out += (try? pipe.encoder!.encryptChunks(data)) ?? Data() }
      let finished = done || error != nil
      client.send(content: out, completion: .contentProcessed { _ in
        if finished { client.cancel(); origin.cancel() } else { self.pumpOrigin(origin, client: client, pipe: pipe) }
      })
    }
  }

  private func decrypt(_ pipe: Pipe) throws {
    if pipe.decoder == nil {
      guard pipe.buffer.count >= cipher.keySize else { return }
      pipe.decoder = SSAEAD(key: ShadowsocksTunnel.subkey(master: master, salt: Data(pipe.buffer.prefix(cipher.keySize)), size: cipher.keySize), cipher: cipher)
      pipe.buffer.removeFirst(cipher.keySize)
    }
    while true {
      if pipe.pending == nil {
        guard pipe.buffer.count >= 18 else { return }
        let header = try pipe.decoder!.open(Data(pipe.buffer.prefix(18)))
        pipe.pending = Int(header[header.startIndex]) << 8 | Int(header[header.startIndex + 1])
        pipe.buffer.removeFirst(18)
      }
      guard let length = pipe.pending, pipe.buffer.count >= length + 16 else { return }
      pipe.plain += try pipe.decoder!.open(Data(pipe.buffer.prefix(length + 16)))
      pipe.buffer.removeFirst(length + 16)
      pipe.pending = nil
    }
  }

  /// Consumes the SOCKS-style target header (type, address, port) and returns host and port.
  private static func target(_ plain: inout Data) -> (String, UInt16)? {
    guard let type = plain.first else { return nil }
    let bytes = [UInt8](plain)
    let length: Int
    let host: String
    switch type {
    case 1:
      guard bytes.count >= 7 else { return nil }
      length = 7; host = bytes[1...4].map(String.init).joined(separator: ".")
    case 3:
      guard bytes.count >= 2, bytes.count >= 2 + Int(bytes[1]) + 2 else { return nil }
      length = 2 + Int(bytes[1]) + 2; host = String(decoding: bytes[2..<(2 + Int(bytes[1]))], as: UTF8.self)
    case 4:
      guard bytes.count >= 19 else { return nil }
      length = 19
      host = stride(from: 1, to: 17, by: 2).map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }.joined(separator: ":")
    default: return nil
    }
    let port = UInt16(bytes[length - 2]) << 8 | UInt16(bytes[length - 1])
    plain.removeFirst(length)
    return (host, port)
  }
}

enum TestListener {
  static func ready(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
      let once = TestOnce()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
        case .failed(let error): if once.take() { continuation.resume(throwing: error) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }
}

final class TestHandlerBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: (@Sendable (NWConnection) -> Void)?
  var handle: (@Sendable (NWConnection) -> Void)? {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

final class TestOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// API transport fake: WBI keys from nav; playurl is region-limited (-10403) or a small manifest.
final class RouteFake: AuthTransport, @unchecked Sendable {
  private let limited: Bool
  private let lock = NSLock()
  private var paths: [String] = []
  init(limited: Bool) { self.limited = limited }
  var playurlRequests: Int { lock.withLock { paths.filter { $0.contains("playurl") }.count } }
  var totalRequests: Int { lock.withLock { paths.count } }

  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    let path = request.url?.path ?? ""
    lock.withLock { paths.append(path) }
    let body: String
    if path.hasSuffix("/nav") {
      body = #"{"code":-101,"data":{"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#
    } else if path.contains("playurl") {
      body = limited ? #"{"code":-10403,"message":"抱歉您所在地区不可观看！"}"#
        : #"{"code":0,"data":{"dash":{"duration":12,"video":[{"id":64,"codecs":"avc1.640028","base_url":"https://video.example/v","bandwidth":100}],"audio":[{"id":30280,"codecs":"mp4a.40.2","base_url":"https://video.example/a","bandwidth":50}]}}}"#
    } else {
      body = #"{"code":0,"data":{}}"#
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
    return AuthHTTPResponse(body: Data(body.utf8), response: response)
  }
}

final class EmptyCredentials: AuthCredentialStore, @unchecked Sendable {
  func save(_ cookies: [HTTPCookie]) {}
  func load() -> [HTTPCookie] { [] }
  func saveToken(_ token: AppToken?) {}
  func loadToken() -> AppToken? { nil }
  func clear() {}
}

/// Real network, opt-in (`MANPING_LIVE_PROXY=1`): the built-in tunnel to an in-process forwarding
/// Shadowsocks server, then real Bilibili endpoints through it.
final class ProxyLiveTests: XCTestCase {
  func testZoneThroughRealTunnel() async throws {
    guard ProcessInfo.processInfo.environment["MANPING_LIVE_PROXY"] != nil else { throw XCTSkip("MANPING_LIVE_PROXY not set") }
    let server = try await TestShadowsocksServer.start(password: "live-pw", cipher: .chacha20, loopbackPort: nil)
    defer { server.stop() }
    let runtime = ProxyRuntime()
    var settings = ProxySettings()
    settings.kind = .shadowsocks; settings.host = "127.0.0.1"; settings.port = Int(server.port)
    try runtime.apply(settings, secret: "live-pw")
    let exit = try await runtime.probe()
    print("PROXIED", exit.summary, exit.milliseconds, "ms")
    let transport = ProxyAuthTransport(runtime: runtime)
    let response = try await transport.send(URLRequest(url: URL(string: "https://api.bilibili.com/x/web-interface/nav")!))
    print("NAV", response.response.statusCode, response.body.count)
  }

  /// Keeps a forwarding server on a fixed port for a Debug app run (`MANPING_SS_SERVE_SECONDS=n`).
  func testServeForDebugApp() async throws {
    guard let seconds = ProcessInfo.processInfo.environment["MANPING_SS_SERVE_SECONDS"].flatMap(Double.init) else {
      throw XCTSkip("MANPING_SS_SERVE_SECONDS not set")
    }
    let server = try await TestShadowsocksServer.start(password: "bili-test-pw", cipher: .chacha20, loopbackPort: nil, port: 18388)
    defer { server.stop() }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    print("SERVED connections=\(server.connections) hosts=\(Set(server.requestedHosts).sorted())")
  }
}
