import AppKit
import ManpingCore
import Foundation
import SwiftUI

@MainActor final class M7SettingsModel: ObservableObject {
  @Published private(set) var values: MacSettings
  @Published private(set) var clearing = false
  @Published private(set) var status: String?
  let capabilities: Set<MacSettingKey>
  private let defaults: any PreferencesStore
  private let apply: (MacSettings) -> Void
  private let clearImages: (() async throws -> Void)?
  private let screenshot: (() -> Void)?
  init(
    defaults: any PreferencesStore = PerformanceEnvironment.defaults,
    capabilities: Set<MacSettingKey>,
    apply: @escaping (MacSettings) -> Void,
    clearImageCache: (() async throws -> Void)? = nil, takeScreenshot: (() -> Void)? = nil) {
    self.defaults = defaults; self.capabilities = capabilities
    self.apply = apply; clearImages = clearImageCache; screenshot = takeScreenshot; values = MacSettings.load(from: defaults)
  }
  var canClearImages: Bool { clearImages != nil && !clearing }
  func takeScreenshot() { screenshot?() }
  func reason(_ descriptor: MacSettingDescriptor) -> String? {
    capabilities.contains(descriptor.key) ? nil : "这个功能暂时还不能在 Mac 上使用。"
  }
  /// The one path for preference changes (settings window, player menus, danmaku panel). The
  /// field is merged into what is stored now, so a value saved elsewhere since this model last
  /// read the store is kept rather than overwritten by an old copy.
  func set(_ key: MacSettingKey, _ value: MacSettingValue) {
    guard let merged = MacSettings.committing(key, value, capabilities: capabilities, to: defaults) else {
      status = "此项不可用，或输入值无效。"; return
    }
    values = merged; apply(merged); status = nil
  }
  func reload() { values = MacSettings.load(from: defaults) }
  func choosePath(_ descriptor: MacSettingDescriptor) {
    guard reason(descriptor) == nil else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
    if case .executable = descriptor.control { panel.canChooseDirectories = false; panel.canChooseFiles = true }
    else { panel.canChooseDirectories = true; panel.canChooseFiles = false }
    let current = values.text(descriptor.key)
    if current.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
    panel.prompt = "选择"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.set(descriptor.key, .text(url.path))
    }
  }
  func openFolder(_ key: MacSettingKey) {
    let path = values.text(key)
    var directory: ObjCBool = false
    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
      status = "目录尚不存在，请先选择一个目录。"; return
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
  }
  func clearImageCache() async {
    guard let clearImages, !clearing else { return }
    clearing = true; status = nil
    defer { clearing = false }
    do { try await clearImages(); status = "图片缓存已清除。" }
    catch { status = "清除失败：\(error.localizedDescription)" }
  }
}
