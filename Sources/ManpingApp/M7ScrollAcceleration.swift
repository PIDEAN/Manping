import AppKit

/// Accelerates physical mouse-wheel pulses only. Trackpad gestures and momentum retain system behavior.
@MainActor final class M7ScrollAcceleration {
  private var monitor: Any?
  private var previousTime: TimeInterval = 0
  private var previousDirection: Double = 0
  private var burst = 0

  func setEnabled(_ enabled: Bool) {
    guard enabled != (monitor != nil) else { return }
    if !enabled {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil; burst = 0; return
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self, !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty,
        event.window != nil, let cgEvent = event.cgEvent?.copy() else { return event }
      let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
      guard delta != 0 else { return event }
      let direction = delta > 0 ? 1.0 : -1.0
      if event.timestamp - previousTime < 0.2 && direction == previousDirection { burst = min(burst + 1, 8) }
      else { burst = 0 }
      previousTime = event.timestamp; previousDirection = direction
      let multiplier = 1.5 + Double(burst) * 0.15
      for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
        cgEvent.setIntegerValueField(field, value: Int64((Double(cgEvent.getIntegerValueField(field)) * multiplier).rounded()))
      }
      return NSEvent(cgEvent: cgEvent) ?? event
    }
  }

  func stop() { setEnabled(false) }
}
