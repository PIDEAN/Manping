import Foundation
import CoreFoundation

public enum AIModelListingFailure: Error, LocalizedError, Equatable {
  case unauthorized, network, invalidFormat, invalidEndpoint, unsupported
  public var errorDescription: String? {
    switch self {
    case .unauthorized: "未授权，请检查访问密钥与地区。"
    case .network: "网络请求失败，请检查网络与服务地址。"
    case .invalidFormat: "模型列表格式无效、过大或分页异常。"
    case .unsupported: "此服务尚未确认兼容的模型目录接口，请手动添加模型。"
    case .invalidEndpoint: "服务地址无效；远程地址必须使用 HTTPS。"
    }
  }
}

/// Discovery sends GET only. No inference endpoint is contacted.
public struct AIModelListing: Sendable {
  private let transport: any AIHTTPTransport
  public init(transport: any AIHTTPTransport = AIURLSessionTransport()) { self.transport = transport }
  public static func request(provider: AIProvider, configuration: AIProviderConfiguration, secrets: AIProviderSecrets,
    cursor: String? = nil) throws -> URLRequest {
    // These credentials use dedicated inference/IAM routes, not ordinary Bearer model discovery.
    guard provider != .ernie, !(provider == .mistral && configuration.useCodestral && configuration.endpoint == nil) else {
      throw AIModelListingFailure.unsupported
    }
    var url: URLComponents
    do { url = try AIChatRequestPlanner.endpoint(configuration.endpoint ?? provider.defaultEndpoint ?? "") }
    catch { throw AIModelListingFailure.invalidEndpoint }
    var path = url.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    switch provider {
    case .anthropic:
      if path.isEmpty { path = "/v1" }
      path += "/models"
      url.queryItems = [URLQueryItem(name: "limit", value: "1000")]
      if let cursor { url.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
    case .gemini:
      if !path.hasSuffix("/v1") && !path.hasSuffix("/v1beta") { path += "/v1beta" }
      path += "/models"
      url.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
      if let cursor { url.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor)) }
    case .azureOpenAI:
      path += "/openai/models"
      url.queryItems = [URLQueryItem(name: "api-version", value: configuration.apiVersion ?? "2024-10-21")]
    case .azureAI: throw AIModelListingFailure.unsupported
    case .ollama: path += "/api/tags"
    default: path += "/models"
    }
    url.percentEncodedPath = path
    guard let target = url.url else { throw AIModelListingFailure.invalidEndpoint }
    var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
    let publicCatalogue = [.openRouter, .opencodeZen, .opencodeGo].contains(provider)
    if !publicCatalogue && ![.ollama, .lmStudio].contains(provider) {
      guard AIChatRequestPlanner.validHeader(secrets.key) else { throw AIModelListingFailure.unauthorized }
      if provider == .anthropic {
        request.setValue(secrets.key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      } else if provider == .gemini { request.setValue(secrets.key, forHTTPHeaderField: "x-goog-api-key") }
      else if [.azureAI, .azureOpenAI].contains(provider) { request.setValue(secrets.key, forHTTPHeaderField: "api-key") }
      else { request.setValue("Bearer " + secrets.key, forHTTPHeaderField: "Authorization") }
    } else if provider == .lmStudio, !secrets.key.isEmpty {
      guard AIChatRequestPlanner.validHeader(secrets.key) else { throw AIModelListingFailure.unauthorized }
      request.setValue("Bearer " + secrets.key, forHTTPHeaderField: "Authorization")
    }
    if [.opencodeZen, .opencodeGo].contains(provider) {
      request.setValue(AIOpenCodeHeaders.userAgent, forHTTPHeaderField: "User-Agent")
      if provider == .opencodeGo { request.setValue(AIOpenCodeHeaders.session, forHTTPHeaderField: "x-opencode-session") }
    }
    return request
  }
  public func models(provider: AIProvider, configuration: AIProviderConfiguration, secrets: AIProviderSecrets) async throws -> [AIModel] {
    do {
      var result: [AIModel] = [], ids = Set<String>(), cursors = Set<String>(), cursor: String?
      var remainingBytes = 16_777_216
      for _ in 0..<32 {
        try Task.checkCancellation()
        let response = try await transport.stream(Self.request(provider: provider, configuration: configuration, secrets: secrets, cursor: cursor))
        let page = try await read(response, provider: provider, remainingBytes: &remainingBytes)
        for model in page.models where ids.insert(model.id).inserted {
          result.append(model)
          if result.count == 1000 { return result }
        }
        guard let next = page.next else { return result }
        guard cursors.insert(next).inserted else { throw AIModelListingFailure.invalidFormat }
        cursor = next
      }
      throw AIModelListingFailure.invalidFormat
    } catch is CancellationError { throw CancellationError() }
    catch let error as AIModelListingFailure { throw error }
    catch { if Task.isCancelled { throw CancellationError() }; throw AIModelListingFailure.network }
  }
  private func read(_ response: AIHTTPStream, provider: AIProvider, remainingBytes: inout Int) async throws -> (models: [AIModel], next: String?) {
    defer { response.cancel() }
    guard (200...299).contains(response.status) else {
      throw [401, 403].contains(response.status) ? AIModelListingFailure.unauthorized : AIModelListingFailure.network
    }
    var data = Data()
    for try await chunk in response.chunks {
      try Task.checkCancellation()
      guard chunk.count <= remainingBytes else { throw AIModelListingFailure.invalidFormat }
      remainingBytes -= chunk.count; data.append(chunk)
    }
    return try Self.parse(data, provider: provider)
  }
  /// Public for deterministic protocol fixtures; response bodies are never displayed in errors.
  public static func parse(_ data: Data, provider: AIProvider) throws -> (models: [AIModel], next: String?) {
    guard data.count <= 16_777_216, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let rows = root[provider == .gemini || provider == .ollama ? "models" : "data"] as? [[String: Any]] else { throw AIModelListingFailure.invalidFormat }
    func positive(_ value: Any?, maximum: Int = 20_000_000) -> Int? {
      guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
        number.intValue > 0, number.intValue <= maximum else { return nil }
      return number.intValue
    }
    var models: [AIModel] = []
    for row in rows.prefix(1000) {
      if row["lifecycle"] as? String == "retired" { continue }
      if provider == .gemini, !(row["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") { continue }
      guard var id = (row[provider == .gemini || provider == .ollama ? "name" : "id"] as? String), !id.isEmpty,
        id.utf8.count <= 512, !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { continue }
      if provider == .gemini, id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
      var context = positive(row["max_input_tokens"] ?? row["inputTokenLimit"] ?? row["context_length"] ?? row["context_window"])
      if let value = context, value < 1024 { context = nil }
      let output = positive(row["max_tokens"] ?? row["outputTokenLimit"] ?? row["max_output_tokens"] ?? (row["top_provider"] as? [String: Any])?["max_completion_tokens"], maximum: 2_000_000)
      var capabilities = row["supported_parameters"] as? [String]
      if let values = row["capabilities"] as? [String: [String: Any]] {
        capabilities = values.compactMap { $0.value["supported"] as? Bool == true ? $0.key : nil }.sorted()
      }
      let name = (row["displayName"] ?? row["display_name"] ?? row["name"]) as? String ?? id
      models.append(AIModel(id: id, name: String(name.prefix(512)), toolSupport: capabilities?.contains("tools") == true,
        visionSupport: capabilities?.contains("image_input") == true, contextTokens: context, maxOutputTokens: output,
        capabilities: capabilities.map { Array($0.prefix(100)).map { String($0.prefix(128)) } }))
    }
    var next = provider == .gemini ? root["nextPageToken"] as? String : nil
    if provider == .anthropic, root["has_more"] as? Bool == true {
      guard let last = root["last_id"] as? String, !last.isEmpty else { throw AIModelListingFailure.invalidFormat }
      next = last
    }
    if let next, next.isEmpty || next.utf8.count > 4096 { throw AIModelListingFailure.invalidFormat }
    return (models, next)
  }
}
