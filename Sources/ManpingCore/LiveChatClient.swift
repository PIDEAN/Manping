import Foundation

public enum LiveChatFailure: Error, Sendable, Equatable {
  case authentication(Int?)
  case riskControl(Int)
  case handshakeTimeout, budgetExhausted, identityChanged
  case network(String)
  public var terminal: Bool {
    switch self {
    case .authentication, .riskControl, .identityChanged, .budgetExhausted: true
    default: false
    }
  }
  public static func classify(_ error: Error) -> LiveChatFailure {
    if let failure = error as? LiveChatFailure { return failure }
    if case BiliError.api(let code, _) = error {
      if code == -352 { return .riskControl(code) }
      if [-101, -111, 1001].contains(code) { return .authentication(code) }
    }
    if case BiliError.http(let status) = error {
      if [401, 403].contains(status) { return .authentication(status) }
      if [412, 429].contains(status) { return .riskControl(status) }
    }
    return .network(String(describing: error))
  }
}

/// One finite budget for endpoint preparation failures, alternate hosts and later reconnects.
/// A message or successful auth never replenishes it. A new room/identity gets a new budget.
public actor LiveChatBudget {
  public let limit: Int
  public private(set) var attempts = 0
  public init(limit: Int = 6) { self.limit = max(0, limit) }
  public func consume() -> Bool {
    guard attempts < limit else { return false }
    attempts += 1
    return true
  }
  public var remaining: Int { max(0, limit - attempts) }
}

public protocol LiveChatSocket: Sendable {
  func send(_ data: Data) async throws
  func receive() async throws -> Data
  /// Must unblock receive even when the receiver ignores Swift task cancellation.
  func cancel()
}
public protocol LiveChatSocketFactory: Sendable {
  func make(_ request: URLRequest) throws -> any LiveChatSocket
}
private final class URLSessionLiveSocket: LiveChatSocket, @unchecked Sendable {
  let task: URLSessionWebSocketTask
  init(_ task: URLSessionWebSocketTask) {
    self.task = task
    task.resume()
  }
  func send(_ data: Data) async throws {
    do { try await task.send(.data(data)) } catch { throw mapped(error) }
  }
  private func mapped(_ error: Error) -> Error {
    if let response = task.response as? HTTPURLResponse,
      [401, 403, 412, 429].contains(response.statusCode)
    {
      if [412, 429].contains(response.statusCode) {
        return LiveChatFailure.riskControl(response.statusCode)
      }
      return LiveChatFailure.authentication(response.statusCode)
    }
    return error
  }
  func receive() async throws -> Data {
    let message: URLSessionWebSocketTask.Message
    do { message = try await task.receive() } catch { throw mapped(error) }
    switch message {
    case .data(let data): return data
    case .string(let string): return Data(string.utf8)
    @unknown default: throw LiveChatFailure.network("Unknown socket frame")
    }
  }
  func cancel() { task.cancel(with: .goingAway, reason: nil) }
}
private final class URLSessionLiveFactory: LiveChatSocketFactory, @unchecked Sendable {
  let session: URLSession
  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    session = URLSession(configuration: configuration)
  }
  deinit { session.invalidateAndCancel() }
  func make(_ request: URLRequest) throws -> any LiveChatSocket {
    URLSessionLiveSocket(session.webSocketTask(with: request))
  }
}

/// Injectable socket and clock; every cleanup is owned by its connection generation.
public final class LiveChatClient: @unchecked Sendable {
  public typealias Sleep = @Sendable (Duration) async throws -> Void
  private let factory: any LiveChatSocketFactory
  private let sleep: Sleep
  private let handshakeTimeout: Duration
  private let reconnectDelay: Duration
  private let heartbeatInterval: Duration
  private let lock = NSLock()
  private var generation: UUID?
  private var worker: Task<Void, Never>?
  private var socket: (any LiveChatSocket)?
  public init(
    factory: (any LiveChatSocketFactory)? = nil, handshakeTimeout: Duration = .seconds(10),
    reconnectDelay: Duration = .seconds(3), heartbeatInterval: Duration = .seconds(30),
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.factory = factory ?? URLSessionLiveFactory()
    self.handshakeTimeout = handshakeTimeout
    self.reconnectDelay = reconnectDelay
    self.heartbeatInterval = heartbeatInterval
    self.sleep = sleep
  }
  deinit {
    worker?.cancel()
    socket?.cancel()
  }

  public func connect(
    _ endpoint: LiveChatEndpoint, budget: LiveChatBudget,
    isIdentityCurrent: @escaping @Sendable () async -> Bool
  ) -> AsyncThrowingStream<LiveChatEvent, Error> {
    disconnect()
    let id = UUID()
    let (stream, continuation) = AsyncThrowingStream<LiveChatEvent, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(512))
    lock.withLock { generation = id }
    continuation.onTermination = { [weak self] _ in self?.cancel(id) }
    let task = Task { [weak self] in
      guard let self else {
        continuation.finish()
        return
      }
      do {
        try await self.run(
          endpoint, id: id, budget: budget, isIdentityCurrent: isIdentityCurrent,
          continuation: continuation)
        continuation.finish()
      } catch is CancellationError { continuation.finish() } catch {
        continuation.finish(throwing: error)
      }
      self.cancel(id)
    }
    let installed = lock.withLock { () -> Bool in
      guard generation == id else { return false }
      worker = task
      return true
    }
    if !installed { task.cancel() }
    return stream
  }
  public func disconnect() {
    let current = lock.withLock { generation }
    if let current { cancel(current) }
  }
  private func cancel(_ id: UUID) {
    let owned = lock.withLock { () -> (Task<Void, Never>?, (any LiveChatSocket)?) in
      guard generation == id else { return (nil, nil) }
      let owned = (worker, socket)
      worker = nil
      socket = nil
      generation = nil
      return owned
    }
    owned.0?.cancel()
    owned.1?.cancel()
  }
  private func install(_ socket: any LiveChatSocket, id: UUID) throws {
    let installed = lock.withLock { () -> Bool in
      guard generation == id else { return false }
      self.socket = socket
      return true
    }
    guard installed else {
      socket.cancel()
      throw CancellationError()
    }
  }
  private func check(_ id: UUID, identity: @Sendable () async -> Bool) async throws {
    try Task.checkCancellation()
    guard lock.withLock({ generation == id }) else { throw CancellationError() }
    guard await identity() else { throw LiveChatFailure.identityChanged }
    try Task.checkCancellation()
    guard lock.withLock({ generation == id }) else { throw CancellationError() }
  }
  private func run(
    _ endpoint: LiveChatEndpoint, id: UUID, budget: LiveChatBudget,
    isIdentityCurrent: @escaping @Sendable () async -> Bool,
    continuation: AsyncThrowingStream<LiveChatEvent, Error>.Continuation
  ) async throws {
    guard !endpoint.urls.isEmpty else { throw LiveChatFailure.network("No chat hosts") }
    var index = 0
    while true {
      try await check(id, identity: isIdentityCurrent)
      let allowed = await budget.consume()
      try await check(id, identity: isIdentityCurrent)
      guard allowed else { throw LiveChatFailure.budgetExhausted }
      var request = URLRequest(url: endpoint.urls[index % endpoint.urls.count])
      index += 1
      request.setValue(BiliService.browserUserAgent, forHTTPHeaderField: "User-Agent")
      request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
      request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
      let connection: any LiveChatSocket
      do {
        connection = try factory.make(request)
        try install(connection, id: id)
        try await check(id, identity: isIdentityCurrent)
        let initial = try await handshake(
          connection, endpoint: endpoint, id: id, identity: isIdentityCurrent)
        try await check(id, identity: isIdentityCurrent)
        for event in initial { continuation.yield(event) }
        // The immediate heartbeat returns current popularity; errors end this attempt.
        try await connection.send(LiveChatPacket.heartbeat)
        try await check(id, identity: isIdentityCurrent)
        try await receive(
          connection, id: id, identity: isIdentityCurrent, continuation: continuation)
      } catch {
        let owned = lock.withLock { generation == id ? socket : nil }
        owned?.cancel()
        try await check(id, identity: isIdentityCurrent)
        let failure = LiveChatFailure.classify(error)
        if failure.terminal { throw failure }
        let remaining = await budget.remaining
        try await check(id, identity: isIdentityCurrent)
        guard remaining > 0 else { throw LiveChatFailure.budgetExhausted }
        try await sleep(reconnectDelay)
        try await check(id, identity: isIdentityCurrent)
      }
    }
  }
  private func handshake(
    _ connection: any LiveChatSocket, endpoint: LiveChatEndpoint, id: UUID,
    identity: @escaping @Sendable () async -> Bool
  ) async throws -> [LiveChatEvent] {
    let sleep = self.sleep
    let deadline = handshakeTimeout
    return try await withThrowingTaskGroup(of: [LiveChatEvent].self) { group in
      group.addTask {
        try await self.check(id, identity: identity)
        try await connection.send(LiveChatPacket.authorization(endpoint))
        try await self.check(id, identity: identity)
        while true {
          let decoded = LiveChatPacket.decode(try await connection.receive())
          try await self.check(id, identity: identity)
          if decoded.authRejected {
            if decoded.authCode == -352 { throw LiveChatFailure.riskControl(-352) }
            throw LiveChatFailure.authentication(decoded.authCode)
          }
          if decoded.events.contains(.connected) { return decoded.events }
        }
      }
      group.addTask {
        try await sleep(deadline)
        try Task.checkCancellation()
        throw LiveChatFailure.handshakeTimeout
      }
      do {
        let initial = try await group.next() ?? []
        group.cancelAll()
        return initial
      } catch {
        connection.cancel()
        group.cancelAll()
        throw error
      }
    }
  }
  private func receive(
    _ connection: any LiveChatSocket, id: UUID,
    identity: @escaping @Sendable () async -> Bool,
    continuation: AsyncThrowingStream<LiveChatEvent, Error>.Continuation
  ) async throws {
    let sleep = self.sleep
    let interval = heartbeatInterval
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        while true {
          try await sleep(interval)
          try Task.checkCancellation()
          try await self.check(id, identity: identity)
          try await connection.send(LiveChatPacket.heartbeat)
          try await self.check(id, identity: identity)
        }
      }
      group.addTask {
        while true {
          let decoded = LiveChatPacket.decode(try await connection.receive())
          try await self.check(id, identity: identity)
          if decoded.authRejected {
            if decoded.authCode == -352 { throw LiveChatFailure.riskControl(-352) }
            throw LiveChatFailure.authentication(decoded.authCode)
          }
          for event in decoded.events { continuation.yield(event) }
        }
      }
      do {
        _ = try await group.next()
        connection.cancel()
        group.cancelAll()
      } catch {
        connection.cancel()
        group.cancelAll()
        throw error
      }
    }
  }
}
