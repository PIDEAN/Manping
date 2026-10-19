import AppKit
import ManpingCore
import SwiftUI

/// Embedded in 设置 › AI; this view does not create another scroll container.
struct M8AISettingsView: View {
  @ObservedObject var model: M8AISettingsModel
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let runtime = model.runtime {
        AISettingsSections(runtime: runtime).padding(.bottom, 12)
      }
      Text("AI 服务").font(Theme.Font.section).padding(.leading, 10)
      HStack(spacing: 12) {
        SettingIcon(symbol: "sparkles")
        VStack(alignment: .leading, spacing: 2) {
          Text("如何配置 AI").font(Theme.Font.headline)
          Text("配置格式与 Bili.Copilot（哔哩助理）和小幻助理相同，说明文档里有每家服务的填写方法。")
            .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        }
        Spacer()
        Button("查看说明") { NSWorkspace.shared.open(URL(string: "https://agent.richasy.net/chat-config")!) }
          .buttonStyle(AppButtonStyle(size: .small))
      }.padding(14).background(Theme.selectedFill(scheme).opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .padding(.bottom, 4)
      M8AppleLocalCard()
      M8ChatGPTPlanCard(model: model)
      ForEach(AIProvider.sourceProviders) { provider in M8AIProviderCard(model: model, provider: provider) }
      if let error = model.loadError {
        InlineErrorText(message: error).padding(12)
      }
    }.onAppear { model.load(); model.loadChatGPT() }.onDisappear { model.clearSensitiveDrafts() }
  }
}

/// Sign in with ChatGPT plan usage, laid out exactly like the API-key provider cards below
/// (collapsible header, label/description rows, footer actions): 使用 ChatGPT 账号登录,
/// a first-use notice and 管理用量.
private struct M8ChatGPTPlanCard: View {
  @ObservedObject var model: M8AISettingsModel
  @State private var expanded = false
  @Environment(\.colorScheme) private var scheme
  private var models: [AIModel] { model.configurations[.chatGPTPlan]?.models ?? [] }
  private var signedIn: Bool { model.chatGPTAccount != nil }
  init(model: M8AISettingsModel) {
    self.model = model
    _expanded = State(initialValue: aiSettingsDebugExpanded(.chatGPTPlan))
  }
  var body: some View {
    VStack(spacing: 0) {
      Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: {
        HStack(spacing: 12) {
          AIProviderLogo(provider: .chatGPTPlan).frame(width: 28)
          Text(AIProvider.chatGPTPlan.title).font(Theme.Font.headline)
          Spacer()
          if signedIn {
            StatusPill(text: "已登录")
          }
          DisclosureChevron(expanded: expanded)
        }.padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if expanded {
        Hairline()
        VStack(spacing: 0) {
          AIServiceSettingsRow("账号", detail: "用 ChatGPT Plus 或 Pro 账号登录后，AI 请求计入套餐用量，不需要 API key。") {
            Text(model.chatGPTAccount.map { $0.email ?? "ChatGPT 账号" } ?? "未登录").font(Theme.Font.body)
              .foregroundStyle(Theme.secondaryText(scheme)).textSelection(.enabled)
          }
          if signedIn {
            AIServiceSettingsRow("可用模型", detail: models.isEmpty ? "尚未获取到可用模型。"
              : models.prefix(6).map(\.name).joined(separator: "、") + (models.count > 6 ? " 等 \(models.count) 个" : "")) {
              Button("刷新模型") { Task { await model.refreshChatGPTModels() } }
                .buttonStyle(AppButtonStyle(size: .small))
            }
          }
          AIServiceSettingsRow("用量", detail: "在 ChatGPT 设置中查看或管理满屏使用的额度。") {
            HStack(spacing: 12) {
              Button("了解更多") { NSWorkspace.shared.open(URL(string: "https://help.openai.com")!) }
                .foregroundStyle(Theme.accentText(scheme)).buttonStyle(AppButtonStyle(role: .plain, size: .small))
              Button("管理用量") { NSWorkspace.shared.open(M8AISettingsModel.manageUsageURL) }
                .buttonStyle(AppButtonStyle(size: .small))
            }
          }
          HStack(spacing: 8) {
            if let status = model.chatGPTStatus {
              Text(status).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(3)
            }
            Spacer()
            if model.chatGPTBusy && !signedIn {
              Text("等待浏览器授权…").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
              Button("取消") { model.cancelChatGPTSignIn() }
                .buttonStyle(AppButtonStyle(size: .small))
            } else if signedIn {
              Button("重新授权") { model.startChatGPTSignIn() }
                .buttonStyle(AppButtonStyle(size: .small))
                .help("再次打开 ChatGPT 授权，例如补授予套餐用量权限")
              Button("退出登录") { Task { await model.signOutOfChatGPT() } }
                .buttonStyle(AppButtonStyle(size: .small))
            } else {
              Button("使用 ChatGPT 账号登录") { model.startChatGPTSignIn() }
                .buttonStyle(AppButtonStyle(role: .primary, size: .small))
            }
          }.padding(.horizontal, 16).padding(.vertical, 12)
        }
      }
    }.foregroundStyle(Theme.text(scheme)).cardSurface(scheme)
      .alert("正在使用你的 ChatGPT 套餐", isPresented: $model.chatGPTWelcome) {
        Button("好", role: .cancel) {}
      } message: {
        Text("在满屏中发起的 AI 总结、评价和问答会使用你的 ChatGPT 套餐额度。可以随时在 ChatGPT 设置中管理用量或断开本应用。")
      }
  }
}

private struct M8AIProviderCard: View {
  @ObservedObject var model: M8AISettingsModel
  let provider: AIProvider
  @State private var expanded = false
  @State private var showPredefined = false
  @State private var confirmDelete = false
  @Environment(\.colorScheme) private var scheme
  private var configuration: AIProviderConfiguration? { model.configurations[provider] }
  private var busy: Bool { model.busy.contains(provider) }
  init(model: M8AISettingsModel, provider: AIProvider) {
    self.model = model; self.provider = provider
    _expanded = State(initialValue: aiSettingsDebugExpanded(provider))
  }
  private func binding<Value>(_ keyPath: WritableKeyPath<M8AIProviderDraft, Value>) -> Binding<Value> {
    Binding(get: { model.draft(provider)[keyPath: keyPath] }, set: { value in model.update(provider) { $0[keyPath: keyPath] = value } })
  }
  var body: some View {
    VStack(spacing: 0) {
      Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: {
        HStack(spacing: 12) {
          AIProviderLogo(provider: provider).frame(width: 28)
          Text(provider.title).font(Theme.Font.headline)
          Spacer()
          if configuration?.isConfigured(for: provider) == true {
            StatusPill(text: "已配置")
          }
          DisclosureChevron(expanded: expanded)
        }.padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if expanded {
        Hairline()
        VStack(spacing: 0) {
          if provider == .anthropic {
            Text("Claude 订阅（Free／Pro／Max）按 Anthropic 条款只能用于 Claude.ai 和 Claude Code，不能在第三方应用中登录使用；请在 console.anthropic.com 创建 API key（按量计费）。")
              .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).padding(.horizontal, 16).padding(.top, 12)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if provider != .ollama {
            AIServiceSettingsRow("访问密钥", detail: configuration?.keyConfigured == true ? "已加密保存在本机，留空保留。" : "仅加密保存在本机。") {
              secureField("API key", text: binding(\.key))
            }
          }
          if provider == .ernie {
            AIServiceSettingsRow("Secret 密钥", detail: configuration?.secretConfigured == true ? "已加密保存在本机，留空保留。" : "文心千帆配置中的 Secret。") {
              secureField("Secret key", text: binding(\.secret))
            }
          }
          if provider == .mistral {
            AIServiceSettingsRow("使用 Codestral", detail: "使用独立的 Codestral API 和密钥。") {
              switchButton(binding(\.useCodestral))
            }
            AIServiceSettingsRow("Codestral 密钥", detail: configuration?.codestralKeyConfigured == true ? "已加密保存在本机，留空保留。" : "仅加密保存在本机。") {
              secureField("Codestral key", text: binding(\.codestralKey))
            }
          }
          if provider.supportsEndpoint {
            AIServiceSettingsRow("终结点", detail: provider.defaultEndpoint == nil ? "请输入此资源的终结点。" : "留空使用原版默认终结点。") {
              textField(provider.defaultEndpoint ?? "https://…", text: binding(\.endpoint))
            }
          }
          if provider == .openAI {
            AIServiceSettingsRow("组织 ID", detail: "可选。") { textField("org-…", text: binding(\.organization)) }
          }
          if provider == .azureOpenAI || provider == .azureAI {
            AIServiceSettingsRow("API 版本", detail: "可选，留空使用这种协议的默认版本。") { textField("例如 2024-02-01", text: binding(\.apiVersion)) }
          }
          if !provider.predefinedModels.isEmpty {
            AIServiceSettingsRow("预定义模型", detail: "与固定原版 SDK 的模型列表一致。") {
              Button("查看所有预定义模型") { showPredefined.toggle() }.foregroundStyle(Theme.accentText(scheme)).buttonStyle(AppButtonStyle(role: .plain, size: .small))
                .popover(isPresented: $showPredefined) {
                  ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                      ForEach(provider.predefinedModels) { item in
                        VStack(alignment: .leading, spacing: 3) {
                          Text(item.name).font(Theme.Font.body)
                          Text(item.id).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).textSelection(.enabled)
                        }
                      }
                    }.frame(width: 300, alignment: .leading).padding(16)
                  }.frame(maxHeight: 420)
                }
            }
          }
          customModels
          HStack(spacing: 8) {
            if let status = model.statuses[provider] { Text(status).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(3) }
            Spacer()
            Button("恢复草稿") { model.resetDraft(provider) }.buttonStyle(AppButtonStyle(size: .small))
            if configuration != nil {
              Button("删除配置") { confirmDelete = true }.buttonStyle(AppButtonStyle(role: .destructive, size: .small))
            }
            Button(busy ? "保存中…" : "保存") { Task { await model.save(provider) } }
              .buttonStyle(AppButtonStyle(role: .primary, size: .small))
          }.padding(.horizontal, 16).padding(.vertical, 12).overlay(alignment: .top) { Hairline().padding(.horizontal, 16) }
        }.disabled(busy)
      }
    }.foregroundStyle(Theme.text(scheme)).cardSurface(scheme)
      .confirmationDialog("删除 \(provider.title) 配置和密钥？", isPresented: $confirmDelete) {
        Button("删除配置和密钥", role: .destructive) { Task { await model.delete(provider) } }
        Button("取消", role: .cancel) {}
      }
  }
  private var customModels: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("自定义模型").font(Theme.Font.body)
      if provider.requiresCustomModels {
        Text(provider == .azureOpenAI ? "模型标识请填写部署名称。" : "此服务没有预定义模型，请添加要使用的模型。")
          .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      }
      ForEach(model.draft(provider).models) { item in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(Theme.Font.body)
            Text(item.id).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
          }
          Spacer()
          Button { model.removeModel(provider, id: item.id) } label: { Image(systemName: "trash") }
            .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("移除模型")
        }
      }
      HStack(spacing: 8) {
        textField("模型标识", text: binding(\.newModelID))
        textField("显示名称（可选）", text: binding(\.newModelName))
        Button("添加模型") { model.addModel(provider) }.buttonStyle(AppButtonStyle(size: .small))
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func textField(_ prompt: String, text: Binding<String>) -> some View {
    TextField(prompt, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(AppTextFieldStyle()).frame(width: 260)
  }
  private func secureField(_ prompt: String, text: Binding<String>) -> some View {
    SecureField(prompt, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.plain).font(Theme.Font.body)
      .padding(.horizontal, 10).frame(width: 260, height: Theme.controlHeight)
      .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
  }
  private func switchButton(_ value: Binding<Bool>) -> some View {
    Toggle("", isOn: value).toggleStyle(.switch).labelsHidden().tint(Theme.accent).controlSize(.small)
  }
}

/// Apple's on-device model: nothing to configure; the card says whether it can run here.
private struct M8AppleLocalCard: View {
  @Environment(\.colorScheme) private var scheme
  @State private var reason = AppleLocalModel.unavailableReason
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AIProviderLogo(provider: .appleLocal, size: 28)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(AIProvider.appleLocal.title).font(Theme.Font.headline)
          StatusPill(text: reason == nil ? "可用" : "不可用", positive: reason == nil)
        }
        Text(reason ?? "在本机运行的 Apple 基础模型：免费、离线，不需要账号或 API key，内容不会离开这台 Mac。上下文较短，过长的字幕和评论会自动截取。")
          .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    .onAppear { reason = AppleLocalModel.unavailableReason }
  }
}

private struct AIServiceSettingsRow<Content: View>: View {
  let title: String
  let detail: String
  let content: Content
  @Environment(\.colorScheme) private var scheme
  init(_ title: String, detail: String, @ViewBuilder content: () -> Content) {
    self.title = title; self.detail = detail; self.content = content()
  }
  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(Theme.Font.body)
        Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      }.frame(maxWidth: .infinity, alignment: .leading)
      content
    }.padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 56)
  }
}

private func aiSettingsDebugExpanded(_ provider: AIProvider) -> Bool {
  #if DEBUG
  let args = ProcessInfo.processInfo.arguments
  if DebugUIFixtures.enabled, let index = args.firstIndex(of: "--ui-ai-provider"), args.indices.contains(index + 1) {
    return args[index + 1] == provider.rawValue
  }
  #endif
  return false
}
