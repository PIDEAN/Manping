import Foundation
import Network

/// Accepts exactly one GET to `http://127.0.0.1:<port>/auth/callback` (never `localhost`,
/// per the Sign in with ChatGPT redirect rules), answers with a static page, then closes.
public final class ChatGPTLoopbackReceiver: ChatGPTCallbackReceiving, @unchecked Sendable {
  public static let path = "/auth/callback"
  private let queue = DispatchQueue(label: "io.github.pidean.manping.chatgpt.callback")
  private let lock = NSLock()
  private var listener: NWListener?
  private var received: URLComponents?
  private var failure: Error?
  private var waiter: CheckedContinuation<URLComponents, Error>?
  private var expectedState = ""

  public init() {}

  public func start(expectedState: String) async throws -> URL {
    lock.withLock { self.expectedState = expectedState }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.acceptLocalOnly = true
    let listener = try NWListener(using: parameters)
    lock.withLock { self.listener = listener }
    listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let once = ResumeOnce(continuation)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if let port = listener.port?.rawValue { once.resume(.success(port)) } else { once.resume(.failure(ChatGPTPlanError.network)) }
        case .failed, .cancelled: once.resume(.failure(ChatGPTPlanError.network))
        default: break
        }
      }
      listener.start(queue: queue)
    }
    return URL(string: "http://127.0.0.1:\(port)\(Self.path)")!
  }

  public func callback() async throws -> URLComponents {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let received { lock.unlock(); continuation.resume(returning: received); return }
        if let failure { lock.unlock(); continuation.resume(throwing: failure); return }
        waiter = continuation
        lock.unlock()
      }
    } onCancel: { [weak self] in self?.deliver(.failure(ChatGPTPlanError.cancelled)) }
  }
  private static func state(of components: URLComponents) -> String? {
    components.queryItems?.first { $0.name == "state" }?.value
  }
  /// The state is fixed before listening starts, so matching needs no buffering or ordering.
  private func accept(_ components: URLComponents) -> Bool {
    let expected = lock.withLock { expectedState }
    return !expected.isEmpty && Self.state(of: components) == expected
  }

  public func stop() {
    let current = lock.withLock { () -> NWListener? in let value = listener; listener = nil; return value }
    current?.cancel()
    deliver(.failure(ChatGPTPlanError.cancelled))
  }

  private func deliver(_ result: Result<URLComponents, Error>) {
    lock.lock()
    guard received == nil, failure == nil else { lock.unlock(); return }
    switch result {
    case .success(let value): received = value
    case .failure(let error): failure = error
    }
    let continuation = waiter; waiter = nil
    lock.unlock()
    continuation?.resume(with: result)
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
      guard let self else { connection.cancel(); return }
      let head = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n", maxSplits: 1).first ?? ""
      let parts = head.split(separator: " ")
      var components: URLComponents?
      if parts.count >= 2, parts[0] == "GET", let target = URLComponents(string: "http://127.0.0.1" + parts[1]),
        target.path == Self.path { components = target }
      // A callback with another attempt's (or no) state is refused; the listener keeps waiting.
      let accepted = components.map { self.accept($0) } ?? false
      let status = components == nil ? "404 Not Found" : (accepted ? "200 OK" : "400 Bad Request")
      let body = components == nil ? "Not Found" : accepted
        ? "<!doctype html><meta charset=utf-8><title>满屏</title><p style=\"font:16px -apple-system;margin:40px\">ChatGPT 登录已完成，可以关闭此页面并回到满屏。</p>"
        : "<!doctype html><meta charset=utf-8><title>满屏</title><p style=\"font:16px -apple-system;margin:40px\">此登录回调无效或已过期。</p>"
      let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
      if let components, accepted { self.deliver(.success(components)) }
    }
  }
}

private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
  func resume(_ result: Result<Value, Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<Value, Error>? in let value = continuation; continuation = nil; return value }
    pending?.resume(with: result)
  }
}
