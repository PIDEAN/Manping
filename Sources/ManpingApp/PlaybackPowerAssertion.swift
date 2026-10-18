import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while media is actually playing. libmpv's render API does not
/// manage the screensaver, so without this an idle Mac dims and sleeps mid-video.
/// Paused, finished, idle or closed playback releases the assertion at once.
@MainActor final class PlaybackPowerAssertion {
  private var assertion: IOPMAssertionID = 0
  private(set) var held = false

  func update(playing: Bool) {
    if playing == held { return }
    if playing {
      var id: IOPMAssertionID = 0
      let result = IOPMAssertionCreateWithName(
        kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "ManpingApp video playback" as CFString, &id)
      guard result == kIOReturnSuccess else { return }
      assertion = id
      held = true
    } else {
      IOPMAssertionRelease(assertion)
      assertion = 0
      held = false
    }
  }

  func release() { update(playing: false) }
}
