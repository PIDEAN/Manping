import Foundation
import FoundationModels

/// Apple's on-device foundation model (Apple Intelligence): free, offline, no account or key.
/// Its context window is small, so long prompts keep their head (instructions and metadata)
/// and their tail (the question) and drop the middle of the subtitle / comment material.
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

  /// Characters of prompt kept; the model shares about 4K tokens between prompt and answer.
  static let promptBudget = 2_600

  static func fitted(_ prompt: String) -> String {
    guard prompt.count > promptBudget else { return prompt }
    let head = prompt.prefix(promptBudget * 3 / 4)
    let tail = prompt.suffix(promptBudget / 4)
    return head + "\n……（内容过长，中间部分已省略）……\n" + tail
  }

  /// Streams text deltas of one answer.
  static func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard isAvailable else { throw AIChatFailure.localModelUnavailable }
          let session = LanguageModelSession(instructions: "你是哔哩哔哩内容助手。请用简体中文回答，条理清晰，不编造视频中没有的内容。")
          var sent = ""
          for try await snapshot in session.streamResponse(to: fitted(prompt)) {
            try Task.checkCancellation()
            let text = snapshot.content
            if text.hasPrefix(sent) {
              let delta = String(text.dropFirst(sent.count))
              if !delta.isEmpty, case .terminated = continuation.yield(delta) { throw CancellationError() }
            }
            sent = text
          }
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
