import Foundation
import XCTest

@testable import ManpingCore

final class LiveFixturePreferencesTests: XCTestCase {
  func testMemoryStoreTypedReadsRegistrationAndRemoval() {
    let store = MemoryPreferences()
    store.register(defaults: ["flag": true, "fallback": "registered"])
    XCTAssertTrue(store.bool(forKey: "flag"))
    store.set(false, forKey: "flag")
    XCTAssertFalse(store.bool(forKey: "flag"))
    store.removeObject(forKey: "flag")
    XCTAssertTrue(store.bool(forKey: "flag"))
    store.set(1314, forKey: "int")
    store.set(Float(1.5), forKey: "float")
    store.set(2.25, forKey: "double")
    store.set("42", forKey: "numericString")
    store.set(Data([1, 2]), forKey: "data")
    store.set(["a", "b"], forKey: "array")
    store.set(["key": "value"], forKey: "dictionary")
    let url = URL(fileURLWithPath: "/tmp/fixture-only")
    store.set(url, forKey: "url")
    XCTAssertEqual(store.integer(forKey: "int"), 1314)
    XCTAssertEqual(store.float(forKey: "float"), 1.5)
    XCTAssertEqual(store.double(forKey: "double"), 2.25)
    XCTAssertEqual(store.integer(forKey: "numericString"), 42)
    XCTAssertEqual(store.string(forKey: "int"), "1314")
    XCTAssertEqual(store.data(forKey: "data"), Data([1, 2]))
    XCTAssertEqual(store.object(forKey: "array") as? [String], ["a", "b"])
    XCTAssertEqual(store.object(forKey: "dictionary") as? [String: String], ["key": "value"])
    XCTAssertEqual(store.url(forKey: "url"), url)
    store.set(nil as URL?, forKey: "url")
    XCTAssertNil(store.url(forKey: "url"))

    XCTAssertEqual(store.string(forKey: "fallback"), "registered")
  }

  func testMemoryStoresCannotWriteStandardOrShareValues() {
    let key = "fixture-test-" + UUID().uuidString
    let standardBefore = UserDefaults.standard.object(forKey: key) as? String
    let first: any PreferencesStore = MemoryPreferences()
    let second: any PreferencesStore = MemoryPreferences()
    first.set("memory", forKey: key)
    first.set(URL(fileURLWithPath: "/tmp/memory-only"), forKey: key + "url")
    XCTAssertEqual(first.string(forKey: key), "memory")
    XCTAssertNil(second.object(forKey: key))
    XCTAssertNil(second.url(forKey: key + "url"))
    XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? String, standardBefore)
    XCTAssertNil(UserDefaults.standard.object(forKey: key + "url"))
    for key in ["pinnedLiveRooms.v1", "pinnedUsers.v1"] {
      let before = UserDefaults.standard.data(forKey: key)
      let publicFixtureData = Data("[{\"id\":900001}]".utf8)
      first.set(publicFixtureData, forKey: key)
      XCTAssertEqual(first.data(forKey: key), publicFixtureData)
      XCTAssertNil(second.data(forKey: key))
      XCTAssertEqual(UserDefaults.standard.data(forKey: key), before)
    }
    XCTAssertFalse(first is UserDefaults)
  }

  func testMemoryStoreNotifiesWithUpdatedValues() {
    let store = MemoryPreferences(values: ["flag": false])
    let notification = expectation(
      forNotification: UserDefaults.didChangeNotification, object: store
    ) { _ in
      store.bool(forKey: "flag")
    }
    store.set(true, forKey: "flag")
    wait(for: [notification], timeout: 1)
    XCTAssertTrue(store.bool(forKey: "flag"))
    let removal = expectation(forNotification: UserDefaults.didChangeNotification, object: store) {
      _ in
      store.object(forKey: "flag") == nil
    }
    store.removeObject(forKey: "flag")
    wait(for: [removal], timeout: 1)
  }

  func testBackgroundMemoryChangeNotifiesOnMainAfterCommit() {
    let store = MemoryPreferences()
    let notification = expectation(
      forNotification: UserDefaults.didChangeNotification, object: store
    ) { _ in
      Thread.isMainThread && store.bool(forKey: "flag")
    }
    DispatchQueue.global().async { store.set(true, forKey: "flag") }
    wait(for: [notification], timeout: 1)
  }

  func testPreferenceProtocolKeepsNativeUserDefaultsReads() throws {
    // Registration is volatile; this control performs no persistent set or domain mutation.
    let native = try XCTUnwrap(
      UserDefaults(suiteName: "invalid.manping.preference-control." + UUID().uuidString))
    let store: any PreferencesStore = native
    store.register(defaults: ["flag": true, "number": 42, "text": "native"])
    XCTAssertTrue(store.bool(forKey: "flag"))
    XCTAssertEqual(store.integer(forKey: "number"), native.integer(forKey: "number"))
    XCTAssertEqual(store.string(forKey: "text"), native.string(forKey: "text"))
    XCTAssertTrue((store as? UserDefaults) === native)
  }

  func testMalformedSceneArgumentsStillRequireMemory() {
    XCTAssertFalse(LiveFixturePresentation.requiresMemory(arguments: []))
    XCTAssertTrue(LiveFixturePresentation.requiresMemory(arguments: ["--ui-live-scene"]))
    XCTAssertTrue(
      LiveFixturePresentation.requiresMemory(arguments: ["--ui-live-scene", "unknown"]))
    XCTAssertTrue(
      LiveFixturePresentation.requiresMemory(arguments: ["--ui-fixture", "--ui-live-scene", "main"])
    )
  }

  func testSettingsAndProxyCommitsUseOnlyTheInjectedMemoryStore() throws {
    let store = MemoryPreferences()
    let separate = MemoryPreferences()
    let settings = try XCTUnwrap(
      MacSettings.committing(
        .livePureMode, .bool(true), capabilities: Set(MacSettingKey.allCases), to: store))
    XCTAssertTrue(settings.bool(.livePureMode))
    XCTAssertTrue(MacSettings.load(from: store).bool(.livePureMode))
    XCTAssertFalse(MacSettings.load(from: separate).bool(.livePureMode))
    let proxy = ProxySettings()
    proxy.save(to: store)
    XCTAssertNotNil(store.data(forKey: ProxySettings.defaultsKey))
    XCTAssertEqual(ProxySettings.load(from: store), proxy)
    XCTAssertNil(separate.data(forKey: ProxySettings.defaultsKey))
  }

  func testAllScenesSpecifyIndependentSidebarAndSettingsTargets() throws {
    let hidden = Set([
      "sidebar-hidden", "fullscreen", "narrow", "fullscreen-unknown", "sidebar-unknown",
    ])
    let settings = Set(["settings-live", "settings-paid", "settings-pure"])
    XCTAssertEqual(LiveSessionFixture.scenes.count, 59)
    for scene in LiveSessionFixture.scenes {
      let presentation = try XCTUnwrap(LiveFixturePresentation(scene: scene))
      XCTAssertEqual(presentation.sidebarHidden, hidden.contains(scene), scene)
      XCTAssertEqual(presentation.opensLiveSettings, settings.contains(scene), scene)
      let store = presentation.makeDefaults(sidebarKey: "sidebar")
      XCTAssertEqual(store.bool(forKey: "sidebar"), hidden.contains(scene), scene)
      let loaded = MacSettings.load(from: store)
      for descriptor in MacSettingsCatalog.descriptors {
        XCTAssertEqual(
          loaded[descriptor.key], presentation.settings[descriptor.key],
          scene + ":" + descriptor.key.rawValue)
      }
    }
    XCTAssertNil(LiveFixturePresentation(scene: "unknown-scene"))
    let pure = try XCTUnwrap(LiveFixturePresentation(scene: "settings-pure")).makeDefaults(
      sidebarKey: "sidebar")
    let main = try XCTUnwrap(LiveFixturePresentation(scene: "main")).makeDefaults(
      sidebarKey: "sidebar")
    pure.set(true, forKey: "sidebar")
    XCTAssertTrue(pure.bool(forKey: MacSettingKey.livePureMode.rawValue))
    XCTAssertFalse(main.bool(forKey: MacSettingKey.livePureMode.rawValue))
    XCTAssertFalse(main.bool(forKey: "sidebar"))
  }
}
