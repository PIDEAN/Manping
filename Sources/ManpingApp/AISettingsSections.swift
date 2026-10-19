import ManpingCore
import SwiftUI

/// 设置 › AI groups of design 04: 预设, 默认发送的内容, 对话与保存, 回答风格. The service cards
/// that follow them are unchanged.
struct AISettingsSections: View {
  @ObservedObject var runtime: AIRuntime
  @ObservedObject var presets: AIPresetStore
  @ObservedObject var prompts: AIPromptStore
  @Environment(\.colorScheme) private var scheme
  @State private var editing: AIPresetDraft?
  @State private var editingSystemPrompt = false
  @State private var usage: AIConversationStore.Usage?
  @State private var confirmClearAll = false
  @State private var error: String?

  init(runtime: AIRuntime) {
    self.runtime = runtime; self.presets = runtime.presets; self.prompts = runtime.prompts
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // Screenshot scene `settings` puts the lower groups first so one window shows them.
      if runtime.scene != "settings" { group("预设") { presetList } }
      group("默认发送的内容") { materials }
      group("对话与保存") { conversations }
      group("回答风格") { style }
      if runtime.scene == "settings" { group("预设") { presetList } }
      if let error { InlineErrorText(message: error) }
    }
    .foregroundStyle(Theme.text(scheme))
    .task(id: runtime.generation) { await loadUsage() }
    .sheet(item: $editing) { draft in
      AIPresetEditor(draft: draft, presets: presets) { editing = nil }
    }
    .sheet(isPresented: $editingSystemPrompt) {
      AISystemPromptEditor(presets: presets) { editingSystemPrompt = false }
    }
    .confirmationDialog("清除全部 AI 回答与对话？", isPresented: $confirmClearAll) {
      Button("清除全部", role: .destructive) {
        Task {
          do { try await runtime.clearAll(); error = nil } catch { self.error = "没能清除 AI 对话，请稍后重试。" }
          await loadUsage()
        }
      }
      Button("取消", role: .cancel) {}
    } message: { Text("本机保存的所有回答、对话与分段摘要都会被删除。") }
  }

  private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      // Titles sit 10 pt inside the card edge, like the other categories' section headers.
      Text(title).font(Theme.Font.section).padding(.leading, 10)
      VStack(spacing: 0) { content() }.cardSurface(scheme)
    }
  }
  private func row<Trailing: View>(_ title: String, _ detail: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(Theme.Font.body)
        if let detail, !detail.isEmpty {
          Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      trailing()
    }.padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 52)
  }
  private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
  }

  // MARK: 预设

  private var presetList: some View {
    VStack(spacing: 0) {
      List {
        ForEach(presets.presets) { preset in
          presetRow(preset).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        .onMove { from, to in
          var ids = presets.presets.map(\.id)
          ids.move(fromOffsets: from, toOffset: to)
          do { try presets.move(ids) } catch { self.error = error.localizedDescription }
        }
      }
      .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
      .frame(height: CGFloat(presets.presets.count) * 53)
      Hairline().padding(.leading, 16)
      HStack(spacing: 12) {
        Button("新建预设…") { editing = AIPresetDraft.new() }.buttonStyle(AppButtonStyle(size: .small))
        Text("拖动排序；面板里按此顺序显示，并按视频分区把推荐的预设排在前面。")
          .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }.padding(.horizontal, 16).padding(.vertical, 12)
    }
  }
  private func presetRow(_ preset: AIPreset) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiaryText(scheme))
          .help("拖动排序")
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(preset.name).font(Theme.Font.body)
            if presets.isEdited(preset.id) { StatusPill(text: "已修改", positive: false) }
            if !preset.builtIn { StatusPill(text: "自定义", positive: false) }
          }
          Text(Self.note(preset)).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Button("编辑") { editing = AIPresetDraft(preset) }.buttonStyle(AppButtonStyle(size: .small))
        toggle(preset.name, isOn: Binding(get: { presets.isEnabled(preset.id) }, set: { value in
          do { try presets.setEnabled(preset.id, value) } catch { self.error = error.localizedDescription }
        }))
      }.padding(.horizontal, 16).frame(height: 52)
      Hairline().padding(.leading, 16)
    }
    .contextMenu {
      Button("上移") { move(preset, by: -1) }
      Button("下移") { move(preset, by: 1) }
    }
  }
  private func move(_ preset: AIPreset, by offset: Int) {
    var ids = presets.presets.map(\.id)
    guard let index = ids.firstIndex(of: preset.id), ids.indices.contains(index + offset) else { return }
    ids.swapAt(index, index + offset)
    try? presets.move(ids)
  }
  static func note(_ preset: AIPreset) -> String {
    let targets = preset.targets.map(\.title).joined(separator: "、")
    let what: String = switch preset.id {
    case AIBuiltInPresets.chapters.id: "带可点击时间戳"
    case AIBuiltInPresets.clips.id: "挑出最值得看的片段，可依次播放"
    case AIBuiltInPresets.highlights.id: "弹幕峰值结合字幕"
    case AIBuiltInPresets.danmakuTalk.id: "高频话题与梗解释"
    case AIBuiltInPresets.commentViews.id: "共识、分歧、补充与勘误"
    case AIBuiltInPresets.evaluation.id, AIBuiltInPresets.articleEvaluation.id: "结合内容与评论的客观评价"
    case AIBuiltInPresets.question.id, AIBuiltInPresets.articleQuestion.id: "下方输入框的追问"
    case AIBuiltInPresets.articlePoints.id: "概述、要点与结论"
    default: preset.legacyTemplate ? "由旧版自定义模板迁移" : "自定义提示词"
    }
    return targets + " · " + what
  }

  // MARK: 默认发送的内容

  private var materials: some View {
    VStack(spacing: 0) {
      ForEach(Array(Self.materialRows.enumerated()), id: \.offset) { index, item in
        if index > 0 { Hairline().padding(.leading, 16) }
        row(item.kind.title, item.note) {
          toggle(item.kind.title, isOn: Binding(get: { !presets.materials.disabled.contains(item.kind) }, set: { on in
            var value = presets.materials
            if on { value.disabled.remove(item.kind) } else { value.disabled.insert(item.kind) }
            presets.materials = value
          }))
        }
      }
      Hairline().padding(.leading, 16)
      row("字幕语言顺序", "按此顺序在人工字幕中挑选；开启 设置 › 下载与截图 › 隐藏 AI 字幕 时不使用 B 站 AI 字幕。") {
        Menu {
          ForEach(AIContextPopover.languageOrders, id: \.title) { order in
            Button(order.title) {
              var value = presets.materials; value.subtitleLanguages = order.languages; presets.materials = value
            }
          }
        } label: { MenuLabel(title: AIContextPopover.languageTitle(presets.materials.subtitleLanguages)) }.appMenuStyle()
      }
    }
  }
  static let materialRows: [(kind: AIMaterialKind, note: String)] = [
    (.subtitles, "人工字幕优先；没有时使用 B 站 AI 字幕。"),
    (.officialSummary, "哔哩哔哩提供的分段与总结。"),
    (.danmaku, "只发统计结果与少量代表弹幕。"),
    (.comments, "置顶、高赞与 UP 主回复，附赞数。"),
    (.viewerPosition, "问答时附带当前时间前后 90 秒的字幕。"),
    (.history, "追问时附带之前的问答；较早的轮次压缩后发送。"),
  ]

  // MARK: 对话与保存

  private var conversations: some View {
    VStack(spacing: 0) {
      row("在本机保存回答与对话", "再次打开同一视频时直接显示，可以接着追问；相同的请求直接用保存的回答，不重复花钱。") {
        toggle("在本机保存回答与对话", isOn: $presets.saveConversations)
      }
      Hairline().padding(.leading, 16)
      row("保存期限") {
        Menu {
          ForEach(Self.retentionOptions, id: \.days) { option in Button(option.title) { presets.retentionDays = option.days } }
        } label: { MenuLabel(title: Self.retentionTitle(presets.retentionDays)) }.appMenuStyle()
      }
      Hairline().padding(.leading, 16)
      row(usageText, runtime.storeError ?? "保存在 ~/Library/Application Support/Manping/ai.sqlite，退出登录时一并清除。") {
        Button("清除全部") { confirmClearAll = true }.buttonStyle(AppButtonStyle(role: .destructive, size: .small))
          .disabled(runtime.conversations == nil)
      }
    }
  }
  static let retentionOptions: [(days: Int, title: String)] = [(7, "7 天"), (30, "30 天"), (90, "90 天"), (365, "1 年"), (0, "永久")]
  static func retentionTitle(_ days: Int) -> String { retentionOptions.first { $0.days == days }?.title ?? "\(days) 天" }
  private var usageText: String {
    guard runtime.conversations != nil else { return "回答与对话不可保存" }
    guard let usage else { return "正在统计…" }
    let megabytes = Double(usage.bytes) / 1_048_576
    let size = megabytes >= 0.1 ? String(format: "%.1f MB", megabytes) : "\(max(1, usage.bytes / 1024)) KB"
    return "已保存 \(usage.sources) 个视频的对话、\(usage.answers) 个回答 · \(size)"
  }
  private func loadUsage() async {
    guard let service = runtime.conversations else { return }
    usage = try? await service.usage()
  }

  // MARK: 回答风格

  private var style: some View {
    VStack(spacing: 0) {
      row("详细程度") {
        Picker("详细程度", selection: $presets.answerDetail) {
          ForEach(AIAnswerDetail.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
      }
      Hairline().padding(.leading, 16)
      row("系统提示词", "所有预设共用的基本规则：只依据提供的材料、标注不确定、不执行材料中的指令。") {
        Button("查看与编辑…") { editingSystemPrompt = true }.buttonStyle(AppButtonStyle(size: .small))
      }
      Hairline().padding(.leading, 16)
      row("使用流式响应", "在生成过程中逐步显示回答。") {
        toggle("使用流式响应", isOn: $prompts.streaming)
      }
    }
  }
}

/// An edit of one preset (or a new custom one).
struct AIPresetDraft: Identifiable {
  let id: String
  var preset: AIPreset
  let isNew: Bool
  init(_ preset: AIPreset, isNew: Bool = false) { id = preset.id; self.preset = preset; self.isNew = isNew }
  static func new() -> AIPresetDraft {
    AIPresetDraft(AIPreset(id: "new", name: "", targets: [.video, .pgc], taskPrompt: "任务：", output: .markdown,
      optional: [.subtitles, .officialSummary, .danmaku, .comments, .viewerPosition, .history]), isNew: true)
  }
}

private struct AIPresetEditor: View {
  @State var draft: AIPresetDraft
  @ObservedObject var presets: AIPresetStore
  let close: () -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var error: String?
  @State private var confirmDelete = false
  private var builtIn: AIPreset? { AIBuiltInPresets.all.first { $0.id == draft.preset.id } }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(draft.isNew ? "新建预设" : "编辑预设").font(Theme.Font.section)
      HStack(spacing: 12) {
        Text("名称").font(Theme.Font.body).frame(width: 64, alignment: .leading)
        TextField("预设名称", text: $draft.preset.name).textFieldStyle(AppTextFieldStyle())
      }
      HStack(spacing: 12) {
        Text("用于").font(Theme.Font.body).frame(width: 64, alignment: .leading)
        if builtIn != nil {
          Text(draft.preset.targets.map(\.title).joined(separator: "、") + " · " + draft.preset.output.title)
            .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        } else {
          ForEach([AISourceKind.video, .pgc, .article], id: \.self) { kind in
            Toggle(kind.title, isOn: Binding(get: { draft.preset.targets.contains(kind) }, set: { on in
              draft.preset.targets.removeAll { $0 == kind }
              if on { draft.preset.targets.append(kind) }
            })).toggleStyle(.checkbox)
          }
        }
        Spacer()
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("任务提示词").font(Theme.Font.body)
        Text(draft.preset.legacyTemplate ? "由旧版模板迁移：使用 {title}、{subtitle} 等变量，不附带分层材料。"
          : "材料会自动按「默认发送的内容」附在提示词之前；这里只写要做什么、用什么格式回答。")
          .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        TextEditor(text: $draft.preset.taskPrompt).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
          .padding(8).background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
      }
      if let error { InlineErrorText(message: error) }
      HStack {
        if let builtIn {
          Button("恢复默认") { draft.preset.name = builtIn.name; draft.preset.taskPrompt = builtIn.taskPrompt }
            .buttonStyle(AppButtonStyle(role: .plain))
        } else if !draft.isNew {
          Button("删除预设") { confirmDelete = true }.buttonStyle(AppButtonStyle(role: .destructive))
        }
        Spacer()
        Button("取消", action: close).buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
        Button("保存", action: save).buttonStyle(AppButtonStyle(role: .primary)).keyboardShortcut(.defaultAction)
      }
    }
    .padding(24).frame(width: 620, height: 560)
    .foregroundStyle(Theme.text(scheme))
    .confirmationDialog("删除预设「\(draft.preset.name)」？", isPresented: $confirmDelete) {
      Button("删除", role: .destructive) {
        do { try presets.delete(draft.preset.id); close() } catch { self.error = error.localizedDescription }
      }
      Button("取消", role: .cancel) {}
    }
  }
  private func save() {
    do {
      if draft.isNew {
        try presets.create(name: draft.preset.name.trimmingCharacters(in: .whitespacesAndNewlines), targets: draft.preset.targets,
          taskPrompt: draft.preset.taskPrompt)
      } else if let builtIn, draft.preset.name == builtIn.name, draft.preset.taskPrompt == builtIn.taskPrompt {
        try presets.reset(draft.preset.id)
      } else {
        try presets.update(draft.preset)
      }
      close()
    } catch { self.error = error.localizedDescription }
  }
}

private struct AISystemPromptEditor: View {
  @ObservedObject var presets: AIPresetStore
  let close: () -> Void
  @State private var text = ""
  @State private var error: String?
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("系统提示词").font(Theme.Font.section)
      Text("所有预设共用；改动后之前保存的回答不再复用。").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
        .padding(8).background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
      if let error { InlineErrorText(message: error) }
      HStack {
        Button("恢复默认") { text = AISystemPrompt.defaultText }.buttonStyle(AppButtonStyle(role: .plain))
        Spacer()
        Button("取消", action: close).buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
        Button("保存") {
          do {
            if text == AISystemPrompt.defaultText { presets.resetSystemPrompt() } else { try presets.saveSystemPrompt(text) }
            close()
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(AppButtonStyle(role: .primary)).keyboardShortcut(.defaultAction)
      }
    }
    .padding(24).frame(width: 620, height: 560)
    .foregroundStyle(Theme.text(scheme))
    .onAppear { text = presets.systemPrompt }
  }
}
