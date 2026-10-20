import ManpingCore
import SwiftUI

extension View {
  /// Only real persistent stores are passed to AppStorage. Live fixtures use explicit state.
  @ViewBuilder func persistentAppStorage() -> some View {
    if let defaults = PerformanceEnvironment.persistentDefaults {
      defaultAppStorage(defaults)
    } else {
      self
    }
  }
}
