import Foundation
import FoundationModels

/// Apple's on-device foundation model (Apple Intelligence): free, offline, no account or key.
/// Its context window is small. Prompts are never silently cut: callers plan with
/// `requestBudget` (the SDK's own context size) and send long material through segmented
/// summaries; a prompt that still does not fit fails with `localContextTooLong`.
public enum AppleLocalModel {
  /// nil when the model can answer now; otherwise why not, for the settings card.
  public static var unavailableReason: String? {
    switch SystemLanguageModel.default.availability {
    case .available: return nil
    case .unavailable(.deviceNotEligible): return "这台 Mac 不支持 Apple 智能。"
    case .unavailable(.appleIntelligenceNotEnabled): return "请先在「系统设置 › Apple 智能与 Siri」中开启 Apple 智能。"
    case .unavailable(.modelNotReady): return "本地模型仍在下载或准备中，请稍后再试。"
    case .unavailable: return "本地模型暂不可用。"
    }
  }
  public static var isAvailable: Bool { unavailableReason == nil }

  static let defaultInstructions = "你是哔哩哔哩内容助手。请用简体中文回答，条理清晰，不编造视频中没有的内容。"
  /// The on-device budget: the SDK's context size, a quarter of it reserved for the answer.
  public static func requestBudget() -> AIRequestBudget {
    let context = SystemLanguageModel.default.contextSize
    return AIRequestBudget(contextTokens: context, maxOutputTokens: max(512, context / 4), known: true)
  }
  /// Instructions and one prompt for a conversation, every message kept in full.
  static func prompt(for conversation: AIConversationRequest) -> (instructions: String, prompt: String) {
    let instructions = conversation.system.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? defaultInstructions
    let prompt: String
    if conversation.messages.count == 1, let only = conversation.messages.first { prompt = only.text }
    else {
      prompt = conversation.messages.map { ($0.role == .user ? "用户：" : "助手：") + $0.text }.joined(separator: "\n\n")
    }
    return (instructions, prompt)
  }

  /// Streams text deltas of one answer.
  static func stream(_ conversation: AIConversationRequest) -> AsyncThrowingStream<String, Error> {
    let parts = prompt(for: conversation)
    return stream(instructions: parts.instructions, prompt: parts.prompt)
  }
  static func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard isAvailable else { throw AIChatFailure.localModelUnavailable }
          let session = LanguageModelSession(instructions: instructions)
          var sent = ""
          for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            let text = snapshot.content
            if text.hasPrefix(sent) {
              let delta = String(text.dropFirst(sent.count))
              if !delta.isEmpty, case .terminated = continuation.yield(delta) { throw CancellationError() }
            }
            sent = text
          }
          guard !sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIChatFailure.emptyResponse }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let failure as AIChatFailure {
          continuation.finish(throwing: failure)
        } catch let error as LanguageModelSession.GenerationError {
          if case .exceededContextWindowSize = error { continuation.finish(throwing: AIChatFailure.localContextTooLong) }
          else if case .guardrailViolation = error { continuation.finish(throwing: AIChatFailure.localRefused) }
          else { continuation.finish(throwing: AIChatFailure.localModelUnavailable) }
        } catch {
          continuation.finish(throwing: AIChatFailure.localModelUnavailable)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
