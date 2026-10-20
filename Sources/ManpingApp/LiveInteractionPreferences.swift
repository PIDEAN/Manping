import Combine
import Foundation
import ManpingCore

/// All live windows observe the same preferences; payment permission changes synchronously.
@MainActor final class LiveInteractionPreferences: ObservableObject {
  static let shared = LiveInteractionPreferences()
  let policySource: LiveGiftPolicySource
  @Published private(set) var effective: LiveEffectiveSettings
  private init() {
    let settings = MacSettings.load(from: PerformanceEnvironment.defaults)
    policySource = LiveGiftPolicySource(settings.liveGiftPolicy())
    effective = settings.liveEffective
  }
  func update(_ settings: MacSettings) {
    policySource.update(settings.liveGiftPolicy())
    effective = settings.liveEffective
  }
}
