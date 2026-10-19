import ManpingCore
import SwiftUI

/// 发送给 AI 的内容 (design 02): what the previewed preset would send, per layer, with this
/// panel's 本次 switches, the estimated size against the model's window and the subtitle order.
struct AIContextPopover: View {
  @ObservedObject var panel: AIPanelModel
  /// Drawn inside the panel (screenshot scene) instead of in a popover window.
  var inline = false
  @Environment(\.colorScheme) private var scheme

  static let languageOrders: [(title: String, languages: [String])] = [
    ("简体中文 › 繁体中文 › English", AIMaterialSettings.defaultLanguages),
    ("繁体中文 › 简体中文 › English", ["zh-Hant", "zh-TW", "zh-HK", "zh-Hans", "zh-CN", "zh", "en"]),
    ("English › 简体中文 › 繁体中文", ["en", "zh-Hans", "zh-CN", "zh", "zh-Hant", "zh-TW", "zh-HK"]),
  ]
  static func languageTitle(_ languages: [String]) -> String {
    languageOrders.first { $0.languages == languages }?.title ?? languages.prefix(3).joined(separator: " › ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("发送给 AI 的内容").font(Theme.Font.section)
        Spacer()
        Text("只在你点按时发送").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
      }
      presetPicker
      usage
      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          if index > 0 { Hairline().padding(.leading, 12) }
          rowView(row)
        }
      }
      .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
      if let message = panel.previewMessage {
        Text(message).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
      }
      Text("这里的开关只对本次有效。默认值在 设置 › AI › 默认发送的内容 中修改；关闭的内容不会离开这台 Mac。")
        .font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)).fixedSize(horizontal: false, vertical: true)
    }
    .padding(16).frame(width: inline ? nil : 380, alignment: .leading).frame(maxWidth: inline ? .infinity : nil, alignment: .leading)
    .foregroundStyle(Theme.text(scheme))
    .onAppear { panel.refreshPreview() }
  }

  private var presetPicker: some View {
    HStack(spacing: 8) {
      Text("预览").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      Menu {
        ForEach(panel.panelPresets + [panel.conversationPreset]) { preset in
          Button(preset.name) { panel.focus(preset) }
        }
      } label: { MenuLabel(title: panel.focusPreset.name) }.appMenuStyle()
      Spacer()
    }
  }

  @ViewBuilder private var usage: some View {
    if let preview = panel.preview {
      let limit = max(1, preview.budget.contextTokens)
      let fraction = min(1, Double(preview.totalTokens) / Double(limit))
      VStack(alignment: .leading, spacing: 6) {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(Theme.fill(scheme))
            Capsule().fill(preview.needsSegmentation ? Theme.highlight : Theme.accent)
              .frame(width: max(4, geometry.size.width * fraction))
          }
        }.frame(height: 6)
        HStack(alignment: .firstTextBaseline) {
          Text("约 \(Self.tokens(preview.totalTokens)) / \(Self.tokens(limit)) tokens").font(Theme.Font.caption.monospacedDigit())
          Spacer()
          Text((preview.budget.known ? "\(panel.modelName) 的上下文上限" : "上限未知，按保守值估计"))
            .font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
        }
        if preview.needsSegmentation {
          Text("超过一次能发送的长度：会先按章节分段整理，分段结果保存在本机并复用。")
            .font(Theme.Font.caption2).foregroundStyle(Theme.warning(scheme)).fixedSize(horizontal: false, vertical: true)
        }
        if let reason = preview.availability.reason {
          Text(reason).font(Theme.Font.caption2).foregroundStyle(Theme.warning(scheme)).fixedSize(horizontal: false, vertical: true)
        }
      }
    } else if panel.previewMessage == nil {
      HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在估算…").font(Theme.Font.caption) }
        .foregroundStyle(Theme.secondaryText(scheme))
    }
  }

  private struct Row {
    let kind: AIMaterialKind
    let detail: String
    let tokens: Int?
    let used: Bool
  }
  private var rows: [Row] {
    if let preview = panel.preview {
      return preview.rows.map { row in
        switch row.state {
        case .sent: Row(kind: row.kind, detail: row.detail, tokens: row.tokens, used: true)
        case .switchedOff: Row(kind: row.kind, detail: "已关闭，不会发送", tokens: nil, used: true)
        case .unavailable(let note): Row(kind: row.kind, detail: note, tokens: nil, used: true)
        case .notUsed: Row(kind: row.kind, detail: "「\(panel.focusPreset.name)」不使用", tokens: nil, used: false)
        }
      }
    }
    let kinds: [AIMaterialKind] = panel.source.kind == .article
      ? [.metadata, .articleBody, .comments, .history] : [.metadata, .subtitles, .officialSummary, .danmaku, .comments, .viewerPosition, .history]
    return kinds.map { Row(kind: $0, detail: Self.defaultDetail($0), tokens: nil, used: true) }
  }
  private func rowView(_ row: Row) -> some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.kind.title).font(Theme.Font.body)
          if row.kind == .subtitles {
            Menu {
              ForEach(Self.languageOrders, id: \.title) { order in
                Button(order.title) { panel.setLanguages(order.languages) }
              }
            } label: { Text("\(Self.languageTitle(panel.settings.subtitleLanguages).components(separatedBy: " › ").first ?? "") ⌄") }
              .menuStyle(.button).buttonStyle(.plain).font(Theme.Font.caption2).foregroundStyle(Theme.accentText(scheme)).fixedSize()
              .help("字幕语言顺序（本次）")
          }
        }
        Text(row.detail).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let tokens = row.tokens, tokens > 0 {
        Text(Self.tokens(tokens)).font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText(scheme))
      }
      if row.kind.isSwitchable {
        Toggle(row.kind.title, isOn: Binding(get: { panel.allows(row.kind) }, set: { panel.setAllowed(row.kind, $0) }))
          .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
      } else {
        Text("必带").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .opacity(row.used ? 1 : 0.6)
  }

  static func tokens(_ value: Int) -> String {
    if value >= 10_000 {
      let text = String(format: "%.1f", Double(value) / 10_000)
      return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + " 万"
    }
    return String(value)
  }
  static func defaultDetail(_ kind: AIMaterialKind) -> String {
    switch kind {
    case .metadata: "标题、简介、标签、分区、UP 主、统计（必带）"
    case .articleBody: "专栏正文（必带）"
    case .subtitles: "人工字幕优先；没有时使用 B 站 AI 字幕"
    case .officialSummary: "哔哩哔哩提供的章节分段与官方总结"
    case .danmaku: "只发统计结果与少量代表弹幕"
    case .comments: "置顶、高赞与 UP 主回复，附赞数"
    case .viewerPosition: "问答时附带当前进度前后的字幕"
    case .history: "追问时附带之前的问答"
    }
  }
}
