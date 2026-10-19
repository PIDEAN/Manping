import Foundation

/// How hard playback saves power. Only presentation choices follow it, each behind its own switch
/// in 设置 › 播放 › 省电 (`PowerPreferences`): the danmaku overlay's frame rate and line count, the
/// player stage's backdrop, and whether a new engine drops to mpv's `fast` profile. Decoding,
/// loading, relays and CDN buffering never change with it.
public enum PowerSaving: Int, Comparable, Sendable, CustomStringConvertible {
  /// Not saving power.
  case normal
  /// On battery, or thermal state fair (or 「始终」): danmaku at most 60 fps when that switch is
  /// on; mpv's `fast` profile for the next engine when 「降低画面处理质量」 is on.
  case light
  /// Low Power Mode, or thermal state serious/critical: with 「进一步省电」 on, also at most 40
  /// danmaku lines and a plain stage backdrop.
  case strong

  /// `thermalState` is `ProcessInfo.ThermalState.rawValue` (nominal 0, fair 1, serious 2, critical 3).
  public init(lowPowerMode: Bool, thermalState: Int, onBattery: Bool) {
    if lowPowerMode || thermalState >= 2 { self = .strong }
    else if onBattery || thermalState >= 1 { self = .light }
    else { self = .normal }
  }
  public init(_ conditions: PowerConditions) {
    self.init(lowPowerMode: conditions.lowPowerMode, thermalState: conditions.thermalState, onBattery: conditions.onBattery)
  }
  /// The level playback uses: 「关闭」 never saves, 「始终」 saves at least lightly, 「自动」 follows
  /// what the Mac reports.
  public static func effective(detected: PowerSaving, mode: PowerSavingMode) -> PowerSaving {
    switch mode {
    case .off: .normal
    case .always: max(detected, .light)
    case .auto: detected
    }
  }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  public var description: String { ["normal", "light", "strong"][rawValue] }
  /// The strongest step is in effect and 「低电量模式或严重发热时进一步省电」 allows it: at most 40
  /// danmaku lines, plain stage backdrop.
  public func furtherSaving(_ preferences: PowerPreferences) -> Bool { self == .strong && preferences.strong }
  /// Lines the danmaku overlay draws at once.
  public func danmakuLineLimit(_ preferences: PowerPreferences) -> Int { furtherSaving(preferences) ? 40 : 100 }
}

/// 省电模式 (设置 › 播放 › 省电).
public enum PowerSavingMode: String, CaseIterable, Sendable {
  case auto, always, off
  public var title: String {
    switch self {
    case .auto: "自动"
    case .always: "始终"
    case .off: "关闭"
    }
  }
}

/// What the Mac reports: power source, Low Power Mode, thermal state.
public struct PowerConditions: Equatable, Sendable {
  public var lowPowerMode: Bool
  /// `ProcessInfo.ThermalState.rawValue` (nominal 0, fair 1, serious 2, critical 3).
  public var thermalState: Int
  public var onBattery: Bool
  public init(lowPowerMode: Bool = false, thermalState: Int = 0, onBattery: Bool = false) {
    self.lowPowerMode = lowPowerMode; self.thermalState = thermalState; self.onBattery = onBattery
  }
}

/// The 省电 section of the settings: the mode and what each saving level is allowed to change.
public struct PowerPreferences: Equatable, Sendable {
  public var mode: PowerSavingMode
  /// 「省电时弹幕最高 60 帧」.
  public var danmakuSixty: Bool
  /// 「低电量模式或严重发热时进一步省电」.
  public var strong: Bool
  /// 「省电时降低画面处理质量」.
  public var lowerQuality: Bool
  public init(_ settings: MacSettings) {
    mode = PowerSavingMode(rawValue: settings.text(.powerSavingMode)) ?? .auto
    danmakuSixty = settings.bool(.powerSavingDanmaku60)
    strong = settings.bool(.powerSavingStrong)
    lowerQuality = settings.bool(.powerSavingLowerQuality)
  }

  /// The disabled first line of the player's 「更多」 menu while saving, or nil when not saving.
  public func menuStatus(_ conditions: PowerConditions) -> String? {
    let level = PowerSaving.effective(detected: PowerSaving(conditions), mode: mode)
    guard level > .normal else { return nil }
    let reason = PowerSaving(conditions) == .normal ? "始终省电"
      : conditions.lowPowerMode ? "低电量模式" : conditions.thermalState >= 1 ? "机身发热" : "用电池"
    return "正在省电 · " + reason
  }

  /// The line under 设置 › 播放 › 省电 that says what is happening now.
  public func settingsStatus(_ conditions: PowerConditions) -> String {
    guard mode != .off else { return "省电模式已关闭。" }
    let detected = PowerSaving(conditions)
    let level = PowerSaving.effective(detected: detected, mode: mode)
    var parts: [String] = []
    if conditions.lowPowerMode { parts.append("已开启低电量模式") }
    if conditions.onBattery { parts.append("用电池") }
    if conditions.thermalState >= 2 { parts.append("机身严重发热") }
    else if conditions.thermalState == 1 { parts.append("机身发热") }
    if parts.isEmpty { parts = ["插电", "机身不热"] }
    let tail: String
    if level.furtherSaving(self) { tail = "正在进一步省电。" }
    else if level >= .light { tail = detected == .normal ? "按设置始终省电。" : "正在省电。" }
    else { tail = "未省电。" }
    return "现在：" + parts.joined(separator: "，") + "，" + tail
  }
}

/// 弹幕帧率 (设置 › 弹幕 › 外观): follow the screen, or at most 60 frames a second.
public enum DanmakuFrameRate {
  public static let display = "display"
  public static let sixty = "60"
  /// The overlay's frame-rate ceiling, or nil for the screen's own maximum. The setting and power
  /// saving (when 「省电时弹幕最高 60 帧」 is on) each can lower it; neither raises it.
  public static func cap(setting: String, saving: PowerSaving, limitWhileSaving: Bool) -> Int? {
    setting == sixty || (saving >= .light && limitWhileSaving) ? 60 : nil
  }
}

extension MpvRuntimePlan {
  /// The built-in mpv profile a new engine applies. 「高性能」 always gives `fast`; otherwise
  /// `fast` only while saving power with 「省电时降低画面处理质量」 on, else `high-quality`. The
  /// power state counts at the time the engine is created (a profile change needs a new engine,
  /// so it applies from the next load). A stored 「自动」 from an older build loads as 高质量.
  public static func profile(_ settings: MacSettings, saving: PowerSaving) -> String {
    if settings.text(.mpvProfile) == "fast" { return "fast" }
    return saving >= .light && PowerPreferences(settings).lowerQuality ? "fast" : "high-quality"
  }
}
