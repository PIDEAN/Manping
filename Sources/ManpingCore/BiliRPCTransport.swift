import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import GRPCProtobuf
import SwiftProtobuf

public enum BiliRPCError: Error, Sendable, Equatable {
  case needsLogin, authenticationFailure, permissionDenied, unavailable, deadlineExceeded
  case serverStatus(Int)
  case invalidPayload(String)
  case invalidArgument, resourceLimit, shutdown

  static func sanitized(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled { return CancellationError() }
    if let error = error as? BiliRPCError { return error }
    if let error = error as? RPCError {
      switch error.code {
      case .unauthenticated: return BiliRPCError.needsLogin
      case .permissionDenied: return BiliRPCError.permissionDenied
      case .unavailable: return BiliRPCError.unavailable
      case .deadlineExceeded: return BiliRPCError.deadlineExceeded
      case .resourceExhausted: return BiliRPCError.resourceLimit
      case .cancelled: return CancellationError()
      default: return BiliRPCError.serverStatus(error.code.rawValue)
      }
    }
    if let error = error as? AuthFailure {
      if case .needsLogin = error { return BiliRPCError.needsLogin }
      return BiliRPCError.authenticationFailure
    }
    // Never expose server messages, metadata, or an underlying error carrying credentials.
    return BiliRPCError.unavailable
  }
}

public protocol BiliRPCTransport: Sendable {
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response
  func shutdown(grace: Duration) async
}

// Owns a single shared HTTP/2 connection pool. Individual RPC cancellation only cancels its stream.
public actor NativeBiliRPCTransport: BiliRPCTransport {
  public static let host = "grpc.biliapi.net"
  private let client: GRPCClient<HTTP2ClientTransport.TransportServices>
  private var connections: Task<Void, Error>?
  private var calls: [UUID: @Sendable () -> Void] = [:]
  private var stopping: Task<Void, Never>?
  private var closed = false
  private let maxConcurrentCalls: Int

  public init(maxConcurrentCalls: Int = 16) throws {
    guard (1...64).contains(maxConcurrentCalls) else { throw BiliRPCError.invalidArgument }
    self.maxConcurrentCalls = maxConcurrentCalls
    let transport = try HTTP2ClientTransport.TransportServices(
      target: .dns(host: Self.host, port: 443), transportSecurity: .tls,
      config: .defaults { $0.compression.enabledAlgorithms = [.gzip, .deflate] })
    client = GRPCClient(transport: transport)
  }

  // Test injection retains the exact production NIOTS pipeline without opening a remote connection.
  init(client: GRPCClient<HTTP2ClientTransport.TransportServices>, maxConcurrentCalls: Int = 16) {
    self.client = client
    self.maxConcurrentCalls = maxConcurrentCalls
  }

  public func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    try Task.checkCancellation()
    guard !closed else { throw BiliRPCError.shutdown }
    guard calls.count < maxConcurrentCalls else { throw BiliRPCError.resourceLimit }
    // Reject locally before opening a stream; the library also enforces this limit on the wire.
    guard try request.serializedData().count <= 1024 * 1024 else {
      throw BiliRPCError.resourceLimit
    }
    let client = self.client
    if connections == nil { connections = Task { try await client.runConnections() } }
    let id = UUID()
    let task = Task {
      try Task.checkCancellation()
      var options = CallOptions.defaults
      options.timeout = .seconds(20)
      options.maxRequestMessageBytes = 1024 * 1024
      options.maxResponseMessageBytes = 8 * 1024 * 1024
      return try await client.unary(
        request: ClientRequest(message: request, metadata: metadata), descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(), deserializer: ProtobufDeserializer<Response>(),
        options: options
      ) { response in
        // ClientResponse.message checks final grpc-status, including trailers after a message.
        try response.message
      }
    }
    calls[id] = { task.cancel() }
    defer { calls.removeValue(forKey: id) }
    do {
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch { throw BiliRPCError.sanitized(error) }
  }

  public func shutdown(grace: Duration = .seconds(2)) async {
    if let stopping {
      await stopping.value
      return
    }
    guard !closed else { return }
    closed = true
    client.beginGracefulShutdown()
    guard let connections else { return }
    let cancelCalls = Array(calls.values)
    // Clamp caller-provided grace to keep shutdown bounded, even during a broken peer connection.
    let deadline = min(max(grace, .zero), .seconds(5))
    let stopping = Task {
      let timer = Task {
        do { try await Task.sleep(for: deadline) } catch { return }
        for cancel in cancelCalls { cancel() }
        connections.cancel()
      }
      _ = await connections.result
      timer.cancel()
    }
    self.stopping = stopping
    await stopping.value
  }

  deinit {
    connections?.cancel()
    client.beginGracefulShutdown()
    for cancel in calls.values { cancel() }
  }
}

// Routes are pinned to BiliApis.cs at 22fdf8ca, including its show.v1/schema namespace difference.
enum BiliRPCMethod: String, CaseIterable, Sendable {
  case mainList = "bilibili.main.community.reply.v1.Reply/MainList"
  case detailList = "bilibili.main.community.reply.v1.Reply/DetailList"
  case dynAll = "bilibili.app.dynamic.v2.Dynamic/DynAll"
  case dynVideo = "bilibili.app.dynamic.v2.Dynamic/DynVideo"
  case dynAllPersonal = "bilibili.app.dynamic.v2.Dynamic/DynAllPersonal"
  case dynVideoPersonal = "bilibili.app.dynamic.v2.Dynamic/DynVideoPersonal"
  case dynSpace = "bilibili.app.dynamic.v2.Dynamic/DynSpace"
  case history = "bilibili.app.interface.v1.History/CursorV2"
  case popular = "bilibili.app.show.v1.Popular/Index"
  case rank = "bilibili.app.show.v1.Rank/RankRegion"
  var descriptor: MethodDescriptor {
    let parts = rawValue.split(separator: "/", maxSplits: 1)
    return MethodDescriptor(
      fullyQualifiedService: String(parts[0]), method: String(parts[1]), type: .unary)
  }
}
