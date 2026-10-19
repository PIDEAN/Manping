import Foundation
import XCTest
@testable import ManpingCore

final class M7SettingsTests: XCTestCase {
  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "Manping.SettingsFixture." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }
  func testLegacyPreferencesLoadAndAutoQualityRemovesOldSelection() throws {
    try withDefaults { defaults in
      defaults.set("深色", forKey: "appTheme")
      defaults.set("hevc", forKey: "preferredCodec")
      defaults.set(80, forKey: "preferredVideoQuality")
      defaults.set(true, forKey: "playWithoutP2P")
      var settings = MacSettings.load(from: defaults)
      XCTAssertEqual(settings.text(.theme), "深色")
      XCTAssertEqual(settings.text(.codec), "hevc")
      XCTAssertEqual(settings.number(.quality), 80)
      XCTAssertTrue(settings.bool(.avoidP2P))
      XCTAssertTrue(settings.set(.quality, .number(0), capabilities: [.quality]))
      settings.save(.quality, to: defaults)
      XCTAssertNil(defaults.object(forKey: "preferredVideoQuality"))
      XCTAssertEqual(MacSettings.load(from: defaults).number(.quality), 0)
    }
  }
  func testFiniteRangesInvalidChoiceAndPlatformConstraints() {
    var settings = MacSettings()
    XCTAssertTrue(settings.set(.stepForward, .number(99999), capabilities: [.stepForward]))
    XCTAssertEqual(settings.number(.stepForward), 600)
    XCTAssertFalse(settings.set(.stepForward, .number(.infinity), capabilities: [.stepForward]))
    XCTAssertFalse(settings.set(.codec, .text("unrecognized"), capabilities: [.codec]))
    XCTAssertEqual(settings.text(.codec), "h264")
    XCTAssertTrue(settings.set(.notifications, .bool(true), capabilities: [.notifications]))
    XCTAssertFalse(settings.set(.globalSpeed, .bool(false), capabilities: []))
    XCTAssertTrue(settings.bool(.globalSpeed))
  }
  func testInvalidPersistedValuesFallBackWithoutMutatingOtherPreferences() throws {
    try withDefaults { defaults in
      defaults.set("unexpected", forKey: MacSettingKey.theme.rawValue)
      defaults.set("av1", forKey: MacSettingKey.codec.rawValue)
      defaults.set("not-a-number", forKey: MacSettingKey.stepForward.rawValue)
      defaults.set(true, forKey: MacSettingKey.volume.rawValue)
      defaults.set("fixture-private-value", forKey: "UnrelatedPreference")
      let settings = MacSettings.load(from: defaults)
      XCTAssertEqual(settings.text(.theme), "跟随系统")
      XCTAssertEqual(settings.text(.codec), "av1")
      XCTAssertEqual(settings.number(.stepForward), 30)
      XCTAssertEqual(settings.number(.volume), 80)
      settings.save(.theme, to: defaults)
      XCTAssertEqual(defaults.string(forKey: "UnrelatedPreference"), "fixture-private-value")
    }
  }
  func testPathsRejectRelativeDirectoriesAndControlCharacters() {
    var settings = MacSettings()
    XCTAssertFalse(settings.set(.downloadDirectory, .text("../Downloads"), capabilities: [.downloadDirectory]))
    XCTAssertFalse(settings.set(.bbdownPath, .text("BBDown\nsecond"), capabilities: [.bbdownPath]))
    XCTAssertTrue(settings.set(.downloadDirectory, .text("/tmp/Bili Fixture"), capabilities: [.downloadDirectory]))
    XCTAssertTrue(settings.set(.bbdownPath, .text("BBDown"), capabilities: [.bbdownPath]))
    XCTAssertEqual(settings.text(.downloadDirectory), "/tmp/Bili Fixture")
    XCTAssertEqual(Set(MacSettingsCatalog.descriptors.map(\.key)).count, MacSettingKey.allCases.count)
  }
  func testWindowsOnlyOptionsAreRetiredAndTheirSavedValuesAreLeftAlone() throws {
    for raw in MacSettingsCatalog.retiredKeys {
      XCTAssertNil(MacSettingKey(rawValue: raw))
      XCTAssertFalse(MacSettingsCatalog.descriptors.contains { $0.key.rawValue == raw })
    }
    try withDefaults { defaults in
      defaults.set(true, forKey: "Manping.nvdec")
      defaults.set(false, forKey: "Manping.topNavigation")
      var settings = MacSettings.load(from: defaults)
      XCTAssertTrue(settings.set(.notifications, .bool(true), capabilities: [.notifications]))
      settings.save(.notifications, to: defaults)
      XCTAssertEqual(defaults.object(forKey: "Manping.nvdec") as? Bool, true)
      XCTAssertEqual(defaults.object(forKey: "Manping.topNavigation") as? Bool, false)
    }
  }
  func testEveryGroupButAIHasTitledSectionsWithSentenceDetails() {
    for group in MacSettingGroup.allCases where group != .ai {
      let sections = MacSettingsCatalog.sections(of: group)
      XCTAssertFalse(sections.isEmpty, group.rawValue)
      XCTAssertTrue(sections.allSatisfy { !$0.title.isEmpty && !$0.descriptors.isEmpty }, group.rawValue)
    }
    XCTAssertTrue(MacSettingsCatalog.sections(of: .ai).isEmpty)
    for descriptor in MacSettingsCatalog.descriptors {
      XCTAssertFalse(descriptor.title.hasSuffix("。"), descriptor.title)
      if !descriptor.detail.isEmpty { XCTAssertTrue(descriptor.detail.hasSuffix("。"), descriptor.title) }
      XCTAssertFalse(descriptor.detail.contains("PGC"), descriptor.title)
    }
    XCTAssertEqual(MacSettingsCatalog.sections(of: .general).map(\.title), ["外观", "侧边栏项目", "搜索建议", "滚动加速"])
  }
  func testOpenModeReadsAndWritesTheTwoOriginalKeys() {
    var settings = MacSettings()
    XCTAssertEqual(MacOpenMode(settings), .mainWindow)
    for mode in MacOpenMode.allCases {
      for (key, value) in mode.values {
        XCTAssertTrue(settings.set(key, value, capabilities: MacSettingsCatalog.openModeKeys))
      }
      XCTAssertEqual(MacOpenMode(settings), mode)
    }
    XCTAssertTrue(settings.set(.integratedPlayer, .bool(false), capabilities: [.integratedPlayer]))
    XCTAssertTrue(settings.set(.displayMode, .text("compact"), capabilities: [.displayMode]))
    XCTAssertEqual(MacOpenMode(settings), .detached)
  }
  func testMacOptionsKeepTheirPathAndValueConstraints() {
    var settings = MacSettings()
    XCTAssertTrue(settings.set(.audioExclusive, .bool(true), capabilities: [.audioExclusive]))
    XCTAssertFalse(settings.set(.customMpv, .text("../mpv"), capabilities: [.customMpv]))
    XCTAssertFalse(settings.set(.customLibMpv, .text("relative.dylib"), capabilities: [.customLibMpv]))
    XCTAssertTrue(settings.set(.customMpv, .text("/tmp/fixture/mpv"), capabilities: [.customMpv]))
    XCTAssertTrue(settings.set(.customLibMpv, .text("/tmp/fixture/libmpv.dylib"), capabilities: [.customLibMpv]))
    XCTAssertTrue(settings.set(.mpvProfile, .text("fast"), capabilities: [.mpvProfile]))
    XCTAssertTrue(settings.set(.logLevel, .text("v"), capabilities: [.logLevel]))
  }
  func testMomentNotificationsMatchLatestThreeAndRetainTenIDs() {
    let moments = (1...5).map { M7MomentNotification(id: String($0), title: "Fixture", publisher: "Sample",
      page: "video", mediaID: "100") }
    let plan = M7MomentNotificationPolicy.plan(moments, previousIDs: ["2", "old1", "old2", "old3", "old4", "old5", "old6", "old7", "old8", "old9"])
    XCTAssertEqual(plan.notifications.map(\.id), ["1", "3"])
    XCTAssertEqual(plan.rememberedIDs, ["1", "2", "3", "old1", "old2", "old3", "old4", "old5", "old6", "old7"])
    let repeatPlan = M7MomentNotificationPolicy.plan(moments, previousIDs: plan.rememberedIDs)
    XCTAssertTrue(repeatPlan.notifications.isEmpty)
    XCTAssertEqual(M7MomentNotificationPolicy.plan([], previousIDs: ["old"]).rememberedIDs, ["old"])
  }
  func testMomentNotificationDeduplicatesWithinFirstThreeWithoutPullingOlderEntries() {
    let moment = M7MomentNotification(id: "1", title: "Fixture", publisher: "Sample", page: "video", mediaID: "100")
    let ignored = M7MomentNotification(id: "4", title: "Older", publisher: "Sample", page: "video", mediaID: "101")
    let plan = M7MomentNotificationPolicy.plan([moment, moment, moment, ignored], previousIDs: [])
    XCTAssertEqual(plan.notifications, [moment])
    XCTAssertEqual(plan.rememberedIDs, ["1"])
  }

}
