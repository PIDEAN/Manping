import Foundation

public struct AIProviderRegion: Sendable {
  public let name: String
  public let endpoint: String
}
extension AIProvider {
  public var regions: [AIProviderRegion] {
    let values: [(String, String)]
    switch self {
    case .moonshot: values = [("中国", "https://api.moonshot.cn/v1"), ("国际", "https://api.moonshot.ai/v1")]
    case .qwen: values = [("中国", "https://dashscope.aliyuncs.com/compatible-mode/v1"), ("国际", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"), ("美国", "https://dashscope-us.aliyuncs.com/compatible-mode/v1")]
    case .zhiPu: values = [("中国", "https://open.bigmodel.cn/api/paas/v4"), ("国际", "https://api.z.ai/api/paas/v4")]
    case .minimax, .minimaxPlan: values = [("国际", "https://api.minimax.io/v1"), ("中国", "https://api.minimax.cn/v1")]
    case .mimoTokenPlan: values = [("中国", "https://token-plan-cn.xiaomimimo.com/v1"), ("新加坡", "https://token-plan-sgp.xiaomimimo.com/v1"), ("阿姆斯特丹", "https://token-plan-ams.xiaomimimo.com/v1")]
    default: values = []
    }
    return values.map { AIProviderRegion(name: $0.0, endpoint: $0.1) }
  }
}

/// No account or device information; one random session identifier per process launch.
enum AIOpenCodeHeaders {
  static let session = UUID().uuidString
  static let userAgent = "Manping/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
}

public enum AIOpenCodeRouting {
  /// Exact official tables verified 2026-10-20. Unknown IDs use Chat Completions.
  /// https://opencode.ai/v2/docs/console/models/ and /v2/docs/console/go/
  public static func family(provider: AIProvider, model: String) -> AIProtocolFamily {
    let anthropic: Set<String>
    let responses: Set<String>
    let google: Set<String>
    if provider == .opencodeGo {
      anthropic = ["claude-haiku-5-5", "minimax-m3", "qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"]
      responses = ["grok-4.7", "gpt-6-luna", "gpt-5.6-luna", "muse-spark-1.3-contributor", "muse-spark-1.2-contributor"]
      google = ["gemini-4-argon-contributor"]
    } else {
      anthropic = ["claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5", "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-haiku-5-5", "claude-haiku-4-5", "qwen3.8-flash", "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus", "qwen3.5-plus"]
      responses = ["gpt-6-astra", "gpt-6-sol", "gpt-6.1-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.4-pro", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.3-codex", "gpt-5.3-codex-spark", "gpt-5.2", "gpt-5.2-codex", "gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5.1-codex-mini", "gpt-5", "gpt-5-codex", "gpt-5-nano", "grok-4.7", "grok-4.6", "grok-4.5", "grok-build-0.1", "muse-spark-1.3", "muse-spark-1.2"]
      google = ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3.1-pro", "gemini-3-flash"]
    }
    if anthropic.contains(model) { return .anthropic }
    if responses.contains(model) { return .responses }
    if google.contains(model) { return .gemini }
    return .openAI
  }
}

public struct AIUnsupportedSubscription: Identifiable, Sendable {
  public var id: String { title }
  public let title: String
  public let reason: String
  public let url: URL
  public static let all: [AIUnsupportedSubscription] = [
    .init(title: "百炼 Coding Plan", reason: "仅限编程工具，禁止自定义应用后端、自动脚本和非交互批量调用。", url: URL(string: "https://help.aliyun.com/zh/model-studio/coding-plan")!),
    .init(title: "百炼 Token Plan", reason: "仅限交互式 AI 编程工具，不允许应用后端等用途。", url: URL(string: "https://www.alibabacloud.com/help/en/model-studio/base-url")!),
    .init(title: "智谱 GLM Coding Plan", reason: "仅限指定的编程工具和产品环境。", url: URL(string: "https://docs.bigmodel.cn/cn/coding-plan/usage-notes")!),
    .init(title: "火山方舟 Coding Plan", reason: "不能用于普通 API 调用，非 AI 编程工具可能被封禁。", url: URL(string: "https://www.volcengine.com/docs/82379/1925114")!),
    .init(title: "Kimi Code", reason: "仅限个人交互式编程；禁止非交互自动化与伪装客户端身份。", url: URL(string: "https://www.kimi.com/code/docs/en/kimi-code/community-guidelines.html")!),
    .init(title: "Claude 订阅", reason: "禁止第三方应用代用 Free／Pro／Max 登录凭据。", url: URL(string: "https://code.claude.com/docs/en/legal-and-compliance")!),
    .init(title: "Gemini 订阅／CLI OAuth", reason: "禁止第三方直接使用 Gemini CLI 的底层服务和 OAuth 凭据。", url: URL(string: "https://geminicli.com/docs/resources/tos-privacy/")!),
  ]
}
