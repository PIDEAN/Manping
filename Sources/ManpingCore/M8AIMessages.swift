import Foundation

public enum AIRole: String, Codable, Sendable { case user, assistant }

/// Content of one message. Text only in this phase; images (current frame) come later.
public enum AIContentBlock: Codable, Sendable, Equatable {
  case text(String)
}

/// Protocol-neutral message. The system prompt is not a message: each protocol adapter places it
/// where that protocol expects it.
public struct AIMessage: Codable, Sendable, Equatable {
  public let role: AIRole
  public let content: [AIContentBlock]
  public init(role: AIRole, content: [AIContentBlock]) { self.role = role; self.content = content }
  public static func user(_ text: String) -> AIMessage { AIMessage(role: .user, content: [.text(text)]) }
  public static func assistant(_ text: String) -> AIMessage { AIMessage(role: .assistant, content: [.text(text)]) }
  public var text: String {
    content.map { block in switch block { case .text(let value): value } }.joined(separator: "\n\n")
  }
}

public enum AIResponseFormat: String, Codable, Sendable { case text, json }

public struct AIConversationRequest: Sendable, Equatable {
  public var system: String?
  public var messages: [AIMessage]
  public var format: AIResponseFormat
  /// The plan this request was assembled against; its output limit is sent as the output cap.
  public var budget: AIRequestBudget?
  public init(system: String?, messages: [AIMessage], format: AIResponseFormat = .text, budget: AIRequestBudget? = nil) {
    self.system = system; self.messages = messages; self.format = format; self.budget = budget
  }
  /// Estimated input tokens of the whole serialized request (system + every message + framing).
  public var estimatedInputTokens: Int {
    AITokenEstimator.estimate(system ?? "") + messages.reduce(0) { $0 + AITokenEstimator.estimate($1.text) + 8 } + 16
  }
}

/// Whether a request can ask the service itself for JSON. Decided by protocol, endpoint and
/// model; anything unlisted gets prompt-only JSON and is validated locally either way.
public enum AIStructuredCapability: Sendable, Equatable {
  case none, openAIJSONObject, geminiJSON, ollamaJSON
  public static func of(provider: AIProvider, configuration: AIProviderConfiguration, model: String) -> AIStructuredCapability {
    let customEndpoint = configuration.endpoint.map { $0 != provider.defaultEndpoint } ?? false
    switch provider {
    case .gemini:
      let host = configuration.endpoint.flatMap { URLComponents(string: $0)?.host } ?? "generativelanguage.googleapis.com"
      return host.hasSuffix("googleapis.com") ? .geminiJSON : .none
    case .ollama:
      return .ollamaJSON
    case .openAI:
      guard !customEndpoint else { return .none }
      let prefixes = ["gpt-4o", "gpt-4.1", "gpt-4.5", "gpt-5", "o3", "o4", "gpt-3.5-turbo"]
      return model == "o1" || prefixes.contains(where: { model.hasPrefix($0) }) ? .openAIJSONObject : .none
    case .deepSeek:
      return !customEndpoint && model == "deepseek-chat" ? .openAIJSONObject : .none
    case .qwen:
      return !customEndpoint && ["qwen-max", "qwen-plus", "qwen-turbo", "qwen-flash"].contains(where: { model.hasPrefix($0) }) ? .openAIJSONObject : .none
    case .zhiPu:
      return !customEndpoint && model.hasPrefix("glm-4") && !model.hasPrefix("glm-4v") ? .openAIJSONObject : .none
    case .moonshot, .mistral, .groq, .xAI:
      return customEndpoint ? .none : .openAIJSONObject
    default:
      return .none
    }
  }
}
