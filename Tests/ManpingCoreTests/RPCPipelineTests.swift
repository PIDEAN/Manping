import BiliProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import GRPCProtobuf
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOTransportServices
import XCTest

@testable import ManpingCore

private actor PipelineProbe {
  var requests: [(String, Metadata)] = []
  var cancelled = 0
  func received(_ body: String, _ metadata: Metadata) { requests.append((body, metadata)) }
  func recordCancel() { cancelled += 1 }
}
private struct LoopbackRPC {
  let core: GRPCClient<HTTP2ClientTransport.TransportServices>
  let native: NativeBiliRPCTransport
  let server: GRPCServer<HTTP2ServerTransport.TransportServices>
  let serverTask: Task<Void, Error>
  let probe: PipelineProbe

  static func start(maxConcurrentCalls: Int = 16) async throws -> Self {
    let probe = PipelineProbe()
    let serverTransport = HTTP2ServerTransport.TransportServices(
      address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext,
      config: .defaults { $0.compression.enabledAlgorithms = [.gzip] })
    var router = RPCRouter<HTTP2ServerTransport.TransportServices>()
    router.registerHandler(
      forMethod: BiliRPCMethod.dynAll.descriptor,
      deserializer: ProtobufDeserializer<Bilibili_App_Dynamic_V2_DynAllReq>(),
      serializer: ProtobufSerializer<Bilibili_App_Dynamic_V2_DynAllReply>()
    ) { request, context in
      let unary = try await ServerRequest(stream: request)
      await probe.received(unary.message.offset, unary.metadata)
      if unary.message.offset == "block" {
        try await context.cancellation.cancelled
        await probe.recordCancel()
        throw RPCError(code: .cancelled, message: "fixture stream cancelled")
      }
      var reply = Bilibili_App_Dynamic_V2_DynAllReply()
      reply.dynamicList.historyOffset =
        unary.message.offset == "oversized-response"
        ? String(repeating: "x", count: 8 * 1024 * 1024 + 1) : unary.message.offset
      let message = reply
      return StreamingServerResponse { writer in
        try await writer.write(message)
        if unary.message.offset == "bad-trailer" {
          throw RPCError(code: .permissionDenied, message: "fixture secret must be redacted")
        }
        return ["fixture-trailer": "ok"]
      }
    }
    let server = GRPCServer(transport: serverTransport, router: router)
    let serverTask = Task { try await server.serve() }
    let address = try await serverTransport.listeningAddress
    let port = try XCTUnwrap(address.ipv4?.port)
    let clientTransport = try HTTP2ClientTransport.TransportServices(
      target: .ipv4(host: "127.0.0.1", port: port), transportSecurity: .plaintext,
      config: .defaults { $0.compression.enabledAlgorithms = [.gzip, .deflate] })
    let core = GRPCClient(transport: clientTransport)
    return Self(
      core: core,
      native: NativeBiliRPCTransport(client: core, maxConcurrentCalls: maxConcurrentCalls),
      server: server, serverTask: serverTask, probe: probe)
  }
  func request(_ offset: String, metadata: Metadata = [:]) async throws
    -> Bilibili_App_Dynamic_V2_DynAllReply
  {
    var req = Bilibili_App_Dynamic_V2_DynAllReq()
    req.offset = offset
    return try await native.unary(
      req, response: Bilibili_App_Dynamic_V2_DynAllReply.self,
      descriptor: BiliRPCMethod.dynAll.descriptor, metadata: metadata)
  }
  func waitForRequests(_ count: Int, cancellations: Int = 0) async throws {
    for _ in 0..<400 {
      if await probe.requests.count >= count, await probe.cancelled >= cancellations { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw BiliRPCError.deadlineExceeded
  }
  func close() async {
    await native.shutdown(grace: .milliseconds(100))
    server.beginGracefulShutdown()
    serverTask.cancel()
    _ = await serverTask.result
  }
}

// Send HTTP status without grpc-status to test the HTTP-to-RPC failure mapping on the wire.
private final class HTTP503Fixture: ChannelInboundHandler {
  typealias InboundIn = HTTP2Frame.FramePayload
  typealias OutboundOut = HTTP2Frame.FramePayload
  var sent = false
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !sent else { return }
    sent = true
    let headers = HPACKHeaders([(":status", "503"), ("content-type", "application/grpc")])
    context.writeAndFlush(
      wrapOutboundOut(.headers(.init(headers: headers, endStream: true))), promise: nil)
  }
}

final class RPCPipelineTests: XCTestCase, @unchecked Sendable {
  func testRealHTTP2LargeMessagesGzipAndBinaryMetadata() async throws {
    let fixture = try await LoopbackRPC.start()
    do {
      let body = String(repeating: "framing-fixture", count: 1024)
      var headers = Metadata()
      headers.addBinary([0, 1, 2, 127, 128, 255], forKey: "fixture-bin")
      let reply = try await fixture.request(body, metadata: headers)
      XCTAssertEqual(reply.dynamicList.historyOffset, body)
      let observed = await fixture.probe.requests
      XCTAssertEqual(observed[0].0, body)
      XCTAssertEqual(Array(observed[0].1[binaryValues: "fixture-bin"]), [[0, 1, 2, 127, 128, 255]])
      // Observe the actual negotiated encoding and successful trailer on the same native pool.
      var request = Bilibili_App_Dynamic_V2_DynAllReq()
      request.offset = body
      var options = CallOptions.defaults
      options.timeout = .seconds(3)
      let result = try await fixture.core.unary(
        request: ClientRequest(message: request),
        descriptor: BiliRPCMethod.dynAll.descriptor,
        serializer: ProtobufSerializer<Bilibili_App_Dynamic_V2_DynAllReq>(),
        deserializer: ProtobufDeserializer<Bilibili_App_Dynamic_V2_DynAllReply>(), options: options
      ) { response in
        (
          try response.message, Array(response.metadata[stringValues: "grpc-encoding"]),
          Array(try response.trailingMetadata[stringValues: "fixture-trailer"])
        )
      }
      XCTAssertEqual(result.0.dynamicList.historyOffset, body)
      XCTAssertEqual(result.1, ["gzip"])
      XCTAssertEqual(result.2, ["ok"])
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }
  func testNonzeroTrailerAfterMessageFailsInsteadOfReturningHTTP200Success() async throws {
    let fixture = try await LoopbackRPC.start()
    do {
      do {
        _ = try await fixture.request("bad-trailer")
        XCTFail("failed trailer was ignored")
      } catch {
        XCTAssertEqual(error as? BiliRPCError, .permissionDenied)
        XCTAssertFalse(String(describing: error).contains("fixture secret"))
      }
      let next = try await fixture.request("next")
      XCTAssertEqual(next.dynamicList.historyOffset, "next")
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }
  func testRealStreamCancellationIsIsolatedAndShutdownDrainsWithDeadline() async throws {
    let fixture = try await LoopbackRPC.start()
    do {
      let first = Task { try await fixture.request("block") }
      try await fixture.waitForRequests(1)
      let second = Task { try await fixture.request("another stream") }
      first.cancel()
      do {
        _ = try await first.value
        XCTFail("cancelled stream")
      } catch { XCTAssertTrue(error is CancellationError) }
      let next = try await second.value
      XCTAssertEqual(next.dynamicList.historyOffset, "another stream")
      try await fixture.waitForRequests(2, cancellations: 1)
      let blocked = Task { try await fixture.request("block") }
      try await fixture.waitForRequests(3)
      let clock = ContinuousClock()
      let start = clock.now
      await fixture.native.shutdown(grace: .milliseconds(100))
      XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
      do {
        _ = try await blocked.value
        XCTFail("shutdown did not cancel stream")
      } catch { XCTAssertTrue(error is CancellationError || error is BiliRPCError) }
      do {
        _ = try await fixture.request("closed")
        XCTFail("new stream during shutdown")
      } catch { XCTAssertEqual(error as? BiliRPCError, .shutdown) }
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }
  func testLimitsAndFreshTransportShutdownDoNotStartConnection() async throws {
    let fresh = try NativeBiliRPCTransport()
    await fresh.shutdown(grace: .zero)
    do {
      _ = try await fresh.unary(
        Bilibili_App_Dynamic_V2_DynAllReq(), response: Bilibili_App_Dynamic_V2_DynAllReply.self,
        descriptor: BiliRPCMethod.dynAll.descriptor, metadata: [:])
      XCTFail("closed fresh transport")
    } catch { XCTAssertEqual(error as? BiliRPCError, .shutdown) }
    let fixture = try await LoopbackRPC.start(maxConcurrentCalls: 1)
    do {
      let blocked = Task { try await fixture.request("block") }
      try await fixture.waitForRequests(1)
      do {
        _ = try await fixture.request("overflow")
        XCTFail("unbounded concurrency")
      } catch { XCTAssertEqual(error as? BiliRPCError, .resourceLimit) }
      blocked.cancel()
      _ = await blocked.result
      let large = String(repeating: "x", count: 1024 * 1024 + 1)
      do {
        _ = try await fixture.request(large)
        XCTFail("oversized request")
      } catch { XCTAssertEqual(error as? BiliRPCError, .resourceLimit) }
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }
  func testHTTP503IsTypedUnavailable() async throws {
    let listener = try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.configureHTTP2Pipeline(mode: .server) { stream in
          stream.pipeline.addHandler(HTTP503Fixture())
        }.map { _ in () }
      }.bind(host: "127.0.0.1", port: 0).get()
    let port = try XCTUnwrap(listener.localAddress?.port)
    let transport = try HTTP2ClientTransport.TransportServices(
      target: .ipv4(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
    let native = NativeBiliRPCTransport(client: GRPCClient(transport: transport))
    do {
      _ = try await native.unary(
        Bilibili_App_Dynamic_V2_DynAllReq(), response: Bilibili_App_Dynamic_V2_DynAllReply.self,
        descriptor: BiliRPCMethod.dynAll.descriptor, metadata: [:])
      XCTFail("HTTP 503 must fail")
    } catch { XCTAssertEqual(error as? BiliRPCError, .unavailable) }
    await native.shutdown(grace: .milliseconds(100))
    try await listener.close().get()
  }
  func testCompressedResponseCannotBypassEightMiBLimit() async throws {
    let fixture = try await LoopbackRPC.start()
    do {
      do {
        _ = try await fixture.request("oversized-response")
        XCTFail("uncompressed response limit")
      } catch {
        XCTAssertTrue(
          error as? BiliRPCError == .resourceLimit || error as? BiliRPCError == .serverStatus(13))
      }
      let next = try await fixture.request("after-limit")
      XCTAssertEqual(next.dynamicList.historyOffset, "after-limit")
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

}
