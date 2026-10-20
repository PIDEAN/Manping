import AppKit
import ManpingCore
import SwiftUI

/// The AI tab of the video and episode pages (design 01): model, 上下文 and ⋯ in the header,
/// the preset chips, the thread with its answer cards. It sits in the page's scroll view; the
/// page pins `AIPanelComposer` below it.
struct AIPanelView: View {
  let runtime: AIRuntime
  let source: AISource
  var body: some View {
    AIPanelContent(panel: runtime.panel(for: source), runtime: runtime, clips: runtime.clipPlayback ?? ClipPlaybackController())
  }
}

/// The question field pinned under the panel.
struct AIPanelComposer: View {
  let runtime: AIRuntime
  let source: AISource
  var body: some View {
    AIComposerContent(panel: runtime.panel(for: source), clock: runtime.clock)
  }
}

/// Panel and composer in one column with their own scrolling (专栏 「AI 助手」 side panel).
struct AIPanelStack: View {
  let runtime: AIRuntime
  let source: AISource
  var body: some View {
    VStack(spacing: 0) {
      ScrollView { AIPanelView(runtime: runtime, source: source).padding(16) }
        .aiThreadScrolling(true)
      Hairline()
      AIPanelComposer(runtime: runtime, source: source).padding(12)
    }
  }
}

private struct AIPanelContent: View {
  @ObservedObject var panel: AIPanelModel
  @ObservedObject var runtime: AIRuntime
  @ObservedObject var clips: ClipPlaybackController
  @Environment(\.colorScheme) private var scheme
  @State private var showingContext = false
  @State private var confirmClear = false
  @State private var guidancePreset: String?
  @State private var sceneStarted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if panel.providersLoaded, panel.hasService, !runtime.introShown { intro }
      chips
      if debugInlineContext { AIContextPopover(panel: panel, inline: true).cardSurface(scheme, radius: Theme.Radius.lg) }
      thread
    }
    .foregroundStyle(Theme.text(scheme))
    .onAppear { runtime.setMarks(panel.markTimes, for: panel.source) }
    .onChange(of: panel.markTimes) { _, times in runtime.setMarks(times, for: panel.source) }
    .onDisappear { runtime.clearMarks(for: panel.source) }
    .task(id: panel.providersLoaded && panel.threadLoaded) { runScene() }
    .confirmationDialog("清除此视频的 AI 对话？", isPresented: $confirmClear) {
      Button("清除对话", role: .destructive) { panel.clearThread() }
      Button("取消", role: .cancel) {}
    } message: { Text("已保存在本机的问答会被删除，之后可以重新生成。") }
  }

  /// Screenshot scene `context`: the popover is drawn in place (a popover is its own window).
  private var debugInlineContext: Bool { runtime.fixtures && runtime.scene == "context" && panel.hasService }
  private func seek(_ seconds: Double) { runtime.seek(seconds, in: panel.source) }
  private var seekAction: ((Double) -> Void)? {
    guard panel.isCurrentMedia else { return nil }
    let runtime = runtime, source = panel.source
    return { runtime.seek($0, in: source) }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      if panel.hasService {
        Menu {
          ForEach(panel.providers) { provider in
            Section(provider.title) {
              ForEach(panel.models[provider] ?? []) { model in
                Button { panel.select(provider: provider, modelID: model.id) } label: {
                  if panel.provider == provider && panel.modelID == model.id { Label(model.name, systemImage: "checkmark") }
                  else { Text(model.name) }
                }
              }
            }
          }
          Divider()
          Button("AI 设置…") { runtime.openSettings() }
        } label: { MenuLabel(title: panel.modelName) }
          .appMenuStyle().disabled(panel.busy).help("选择回答用的模型")
        Button { showingContext.toggle() } label: {
          Text("上下文：" + contextSummary).font(Theme.Font.caption.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 10).frame(height: Theme.compactControlHeight)
            .foregroundStyle(Theme.accentText(scheme))
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help("查看并临时调整本次发送的内容")
        .popover(isPresented: Binding(get: { showingContext && !debugInlineContext }, set: { showingContext = $0 }), arrowEdge: .bottom) {
          AIContextPopover(panel: panel)
        }
      } else {
        Label("AI", systemImage: "sparkles").font(Theme.Font.headline).foregroundStyle(Theme.accentText(scheme))
      }
      Spacer(minLength: 0)
      Menu {
        Button("导出 Markdown…") { panel.exportMarkdown() }.disabled(panel.turns.isEmpty)
        Button("清除此视频的对话…", role: .destructive) { confirmClear = true }.disabled(panel.turns.isEmpty && !panel.busy)
        Divider()
        Button("AI 设置…") { runtime.openSettings() }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.button).buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).menuIndicator(.hidden).fixedSize()
        .help("更多")
    }
  }
  private var contextSummary: String {
    let preset = panel.focusPreset
    let kinds = preset.materials.filter { $0.isSwitchable && $0 != .history && panel.allows($0) }
    let names = kinds.map { $0 == .officialSummary ? "章节" : $0.shortTitle }
    return names.isEmpty ? (panel.source.kind == .article ? "正文" : "基本信息") : names.joined(separator: " · ")
  }

  private var intro: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "lock.shield").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accentText(scheme))
      VStack(alignment: .leading, spacing: 4) {
        Text("AI 只在你点按时发送内容").font(Theme.Font.caption.weight(.semibold))
        Text(panel.source.kind == .article
          ? "发送标题、作者与正文，以及按预设需要的评论精选和对话历史。点「上下文」可以本次关闭某项；默认值在 设置 › AI › 默认发送的内容 中修改。"
          : "发送标题与简介等基本信息，以及按预设需要的字幕、官方章节与总结、弹幕统计、评论精选和当前进度。点「上下文」可以本次关闭某项；默认值在 设置 › AI › 默认发送的内容 中修改。")
          .font(Theme.Font.caption2).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      Button("知道了") { runtime.markIntroShown() }.buttonStyle(AppButtonStyle(size: .small))
    }
    .padding(12)
    .background(Theme.selectedFill(scheme).opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
  }

  // MARK: Preset chips

  private var chips: some View {
    FlowLayout(spacing: 6) {
      ForEach(panel.panelPresets) { preset in chip(preset) }
    }
  }
  @ViewBuilder private func chip(_ preset: AIPreset) -> some View {
    let selected = panel.focusPresetID == preset.id && !panel.turns.isEmpty
    if !panel.hasService {
      Button(preset.name) { guidancePreset = preset.id }
        .buttonStyle(AIPresetChipStyle(selected: (guidancePreset ?? AIBuiltInPresets.chapters.id) == preset.id))
    } else {
      switch panel.availability(preset) {
      case .needsMaterial(let kind):
        // F5: shown as unavailable, saying what it needs, with a one-time permission.
        Menu {
          Button("仅本次发送「\(kind.title)」并生成") { panel.run(preset, oneTime: [kind]) }
          Button("在设置中打开…") { runtime.openSettings() }
        } label: {
          HStack(spacing: 4) {
            Text(preset.name)
            Text("需要\(kind.shortTitle)").font(Theme.Font.caption2).foregroundStyle(Theme.warning(scheme))
          }
        }
        .menuStyle(.button).buttonStyle(AIPresetChipStyle(unavailable: true)).menuIndicator(.hidden).fixedSize()
        .disabled(panel.busy).help(AIPresetAvailability.needsMaterial(kind).reason ?? "")
      case .notApplicable:
        EmptyView()
      default:
        Button(preset.name) { panel.run(preset) }
          .buttonStyle(AIPresetChipStyle(selected: selected)).disabled(panel.busy).demoAnchor("ai.\(preset.name)")
      }
    }
  }

  // MARK: Thread

  @ViewBuilder private var thread: some View {
    if !panel.providersLoaded || !panel.threadLoaded {
      HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取…").font(Theme.Font.caption) }
        .foregroundStyle(Theme.secondaryText(scheme)).padding(.vertical, 8)
    } else if !panel.hasService {
      noService
    } else {
      VStack(alignment: .leading, spacing: 10) {
        if panel.turns.isEmpty, panel.pending == nil, panel.failure == nil {
          Text(panel.source.kind == .article ? "选择一个预设，或在下方追问这篇专栏。" : "选择一个预设，或在下方追问这个视频。")
            .font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).padding(.vertical, 6)
        }
        ForEach(panel.turns) { turn in
          if panel.pending?.replacing != turn.id {
            bubble(question: turn.question, preset: turn.presetName, position: panel.position(of: turn),
              sentPosition: turn.materials.contains(.viewerPosition))
            AIAnswerCard(turn: turn, panel: panel, clips: clips, seek: seek)
          }
        }
        if let pending = panel.pending {
          bubble(question: pending.question, preset: pending.presetName, position: pending.position, sentPosition: pending.position != nil)
          AIPendingCard(pending: pending, cancel: panel.cancel)
        }
        if let failure = panel.failure { failureCard(failure) }
      }
    }
  }

  @ViewBuilder private func bubble(question: String?, preset: String, position: Double?, sentPosition: Bool) -> some View {
    if let question {
      VStack(alignment: .leading, spacing: 4) {
        Text(question).font(Theme.Font.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if sentPosition {
          Text(position.map { "附带进度 \(AITimecode.format($0)) 前后 90 秒" } ?? "附带当前进度")
            .font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.accentText(scheme))
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(Theme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
      .frame(maxWidth: 300, alignment: .trailing).frame(maxWidth: .infinity, alignment: .trailing)
    } else {
      Text(preset).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.accentText(scheme))
        .padding(.horizontal, 12).frame(height: 26)
        .background(Capsule().fill(Theme.accent.opacity(0.2)))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func failureCard(_ failure: AIPanelModel.Failure) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning(scheme))
        VStack(alignment: .leading, spacing: 2) {
          Text("没能生成回答").font(Theme.Font.headline)
          Text(failure.message + (panel.turns.isEmpty ? "" : (failure.message.hasSuffix("。") ? "" : "。") + "已保存的回答仍可查看。"))
            .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack(spacing: 8) {
        if failure.usageLimit {
          // OpenAI guidance: managing usage is the primary action; no silent fallback to other billing.
          Button("管理用量") { NSWorkspace.shared.open(M8AISettingsModel.manageUsageURL) }
            .buttonStyle(AppButtonStyle(role: .primary, size: .small))
        }
        if failure.aiSubtitlesOff {
          Button("使用 AI 字幕") { panel.allowAISubtitlesAndRetry() }
            .buttonStyle(AppButtonStyle(role: .primary, size: .small))
            .help("打开 设置 › AI ›「使用 AI 字幕」并重试")
        }
        Button("重试") { panel.retry() }.buttonStyle(AppButtonStyle(size: .small))
        if panel.models.values.joined().count > 1 {
          Menu {
            ForEach(panel.providers) { provider in
              Section(provider.title) {
                ForEach(panel.models[provider] ?? []) { model in
                  Button(model.name) { panel.select(provider: provider, modelID: model.id); panel.retry() }
                }
              }
            }
          } label: { Text("换一个模型") }.appMenuStyle()
        }
        Spacer(minLength: 0)
        Button { panel.dismissFailure() } label: { Image(systemName: "xmark") }
          .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("关闭")
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.danger(scheme).opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.danger(scheme).opacity(0.3), lineWidth: 0.5))
  }

  /// No AI service (F15): 章节总结 shows Bilibili's official summary; the other presets say
  /// what to configure.
  @ViewBuilder private var noService: some View {
    let selected = guidancePreset ?? AIBuiltInPresets.chapters.id
    if selected == AIBuiltInPresets.chapters.id, panel.source.kind.isTimeline {
      AIOfficialSummaryCard(state: panel.official, seek: seekAction,
        retry: { panel.loadOfficial() }, configure: runtime.openSettings)
        .onAppear { panel.loadOfficial() }
    } else {
      let name = panel.panelPresets.first { $0.id == selected }?.name ?? "AI 助手"
      VStack(alignment: .leading, spacing: 10) {
        SettingIcon(symbol: "sparkles")
        Text("「\(name)」需要 AI 服务").font(Theme.Font.headline)
        Text("在 设置 › AI 中配置服务和模型，或使用 Apple 智能，就能使用预设和追问。")
          .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
        Button("配置 AI 服务") { runtime.openSettings() }.buttonStyle(AppButtonStyle(role: .primary, size: .small))
      }.padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface(scheme)
    }
  }

  // MARK: Screenshot scenes (fixtures)

  private func runScene() {
    guard runtime.fixtures, let scene = runtime.scene, !sceneStarted, panel.providersLoaded, panel.threadLoaded,
      panel.hasService, panel.turns.isEmpty, panel.pending == nil else { return }
    sceneStarted = true
    let presets = runtime.presets
    switch scene {
    case "chapters":
      presets.preset(AIBuiltInPresets.chapters.id).map { panel.run($0) }
      Task { @MainActor in
        while panel.pending != nil { try? await Task.sleep(for: .milliseconds(100)) }
        panel.question = "刚才那段日出是在哪里拍的？"
        panel.ask()
      }
    case "highlights": presets.preset(AIBuiltInPresets.highlights.id).map { panel.run($0) }
    case "comments": presets.preset(AIBuiltInPresets.commentViews.id).map { panel.run($0) }
    case "clips": presets.preset(AIBuiltInPresets.clips.id).map { panel.run($0) }
    case "context": presets.preset(AIBuiltInPresets.chapters.id).map { panel.focus($0) }
    default: break
    }
  }
}

/// Preset chips: accent fill when it is the answer on screen, dimmed when unavailable.
struct AIPresetChipStyle: ButtonStyle {
  var selected = false
  var unavailable = false
  func makeBody(configuration: Configuration) -> some View { AIPresetChipBody(configuration: configuration, selected: selected, unavailable: unavailable) }
}

private struct AIPresetChipBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let unavailable: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var body: some View {
      configuration.label.font(Theme.Font.caption.weight(selected ? .bold : .regular)).lineLimit(1)
        .padding(.horizontal, 12).frame(height: Theme.compactControlHeight)
        .foregroundStyle(selected ? Theme.onAccent : (isEnabled && !unavailable ? Theme.text(scheme) : Theme.disabledText(scheme)))
        .background(Capsule().fill(selected ? Theme.accent
          : configuration.isPressed ? Theme.fillPressed(scheme) : hovering ? Theme.fillHover(scheme) : Theme.fill(scheme)))
        .overlay(Capsule().strokeBorder(selected ? .clear : Theme.separator(scheme), lineWidth: 1)
          .opacity(unavailable ? 1 : 0.9))
        .overlay {
          if unavailable { Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Theme.separator(scheme)) }
        }
        .contentShape(Capsule())
        .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value } }
    }
}

/// The answer being generated: status, streamed text, degradation notes and 停止.
struct AIPendingCard: View {
  let pending: AIPanelModel.Pending
  let cancel: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !pending.text.isEmpty {
        AIMarkdownView(text: pending.text + " ▍", seek: nil, duration: nil)
      }
      if case .segmenting(let done, let total) = pending.status, total > 0 {
        VStack(alignment: .leading, spacing: 6) {
          Text("内容较长，正在分段整理（\(done) / \(total)）").font(Theme.Font.caption.weight(.semibold))
          HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
              Capsule().fill(index < done ? Theme.accent : Theme.fill(scheme)).frame(height: 4)
            }
          }
          Text("分段结果会保存在本机，之后换任务或追问都直接复用。").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
        }
      } else if pending.text.isEmpty || pending.status != .generating {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(statusText).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        }
      }
      ForEach(pending.notes, id: \.self) { AINoteRow(text: $0) }
      HStack {
        Spacer()
        Button("停止", action: cancel).buttonStyle(AppButtonStyle(size: .small))
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
  }
  private var statusText: String {
    switch pending.status {
    case .loadingMaterials: "正在读取字幕、弹幕与评论…"
    case .segmenting: "正在分段整理…"
    case .generating: "正在生成…"
    case .organizing: "正在整理…"
    case .cached: "已从本机读取保存的回答"
    case .degraded(let note): note
    }
  }
}

/// The composer: question field, the 当前进度 chip, send / stop.
private struct AIComposerContent: View {
  @ObservedObject var panel: AIPanelModel
  let clock: PlaybackClock?
  @Environment(\.colorScheme) private var scheme
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(placeholder, text: $panel.question, prompt: Text(placeholder), axis: .vertical).labelsHidden()
        .textFieldStyle(.plain).font(Theme.Font.body).lineLimit(1...5)
        .focused($focused)
        .disabled(!panel.hasService)
        .onSubmit { panel.ask() }
        .accessibilityLabel("追问")
      HStack(spacing: 6) {
        if panel.source.kind.isTimeline {
          if panel.positionAllowed, panel.hasService {
            Button { panel.includePosition.toggle() } label: {
              AIPositionLabel(clock: clock, fallback: panel.currentPosition ?? 0, on: panel.includePosition)
            }.buttonStyle(.plain).help(panel.includePosition ? "提问时附带当前进度前后 90 秒的字幕；点按关闭" : "点按后提问时附带当前进度")
          }
        }
        Spacer(minLength: 0)
        if panel.busy {
          Button(action: panel.cancel) { Image(systemName: "stop.fill") }
            .buttonStyle(AppButtonStyle(size: .small, iconOnly: true)).help("停止生成")
        } else {
          Button(action: panel.ask) { Image(systemName: "arrow.up") }
            .buttonStyle(AppButtonStyle(role: .primary, size: .small, iconOnly: true))
            .disabled(!panel.hasService || panel.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("发送")
        }
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    // The answer cards' radius and inset (16 pt in the rounded side panel), so the corners nest.
    .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
      .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.separator(scheme), lineWidth: 1))
    .foregroundStyle(Theme.text(scheme))
  }
  private var placeholder: String {
    guard panel.hasService else { return "配置 AI 服务后可以追问" }
    return panel.source.kind == .article ? "追问这篇专栏" : "追问这个视频"
  }
}

/// 「当前进度 mm:ss」: observes only the playback clock.
private struct AIPositionLabel: View {
  let clock: PlaybackClock?
  let fallback: Double
  let on: Bool
  var body: some View {
    if let clock { Observed(clock: clock, fallback: fallback, on: on) } else { Chip(time: fallback, on: on) }
  }
  private struct Observed: View {
    @ObservedObject var clock: PlaybackClock
    let fallback: Double
    let on: Bool
    var body: some View { Chip(time: clock.time > 0 ? clock.time : fallback, on: on) }
  }
  private struct Chip: View {
    let time: Double
    let on: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
      Text("当前进度 " + AITimecode.format(time)).font(Theme.Font.caption2.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 10).frame(height: 24)
        .foregroundStyle(on ? Theme.accentText(scheme) : Theme.secondaryText(scheme))
        .background(Capsule().fill(on ? Theme.accent.opacity(0.18) : Theme.fill(scheme)))
        .overlay(Capsule().strokeBorder(on ? .clear : Theme.separator(scheme), lineWidth: 1))
        .contentShape(Capsule())
    }
  }
}

extension View {
  /// A scroll view holding an AI thread: opens at the newest answer and follows it as it
  /// streams, while a short thread stays at the top.
  func aiThreadScrolling(_ enabled: Bool) -> some View {
    defaultScrollAnchor(enabled ? .bottom : nil, for: .initialOffset)
      .defaultScrollAnchor(enabled ? .bottom : nil, for: .sizeChanges)
      .defaultScrollAnchor(enabled ? .top : nil, for: .alignment)
  }
}
