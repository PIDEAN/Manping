import AppKit
import ManpingCore
import SwiftUI

struct M8AIResponseView: View {
  let source: AIContextSource
  @StateObject private var response: M8AIResponseModel
  @ObservedObject private var prompts: AIPromptStore
  private let fixtures: Bool
  private let openSettings: () -> Void
  @Environment(\.colorScheme) private var scheme
  init(source: AIContextSource, service: BiliService, rpc: (any BiliRPCService)?,
    configuration: AIConfigurationStore, prompts: AIPromptStore, fixtures: Bool, openSettings: @escaping () -> Void) {
    self.source = source; self.prompts = prompts; self.fixtures = fixtures; self.openSettings = openSettings
    _response = StateObject(wrappedValue: M8AIResponseModel(service: service, rpc: rpc, configuration: configuration,
      prompts: prompts, fixtures: fixtures))
  }
  private var tasks: [AIPromptTask] {
    source.isArticle ? [.articleSummary, .articleEvaluation] : [.videoSummary, .videoEvaluation, .videoQuestion]
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if response.providers.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          SettingIcon(symbol: "sparkles")
          Text("尚未配置 AI 服务").font(Theme.Font.headline)
          Text("在 设置 › AI 中配置服务、API key 和模型后，就能使用总结、评价和问答。")
            .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
          Button("配置 AI 服务", action: openSettings).buttonStyle(AppButtonStyle(role: .primary, size: .small))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface(scheme)
      } else if response.models.isEmpty {
        Text("当前服务尚未配置模型，请添加模型后重试。").font(Theme.Font.body).foregroundStyle(Theme.secondaryText(scheme))
        Button("配置模型", action: openSettings).buttonStyle(AppButtonStyle(size: .small))
      } else {
        quickActions
        if !response.request.isEmpty {
          Text(response.request).font(Theme.Font.body).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(Theme.selectedFill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        if !response.output.isEmpty { AIResponseMarkdown(text: response.output) }
        if response.busy {
          HStack(spacing: 8) { ProgressView().controlSize(.small); Text(response.status).font(Theme.Font.caption) }
        } else if !response.status.isEmpty {
          Text(response.status).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        }
        if let error = response.error {
          InlineErrorText(message: error)
          HStack(spacing: 8) {
            if response.usageLimitReached {
              // OpenAI guidance: managing usage is the primary action; no silent fallback to other billing.
              Button("管理用量") { NSWorkspace.shared.open(M8AISettingsModel.manageUsageURL) }
                .buttonStyle(AppButtonStyle(role: .primary, size: .small))
            }
            Button("重试") { response.retry() }.buttonStyle(AppButtonStyle(size: .small))
          }
        }
        if !source.isArticle {
          HStack(alignment: .bottom, spacing: 8) {
            TextField("关于当前视频，你想了解什么？", text: $response.question, axis: .vertical)
              .textFieldStyle(.plain).lineLimit(2...5).font(Theme.Font.body).padding(10)
              .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
              .disabled(response.busy)
              .onSubmit { response.generate(.videoQuestion) }
            Button { response.generate(.videoQuestion) } label: { Image(systemName: "arrow.up") }
              .buttonStyle(AppButtonStyle(role: .primary, iconOnly: true)).disabled(response.busy || response.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .help("提交当前视频问题")
          }
        }
        footer
      }
    }.padding(.vertical, 4).foregroundStyle(Theme.text(scheme))
      .task(id: source) {
        await response.prepare(source)
        #if DEBUG
        if fixtures, ProcessInfo.processInfo.arguments.contains("--ui-ai-preview"), !Task.isCancelled {
          response.generate(source.isArticle ? .articleSummary : .videoSummary)
        }
        #endif
      }
      .onReceive(prompts.objectWillChange) { response.templatesChanged() }
      .onDisappear { response.shutdown() }
  }
  private var header: some View {
    HStack(spacing: 8) {
      if let provider = response.provider { AIProviderLogo(provider: provider, size: 20) }
      else { Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(Theme.accentText(scheme)) }
      Menu {
        ForEach(response.providers) { provider in
          Button { response.selectProvider(provider) } label: {
            Label { Text(provider.title) } icon: { AIProviderLogo(provider: provider, size: 16) }
          }
        }
      } label: { MenuLabel(title: response.provider?.title ?? "AI 服务") }
        .appMenuStyle().disabled(response.busy)
      Spacer(minLength: 0)
      Menu {
        ForEach(response.models) { model in
          Button { response.selectModel(model.id) } label: {
            if response.modelID == model.id { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
          }
        }
      } label: {
        MenuLabel(title: response.models.first(where: { $0.id == response.modelID })?.name ?? "选择模型").frame(maxWidth: 150)
      }.appMenuStyle().disabled(response.busy)
      Button(action: openSettings) { Image(systemName: "gearshape") }
        .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("AI 设置")
    }.padding(.vertical, 8)
    .overlay(alignment: .bottomLeading) {
      if response.provider == .chatGPTPlan {
        HStack(spacing: 6) {
          Text("正在使用 ChatGPT 套餐").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
          Button("管理用量") { NSWorkspace.shared.open(M8AISettingsModel.manageUsageURL) }
            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accentText(scheme))
        }.offset(x: 28, y: 12)
      }
    }
  }
  private var quickActions: some View {
    VStack(spacing: 8) {
      ForEach(tasks.filter { !$0.isQuestion }) { task in
        Button { response.generate(task) } label: {
          HStack(spacing: 10) {
            SettingIcon(symbol: task.needsComments ? "bubble.left.and.text.bubble.right" : "text.bubble")
            VStack(alignment: .leading, spacing: 2) {
              Text(task.title).font(Theme.Font.headline)
              Text(task.needsComments ? "结合内容与热门评论进行评价" : (source.isArticle ? "根据文章正文总结内容" : "根据视频字幕与简介总结内容"))
                .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
            }
            Spacer(minLength: 0)
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(ChromeButtonStyle(fullWidth: true, icon: true)).disabled(response.busy)
      }
    }
  }
  private var footer: some View {
    HStack(spacing: 12) {
      if response.busy {
        Button("停止生成") { response.cancel() }.buttonStyle(AppButtonStyle(size: .small))
      }
      Spacer(minLength: 0)
      Button {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(response.output, forType: .string)
      } label: { Image(systemName: "doc.on.doc") }
        .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).disabled(response.busy || response.output.isEmpty).help("拷贝回答")
      Button { response.discard() } label: { Image(systemName: "eraser") }
        .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).disabled(response.busy || response.output.isEmpty).help("清除回答")
      Button { response.retry() } label: { Image(systemName: "arrow.clockwise") }
        .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).disabled(response.busy || response.request.isEmpty).help("重新生成")
    }
  }
}

private struct AIResponseMarkdown: View {
  let text: String
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
        if line.hasPrefix("### ") { Text(String(line.dropFirst(4))).font(Theme.Font.headline).padding(.top, 6) }
        else if line.hasPrefix("## ") { Text(String(line.dropFirst(3))).font(Theme.Font.section).padding(.top, 10) }
        else if line.hasPrefix("# ") { Text(String(line.dropFirst(2))).font(.system(size: 18, weight: .bold)).padding(.top, 10) }
        else if line.hasPrefix("- ") || line.hasPrefix("* ") {
          HStack(alignment: .top, spacing: 8) { Text("•"); inline(String(line.dropFirst(2))) }.font(Theme.Font.body)
        } else if !line.isEmpty { inline(line).font(Theme.Font.body) }
        else { Color.clear.frame(height: 4) }
      }
    }.lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).tint(Theme.accentText(scheme))
  }
  private func inline(_ line: String) -> Text {
    if let attributed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(attributed) }
    return Text(line)
  }
}
