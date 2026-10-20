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
  public static func family(_ provider: AIProvider, model: String = "") -> AIProtocolFamily {
    if [.opencodeZen, .opencodeGo].contains(provider) { return AIOpenCodeRouting.family(provider: provider, model: model) }
    return switch provider {
    case .anthropic: .anthropic
    case .chatGPTPlan: .responses
    case .gemini: .gemini
    case .ollama: .ollama
    default: .openAI
    }
  }
  static func validHeader(_ value: String) -> Bool {
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
  /// Maps the protocol-neutral conversation onto each family: Anthropic top-level `system`,
  /// OpenAI-compatible `messages` with a leading system message, Responses `instructions` +
  /// `input`, Gemini `systemInstruction` + `contents` (user/model), Ollama `messages`. The budget's
  /// output limit becomes the family's own output cap; JSON mode follows the capability table.
  public static func request(provider: AIProvider, configuration: AIProviderConfiguration, secrets: AIProviderSecrets,
    model: String, conversation: AIConversationRequest, streaming: Bool = true, options: AIResponseOptions = .init(),
    bearerToken: String? = nil) throws -> URLRequest {
    let totalBytes = conversation.messages.reduce(conversation.system?.utf8.count ?? 0) { $0 + $1.text.utf8.count }
    guard !model.isEmpty, model.utf8.count <= 512, !model.unicodeScalars.contains(where: { $0.value < 32 }),
      let last = conversation.messages.last, last.role == .user, !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      conversation.messages.allSatisfy({ !$0.text.isEmpty }), totalBytes <= 8_388_608,
      options.temperature == nil || (options.temperature!.isFinite && (0...2).contains(options.temperature!)),
      options.maxTokens == nil || (1...1_048_576).contains(options.maxTokens!) else { throw AIChatFailure.missingConfiguration }
    if provider == .moonshot, model == "kimi-k3", conversation.messages.contains(where: { $0.role == .assistant }) {
      throw AIChatFailure.reasoningHistoryRequired
    }
    let system = conversation.system.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    let capability = AIStructuredCapability.of(provider: provider, configuration: configuration, model: model)
    let wantsJSON = conversation.format == .json
    // An explicit option wins; otherwise the planned budget sets the cap.
    let explicitTokens = options.maxTokens
    let plannedTokens = explicitTokens == nil ? conversation.budget?.maxOutputTokens : nil
    var key = secrets.key
    if provider == .mistral, configuration.useCodestral { key = secrets.codestralKey ?? "" }
    if provider.needsKey || !key.isEmpty, !validHeader(key) { throw AIChatFailure.missingConfiguration }
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
    let family = family(provider, model: model)
    let openCode = [.opencodeZen, .opencodeGo].contains(provider)
    if openCode {
      if path.hasSuffix("/v1") { path = String(path.dropLast(3)) }
      switch family {
      case .anthropic: path += "/anthropic/v1"
      case .gemini: path += "/google/v1beta"
      default: path += "/openai/v1"
      }
    }
    let chatMessages: [[String: Any]] = (family == .anthropic ? [] : system.map { [["role": "system", "content": $0]] } ?? [])
      + conversation.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
    var body: [String: Any] = ["model": model, "stream": streaming, "messages": chatMessages]
    var headers: [String: String] = ["Content-Type": "application/json",
      "Accept": streaming && provider != .ollama ? "text/event-stream" : "application/json"]
    if openCode {
      headers["User-Agent"] = AIOpenCodeHeaders.userAgent
      if provider == .opencodeGo { headers["x-opencode-session"] = AIOpenCodeHeaders.session }
    }
    let protocolProvider: AIProvider = openCode ? (family == .anthropic ? .anthropic : family == .gemini ? .gemini : family == .responses ? .opencodeZen : .openAI) : provider
    switch protocolProvider {
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
      // The initial system instruction is a top-level field, never a message.
      if let system { body["system"] = system }
      body["max_tokens"] = explicitTokens ?? plannedTokens ?? 16_000
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
    case .opencodeZen:
      path += "/responses"
      headers["Authorization"] = "Bearer " + key
      body = ["model": model, "stream": streaming, "input": conversation.messages.map { ["role": $0.role.rawValue, "content": $0.text] }]
      if let system { body["instructions"] = system }
      if let tokens = explicitTokens ?? plannedTokens { body["max_output_tokens"] = tokens }
      if let effort = options.effort, ["low", "medium", "high", "xhigh", "max"].contains(effort) { body["reasoning"] = ["effort": effort] }
    case .chatGPTPlan:
      // Public Responses API only; plan usage requires store:false and stream:true on every request.
      // No output cap or JSON parameter: plan usage rejects capabilities it does not support.
      guard url.scheme == "https", url.host == "api.openai.com", url.port == nil, path == "/v1" else { throw AIChatFailure.invalidEndpoint }
      path += "/responses"
      headers["Authorization"] = "Bearer " + key
      headers["Accept"] = "text/event-stream"
      body = ["model": model, "store": false, "stream": true,
        "input": conversation.messages.map { message -> [String: Any] in
          ["role": message.role.rawValue, "content": [["type": message.role == .user ? "input_text" : "output_text", "text": message.text]]]
        }]
      if let system { body["instructions"] = system }
    case .gemini:
      if !path.hasSuffix("/v1") && !path.hasSuffix("/v1beta") { path += "/v1beta" }
      let modelID = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
      path += "/models/" + escaped(modelID) + (streaming ? ":streamGenerateContent" : ":generateContent")
      // Google's REST endpoint accepts an API-key header; secrets never enter the URL.
      headers["x-goog-api-key"] = key
      if streaming { url.queryItems = [URLQueryItem(name: "alt", value: "sse")] }
      body = ["contents": conversation.messages.map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] }]
      if let system { body["systemInstruction"] = ["parts": [["text": system]]] }
      var generation: [String: Any] = [:]
      if let temperature = options.temperature { generation["temperature"] = temperature }
      if let tokens = explicitTokens ?? plannedTokens { generation["maxOutputTokens"] = tokens }
      if wantsJSON, capability == .geminiJSON { generation["responseMimeType"] = "application/json" }
      if !generation.isEmpty { body["generationConfig"] = generation }
    case .ollama:
      if !path.hasSuffix("/api/chat") { path += "/api/chat" }
      var values: [String: Any] = [:]
      if let temperature = options.temperature { values["temperature"] = temperature }
      if let tokens = explicitTokens ?? plannedTokens { values["num_predict"] = tokens }
      if !values.isEmpty { body["options"] = values }
      if wantsJSON, capability == .ollamaJSON { body["format"] = "json" }
    default:
      if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
      if provider == .ernie {
        guard let token = bearerToken, validHeader(token), let secret = secrets.secret, validHeader(secret) else {
          throw AIChatFailure.missingConfiguration
        }
        headers["Authorization"] = "Bearer " + token
      } else if !key.isEmpty { headers["Authorization"] = "Bearer " + key }
      if provider == .openAI, let organization = configuration.organization, !organization.isEmpty {
        guard validHeader(organization) else { throw AIChatFailure.missingConfiguration }
        headers["OpenAI-Organization"] = organization
      }
    }
    if family != .gemini && family != .ollama && family != .responses {
      // Current Claude models reject sampling parameters.
      if let temperature = options.temperature, ![.xiaomiMimo, .mimoTokenPlan].contains(provider), !(provider == .moonshot && model == "kimi-k3"), !(family == .anthropic && isCurrentClaude(model)) { body["temperature"] = temperature }
      if let tokens = explicitTokens { body[provider == .moonshot && model == "kimi-k3" || [.openAI, .azureOpenAI, .xiaomiMimo, .mimoTokenPlan].contains(provider) ? "max_completion_tokens" : "max_tokens"] = tokens }
      else if let tokens = plannedTokens, family != .anthropic {
        // OpenAI's own chat models (reasoning ones included) take max_completion_tokens.
        body[([.openAI, .azureOpenAI, .xiaomiMimo, .mimoTokenPlan].contains(provider) || (provider == .moonshot && model == "kimi-k3")) ? "max_completion_tokens" : "max_tokens"] = tokens
      }
      if wantsJSON, capability == .openAIJSONObject { body["response_format"] = ["type": "json_object"] }
    }
    if openCode {
      headers["x-api-key"] = nil; headers["x-goog-api-key"] = nil
      headers["Authorization"] = "Bearer " + key
    }
    if family == .openAI { applyThinking(provider: provider, model: model, effort: options.effort, body: &body) }
    url.percentEncodedPath = path
    guard let target = url.url else { throw AIChatFailure.invalidEndpoint }
    var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }
  private static func applyThinking(provider: AIProvider, model: String, effort: String?, body: inout [String: Any]) {
    guard let effort else { return }
    let id = model.lowercased()
    if [.minimax, .minimaxPlan].contains(provider), id == "minimax-m3.1-flash", ["low", "medium", "high", "xhigh", "max"].contains(effort) {
      body["reasoning_effort"] = effort; return
    }
    guard ["low", "medium", "high", "max"].contains(effort) else { return }
    // Official parameter sources and model restrictions are recorded in docs/AIProviders.md.
    if provider == .deepSeek, ["deepseek-flash", "deepseek-v4-pro"].contains(id) {
      body["thinking"] = ["type": effort == "low" ? "disabled" : "enabled"]
      if effort != "low" { body["reasoning_effort"] = effort == "medium" ? "high" : effort }
    } else if (provider == .qwen && ["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus", "qwen3.6-plus", "qwen3.5-plus"].contains(id))
      || (provider == .siliconFlow && id == "qwen/qwen3.6-35b-a3b") {
      body["enable_thinking"] = effort != "low"
    } else if provider == .zhiPu {
      if ["glm-5.3", "glm-5.3-flash", "glm-5.3-flashx"].contains(id) {
        body["thinking"] = ["type": "enabled"]; body["reasoning_effort"] = effort == "medium" ? "high" : effort
      } else if ["glm-4.5", "glm-4.6", "glm-4.7"].contains(id) { body["thinking"] = ["type": effort == "low" ? "disabled" : "enabled"] }
    } else if [.xiaomiMimo, .mimoTokenPlan].contains(provider), ["mimo-v2.6-pro", "mimo-v2.6-flash", "mimo-v2.6-pro-ultraspeed"].contains(id) {
      body["thinking"] = ["type": effort == "low" ? "disabled" : "enabled"]
    } else if provider == .moonshot, id == "kimi-k3" {
      body["reasoning_effort"] = effort == "medium" ? "high" : effort
    }
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
  /// The conversation used by AI presets and follow-up questions.
  /// `refreshBearer` is used once, for the ChatGPT plan only, when the API rejects a token with 401.
  public func response(provider: AIProvider, configuration: AIProviderConfiguration, secrets: AIProviderSecrets,
    model: String, conversation: AIConversationRequest, streaming requestedStreaming: Bool = true, options: AIResponseOptions = .init(),
    refreshBearer: (@Sendable () async throws -> String)? = nil, retryDelay: Duration = .seconds(1)) -> AsyncThrowingStream<String, Error> {
    if provider == .appleLocal { return AppleLocalModel.stream(conversation) }
    // ChatGPT plan usage only accepts streamed requests; text is still delivered incrementally.
    let streaming = provider == .chatGPTPlan ? true : requestedStreaming
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try Task.checkCancellation()
          // Validate the entire user configuration before Ernie's credential-bearing
          // IAM request, just as for the other providers' first request.
          _ = try AIChatRequestPlanner.request(provider: provider, configuration: configuration,
            secrets: secrets, model: model, conversation: conversation, streaming: streaming, options: options,
            bearerToken: provider == .ernie ? "validation-only" : nil)
          let bearer = provider == .ernie ? try await authorizeErnie(secrets: secrets) : nil
          let family = AIChatRequestPlanner.family(provider, model: model)
          var credentials = secrets
          var attempt = 0, refreshed = false
          var response: AIHTTPStream
          while true {
            let request = try AIChatRequestPlanner.request(provider: provider, configuration: configuration,
              secrets: credentials, model: model, conversation: conversation, streaming: streaming, options: options, bearerToken: bearer)
            response = try await transport.stream(request)
            if (200...299).contains(response.status) { break }
            let failure = await Self.failure(response, family: provider == .chatGPTPlan ? .responses : family == .responses ? .openAI : family)
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
            var parser = AIStreamParser(family: family, planUsage: provider == .chatGPTPlan)
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
          // A local storage failure while saving a refreshed token is not a network failure.
          else if error is AIConfigurationError || error is LocalSecretVault.Failure { continuation.finish(throwing: error) }
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
    do {
      for try await chunk in response.chunks {
        guard data.count + chunk.count <= 65_536 else { break }
        data.append(chunk)
      }
    } catch {}
    // The body is only inspected for known markers, never shown or logged.
    if [400, 413, 422].contains(response.status), AIStreamParser.isContextOverflow(data) { return .contextTooLong }
    if family == .responses {
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
