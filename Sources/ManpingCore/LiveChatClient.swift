import Foundation

/// One live chat connection: authenticates, sends the 30 s heartbeat and yields decoded events.
/// The stream finishes when the socket closes; the caller decides whether to reconnect (with a
/// fresh token from `liveChatEndpoint`).
public final class LiveChatClient: @unchecked Sendable {
  private let session: URLSession
  private let lock = NSLock()
  private var socket: URLSessionWebSocketTask?
  private var heartbeat: Task<Void, Never>?

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    session = URLSession(configuration: configuration)
  }
  deinit { session.invalidateAndCancel() }

  public func connect(_ endpoint: LiveChatEndpoint) -> AsyncStream<LiveChatEvent> {
    disconnect()
    var request = URLRequest(url: endpoint.urls[0])
    request.setValue(BiliService.browserUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
    let socket = session.webSocketTask(with: request)
    let (stream, continuation) = AsyncStream<LiveChatEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
    let beat = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        guard !Task.isCancelled else { return }
        socket.send(.data(LiveChatPacket.heartbeat)) { _ in }
      }
    }
    lock.withLock { self.socket = socket; self.heartbeat = beat }
    continuation.onTermination = { _ in
      beat.cancel()
      socket.cancel(with: .goingAway, reason: nil)
    }
    socket.resume()
    socket.send(.data(LiveChatPacket.authorization(endpoint))) { error in
      if error != nil { continuation.finish(); return }
      // The first heartbeat right after auth returns the popularity value immediately.
      socket.send(.data(LiveChatPacket.heartbeat)) { _ in }
    }
    Self.receive(socket, continuation)
    return stream
  }

  public func disconnect() {
    let (socket, beat) = lock.withLock { () -> (URLSessionWebSocketTask?, Task<Void, Never>?) in
      defer { self.socket = nil; self.heartbeat = nil }
      return (self.socket, self.heartbeat)
    }
    beat?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
  }

  private static func receive(_ socket: URLSessionWebSocketTask, _ continuation: AsyncStream<LiveChatEvent>.Continuation) {
    socket.receive { result in
      switch result {
      case .success(let message):
        if case .data(let data) = message {
          let decoded = LiveChatPacket.decode(data)
          // A refused auth ends this connection; the caller retries with a fresh token.
          if decoded.authRejected {
            socket.cancel(with: .normalClosure, reason: nil)
            continuation.finish()
            return
          }
          for event in decoded.events { continuation.yield(event) }
        }
        receive(socket, continuation)
      case .failure:
        continuation.finish()
      }
    }
  }
}
