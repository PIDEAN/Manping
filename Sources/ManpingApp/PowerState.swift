import Combine
import Foundation
import IOKit.ps
import ManpingCore

/// Follows the power source, Low Power Mode and the thermal state, and the 设置 › 播放 › 省电
/// choices (see `PowerSaving` and `PowerPreferences`). `level` is the effective level: 「关闭」
/// keeps it normal, 「始终」 at least light, 「自动」 follows the Mac. While saving, the danmaku
/// overlay draws at most 60 fps and a new engine may pick mpv's `fast` profile, each only when
/// its switch is on; the strongest step can also limit the overlay to 40 lines and make the stage
/// backdrop plain. Video decoding and loading are untouched. Settings changes from any window
/// arrive through `UserDefaults.didChangeNotification`.
@MainActor final class PowerState: ObservableObject {
  static let shared = PowerState()
  /// The effective level, after the 省电模式 setting.
  @Published private(set) var level = PowerSaving.normal
  @Published private(set) var conditions = PowerConditions()
  @Published private(set) var preferences = PowerPreferences(MacSettings())
  /// The strongest step with 「进一步省电」 on: 40 danmaku lines, plain stage backdrop.
  var constrained: Bool { level.furtherSaving(preferences) }
  private var observers: [NSObjectProtocol] = []
  private var powerSource: CFRunLoopSource?

  private init() {
    update()
    let center = NotificationCenter.default
    for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { PowerState.shared.update() }
      })
    }
    // Any window's settings write; only the stored choices are re-read, not the hardware state.
    observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { PowerState.shared.update(readingHardware: false) }
    })
    // Power adapter plugged in or removed; the source is added to the main run loop.
    if let source = IOPSNotificationCreateRunLoopSource({ _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { PowerState.shared.update() } }
    }, nil)?.takeRetainedValue() {
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
      powerSource = source
    }
  }

  /// `MANPING_POWER_SOURCE=battery|ac` overrides the detected source (measurements only).
  nonisolated static func drawsFromBattery() -> Bool {
    if let forced = ProcessInfo.processInfo.environment["MANPING_POWER_SOURCE"] { return forced == "battery" }
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return (type as String) == kIOPSBatteryPowerValue
  }

  private func update(readingHardware: Bool = true) {
    let info = ProcessInfo.processInfo
    let current = readingHardware ? PowerConditions(lowPowerMode: info.isLowPowerModeEnabled,
      thermalState: info.thermalState.rawValue, onBattery: Self.drawsFromBattery()) : conditions
    let chosen = PowerPreferences(MacSettings.load(from: PerformanceEnvironment.defaults))
    let next = PowerSaving.effective(detected: PowerSaving(current), mode: chosen.mode)
    if current != conditions { conditions = current }
    if chosen != preferences { preferences = chosen }
    if next != level { level = next }
  }

  var danmakuLineLimit: Int { level.danmakuLineLimit(preferences) }
  /// The danmaku overlay's frame-rate ceiling for the 弹幕帧率 setting, or nil for the screen's.
  func danmakuFrameCap(setting: String) -> Int? {
    DanmakuFrameRate.cap(setting: setting, saving: level, limitWhileSaving: preferences.danmakuSixty)
  }
  var menuStatus: String? { preferences.menuStatus(conditions) }
  var settingsStatus: String { preferences.settingsStatus(conditions) }
}
