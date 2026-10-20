import Foundation

/// Shared session preparation used by the App and deterministic tests. The identity is
/// published before validation, so an identity event cannot fall into an unbound gap.
public enum LiveChatSession {
  @MainActor public static func captureIdentity(
    snapshot: @Sendable () async -> AuthSnapshot,
    publish: @MainActor (AuthSnapshot) -> Void,
    isIdentityCurrent: @Sendable (AuthSnapshot) async -> Bool,
    isGenerationCurrent: @MainActor () -> Bool
  ) async throws -> AuthSnapshot {
    while true {
      try Task.checkCancellation()
      guard isGenerationCurrent() else { throw CancellationError() }
      let identity = await snapshot()
      try Task.checkCancellation()
      guard isGenerationCurrent() else { throw CancellationError() }
      publish(identity)
      let matches = await isIdentityCurrent(identity)
      try Task.checkCancellation()
      guard isGenerationCurrent() else { throw CancellationError() }
      if matches { return identity }
      // The initial observer may already have consumed the change while unbound. Capture
      // again in this generation rather than waiting for an event that will never repeat.
    }
  }

  /// Only failed endpoint preparation consumes an attempt; successful preparation passes
  /// the same budget to LiveChatClient, where socket attempts consume the remainder.
  public static func endpoint(
    budget: LiveChatBudget,
    load: @Sendable () async throws -> LiveChatEndpoint,
    isIdentityCurrent: @Sendable () async -> Bool,
    reconnectDelay: Duration = .seconds(3),
    sleep: LiveChatClient.Sleep = { try await Task.sleep(for: $0) }
  ) async throws -> LiveChatEndpoint {
    func checkIdentity() async throws {
      try Task.checkCancellation()
      let matches = await isIdentityCurrent()
      try Task.checkCancellation()
      guard matches else { throw LiveChatFailure.identityChanged }
    }
    while true {
      try await checkIdentity()
      let remaining = await budget.remaining
      try await checkIdentity()
      guard remaining > 0 else { throw LiveChatFailure.budgetExhausted }
      do {
        let endpoint = try await load()
        try await checkIdentity()
        return endpoint
      } catch is CancellationError { throw CancellationError() } catch {
        try await checkIdentity()
        let failure = LiveChatFailure.classify(error)
        if failure.terminal { throw failure }
        let allowed = await budget.consume()
        try await checkIdentity()
        let remaining = await budget.remaining
        try await checkIdentity()
        guard allowed, remaining > 0 else { throw LiveChatFailure.budgetExhausted }
        try await sleep(reconnectDelay)
        try await checkIdentity()
      }
    }
  }
}
