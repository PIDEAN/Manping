import ManpingCore
import AppKit
import Foundation
import SwiftUI

struct M8AIProviderDraft {
  var endpoint = ""
  var organization = ""
  var apiVersion = ""
  var useCodestral = false
  var models: [AIModel] = []
  var key = ""
  var secret = ""
  var codestralKey = ""
  var newModelID = ""
  var newModelName = ""
  init(configuration: AIProviderConfiguration? = nil) {
    endpoint = configuration?.endpoint ?? ""; organization = configuration?.organization ?? ""
    apiVersion = configuration?.apiVersion ?? ""; useCodestral = configuration?.useCodestral ?? false
    models = configuration?.models ?? []
  }
  var configuration: AIProviderConfiguration {
    AIProviderConfiguration(endpoint: endpoint.isEmpty ? nil : endpoint, models: models,
      organization: organization.isEmpty ? nil : organization, useCodestral: useCodestral,
      apiVersion: apiVersion.isEmpty ? nil : apiVersion)
  }
}

@MainActor final class M8AISettingsModel: ObservableObject {
  let store: AIConfigurationStore
  @Published private(set) var configurations: [AIProvider: AIProviderConfiguration] = [:]
  @Published var drafts: [AIProvider: M8AIProviderDraft] = [:]
  @Published private(set) var busy: Set<AIProvider> = []
  @Published private(set) var statuses: [AIProvider: String] = [:]
  @Published private(set) var loadError: String?
  private var loadingTask: Task<Void, Never>?
  // ChatGPT plan (Sign in with ChatGPT): account label only; tokens never reach the UI layer.
  @Published private(set) var chatGPTAccount: ChatGPTPlanAccount?
  @Published private(set) var chatGPTBusy = false
  @Published private(set) var chatGPTStatus: String?
  @Published var chatGPTWelcome = false
  static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
  private static let welcomeShownKey = "Manping.chatGPTPlanWelcomeShown"
  /// Presets, materials and saved conversations shown above the service cards.
  weak var runtime: AIRuntime?
  init(store: AIConfigurationStore) { self.store = store }
  func loadChatGPT() {
    guard let auth = store.chatGPT else { return }
    Task { [weak self] in
      let account = try? await auth.account()
      guard let self else { return }
      chatGPTAccount = account
      // A configuration flag left "signed in" after tokens were cleared is corrected here.
      if account == nil, configurations[.chatGPTPlan]?.keyConfigured == true {
        try? await store.setChatGPTPlan(signedIn: false, models: [])
        configurations = (try? await store.allConfigurations()) ?? configurations
      }
    }
  }
  private var signInTask: Task<Void, Never>?
  func startChatGPTSignIn() {
    guard signInTask == nil else { return }
    signInTask = Task { [weak self] in await self?.signInWithChatGPT(); self?.signInTask = nil }
  }
  /// Cancels a pending browser sign-in; the loopback listener closes and nothing is stored.
  func cancelChatGPTSignIn() { signInTask?.cancel() }
  func signInWithChatGPT() async {
    guard let auth = store.chatGPT, !chatGPTBusy else { return }
    chatGPTBusy = true; chatGPTStatus = "已在浏览器中打开 ChatGPT 登录页，完成授权后会自动返回。"
    defer { chatGPTBusy = false }
    do {
      let account = try await auth.signIn { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
      let models = try await auth.models()
      try await store.setChatGPTPlan(signedIn: true, models: models)
      configurations = try await store.allConfigurations()
      chatGPTAccount = account
      chatGPTStatus = models.isEmpty ? "已登录，但此账号当前没有可用模型。" : "已登录，可用模型 \(models.count) 个。"
      if !UserDefaults.standard.bool(forKey: Self.welcomeShownKey) {
        UserDefaults.standard.set(true, forKey: Self.welcomeShownKey); chatGPTWelcome = true
      }
    } catch {
      chatGPTStatus = Task.isCancelled ? ChatGPTPlanError.cancelled.errorDescription : Self.chatGPTError(error)
      // A signed-in identity without plan usage is still shown, so the user can sign out.
      chatGPTAccount = try? await auth.account()
    }
  }
  func refreshChatGPTModels() async {
    guard let auth = store.chatGPT, !chatGPTBusy else { return }
    chatGPTBusy = true; defer { chatGPTBusy = false }
    do {
      let models = try await auth.models()
      try await store.setChatGPTPlan(signedIn: true, models: models)
      configurations = try await store.allConfigurations()
      chatGPTStatus = "模型列表已更新（\(models.count) 个）。"
    } catch { chatGPTStatus = Self.chatGPTError(error) }
  }
  func signOutOfChatGPT() async {
    guard let auth = store.chatGPT, !chatGPTBusy else { return }
    chatGPTBusy = true; defer { chatGPTBusy = false }
    // Requests stop immediately: the plan provider is disabled before revocation finishes.
    try? await store.setChatGPTPlan(signedIn: false, models: [])
    configurations = (try? await store.allConfigurations()) ?? configurations
    let confirmed: Bool
    do { confirmed = try await auth.signOut() }
    catch {
      // Keep the account (and the sign-out button) visible so the user can retry.
      chatGPTStatus = "未能清除本地 ChatGPT 凭据（钥匙串操作失败），请重试退出登录。"
      return
    }
    chatGPTAccount = nil
    chatGPTStatus = confirmed ? "已退出 ChatGPT 登录。" : "本地凭据已清除，但未能确认远端撤销；可在 ChatGPT 设置中断开本应用。"
  }
  static func chatGPTError(_ error: Error) -> String {
    (error as? ChatGPTPlanError)?.errorDescription ?? (error as? AIConfigurationError)?.errorDescription ?? "ChatGPT 登录失败。"
  }
  func load() {
    loadingTask?.cancel()
    loadingTask = Task { [weak self] in
      guard let self else { return }
      do {
        // Rendering configuration must not read Keychain or request its authorization.
        let values = try await store.allConfigurations()
        try Task.checkCancellation()
        configurations = values
        for provider in AIProvider.sourceProviders where drafts[provider] == nil {
          drafts[provider] = M8AIProviderDraft(configuration: values[provider])
        }
        loadError = nil
      } catch is CancellationError { return }
      catch { loadError = Self.safeError(error) }
    }
  }
  func draft(_ provider: AIProvider) -> M8AIProviderDraft { drafts[provider] ?? M8AIProviderDraft(configuration: configurations[provider]) }
  func update(_ provider: AIProvider, _ edit: (inout M8AIProviderDraft) -> Void) {
    var value = draft(provider); edit(&value); drafts[provider] = value
  }
  func resetDraft(_ provider: AIProvider) {
    drafts[provider] = M8AIProviderDraft(configuration: configurations[provider]); statuses[provider] = nil
  }
  func addModel(_ provider: AIProvider) {
    let value = draft(provider)
    let id = value.newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = value.newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, id.utf8.count <= 512, !id.contains("\n"), !id.contains("\r"), !id.contains("\0") else {
      statuses[provider] = "请输入有效的模型标识。"; return
    }
    guard !(provider.predefinedModels + value.models).contains(where: { $0.id == id }) else {
      statuses[provider] = "此模型已在列表中。"; return
    }
    update(provider) { $0.models.append(AIModel(id: id, name: name.isEmpty ? id : name)); $0.newModelID = ""; $0.newModelName = "" }
    statuses[provider] = "模型已添加到草稿，请保存配置。"
  }
  func removeModel(_ provider: AIProvider, id: String) { update(provider) { $0.models.removeAll { $0.id == id } } }
  func save(_ provider: AIProvider) async {
    guard busy.insert(provider).inserted else { return }
    defer { busy.remove(provider) }
    let value = draft(provider)
    do {
      var replacement: AIProviderSecrets?
      if !value.key.isEmpty || !value.secret.isEmpty || !value.codestralKey.isEmpty {
        // A user-initiated save may read the existing secret to preserve fields left blank.
        var merged = try await store.secrets(for: provider) ?? AIProviderSecrets(key: "")
        if !value.key.isEmpty { merged.key = value.key }
        if !value.secret.isEmpty { merged.secret = value.secret }
        if !value.codestralKey.isEmpty { merged.codestralKey = value.codestralKey }
        replacement = merged
      }
      try await store.save(provider: provider, configuration: value.configuration, secrets: replacement)
      let stored = try await store.configuration(for: provider)
      configurations[provider] = stored
      drafts[provider] = M8AIProviderDraft(configuration: stored)
      statuses[provider] = "已保存。未发送验证请求。"
    } catch { statuses[provider] = Self.safeError(error) }
  }
  func delete(_ provider: AIProvider) async {
    guard busy.insert(provider).inserted else { return }
    defer { busy.remove(provider) }
    do {
      try await store.delete(provider: provider)
      configurations.removeValue(forKey: provider); drafts[provider] = M8AIProviderDraft()
      statuses[provider] = "配置与钥匙串中的密钥已删除。"
    } catch { statuses[provider] = Self.safeError(error) }
  }
  func clearSensitiveDrafts() {
    for provider in Array(drafts.keys) { update(provider) { $0.key = ""; $0.secret = ""; $0.codestralKey = "" } }
  }
  static func safeError(_ error: Error) -> String {
    (error as? AIConfigurationError)?.errorDescription ?? "AI 配置操作失败。"
  }
}
