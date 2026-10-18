import Combine
import Foundation

/// Low Power Mode or serious thermal pressure: the danmaku overlay draws at most 60 fps with
/// fewer lines until the Mac is back to normal. Video decoding is untouched.
@MainActor final class PowerState: ObservableObject {
  static let shared = PowerState()
  @Published private(set) var constrained = false
  private var observers: [NSObjectProtocol] = []

  private init() {
    update()
    let center = NotificationCenter.default
    for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { PowerState.shared.update() }
      })
    }
  }

  private func update() {
    let info = ProcessInfo.processInfo
    let next = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    if next != constrained { constrained = next }
  }

  var danmakuLineLimit: Int { constrained ? 40 : 100 }
}
