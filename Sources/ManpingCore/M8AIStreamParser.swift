import Foundation

public enum AIChatFailure: Error, LocalizedError, Equatable, Sendable {
  case missingConfiguration, invalidEndpoint, unauthorized, rateLimited, httpStatus(Int)
  case invalidResponse, providerError, truncatedStream, emptyResponse, outputLimit, transport(Int)
  case refused, planUsageLimit, planNotEligible, planUnavailable, planSignInRequired, unsupportedCapability
  case localModelUnavailable, localContextTooLong, localRefused
  /// The provider reported that the request exceeds the model's context window.
  case contextTooLong, reasoningHistoryRequired
  public var errorDescription: String? {
    switch self {
    case .missingConfiguration: "请先配置 AI 服务、模型和所需凭据。"
    case .invalidEndpoint: "AI 终结点无效；远程服务必须使用 HTTPS。"
    case .unauthorized: "AI 服务鉴权失败（401/403），请检查凭据和权限。"
    case .rateLimited: "AI 服务已限流（429），请稍后重试。"
    case .httpStatus(let status): "AI 服务请求失败（HTTP \(status)）。"
    case .invalidResponse: "AI 服务响应格式无效。"
    case .providerError: "AI 服务返回错误，请检查模型和服务配置。"
    case .truncatedStream: "AI 响应中断，尚未收到完整结束标记。"
    case .emptyResponse: "AI 服务没有返回正文。"
    case .outputLimit: "AI 响应达到输出限制，正文尚未完整结束。"
    case .transport(let code): "AI 网络请求失败（\(code)）。"
    case .refused: "模型出于安全策略拒绝了此请求。"
    case .planUsageLimit: "已达到用量上限：ChatGPT 套餐或本应用的用量已用完，请在 ChatGPT 设置中查看或管理用量。"
    case .planNotEligible: "当前 ChatGPT 账号、工作区或策略不支持在本应用中使用套餐用量。"
    case .planUnavailable: "ChatGPT 套餐用量暂时无法确认，请稍后重试。"
    case .planSignInRequired: "ChatGPT 登录已失效，请在 设置 › AI 中重新使用 ChatGPT 账号登录。"
    case .unsupportedCapability: "ChatGPT 套餐暂不支持此请求中的模型或参数。"
    case .localModelUnavailable:
      #if os(macOS) && !MANPING_PORTABLE_CORE
      AppleLocalModel.unavailableReason ?? "Apple 本地模型暂时无法生成，请稍后重试。"
      #else
      "Apple 本地模型仅适用于受支持的 Mac。"
      #endif
    case .localContextTooLong: "内容超出 Apple 本地模型的上下文长度，请改用其他 AI 服务或缩短问题。"
    case .localRefused: "Apple 本地模型出于安全策略未回答此请求。"
    case .contextTooLong: "内容超出当前模型的上下文长度，请在 设置 › AI › 对应服务 › 自定义模型中填写模型标识、上下文长度和最大输出，再添加并保存。"
    case .reasoningHistoryRequired: "此模型的多轮对话要求保留完整思考历史，当前仅支持单轮请求；请换用其他模型。"
    }
  }
}
public enum AIProtocolFamily: Equatable, Sendable { case openAI, anthropic, gemini, ollama, responses }

/// Incremental framing works on bytes, so UTF-8 scalars split between network chunks
/// are decoded only after a complete line. SSE data lines form a single event.
public struct AIStreamParser: Sendable {
  private let family: AIProtocolFamily
  private let planUsage: Bool
  private var bytes = Data()
  private var eventData: [String] = []
  private var eventName = ""
  private var firstLine = true
  public private(set) var finished = false
  private var hasText = false
  private var totalBytes = 0
  public init(family: AIProtocolFamily, planUsage: Bool = true) { self.family = family; self.planUsage = planUsage }
  public mutating func append(_ data: Data) throws -> [String] {
    guard !finished else { return [] }
    totalBytes += data.count
    guard totalBytes <= 16_777_216 else { throw AIChatFailure.invalidResponse }
    bytes.append(data)
    var result: [String] = []
    while let end = bytes.firstIndex(where: { $0 == 10 || $0 == 13 }) {
      if bytes[end] == 13, end == bytes.index(before: bytes.endIndex) { break }
      let line = Data(bytes[..<end])
      var next = bytes.index(after: end)
      if bytes[end] == 13, next < bytes.endIndex, bytes[next] == 10 { next = bytes.index(after: next) }
      bytes.removeSubrange(..<next)
      result += try consumeLine(line)
      if finished { bytes.removeAll(); break }
    }
    guard bytes.count <= 1_048_576, eventData.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576 else {
      throw AIChatFailure.invalidResponse
    }
    return result
  }
  public mutating func finish() throws -> [String] {
    var result: [String] = []
    if !finished, !bytes.isEmpty {
      // NDJSON permits a final complete JSON line without LF. An SSE stream needs
      // a blank event delimiter; unfinished data at EOF is not implicitly accepted.
      if family == .ollama {
        result += try consumeLine(bytes); bytes.removeAll()
      } else if bytes == Data([13]) {
        bytes.removeAll(); result += try consumeLine(Data())
      }
    }
    guard finished else { throw AIChatFailure.truncatedStream }
    guard hasText else { throw AIChatFailure.emptyResponse }
    return result
  }
  private mutating func consumeLine(_ data: Data) throws -> [String] {
    guard var line = String(data: data, encoding: .utf8) else { throw AIChatFailure.invalidResponse }
    if firstLine { firstLine = false; if line.hasPrefix("\u{feff}") { line.removeFirst() } }
    if family == .ollama {
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
      return try consumeJSON(Data(line.utf8))
    }
    if line.isEmpty {
      guard !eventData.isEmpty else { eventName = ""; return [] }
      let payload = eventData.joined(separator: "\n")
      let name = eventName
      eventData.removeAll(); eventName = ""
      if name == "error" && family != .responses { throw AIChatFailure.providerError }
      if payload.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "[DONE]" {
        // Responses success is signalled only by response.completed; [DONE] is just the end.
        if family != .responses { finished = true }
        return []
      }
      return try consumeJSON(Data(payload.utf8))
    }
    if line.hasPrefix(":") { return [] }
    let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    var value = pieces.count > 1 ? String(pieces[1]) : ""
    if value.hasPrefix(" ") { value.removeFirst() }
    if pieces[0] == "data" { eventData.append(value) }
    else if pieces[0] == "event" { eventName = value }
    return []
  }
  private mutating func consumeJSON(_ data: Data) throws -> [String] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AIChatFailure.invalidResponse
    }
    if family != .responses, object["error"] != nil { throw AIChatFailure.providerError }
    var text = ""
    switch family {
    case .responses:
      switch object["type"] as? String {
      case "response.output_text.delta": text = object["delta"] as? String ?? ""
      // The only success signal; a stream that ends without it is a failure.
      case "response.completed": finished = true
      case "response.failed":
        let error = (object["response"] as? [String: Any])?["error"] as? [String: Any]
        throw responseFailure(code: error?["code"] as? String ?? "")
      case "response.incomplete":
        let details = (object["response"] as? [String: Any])?["incomplete_details"] as? [String: Any]
        throw details?["reason"] as? String == "max_output_tokens" ? AIChatFailure.outputLimit : AIChatFailure.providerError
      case "error":
        let code = (object["error"] as? [String: Any])?["code"] as? String ?? object["code"] as? String ?? ""
        throw responseFailure(code: code)
      default: break
      }
    case .openAI:
      guard let choices = object["choices"] as? [[String: Any]] else {
        // Usage-only events are permitted after text; every other malformed event fails.
        if object["usage"] != nil { return [] }
        throw AIChatFailure.invalidResponse
      }
      if let choice = choices.first {
        if let delta = choice["delta"] as? [String: Any] { text = delta["content"] as? String ?? "" }
        if let reason = choice["finish_reason"] as? String {
          if reason == "length" { throw AIChatFailure.outputLimit }
          guard reason == "stop" else { throw AIChatFailure.providerError }
          finished = true
        }
      }
    case .anthropic:
      switch object["type"] as? String {
      case "content_block_delta":
        if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
          text = delta["text"] as? String ?? ""
        }
      case "content_block_start":
        if let block = object["content_block"] as? [String: Any], block["type"] as? String == "text" {
          text = block["text"] as? String ?? ""
        }
      case "message_delta":
        let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String
        if reason == "max_tokens" { throw AIChatFailure.outputLimit }
        if reason == "refusal" { throw AIChatFailure.refused }
      case "message_stop": finished = true
      case "error": throw AIChatFailure.providerError
      // thinking/signature deltas, ping and future event types carry no answer text.
      default: break
      }
    case .gemini:
      guard let candidates = object["candidates"] as? [[String: Any]], let candidate = candidates.first else {
        throw AIChatFailure.providerError
      }
      text = Self.geminiText(candidate)
      if let reason = candidate["finishReason"] as? String {
        if reason == "MAX_TOKENS" { throw AIChatFailure.outputLimit }
        guard reason == "STOP" else { throw AIChatFailure.providerError }
        finished = true
      }
    case .ollama:
      if let message = object["message"] as? [String: Any] { text = message["content"] as? String ?? "" }
      if object["done"] as? Bool == true {
        if object["done_reason"] as? String == "length" { throw AIChatFailure.outputLimit }
        finished = true
      }
    }
    if !text.isEmpty {
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
      return [text]
    }
    return []
  }
  private func responseFailure(code: String) -> AIChatFailure {
    if planUsage { return Self.responsesFailure(code: code) ?? .providerError }
    return code == "rate_limit_exceeded" ? .rateLimited : .providerError
  }
  /// Structured Responses error codes for ChatGPT plan usage (errors-and-recovery reference).
  static func responsesFailure(code: String) -> AIChatFailure? {
    switch code {
    case "subscription_sharing_usage_limit_exceeded": .planUsageLimit
    case "subscription_sharing_user_not_eligible", "subscription_sharing_route_not_supported",
      "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": .planNotEligible
    case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": .planUnavailable
    case "subscription_sharing_invalid_user": .planSignInRequired
    case "subscription_sharing_unsupported_capability": .unsupportedCapability
    case "rate_limit_exceeded": .rateLimited
    default: nil
    }
  }
  private static func geminiText(_ candidate: [String: Any]) -> String {
    guard let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { return "" }
    return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
  }
  static let overflowMarkers = ["context_length_exceeded", "maximum context length", "context window", "context length",
    "prompt is too long", "too many tokens", "input is too long", "exceeds the context", "token limit", "string_above_max_length",
    "input token count", "reduce the length"]
  /// Recognises context-overflow errors across providers from a bounded error body.
  static func isContextOverflow(_ data: Data) -> Bool {
    let text = String(decoding: data.prefix(65_536), as: UTF8.self).lowercased()
    return overflowMarkers.contains { text.contains($0) }
  }
  public static func complete(_ data: Data, family: AIProtocolFamily) throws -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIChatFailure.invalidResponse }
    if object["error"] != nil { throw AIChatFailure.providerError }
    let text: String
    switch family {
    case .openAI:
      guard let choice = (object["choices"] as? [[String: Any]])?.first,
        let message = choice["message"] as? [String: Any], let content = message["content"] as? String else {
        throw AIChatFailure.invalidResponse
      }
      if choice["finish_reason"] as? String == "length" { throw AIChatFailure.outputLimit }
      text = content
    case .anthropic:
      guard let content = object["content"] as? [[String: Any]] else { throw AIChatFailure.invalidResponse }
      if object["stop_reason"] as? String == "max_tokens" { throw AIChatFailure.outputLimit }
      if object["stop_reason"] as? String == "refusal" { throw AIChatFailure.refused }
      text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    case .gemini:
      guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { throw AIChatFailure.providerError }
      if candidate["finishReason"] as? String == "MAX_TOKENS" { throw AIChatFailure.outputLimit }
      if let reason = candidate["finishReason"] as? String, reason != "STOP" { throw AIChatFailure.providerError }
      text = geminiText(candidate)
    case .responses:
      if object["status"] as? String == "incomplete" { throw AIChatFailure.outputLimit }
      guard object["status"] as? String == "completed", let output = object["output"] as? [[String: Any]] else { throw AIChatFailure.invalidResponse }
      text = output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
    case .ollama:
      guard object["done"] as? Bool == true, let message = object["message"] as? [String: Any],
        let content = message["content"] as? String else { throw AIChatFailure.invalidResponse }
      if object["done_reason"] as? String == "length" { throw AIChatFailure.outputLimit }
      text = content
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIChatFailure.emptyResponse }
    return text
  }
}
