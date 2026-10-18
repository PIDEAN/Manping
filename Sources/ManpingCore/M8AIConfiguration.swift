import Foundation
import CryptoKit
import Security

/// Registration order and JSON keys mirror the fixed UI GlobalDependencies and ChatClientConfiguration.
public enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
  public var id: String { rawValue }
  case openAI = "openai"
  case azureOpenAI = "azure_openai"
  case azureAI = "azure_ai"
  case xAI = "xai"
  case zhiPu = "zhipu"
  case lingYi = "lingyi"
  case anthropic = "anthropic"
  case moonshot = "moonshot"
  case gemini = "gemini"
  case deepSeek = "deepseek"
  case qwen = "qwen"
  case ernie = "ernie"
  case hunyuan = "hunyuan"
  case spark = "spark"
  case doubao = "doubao"
  case siliconFlow = "siliconflow"
  case openRouter = "open_router"
  case togetherAI = "together_ai"
  case groq = "groq"
  case ollama = "ollama"
  case mistral = "mistral"
  case perplexity = "perplexity"
  /// Mac addition: "Sign in with ChatGPT" plan usage (OAuth, not an API key).
  case chatGPTPlan = "chatgpt_plan"
  /// Mac addition: Apple's on-device model (Apple Intelligence), no key or network.
  case appleLocal = "apple_local"
  /// The 22 providers registered by the fixed upstream UI, in source order.
  public static var sourceProviders: [AIProvider] { allCases.filter { $0 != .chatGPTPlan && $0 != .appleLocal } }
  public var isOnDevice: Bool { self == .appleLocal }
  public var usesOAuth: Bool { self == .chatGPTPlan }
  public var title: String {
    switch self {
    case .openAI: "OpenAI"
    case .azureOpenAI: "Azure OpenAI"
    case .azureAI: "Azure AI"
    case .xAI: "xAI"
    case .zhiPu: "智谱"
    case .lingYi: "零一万物"
    case .anthropic: "Anthropic"
    case .moonshot: "Moonshot"
    case .gemini: "Gemini"
    case .deepSeek: "DeepSeek"
    case .qwen: "通义千问"
    case .ernie: "文心千帆"
    case .hunyuan: "腾讯混元"
    case .spark: "讯飞星火"
    case .doubao: "豆包"
    case .siliconFlow: "SiliconFlow"
    case .openRouter: "OpenRouter"
    case .togetherAI: "Together AI"
    case .groq: "Groq"
    case .ollama: "Ollama"
    case .mistral: "Mistral"
    case .perplexity: "Perplexity"
    case .chatGPTPlan: "ChatGPT 套餐"
    case .appleLocal: "Apple 本地模型"
    }
  }
  public var defaultEndpoint: String? {
    switch self {
    case .openAI: "https://api.openai.com/v1"
    case .azureOpenAI: nil
    case .azureAI: nil
    case .xAI: "https://api.x.ai/v1"
    case .zhiPu: "https://open.bigmodel.cn/api/paas/v4"
    case .lingYi: "https://api.lingyiwanwu.com/v1"
    case .anthropic: "https://api.anthropic.com"
    case .moonshot: "https://api.moonshot.cn/v1"
    case .gemini: "https://generativelanguage.googleapis.com"
    case .deepSeek: "https://api.deepseek.com"
    case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
    case .ernie: "https://qianfan.baidubce.com/v2"
    case .hunyuan: "https://api.hunyuan.cloud.tencent.com/v1"
    case .spark: "https://spark-api-open.xf-yun.com/v1"
    case .doubao: "https://ark.cn-beijing.volces.com/api/v3"
    case .siliconFlow: "https://api.siliconflow.cn/v1"
    case .openRouter: "https://openrouter.ai/api/v1"
    case .togetherAI: "https://api.together.xyz/v1"
    case .groq: "https://api.groq.com/openai/v1"
    case .ollama: "http://localhost:11434"
    case .mistral: "https://api.mistral.ai/v1"
    case .perplexity: "https://api.perplexity.ai"
    case .chatGPTPlan: "https://api.openai.com/v1"
    case .appleLocal: "on-device"
    }
  }
  public var supportsEndpoint: Bool { [.openAI, .azureOpenAI, .azureAI, .anthropic, .gemini, .ollama].contains(self) }
  public var requiresCustomModels: Bool { predefinedModels.isEmpty }
  /// Exact AgentKernel 0.0.8-preview5 GetPredefinedModels; these are source-parity choices, not a live catalogue.
  public var predefinedModels: [AIModel] {
    switch self {
    case .openAI:
      [
        AIModel(id: "gpt-5", name: "GPT-5", toolSupport: true, visionSupport: true),
        AIModel(id: "gpt-5-mini", name: "GPT-5 mini", toolSupport: true, visionSupport: true),
        AIModel(id: "gpt-5-nano", name: "GPT-5 nano", toolSupport: true, visionSupport: true),
        AIModel(id: "gpt-5-pro", name: "GPT-5 pro", toolSupport: true, visionSupport: true),
        AIModel(id: "gpt-4.1", name: "GPT-4.1", toolSupport: true, visionSupport: true),
        AIModel(id: "gpt-4o", name: "GPT-4o", toolSupport: true, visionSupport: true),
        AIModel(id: "gpt-4o-mini", name: "GPT-4o Mini", toolSupport: true, visionSupport: true),
        AIModel(id: "gpt-4.5-preview", name: "GPT-4.5 Preview", toolSupport: true, visionSupport: true),
        AIModel(id: "o4-mini", name: "O4 Mini", toolSupport: true, visionSupport: true),
        AIModel(id: "o3", name: "O3", toolSupport: true, visionSupport: true),
        AIModel(id: "o3-mini", name: "O3 Mini", toolSupport: true),
        AIModel(id: "o1", name: "O1", toolSupport: true, visionSupport: true),
        AIModel(id: "o1-mini", name: "O1 Mini", toolSupport: true, visionSupport: true),
        AIModel(id: "o1-preview", name: "O1 Preview", toolSupport: true, visionSupport: true),
        AIModel(id: "gpt-4", name: "GPT-4", toolSupport: true),
        AIModel(id: "gpt-3.5-turbo", name: "GPT-3.5 Turbo"),
      ]
    case .azureOpenAI:
      []
    case .azureAI:
      []
    case .xAI:
      [
        AIModel(id: "grok-4-fast-reasoning", name: "Grok 4 Fast Reasoning", toolSupport: true, visionSupport: true),
        AIModel(id: "grok-4-fast-non-reasoning", name: "Grok 4 Fast Non-Reasoning", toolSupport: true, visionSupport: true),
        AIModel(id: "grok-4-0709", name: "Grok 4", toolSupport: true, visionSupport: true),
        AIModel(id: "grok-3", name: "Grok 3", toolSupport: true),
        AIModel(id: "grok-3-mini", name: "Grok 3 Mini", toolSupport: true),
        AIModel(id: "grok-2-latest", name: "Grok 2", toolSupport: true),
        AIModel(id: "grok-2-vision", name: "Grok 2 Vision", toolSupport: true, visionSupport: true),
        AIModel(id: "grok-beta", name: "Grok Beta", toolSupport: true),
      ]
    case .zhiPu:
      [
        AIModel(id: "glm-4.6", name: "GLM-4.6", toolSupport: true),
        AIModel(id: "glm-4.5", name: "GLM-4.5", toolSupport: true),
        AIModel(id: "glm-z1-air", name: "GLM-Z1-Air"),
        AIModel(id: "glm-z1-airx", name: "GLM-Z1-AirX"),
        AIModel(id: "glm-4-plus", name: "GLM-4-Plus", toolSupport: true),
        AIModel(id: "glm-4-0520", name: "GLM-4", toolSupport: true),
        AIModel(id: "glm-4-long", name: "GLM-4-Long", toolSupport: true),
        AIModel(id: "glm-4-airx", name: "GLM-4-AirX", toolSupport: true),
        AIModel(id: "glm-4-air", name: "GLM-4-Air", toolSupport: true),
        AIModel(id: "glm-4-flashx", name: "GLM-4-FlashX", toolSupport: true),
        AIModel(id: "glm-4-flash", name: "GLM-4-Flash", toolSupport: true),
        AIModel(id: "glm-4v-flash", name: "GLM-4V-Flash", visionSupport: true),
        AIModel(id: "glm-4v-plus", name: "GLM-4V-Plus", visionSupport: true),
        AIModel(id: "glm-4v", name: "GLM-4V", visionSupport: true),
      ]
    case .lingYi:
      [
        AIModel(id: "yi-lightning", name: "Yi Lightning"),
        AIModel(id: "yi-medium-200k", name: "Yi Medium 200K"),
        AIModel(id: "yi-large", name: "Yi Large"),
        AIModel(id: "yi-vision", name: "Yi Vision", visionSupport: true),
        AIModel(id: "yi-vision-v2", name: "Yi Vision V2", visionSupport: true),
      ]
    case .anthropic:
      // Current Claude models (the pinned SDK list named retired 3.x/4.x snapshots).
      [
        AIModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", toolSupport: true, visionSupport: true),
        AIModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", toolSupport: true, visionSupport: true),
        AIModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", toolSupport: true, visionSupport: true),
        AIModel(id: "claude-fable-5-1", name: "Claude Fable 5.1", toolSupport: true, visionSupport: true),
      ]
    case .moonshot:
      [
        AIModel(id: "kimi-k2-turbo-preview", name: "Kimi K2 Turbo Preview"),
        AIModel(id: "kimi-latest", name: "Kimi Latest"),
        AIModel(id: "moonshot-v1-8k", name: "Moonshot V1 8K"),
        AIModel(id: "moonshot-v1-32k", name: "Moonshot V1 32K"),
        AIModel(id: "moonshot-v1-128k", name: "Moonshot V1 128K"),
        AIModel(id: "moonshot-v1-auto", name: "Moonshot V1 Auto"),
      ]
    case .gemini:
      [
        AIModel(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", toolSupport: true, visionSupport: true),
        AIModel(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", toolSupport: true, visionSupport: true),
        AIModel(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", toolSupport: true, visionSupport: true),
        AIModel(id: "gemini-1.5-flash", name: "Gemini 1.5 Flash", toolSupport: true, visionSupport: true),
        AIModel(id: "gemini-1.5-flash-8b", name: "Gemini 1.5 Flash-8B", toolSupport: true, visionSupport: true),
        AIModel(id: "gemini-1.5-pro", name: "Gemini 1.5 Pro", toolSupport: true, visionSupport: true),
      ]
    case .deepSeek:
      [
        AIModel(id: "deepseek-chat", name: "DeepSeek Chat"),
        AIModel(id: "deepseek-coder", name: "DeepSeek Coder"),
        AIModel(id: "deepseek-reasoner", name: "DeepSeek Reasoner"),
      ]
    case .qwen:
      [
        AIModel(id: "qwen-max", name: "通义千问-Max", toolSupport: true),
        AIModel(id: "qwen-plus", name: "通义千问-Plus", toolSupport: true),
        AIModel(id: "qwen-turbo", name: "通义千问-Turbo", toolSupport: true),
        AIModel(id: "qwen-flash", name: "通义千问-Flash", toolSupport: true),
        AIModel(id: "qwq-plus-latest", name: "QwQ 推理", toolSupport: true),
        AIModel(id: "qwen-omni-turbo", name: "通义千问-Omni"),
        AIModel(id: "qwen-long-latest", name: "通义千问-Long"),
        AIModel(id: "qwen-vl-max", name: "通义千问 VL", visionSupport: true),
        AIModel(id: "qwen3-next-80b-a3b-thinking", name: "通义千问 3-开源版-思考模式"),
        AIModel(id: "qwen3-next-80b-a3b-instruct", name: "通义千问 3-开源版-非思考模式"),
        AIModel(id: "qwen2.5-72b-instruct", name: "通义千问 2.5-开源版"),
        AIModel(id: "qwen2-72b", name: "通义千问 2-开源版"),
      ]
    case .ernie:
      [
        AIModel(id: "ernie-4.5-turbo-latest", name: "ERNIE 4.5 Turbo 128K", toolSupport: true, visionSupport: true),
        AIModel(id: "ernie-4.0-turbo-8k-latest", name: "ERNIE 4.0 Turbo 8K", toolSupport: true),
        AIModel(id: "ernie-4.0-turbo-128k", name: "ERNIE 4.0 Turbo 128K", toolSupport: true),
        AIModel(id: "ernie-speed-8k", name: "ERNIE Speed 8K"),
        AIModel(id: "ernie-speed-128k", name: "ERNIE Speed 128K"),
        AIModel(id: "ernie-speed-pro-128k", name: "ERNIE Speed Pro 128K", toolSupport: true),
        AIModel(id: "ernie-lite-8k", name: "ERNIE Lite 8K"),
        AIModel(id: "ernie-lite-pro-128k", name: "ERNIE Lite Pro 128K", toolSupport: true),
        AIModel(id: "ernie-tiny-8k", name: "ERNIE Tiny"),
        AIModel(id: "ernie-character-8k", name: "ERNIE Character"),
        AIModel(id: "ernie-novel-8k", name: "ERNIE-Novel-8K"),
      ]
    case .hunyuan:
      [
        AIModel(id: "hunyuan-turbos-latest", name: "Hunyuan TurboS", toolSupport: true),
        AIModel(id: "hunyuan-t1-latest", name: "Hunyuan T1"),
        AIModel(id: "hunyuan-turbo-latest", name: "Hunyuan Turbo", toolSupport: true),
        AIModel(id: "hunyuan-large", name: "Hunyuan Large"),
        AIModel(id: "hunyuan-large-longcontext", name: "Hunyuan Large Long Context"),
        AIModel(id: "hunyuan-standard-256k", name: "Hunyuan Standard 256K"),
        AIModel(id: "hunyuan-standard", name: "Hunyuan Standard"),
        AIModel(id: "hunyuan-lite", name: "Hunyuan Lite"),
        AIModel(id: "hunyuan-functioncall", name: "Hunyuan Function Call"),
      ]
    case .spark:
      [
        AIModel(id: "lite", name: "Spark Lite"),
        AIModel(id: "generalv3", name: "Spark Pro"),
        AIModel(id: "pro-128k", name: "Spark Pro 128K"),
        AIModel(id: "generalv3.5", name: "Spark Max", toolSupport: true),
        AIModel(id: "max-32k", name: "Spark Max 32K", toolSupport: true),
        AIModel(id: "4.0Ultra", name: "Spark 4.0 Ultra", toolSupport: true),
        AIModel(id: "x1", name: "Spark X1", toolSupport: true),
      ]
    case .doubao:
      []
    case .siliconFlow:
      [
        AIModel(id: "Qwen/QwQ-32B", name: "QwQ-32B"),
        AIModel(id: "deepseek-ai/DeepSeek-R1", name: "DeepSeek-R1"),
        AIModel(id: "deepseek-ai/DeepSeek-V3", name: "DeepSeek-V3"),
      ]
    case .openRouter:
      [
        AIModel(id: "deepseek/deepseek-chat", name: "DeepSeek V3"),
        AIModel(id: "qwen/qvq-72b-preview", name: "Qwen: QVQ 72B Preview"),
        AIModel(id: "google/gemini-2.0-flash-thinking-exp:free", name: "Google: Gemini 2.0 Flash Thinking Experimental"),
        AIModel(id: "sao10k/l3.3-euryale-70b", name: "Sao10K: Llama 3.3 Euryale 70B"),
        AIModel(id: "openai/o1", name: "OpenAI: o1"),
      ]
    case .togetherAI:
      [
        AIModel(id: "deepseek-ai/DeepSeek-V3", name: "DeepSeek V3"),
        AIModel(id: "deepseek-ai/DeepSeek-R1", name: "DeepSeek R1"),
        AIModel(id: "Qwen/QwQ-32B", name: "Qwen QwQ 32B"),
      ]
    case .groq:
      [
        AIModel(id: "gemma2-9b-it", name: "Gemma2 9B"),
        AIModel(id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B"),
        AIModel(id: "llama-3.1-8b-instant", name: "Llama 3.1 8B"),
        AIModel(id: "llama3-70b-8192", name: "Llama3 70B 8192"),
        AIModel(id: "mixtral-8x7b-32768", name: "Mixtral 8x7B 32768"),
      ]
    case .ollama:
      []
    case .mistral:
      [
        AIModel(id: "mistral-large-latest", name: "Mistral Large", toolSupport: true),
        AIModel(id: "pixtral-large-latest", name: "Pixtral Large", toolSupport: true, visionSupport: true),
        AIModel(id: "magistral-medium-2509", name: "Magistral Medium"),
        AIModel(id: "ministral-3b-latest", name: "Ministral 3B"),
        AIModel(id: "ministral-8b-latest", name: "Ministral 8B"),
        AIModel(id: "ministral-small-latest", name: "Ministral Small"),
        AIModel(id: "codestral-latest", name: "Codestral"),
      ]
    case .perplexity:
      [
        AIModel(id: "llama-3.1-sonar-small-128k-online", name: "Llama 3.1 Sonar Small 128K Online"),
        AIModel(id: "llama-3.1-sonar-large-128k-online", name: "Llama 3.1 Sonar Large 128K Online"),
        AIModel(id: "llama-3.1-sonar-huge-128k-online", name: "Llama 3.1 Sonar Huge 128K Online"),
      ]
    case .chatGPTPlan:
      // Account-specific list fetched from GET /v1/models after sign-in.
      []
    case .appleLocal:
      [AIModel(id: "apple-foundation", name: "Apple 基础模型（本机）")]
    }
  }
}

public struct AIModel: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var toolSupport: Bool
  public var visionSupport: Bool
  public init(id: String, name: String, toolSupport: Bool = false, visionSupport: Bool = false) {
    self.id = id; self.name = name; self.toolSupport = toolSupport; self.visionSupport = visionSupport
  }
  enum CodingKeys: String, CodingKey { case id, name, toolSupport = "tool_support", visionSupport = "vision_support" }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
    toolSupport = try container.decodeIfPresent(Bool.self, forKey: .toolSupport) ?? false
    visionSupport = try container.decodeIfPresent(Bool.self, forKey: .visionSupport) ?? false
  }
}

/// The source JSON's public configuration fields. Secrets are deliberately a separate, non-Codable type.
public struct AIProviderConfiguration: Codable, Sendable, Equatable {
  public var endpoint: String?
  public var models: [AIModel]
  public var organization: String?
  public var useCodestral: Bool
  public var apiVersion: String?
  /// Non-secret transaction nonce, persisted with the public configuration.
  public var credentialVersion: String?
  /// Public presence flags avoid reading Keychain just to render the settings page.
  public var keyConfigured: Bool = false
  public var secretConfigured: Bool = false
  public var codestralKeyConfigured: Bool = false
  public init(endpoint: String? = nil, models: [AIModel] = [], organization: String? = nil,
    useCodestral: Bool = false, apiVersion: String? = nil) {
    self.endpoint = endpoint; self.models = models; self.organization = organization
    self.useCodestral = useCodestral; self.apiVersion = apiVersion
    credentialVersion = nil
  }
  enum CodingKeys: String, CodingKey {
    case endpoint, models, organization, useCodestral = "use_codestral", apiVersion = "api_version"
    case keyConfigured = "mac_key_configured", secretConfigured = "mac_secret_configured", codestralKeyConfigured = "mac_codestral_key_configured"
    case credentialVersion = "mac_credential_version"
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
    models = try container.decodeIfPresent([AIModel].self, forKey: .models) ?? []
    organization = try container.decodeIfPresent(String.self, forKey: .organization)
    useCodestral = try container.decodeIfPresent(Bool.self, forKey: .useCodestral) ?? false
    apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion)
    credentialVersion = try container.decodeIfPresent(String.self, forKey: .credentialVersion)
    keyConfigured = try container.decodeIfPresent(Bool.self, forKey: .keyConfigured) ?? false
    secretConfigured = try container.decodeIfPresent(Bool.self, forKey: .secretConfigured) ?? false
    codestralKeyConfigured = try container.decodeIfPresent(Bool.self, forKey: .codestralKeyConfigured) ?? false
  }
  public func isConfigured(for provider: AIProvider) -> Bool {
    if provider == .chatGPTPlan { return keyConfigured && !models.isEmpty }
    if provider == .appleLocal { return AppleLocalModel.isAvailable }
    let hasCredentials = provider == .ollama || (provider == .mistral && useCodestral ? codestralKeyConfigured : keyConfigured)
    return hasCredentials && (provider != .ernie || secretConfigured)
      && !availableModels(for: provider).isEmpty
      && (![AIProvider.azureOpenAI, .azureAI].contains(provider) || !(endpoint ?? "").isEmpty)
  }
  public func availableModels(for provider: AIProvider) -> [AIModel] {
    var ids = Set<String>()
    return (provider.predefinedModels + models).filter { ids.insert($0.id).inserted }
  }
}

public struct AIProviderSecrets: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  public var key: String
  public var secret: String?
  public var codestralKey: String?
  /// Stored only in Keychain; binds this record to the committed nonce and destination.
  public var configurationBinding: String?
  public init(key: String, secret: String? = nil, codestralKey: String? = nil) {
    self.key = key; self.secret = secret; self.codestralKey = codestralKey
    configurationBinding = nil
  }
  public var description: String { "AIProviderSecrets(<redacted>)" }
  public var debugDescription: String { description }
}

public struct AIConfigurationSnapshot: Sendable {
  public let provider: AIProvider
  public let configuration: AIProviderConfiguration
  public let secrets: AIProviderSecrets
  public let revision: UInt64
}

public enum AIConfigurationError: Error, LocalizedError, Sendable {
  case invalidConfiguration, missingCredentials, unconfigured, plaintextSecretsForbidden, corruptConfiguration
  case keychain(OSStatus), persistence, rollback, credentialsChanged
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "AI 服务配置无效，请检查终结点和模型标识。"
    case .missingCredentials: "AI 服务密钥未配置。"
    case .unconfigured: "请先保存 AI 服务配置。"
    case .plaintextSecretsForbidden: "检测到旧格式明文密钥，请移除明文字段后通过设置保存到钥匙串。"
    case .corruptConfiguration: "AI 配置文件无法读取。"
    case .keychain(let status): "钥匙串操作失败（\(status)）。"
    case .persistence: "AI 配置无法保存，请检查磁盘与目录权限。"
    case .rollback: "AI 配置保存失败，密钥恢复也失败。请重新保存此服务。"
    case .credentialsChanged: "AI 密钥与配置版本不一致，请重新保存此服务。"
    }
  }
}

public actor AIConfigurationStore {
  private var configurations: [AIProvider: AIProviderConfiguration] = [:]
  private let credentials: any AISecretStore
  private let fileURL: URL?
  private var loaded = false
  private var quarantined: Set<AIProvider> = []
  public private(set) var revision: UInt64 = 0
  private var observers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
  /// Token source for the ChatGPT plan provider; nil in fixtures and tests that do not exercise it.
  public nonisolated let chatGPT: ChatGPTPlanAuth?
  public init(fileURL: URL? = AIConfigurationStore.defaultFileURL, credentials: any AISecretStore = AIKeychainSecretStore(),
    chatGPT: ChatGPTPlanAuth? = nil) {
    self.fileURL = fileURL; self.credentials = credentials; self.chatGPT = chatGPT
  }
  public static var defaultFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Manping", isDirectory: true).appendingPathComponent("ChatClientConfiguration.json")
  }
  public static func fixture(configurations: [AIProvider: AIProviderConfiguration] = [:],
    secrets: [AIProvider: AIProviderSecrets] = [:]) -> AIConfigurationStore {
    var values = configurations
    var boundSecrets = secrets
    for (provider, secret) in secrets where values[provider] != nil {
      values[provider]?.keyConfigured = !secret.key.isEmpty
      values[provider]?.secretConfigured = !(secret.secret ?? "").isEmpty
      values[provider]?.codestralKeyConfigured = !(secret.codestralKey ?? "").isEmpty
      values[provider]?.credentialVersion = UUID().uuidString
      if let configuration = values[provider] {
        boundSecrets[provider]?.configurationBinding = binding(configuration, provider: provider)
      }
    }
    return AIConfigurationStore(configurations: values, credentials: AIMemorySecretStore(values: boundSecrets))
  }
  public static func previewFixture() -> AIConfigurationStore {
    var configuration = AIProviderConfiguration()
    configuration.keyConfigured = true; configuration.credentialVersion = UUID().uuidString
    var secrets = AIProviderSecrets(key: "fixture-ai-key")
    secrets.configurationBinding = binding(configuration, provider: .openAI)
    // The ChatGPT card is shown signed out from memory-only storage; no network or Keychain.
    return AIConfigurationStore(configurations: [.openAI: configuration],
      credentials: AIMemorySecretStore(values: [.openAI: secrets]), chatGPT: ChatGPTPlanAuth(store: ChatGPTPlanMemoryStore()))
  }
  private init(configurations: [AIProvider: AIProviderConfiguration], credentials: any AISecretStore,
    chatGPT: ChatGPTPlanAuth? = nil) {
    self.configurations = configurations; self.credentials = credentials; fileURL = nil; loaded = true; self.chatGPT = chatGPT
  }
  public static func fixture(configurations: [AIProvider: AIProviderConfiguration], chatGPT: ChatGPTPlanAuth) -> AIConfigurationStore {
    AIConfigurationStore(configurations: configurations, credentials: AIMemorySecretStore(), chatGPT: chatGPT)
  }
  public func configuration(for provider: AIProvider) throws -> AIProviderConfiguration? {
    try load()
    // The on-device model has nothing to save: its defaults carry the predefined model.
    if provider == .appleLocal { return configurations[provider] ?? AIProviderConfiguration() }
    return configurations[provider]
  }
  public func allConfigurations() throws -> [AIProvider: AIProviderConfiguration] { try load(); return configurations }
  public func configuredProviders() throws -> [AIProvider] {
    try load()
    return AIProvider.allCases.filter { provider in
      // The on-device model needs no saved configuration: it is ready whenever Apple Intelligence is.
      if provider == .appleLocal { return AppleLocalModel.isAvailable }
      return !quarantined.contains(provider) && configurations[provider]?.isConfigured(for: provider) == true
    }
  }
  public func secrets(for provider: AIProvider) throws -> AIProviderSecrets? { try credentials.load(provider) }
  public func snapshot(for provider: AIProvider) async throws -> AIConfigurationSnapshot {
    try load()
    guard !quarantined.contains(provider) else { throw AIConfigurationError.credentialsChanged }
    if provider == .appleLocal {
      guard AppleLocalModel.isAvailable else { throw AIConfigurationError.unconfigured }
      return AIConfigurationSnapshot(provider: provider, configuration: configurations[provider] ?? AIProviderConfiguration(),
        secrets: AIProviderSecrets(key: ""), revision: revision)
    }
    guard let configuration = configurations[provider] else { throw AIConfigurationError.unconfigured }
    if provider == .chatGPTPlan {
      guard configuration.isConfigured(for: provider), let chatGPT else { throw AIConfigurationError.unconfigured }
      let revision = revision
      // A fresh (refreshed if needed) bearer token is carried only in this in-memory snapshot.
      let token = try await chatGPT.accessToken()
      return AIConfigurationSnapshot(provider: provider, configuration: configuration, secrets: AIProviderSecrets(key: token),
        revision: revision)
    }
    let secrets = try credentials.load(provider) ?? AIProviderSecrets(key: "")
    guard provider == .ollama || (configuration.credentialVersion != nil && secrets.configurationBinding == Self.binding(configuration, provider: provider)) else {
      throw AIConfigurationError.credentialsChanged
    }
    guard provider == .ollama || !(configuration.useCodestral && provider == .mistral ? secrets.codestralKey ?? "" : secrets.key).isEmpty,
      provider != .ernie || !(secrets.secret ?? "").isEmpty else { throw AIConfigurationError.missingCredentials }
    guard !configuration.availableModels(for: provider).isEmpty else { throw AIConfigurationError.invalidConfiguration }
    return AIConfigurationSnapshot(provider: provider, configuration: configuration, secrets: secrets, revision: revision)
  }
  public func changes() -> AsyncStream<UInt64> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      observers[id] = continuation
      continuation.yield(revision)
      continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    }
  }
  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
  private func changed() { revision &+= 1; for observer in observers.values { observer.yield(revision) } }

  public func save(provider: AIProvider, configuration: AIProviderConfiguration, secrets: AIProviderSecrets? = nil) throws {
    try load()
    var configuration = try Self.validated(configuration, provider: provider)
    if let secrets {
      try Self.validateSecrets(secrets)
      configuration.keyConfigured = !secrets.key.isEmpty
      configuration.secretConfigured = !(secrets.secret ?? "").isEmpty
      configuration.codestralKeyConfigured = !(secrets.codestralKey ?? "").isEmpty
    } else {
      configuration.keyConfigured = configurations[provider]?.keyConfigured ?? false
      configuration.secretConfigured = configurations[provider]?.secretConfigured ?? false
      configuration.codestralKeyConfigured = configurations[provider]?.codestralKeyConfigured ?? false
    }
    let previous = configurations[provider]
    let preservesCredential = previous?.keyConfigured == true || previous?.secretConfigured == true
      || previous?.codestralKeyConfigured == true || quarantined.contains(provider)
    // Creating a public configuration without a key needs no Keychain access.
    let oldSecret = secrets != nil || preservesCredential ? try credentials.load(provider) : nil
    var replacement = secrets ?? oldSecret
    configuration.credentialVersion = UUID().uuidString
    replacement?.configurationBinding = Self.binding(configuration, provider: provider)
    if let replacement { try credentials.save(replacement, for: provider) }
    var next = configurations; next[provider] = configuration
    do { try persist(next) }
    catch {
      if replacement != nil {
        do { if let oldSecret { try credentials.save(oldSecret, for: provider) } else { try credentials.delete(provider) } }
        catch { quarantined.insert(provider); changed(); throw AIConfigurationError.rollback }
      }
      throw AIConfigurationError.persistence
    }
    configurations = next; quarantined.remove(provider); changed()
  }
  /// Records whether the ChatGPT plan is signed in and the account's model list (public, non-secret).
  public func setChatGPTPlan(signedIn: Bool, models: [AIModel]) throws {
    try load()
    var configuration = configurations[.chatGPTPlan] ?? AIProviderConfiguration()
    configuration.endpoint = nil; configuration.organization = nil; configuration.apiVersion = nil
    configuration.models = signedIn ? models : configuration.models
    configuration.keyConfigured = signedIn
    configuration = try Self.validated(configuration, provider: .chatGPTPlan)
    var next = configurations; next[.chatGPTPlan] = configuration
    do { try persist(next) } catch { throw AIConfigurationError.persistence }
    configurations = next; changed()
  }
  public func delete(provider: AIProvider) throws {
    try load()
    let old = try credentials.load(provider)
    try credentials.delete(provider)
    var next = configurations; next.removeValue(forKey: provider)
    do { try persist(next) }
    catch {
      if let old { do { try credentials.save(old, for: provider) } catch { quarantined.insert(provider); changed(); throw AIConfigurationError.rollback } }
      throw AIConfigurationError.persistence
    }
    configurations = next; quarantined.remove(provider); changed()
  }
  private static func binding(_ configuration: AIProviderConfiguration, provider: AIProvider) -> String {
    // Fixed public fields, not credentials, determine the binding. A nonce also
    // detects failed key-only updates after restart when the endpoint is unchanged.
    let fields = ["provider": provider.rawValue, "version": configuration.credentialVersion ?? "",
      "endpoint": configuration.endpoint ?? provider.defaultEndpoint ?? "", "organization": configuration.organization ?? "",
      "apiVersion": configuration.apiVersion ?? "", "codestral": configuration.useCodestral ? "yes" : "no"]
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private func load() throws {
    guard !loaded else { return }
    if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
      do { configurations = try Self.decodePublicConfiguration(Data(contentsOf: fileURL)) }
      catch let error as AIConfigurationError { throw error }
      catch { throw AIConfigurationError.corruptConfiguration }
    }
    loaded = true
  }
  private func persist(_ values: [AIProvider: AIProviderConfiguration]) throws {
    guard let fileURL else { return }
    let data = try Self.encodePublicConfiguration(values)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: fileURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
  public static func encodePublicConfiguration(_ values: [AIProvider: AIProviderConfiguration]) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
  }
  public static func decodePublicConfiguration(_ data: Data) throws -> [AIProvider: AIProviderConfiguration] {
    guard data.count <= 2 * 1024 * 1024,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIConfigurationError.corruptConfiguration }
    for value in object.values {
      if let fields = value as? [String: Any], ["key", "secret", "codestral_key"].contains(where: { fields[$0] != nil }) {
        throw AIConfigurationError.plaintextSecretsForbidden
      }
    }
    let decoded = try JSONDecoder().decode([String: AIProviderConfiguration].self, from: data)
    var configurations: [AIProvider: AIProviderConfiguration] = [:]
    for (key, value) in decoded {
      guard let provider = AIProvider(rawValue: key) else { continue }
      configurations[provider] = try validated(value, provider: provider)
    }
    return configurations
  }
  private static func validateSecrets(_ secrets: AIProviderSecrets) throws {
    for value in [secrets.key, secrets.secret ?? "", secrets.codestralKey ?? ""] {
      guard value.utf8.count <= 65536, !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
        throw AIConfigurationError.invalidConfiguration
      }
    }
  }
  private static func validated(_ configuration: AIProviderConfiguration, provider: AIProvider) throws -> AIProviderConfiguration {
    var result = configuration
    result.endpoint = trimmed(result.endpoint); result.organization = trimmed(result.organization); result.apiVersion = trimmed(result.apiVersion)
    if let endpoint = result.endpoint {
      guard endpoint.utf8.count <= 2048, let url = URLComponents(string: endpoint), let host = url.host,
        !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
        url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
        throw AIConfigurationError.invalidConfiguration
      }
    }
    if [.azureOpenAI, .azureAI].contains(provider), result.endpoint == nil { throw AIConfigurationError.invalidConfiguration }
    var ids = Set<String>()
    guard result.models.count <= 1000 else { throw AIConfigurationError.invalidConfiguration }
    for index in result.models.indices {
      result.models[index].id = result.models[index].id.trimmingCharacters(in: .whitespacesAndNewlines)
      result.models[index].name = result.models[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
      let model = result.models[index]
      guard !model.id.isEmpty, model.id.utf8.count <= 512, model.name.utf8.count <= 1024,
        !model.id.contains("\0"), !model.id.contains("\n"), !model.id.contains("\r"), ids.insert(model.id).inserted else {
        throw AIConfigurationError.invalidConfiguration
      }
      if result.models[index].name.isEmpty { result.models[index].name = model.id }
    }
    for value in [result.organization, result.apiVersion].compactMap({ $0 }) {
      guard value.utf8.count <= 512, !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
        throw AIConfigurationError.invalidConfiguration
      }
    }
    return result
  }
  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}
