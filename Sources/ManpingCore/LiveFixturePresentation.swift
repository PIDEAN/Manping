import Foundation

/// Scene intent is independent of the previous process and of every user's saved settings.
public struct LiveFixturePresentation: Sendable {
  public let sidebarHidden: Bool
  public let opensLiveSettings: Bool
  public let settings: MacSettings

  public static func requiresMemory(arguments: [String]) -> Bool {
    arguments.contains("--ui-live-scene")
  }

  public init?(scene: String) {
    guard LiveSessionFixture.scenes.contains(scene) else { return nil }
    sidebarHidden = [
      "fullscreen", "fullscreen-unknown", "sidebar-hidden", "sidebar-unknown", "narrow",
    ].contains(scene)
    opensLiveSettings = ["settings-live", "settings-paid", "settings-pure"].contains(scene)
    var settings = MacSettings()
    let capabilities = Set(MacSettingKey.allCases)
    let paid = [
      "gift-confirm", "gift-confirm-high", "gift-sending", "confirmation-required",
      "gift-success", "rejected", "timeout", "late", "executedResponseLost", "unknown-cross-room",
      "fullscreen-unknown", "sidebar-unknown", "settings-paid",
    ].contains(scene)
    settings.set(.liveAllowPaidGifts, .bool(paid), capabilities: capabilities)
    settings.set(
      .powerSavingMode, .text(scene == "effects-power" ? "always" : "off"),
      capabilities: capabilities)
    settings.set(
      .livePureMode, .bool(["pure", "settings-pure"].contains(scene)), capabilities: capabilities)
    settings.set(.liveHideGifting, .bool(scene == "hide-gifting"), capabilities: capabilities)
    if scene == "effects-disabled" {
      for key: MacSettingKey in [
        .liveGiftEffects, .liveGuardEffects, .liveSuperChatEffects, .liveLotteryBanner,
        .liveInteractNotices,
      ] {
        settings.set(key, .bool(false), capabilities: capabilities)
      }
    }
    self.settings = settings
  }

  public func makeDefaults(sidebarKey: String) -> MemoryPreferences {
    var values: [String: Any] = [sidebarKey: NSNumber(value: sidebarHidden)]
    for descriptor in MacSettingsCatalog.descriptors {
      switch settings[descriptor.key] {
      case .bool(let value): values[descriptor.key.rawValue] = NSNumber(value: value)
      case .number(let value): values[descriptor.key.rawValue] = NSNumber(value: value)
      case .text(let value): values[descriptor.key.rawValue] = value
      }
    }
    return MemoryPreferences(values: values)
  }
}
