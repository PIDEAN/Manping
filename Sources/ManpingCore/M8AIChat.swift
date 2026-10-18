import CryptoKit
import Foundation

public struct AIResponseOptions: Sendable, Equatable {
  public var temperature: Double?
  public var maxTokens: Int?
  /// Claude `output_config.effort` (low/medium/high/xhigh/max); ignored by other families.
  public var effort: String?
  public init(temperature: Double? = nil, maxTokens: Int? = nil, effort: String? = nil) {
    self.temperature = temperature; self.maxTokens = maxTokens; self.effort = effort
  }
}
public struct AIHTTPStream: Sendable {
  public let status: Int
  public let chunks: AsyncThrowingStream<Data, Error>
  public let cancel: @Sendable () -> Void
  public init(status: Int, chunks: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void = {}) {
    self.status = status; self.chunks = chunks; self.cancel = cancel
  }
}
public protocol AIHTTPTransport: Sendable {
  func stream(_ request: URLRequest) async throws -> AIHTTPStream
}
private final class AIRejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
      ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
}
public struct AIURLSessionTransport: AIHTTPTransport {
  public init() {}
  public func stream(_ request: URLRequest) async throws -> AIHTTPStream {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 300
    let session = URLSession(configuration: configuration, delegate: AIRejectRedirects(), delegateQueue: nil)
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse else {
        session.invalidateAndCancel(); throw AIChatFailure.invalidResponse
      }
      let chunks = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(128)) { continuation in
        let task = Task {
          do {
            var buffer = Data()
            for try await byte in bytes {
              try Task.checkCancellation()
              buffer.append(byte)
              if byte == 10 || buffer.count >= 2048 {
                switch continuation.yield(buffer) {
                case .terminated: throw CancellationError()
                case .dropped: throw AIChatFailure.invalidResponse
                case .enqueued: break
                @unknown default: throw AIChatFailure.invalidResponse
                }
                buffer.removeAll(keepingCapacity: true)
              }
            }
            if !buffer.isEmpty { continuation.yield(buffer) }
            continuation.finish()
          } catch { continuation.finish(throwing: error) }
          session.invalidateAndCancel()
        }
        continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
      }
      return AIHTTPStream(status: response.statusCode, chunks: chunks, cancel: { session.invalidateAndCancel() })
    } catch { session.invalidateAndCancel(); throw error }
  }
}

public enum AIChatRequestPlanner {
  public static func family(_ provider: AIProvider) -> AIProtocolFamily {
    switch provider {
    case .anthropic: .anthropic
    case .chatGPTPlan: .responses
    case .gemini: .gemini
    case .ollama: .ollama
    default: .openAI
    }
  }
  private static func validHeader(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 16_384 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
  }
  private static func escaped(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? ""
  }
  /// Claude models that take adaptive thinking + effort and reject `temperature`.
  static func isCurrentClaude(_ model: String) -> Bool {
    ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5"].contains { model.hasPrefix($0) }
  }
  /// Models that accept the server-side refusal fallback (`fallbacks: "default"`).
  static func supportsDefaultFallback(_ model: String) -> Bool {
    ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
  }
  static func endpoint(_ value: String) throws -> URLComponents {
    guard let components = URLComponents(string: value), let host = components.host,
      components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
      components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())) else {
      throw AIChatFailure.invalidEndpoint
    }
    return components
  }
  public static func request(provider: AIProvider, configuration: AIProviderConfiguration, secrets: AIProviderSecrets,
    model: String, prompt: String, streaming: Bool = true, options: AIResponseOptions = .init(), bearerToken: String? = nil) throws -> URLRequest {
    guard !model.isEmpty, model.utf8.count <= 512, !model.unicodeScalars.contains(where: { $0.value < 32 }),
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 2_097_152,
      options.temperature == nil || (options.temperature!.isFinite && (0...2).contains(options.temperature!)),
      options.maxTokens == nil || (1...1_048_576).contains(options.maxTokens!) else { throw AIChatFailure.missingConfiguration }
    var key = secrets.key
    if provider == .mistral, configuration.useCodestral { key = secrets.codestralKey ?? "" }
    if provider != .ollama, !validHeader(key) { throw AIChatFailure.missingConfiguration }
    var endpointText = configuration.endpoint ?? provider.defaultEndpoint ?? ""
    // The plan bearer only ever goes to the public Responses API; the public JSON
    // configuration cannot redirect it to another host.
    if provider == .chatGPTPlan { endpointText = AIProvider.chatGPTPlan.defaultEndpoint! }
    if provider == .spark, model == "x1", configuration.endpoint == nil {
      endpointText = "https://spark-api-open.xf-yun.com/v2"
    }
    if provider == .mistral, configuration.useCodestral, configuration.endpoint == nil {
      endpointText = "https://codestral.mistral.ai/v1"
    }
    var url = try endpoint(endpointText)
    var path = url.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    var body: [String: Any] = ["model": model, "stream": streaming,
      "messages": [["role": "user", "content": prompt]]]
    var headers: [String: String] = ["Content-Type": "application/json",
      "Accept": streaming && provider != .ollama ? "text/event-stream" : "application/json"]
    switch provider {
    case .azureOpenAI:
      path += "/openai/deployments/" + escaped(model) + "/chat/completions"
      url.queryItems = [URLQueryItem(name: "api-version", value: configuration.apiVersion ?? "2024-10-21")]
      headers["api-key"] = key
    case .azureAI:
      // Azure AI inference has its own root route and auth/version, not deployments.
      if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
      url.queryItems = [URLQueryItem(name: "api-version", value: configuration.apiVersion ?? "2024-05-01-preview")]
      headers["api-key"] = key
    case .anthropic:
      if path.isEmpty { path = "/v1" }
      if !path.hasSuffix("/messages") { path += "/messages" }
      headers["x-api-key"] = key; headers["anthropic-version"] = "2023-06-01"
      body["max_tokens"] = options.maxTokens ?? 16_000
      if isCurrentClaude(model) {
        // Thinking cannot be disabled on these models; effort is the depth/cost control.
        body["thinking"] = ["type": "adaptive"]
        body["output_config"] = ["effort": options.effort ?? "medium"]
        // Refusal fallback is a first-party API feature; custom proxies may reject it.
        if supportsDefaultFallback(model), url.host?.lowercased() == "api.anthropic.com" {
          headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
          body["fallbacks"] = "default"
        }
      }
    case .chatGPTPlan:
      // Public Responses API only; plan usage requires store:false and stream:true on every request.
      guard url.scheme == "https", url.host == "api.openai.com", url.port == nil, path == "/v1" else { throw AIChatFailure.invalidEndpoint }
      path += "/responses"
      headers["Authorization"] = "Bearer " + key
      headers["Accept"] = "text/event-stream"
      body = ["model": model, "store": false, "stream": true,
        "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]]]
    case .gemini:
      if !path.hasSuffix("/v1") && !path.hasSuffix("/v1beta") { path += "/v1beta" }
      let modelID = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
      path += "/models/" + escaped(modelID) + (streaming ? ":streamGenerateContent" : ":generateContent")
      // Google's REST endpoint accepts an API-key header; secrets never enter the URL.
      headers["x-goog-api-key"] = key
      if streaming { url.queryItems = [URLQueryItem(name: "alt", value: "sse")] }
      body = ["contents": [["role": "user", "parts": [["text": prompt]]]]]
      var generation: [String: Any] = [:]
      if let temperature = options.temperature { generation["temperature"] = temperature }
      if let tokens = options.maxTokens { generation["maxOutputTokens"] = tokens }
      if !generation.isEmpty { body["generationConfig"] = generation }
    case .ollama:
      if !path.hasSuffix("/api/chat") { path += "/api/chat" }
      var values: [String: Any] = [:]
      if let temperature = options.temperature { values["temperature"] = temperature }
      if let tokens = options.maxTokens { values["num_predict"] = tokens }
      if !values.isEmpty { body["options"] = values }
    default:
      if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
      if provider == .ernie {
        guard let token = bearerToken, validHeader(token), let secret = secrets.secret, validHeader(secret) else {
          throw AIChatFailure.missingConfiguration
        }
        headers["Authorization"] = "Bearer " + token
      } else { headers["Authorization"] = "Bearer " + key }
      if provider == .openAI, let organization = configuration.organization, !organization.isEmpty {
        guard validHeader(organization) else { throw AIChatFailure.missingConfiguration }
        headers["OpenAI-Organization"] = organization
      }
    }
    if ![.gemini, .ollama, .chatGPTPlan].contains(provider) {
      // Current Claude models reject sampling parameters.
      if let temperature = options.temperature, !(provider == .anthropic && isCurrentClaude(model)) { body["temperature"] = temperature }
      if let tokens = options.maxTokens { body["max_tokens"] = tokens }
    }
    url.percentEncodedPath = path
    guard let target = url.url else { throw AIChatFailure.invalidEndpoint }
    var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }
  public static func ernieAuthorization(accessKey: String, secret: String, date: Date) throws -> String {
    guard validHeader(accessKey), validHeader(secret), !accessKey.contains("/") else { throw AIChatFailure.missingConfiguration }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime]; format.timeZone = TimeZone(secondsFromGMT: 0)
    let prefix = "bce-auth-v1/\(accessKey)/\(format.string(from: date))/3600"
    func hmac(_ key: String, _ value: String) -> String {
      HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: Data(key.utf8)))
        .map { String(format: "%02x", $0) }.joined()
    }
    let signingKey = hmac(secret, prefix)
    let canonical = "GET\n/v1/BCE-BEARER/token\nexpireInSeconds=3600\nhost:iam.bj.baidubce.com"
    return prefix + "/host/" + hmac(signingKey, canonical)
  }
}

public struct AIChatClient: Sendable {
  private let transport: any AIHTTPTransport
  private let ernieAuthorizationEndpoint: URL
  public init(transport: any AIHTTPTransport = AIURLSessionTransport(),
    ernieAuthorizationEndpoint: URL = URL(string: "https://iam.bj.baidubce.com/v1/BCE-BEARER/token?expireInSeconds=3600")!) {
    self.transport = transport; self.ernieAuthorizationEndpoint = ernieAuthorizationEndpoint
  }
  /// `refreshBearer` is used once, for the ChatGPT plan only, when the API rejects a token with 401.
  public func response(provider: AIProvider, configuration: AIProviderConfiguration, secrets: AIProviderSecrets,
    model: String, prompt: String, streaming requestedStreaming: Bool = true, options: AIResponseOptions = .init(),
    refreshBearer: (@Sendable () async throws -> String)? = nil, retryDelay: Duration = .seconds(1)) -> AsyncThrowingStream<String, Error> {
    // On-device: no request, no credentials, nothing leaves the Mac.
    if provider == .appleLocal { return AppleLocalModel.stream(prompt: prompt) }
    // ChatGPT plan usage only accepts streamed requests; text is still delivered incrementally.
    let streaming = provider == .chatGPTPlan ? true : requestedStreaming
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try Task.checkCancellation()
          // Validate the entire user configuration before Ernie's credential-bearing
          // IAM request, just as for the other providers' first request.
          _ = try AIChatRequestPlanner.request(provider: provider, configuration: configuration,
            secrets: secrets, model: model, prompt: prompt, streaming: streaming, options: options,
            bearerToken: provider == .ernie ? "validation-only" : nil)
          let bearer = provider == .ernie ? try await authorizeErnie(secrets: secrets) : nil
          let family = AIChatRequestPlanner.family(provider)
          var credentials = secrets
          var attempt = 0, refreshed = false
          var response: AIHTTPStream
          while true {
            let request = try AIChatRequestPlanner.request(provider: provider, configuration: configuration,
              secrets: credentials, model: model, prompt: prompt, streaming: streaming, options: options, bearerToken: bearer)
            response = try await transport.stream(request)
            if (200...299).contains(response.status) { break }
            let failure = await Self.failure(response, family: family)
            response.cancel()
            if provider == .chatGPTPlan, response.status == 401, !refreshed, let refreshBearer {
              refreshed = true; credentials.key = try await refreshBearer(); continue
            }
            // Bounded backoff only for temporary unavailability; never a different billing path.
            if provider == .chatGPTPlan, failure == .planUnavailable, attempt < 2 {
              attempt += 1; try await Task.sleep(for: retryDelay * attempt); continue
            }
            throw failure
          }
          defer { response.cancel() }
          if streaming {
            var parser = AIStreamParser(family: family)
            for try await chunk in response.chunks {
              try Task.checkCancellation()
              for text in try parser.append(chunk) {
                if case .terminated = continuation.yield(text) { throw CancellationError() }
              }
              if parser.finished { break }
            }
            for text in try parser.finish() { continuation.yield(text) }
          } else {
            let body = try await Self.body(response)
            continuation.yield(try AIStreamParser.complete(body, family: family))
          }
          try Task.checkCancellation()
          continuation.finish()
        } catch {
          if Task.isCancelled || error is CancellationError { continuation.finish(throwing: CancellationError()) }
          else if let known = error as? AIChatFailure { continuation.finish(throwing: known) }
          else if let plan = error as? ChatGPTPlanError {
            // Token refresh failures keep their meaning (sign in again vs. network) for the UI.
            continuation.finish(throwing: plan == .signInRequired ? AIChatFailure.planSignInRequired : plan)
          }
          else { continuation.finish(throwing: AIChatFailure.transport((error as NSError).code)) }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
  private func authorizeErnie(secrets: AIProviderSecrets) async throws -> String {
    guard let secret = secrets.secret else { throw AIChatFailure.missingConfiguration }
    let authorization = try AIChatRequestPlanner.ernieAuthorization(accessKey: secrets.key, secret: secret, date: Date())
    // Production default is fixed to the SDK's IAM route. Tests may inject a local
    // fixture endpoint; insecure remote overrides are rejected before sending keys.
    guard var components = URLComponents(url: ernieAuthorizationEndpoint, resolvingAgainstBaseURL: false) else { throw AIChatFailure.invalidEndpoint }
    let host = components.host?.lowercased() ?? ""
    let fixedIAM = components.scheme == "https" && host == "iam.bj.baidubce.com"
      && (components.port == nil || components.port == 443)
      && components.path == "/v1/BCE-BEARER/token" && components.query == "expireInSeconds=3600"
    let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    guard fixedIAM || loopback else { throw AIChatFailure.invalidEndpoint }
    components.query = nil
    _ = try AIChatRequestPlanner.endpoint(components.string ?? "")
    var request = URLRequest(url: ernieAuthorizationEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.httpMethod = "GET"; request.setValue(authorization, forHTTPHeaderField: "Authorization")
    let response = try await transport.stream(request)
    defer { response.cancel() }
    try Self.validate(response.status)
    let data = try await Self.body(response)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = (object["token"] ?? object["Token"]) as? String, !token.isEmpty else { throw AIChatFailure.providerError }
    return token
  }
  /// Maps an error response, using the structured `error.code` where the family defines one.
  private static func failure(_ response: AIHTTPStream, family: AIProtocolFamily) async -> AIChatFailure {
    var data = Data()
    if family == .responses {
      do {
        for try await chunk in response.chunks {
          guard data.count + chunk.count <= 65_536 else { break }
          data.append(chunk)
        }
      } catch {}
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      if let error = object?["error"] as? [String: Any], let code = error["code"] as? String,
        let mapped = AIStreamParser.responsesFailure(code: code) { return mapped }
      switch response.status {
      case 401: return .planSignInRequired
      case 403: return .planNotEligible
      case 503: return .planUnavailable
      default: break
      }
    }
    do { try validate(response.status) } catch let error as AIChatFailure { return error } catch {}
    return .httpStatus(response.status)
  }
  private static func validate(_ status: Int) throws {
    switch status {
    case 200...299: return
    case 401, 403: throw AIChatFailure.unauthorized
    case 429: throw AIChatFailure.rateLimited
    default: throw AIChatFailure.httpStatus(status)
    }
  }
  private static func body(_ response: AIHTTPStream) async throws -> Data {
    var data = Data()
    for try await chunk in response.chunks {
      try Task.checkCancellation()
      guard data.count + chunk.count <= 8_388_608 else { throw AIChatFailure.invalidResponse }
      data.append(chunk)
    }
    return data
  }
}
