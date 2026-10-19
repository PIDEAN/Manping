import Foundation
import XCTest
@testable import ManpingCore

final class PowerPolicyTests: XCTestCase {
  func testPowerSavingSteps() {
    XCTAssertEqual(PowerSaving(lowPowerMode: false, thermalState: 0, onBattery: false), .normal)
    XCTAssertEqual(PowerSaving(lowPowerMode: false, thermalState: 0, onBattery: true), .light)
    XCTAssertEqual(PowerSaving(lowPowerMode: false, thermalState: 1, onBattery: false), .light)
    XCTAssertEqual(PowerSaving(lowPowerMode: false, thermalState: 2, onBattery: false), .strong)
    XCTAssertEqual(PowerSaving(lowPowerMode: false, thermalState: 3, onBattery: true), .strong)
    XCTAssertEqual(PowerSaving(lowPowerMode: true, thermalState: 0, onBattery: false), .strong)
  }

  func testEffectiveLevelFollowsTheMode() {
    for detected in [PowerSaving.normal, .light, .strong] {
      XCTAssertEqual(PowerSaving.effective(detected: detected, mode: .off), .normal)
      XCTAssertEqual(PowerSaving.effective(detected: detected, mode: .auto), detected)
    }
    XCTAssertEqual(PowerSaving.effective(detected: .normal, mode: .always), .light)
    XCTAssertEqual(PowerSaving.effective(detected: .light, mode: .always), .light)
    XCTAssertEqual(PowerSaving.effective(detected: .strong, mode: .always), .strong)
  }

  func testPowerDefaultsAndSection() throws {
    let settings = MacSettings()
    let preferences = PowerPreferences(settings)
    XCTAssertEqual(preferences.mode, .auto)
    XCTAssertTrue(preferences.danmakuSixty)
    XCTAssertTrue(preferences.strong)
    XCTAssertFalse(preferences.lowerQuality)
    XCTAssertEqual(settings.text(.mpvProfile), "high-quality")
    XCTAssertEqual(MacSettingKey.powerSavingMode.rawValue, "Manping.powerSavingMode")
    let sections = MacSettingsCatalog.sections(of: .playback).map(\.title)
    let index = try XCTUnwrap(sections.firstIndex(of: "省电"))
    XCTAssertEqual(sections[index - 1], "进度与倍速")
    XCTAssertEqual(MacSettingsCatalog.sections(of: .playback)[index].descriptors.map(\.key),
      [.powerSavingMode, .powerSavingDanmaku60, .powerSavingStrong, .powerSavingLowerQuality])
    var edited = settings
    XCTAssertFalse(edited.set(.powerSavingMode, .text("sometimes"), capabilities: [.powerSavingMode]))
    XCTAssertTrue(edited.set(.powerSavingMode, .text("off"), capabilities: [.powerSavingMode]))
    XCTAssertEqual(PowerPreferences(edited).mode, .off)
  }

  func testLineLimitNeedsTheStrongSwitch() {
    var settings = MacSettings()
    XCTAssertEqual(PowerSaving.normal.danmakuLineLimit(PowerPreferences(settings)), 100)
    XCTAssertEqual(PowerSaving.light.danmakuLineLimit(PowerPreferences(settings)), 100)
    XCTAssertEqual(PowerSaving.strong.danmakuLineLimit(PowerPreferences(settings)), 40)
    XCTAssertTrue(PowerSaving.strong.furtherSaving(PowerPreferences(settings)))
    XCTAssertTrue(settings.set(.powerSavingStrong, .bool(false), capabilities: [.powerSavingStrong]))
    XCTAssertEqual(PowerSaving.strong.danmakuLineLimit(PowerPreferences(settings)), 100)
    XCTAssertFalse(PowerSaving.strong.furtherSaving(PowerPreferences(settings)))
  }

  func testDanmakuFrameRateCap() {
    XCTAssertNil(DanmakuFrameRate.cap(setting: DanmakuFrameRate.display, saving: .normal, limitWhileSaving: true))
    XCTAssertEqual(DanmakuFrameRate.cap(setting: DanmakuFrameRate.sixty, saving: .normal, limitWhileSaving: true), 60)
    XCTAssertEqual(DanmakuFrameRate.cap(setting: DanmakuFrameRate.display, saving: .light, limitWhileSaving: true), 60)
    XCTAssertEqual(DanmakuFrameRate.cap(setting: DanmakuFrameRate.display, saving: .strong, limitWhileSaving: true), 60)
    XCTAssertNil(DanmakuFrameRate.cap(setting: DanmakuFrameRate.display, saving: .strong, limitWhileSaving: false))
    XCTAssertEqual(DanmakuFrameRate.cap(setting: DanmakuFrameRate.sixty, saving: .light, limitWhileSaving: false), 60)
  }

  func testProfileChoice() {
    var settings = MacSettings()
    XCTAssertEqual(MpvRuntimePlan.profile(settings, saving: .normal), "high-quality")
    XCTAssertEqual(MpvRuntimePlan.profile(settings, saving: .strong), "high-quality")
    XCTAssertTrue(settings.set(.powerSavingLowerQuality, .bool(true), capabilities: [.powerSavingLowerQuality]))
    XCTAssertEqual(MpvRuntimePlan.profile(settings, saving: .normal), "high-quality")
    XCTAssertEqual(MpvRuntimePlan.profile(settings, saving: .light), "fast")
    XCTAssertEqual(MpvRuntimePlan.profile(settings, saving: .strong), "fast")
    XCTAssertTrue(settings.set(.mpvProfile, .text("fast"), capabilities: [.mpvProfile]))
    XCTAssertEqual(MpvRuntimePlan.profile(settings, saving: .normal), "fast")
    XCTAssertFalse(settings.set(.mpvProfile, .text("auto"), capabilities: [.mpvProfile]))
  }

  func testSavedProfilesKeepTheirMeaningAndOldAutomaticBecomesHighQuality() throws {
    let name = "Manping.PowerFixture." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    XCTAssertEqual(MacSettings.load(from: defaults).text(.mpvProfile), "high-quality")
    defaults.set("auto", forKey: MacSettingKey.mpvProfile.rawValue)
    XCTAssertEqual(MacSettings.load(from: defaults).text(.mpvProfile), "high-quality")
    XCTAssertEqual(MpvRuntimePlan.profile(MacSettings.load(from: defaults), saving: .strong), "high-quality")
    defaults.set("fast", forKey: MacSettingKey.mpvProfile.rawValue)
    XCTAssertEqual(MacSettings.load(from: defaults).text(.mpvProfile), "fast")
    XCTAssertEqual(MacSettingKey.mpvProfile.rawValue, "Manping.mpvProfile")
  }

  func testStatusLines() {
    var settings = MacSettings()
    let cool = PowerConditions()
    let battery = PowerConditions(onBattery: true)
    let lowPower = PowerConditions(lowPowerMode: true)
    let warm = PowerConditions(thermalState: 1)
    var preferences = PowerPreferences(settings)
    XCTAssertNil(preferences.menuStatus(cool))
    XCTAssertEqual(preferences.menuStatus(battery), "正在省电 · 用电池")
    XCTAssertEqual(preferences.menuStatus(warm), "正在省电 · 机身发热")
    XCTAssertEqual(preferences.menuStatus(lowPower), "正在省电 · 低电量模式")
    XCTAssertEqual(preferences.settingsStatus(cool), "现在：插电，机身不热，未省电。")
    XCTAssertEqual(preferences.settingsStatus(battery), "现在：用电池，正在省电。")
    XCTAssertEqual(preferences.settingsStatus(lowPower), "现在：已开启低电量模式，正在进一步省电。")
    XCTAssertTrue(settings.set(.powerSavingMode, .text("always"), capabilities: [.powerSavingMode]))
    preferences = PowerPreferences(settings)
    XCTAssertEqual(preferences.menuStatus(cool), "正在省电 · 始终省电")
    XCTAssertEqual(preferences.menuStatus(battery), "正在省电 · 用电池")
    XCTAssertTrue(settings.set(.powerSavingMode, .text("off"), capabilities: [.powerSavingMode]))
    preferences = PowerPreferences(settings)
    XCTAssertNil(preferences.menuStatus(lowPower))
    XCTAssertEqual(preferences.settingsStatus(lowPower), "省电模式已关闭。")
  }

  /// The renderer idles on `hasVisible`; it must agree with `visible` everywhere.
  func testHasVisibleMatchesVisible() {
    var comments: [DanmakuComment] = []
    for (index, time) in stride(from: 0.5, to: 60, by: 0.5).enumerated() where time.truncatingRemainder(dividingBy: 20) < 4 {
      comments.append(DanmakuComment(time: time, mode: [1, 4, 5][index % 3], text: "样本 \(index)"))
    }
    let timeline = DanmakuTimeline(comments: comments)
    XCTAssertFalse(DanmakuTimeline(comments: []).hasVisible(at: 3))
    for speed in [0.5, 1, 2] {
      for step in 0...1300 {
        let clock = Double(step) * 0.05 - 1
        XCTAssertEqual(timeline.hasVisible(at: clock, speed: speed), !timeline.visible(at: clock, speed: speed).isEmpty,
          "clock \(clock) speed \(speed)")
      }
    }
    XCTAssertFalse(timeline.hasVisible(at: .nan))
  }

  func testDanmakuFrameRateSettingSitsInDanmakuAppearance() {
    let descriptor = MacSettingsCatalog.descriptor(.danmakuFrameRate)
    XCTAssertEqual(descriptor.group, .danmaku)
    XCTAssertEqual(descriptor.section, "外观")
    XCTAssertEqual(descriptor.defaultValue, .text(DanmakuFrameRate.display))
    var settings = MacSettings()
    XCTAssertTrue(settings.set(.danmakuFrameRate, .text(DanmakuFrameRate.sixty), capabilities: [.danmakuFrameRate]))
    XCTAssertFalse(settings.set(.danmakuFrameRate, .text("144"), capabilities: [.danmakuFrameRate]))
    XCTAssertEqual(settings.text(.danmakuFrameRate), DanmakuFrameRate.sixty)
  }
}
