import AppKit
import ManpingCore
import SwiftUI

// MARK: - Shared pieces

/// A cited time. Seekable times are amber or accent capsules that jump the player; the rest
/// stay plain text (design 03: only times backed by material are links).
struct AITimestampPill: View {
  let text: String
  let seekable: Bool
  var highlight = false
  let action: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    if seekable {
      Button(action: action) {
        Text(text).font(Theme.Font.caption2.weight(.bold).monospacedDigit())
          .padding(.horizontal, 8).frame(height: 22)
          .foregroundStyle(highlight ? Theme.warning(scheme) : Theme.accentText(scheme))
          .background(Capsule().fill(highlight ? Theme.highlight.opacity(0.18) : Theme.accent.opacity(0.16)))
          .contentShape(Capsule())
      }.buttonStyle(.plain).help("跳到 \(text)")
        .accessibilityLabel("跳到 \(text)").demoAnchor("ai.time.\(text)")
    } else {
      Text(text).font(Theme.Font.caption2.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 8).frame(height: 22)
        .foregroundStyle(Theme.tertiaryText(scheme))
        .background(Capsule().strokeBorder(Theme.separator(scheme), lineWidth: 1))
        .help("没有对应材料依据的时间，不能跳转")
    }
  }
}

/// Small capsule action at the bottom of a card (拷贝, 重新生成).
struct AICardAction: View {
  let title: String
  let action: () -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      Text(title).font(Theme.Font.caption2).padding(.horizontal, 8).frame(height: 22)
        .foregroundStyle(Theme.secondaryText(scheme))
        .background(Capsule().fill(hovering ? Theme.fillHover(scheme) : Theme.fill(scheme)))
        .contentShape(Capsule())
    }.buttonStyle(.plain).onHover { hovering = $0 }
  }
}

/// Non-blocking note (降级说明): amber hairline box, one sentence.
struct AINoteRow: View {
  let text: String
  var symbol = "info.circle"
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warning(scheme))
      Text(text).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.highlight.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.highlight.opacity(0.25), lineWidth: 0.5))
  }
}

extension AIMaterialKind {
  /// Short name for 依据 lines and the context button.
  var shortTitle: String {
    switch self {
    case .metadata: "基本信息"
    case .articleBody: "正文"
    case .subtitles: "字幕"
    case .officialSummary: "官方章节"
    case .danmaku: "弹幕"
    case .comments: "评论"
    case .viewerPosition: "当前进度"
    case .history: "对话历史"
    }
  }
}

enum AIRelativeTime {
  static func text(_ date: Date, now: Date = Date()) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M 月 d 日"
    return formatter.string(from: date)
  }
}

// MARK: - The answer card

/// One saved answer: its content by kind, then 依据, model and time, 拷贝 and 重新生成.
struct AIAnswerCard: View {
  let turn: AITurn
  @ObservedObject var panel: AIPanelModel
  @ObservedObject var clips: ClipPlaybackController
  let seek: (Double) -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var copied = false
  @State private var parsing = AIMarkdownParseCache()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      content
      if !turn.notes.isEmpty {
        VStack(alignment: .leading, spacing: 6) { ForEach(turn.notes, id: \.self) { AINoteRow(text: $0) } }
      }
      if let basis { Text("依据：" + basis).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)) }
      footer
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
  }

  @ViewBuilder private var content: some View {
    switch turn.content {
    case .structured(.chapters(let result)): AIChaptersContent(result: result, seek: seek)
    case .structured(.highlights(let result)): AIHighlightsContent(result: result, duration: panel.source.duration, seek: seek)
    case .structured(.clips(let result)):
      AIClipsContent(result: result, turnID: turn.id, panel: panel, clips: clips, seek: seek)
    case .markdown(let text):
      if turn.presetID == AIBuiltInPresets.commentViews.id, let sections = parsing.comments(text) {
        AICommentViewsContent(sections: sections, seek: panel.isCurrentMedia ? seek : nil, duration: panel.source.duration)
      } else {
        AIMarkdownView(text: text, seek: panel.isCurrentMedia ? seek : nil, duration: panel.source.duration)
      }
    case .fallback(let text, let reason):
      VStack(alignment: .leading, spacing: 8) {
        AINoteRow(text: reason, symbol: "exclamationmark.triangle")
        AIMarkdownView(text: text, seek: nil, duration: nil)
      }
    }
  }

  /// 依据: the materials this answer was built on, most important first.
  private var basis: String? {
    let kinds = turn.materials.subtracting([.metadata]).sorted()
    guard !kinds.isEmpty else { return nil }
    return kinds.map(\.shortTitle).joined(separator: "、")
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Text(meta).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
      Spacer(minLength: 4)
      AICardAction(title: copied ? "已拷贝" : "拷贝") {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(turn.content.markdownText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
      }
      AICardAction(title: "重新生成") { panel.regenerate(turn) }.disabled(panel.busy || !panel.hasService)
    }
  }
  private var meta: String {
    let model = panel.models.values.joined().first { $0.id == turn.model }?.name ?? turn.model
    var parts = [model]
    if turn.fromCache { parts.append("来自本机保存") } else if panel.presets.saveConversations { parts.append("已保存") }
    parts.append(AIRelativeTime.text(turn.createdAt))
    return parts.joined(separator: " · ")
  }
}

// MARK: - 章节总结

struct AIChaptersContent: View {
  let result: AIChaptersResult
  let seek: (Double) -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !result.overview.isEmpty {
        Text(result.overview).font(Theme.Font.body).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      if result.insufficient { AINoteRow(text: "材料不足，总结可能不完整。") }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(result.chapters.enumerated()), id: \.offset) { _, chapter in
          HStack(alignment: .top, spacing: 10) {
            AITimestampPill(text: chapter.start.text, seekable: chapter.start.seekable, highlight: chapter.highlight) {
              seek(chapter.start.seconds)
            }
            Text("\(Text(chapter.title).fontWeight(.semibold).foregroundColor(Theme.text(scheme)))\(Text(chapter.points.isEmpty ? "" : " · " + chapter.points.joined(separator: "；")).foregroundColor(Theme.secondaryText(scheme)))")
              .font(Theme.Font.caption).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              .padding(.top, 2)
          }
        }
      }
    }
  }
}

// MARK: - 高能时刻

struct AIHighlightsContent: View {
  let result: AIHighlightsResult
  let duration: Double?
  let seek: (Double) -> Void
  @Environment(\.colorScheme) private var scheme
  /// The digest carries counts per window; the curve is drawn against the busiest one.
  private var normalized: [Double] {
    let peak = result.density.max() ?? 0
    return peak > 0 ? result.density.map { $0 / peak } : result.density
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if result.density.count > 1 {
        ZStack(alignment: .bottomLeading) {
          DanmakuDensityCurve(values: normalized)
            .fill(LinearGradient(colors: [Theme.highlight.opacity(0.85), Theme.highlight.opacity(0.08)], startPoint: .top, endPoint: .bottom))
          GeometryReader { geometry in
            ForEach(Array(result.moments.enumerated()), id: \.offset) { _, moment in
              if let duration, duration > 0 {
                Circle().fill(Theme.highlight).frame(width: 6, height: 6)
                  .position(x: geometry.size.width * min(1, max(0, moment.start.seconds / duration)), y: geometry.size.height - 3)
              }
            }
          }
        }
        .frame(height: 40)
        .padding(.horizontal, 2)
        .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .accessibilityLabel("弹幕密度曲线")
      }
      if result.moments.isEmpty {
        Text("没有找到可以确认的高能时刻。").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      }
      ForEach(Array(result.moments.enumerated()), id: \.offset) { _, moment in
        HStack(alignment: .top, spacing: 10) {
          AITimestampPill(text: moment.start.text, seekable: moment.start.seekable, highlight: true) { seek(moment.start.seconds) }
          VStack(alignment: .leading, spacing: 4) {
            Text("\(Text(moment.title).fontWeight(.semibold).foregroundColor(Theme.text(scheme)))\(Text(moment.why.isEmpty ? "" : " · " + moment.why).foregroundColor(Theme.secondaryText(scheme)))")
              .font(Theme.Font.caption).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if !moment.quotes.isEmpty {
              Text("弹幕：" + moment.quotes.map { "「\($0.text)」" }.joined())
                .font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)).fixedSize(horizontal: false, vertical: true)
            }
          }.padding(.top, 2).textSelection(.enabled)
        }
      }
      Text("弹幕代表观众反应，不代表事实。").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
    }
  }
}

// MARK: - 只看 3 分钟

struct AIClipsContent: View {
  let result: AIClipsResult
  let turnID: String
  @ObservedObject var panel: AIPanelModel
  @ObservedObject var clips: ClipPlaybackController
  let seek: (Double) -> Void
  @Environment(\.colorScheme) private var scheme
  private var playing: Bool { clips.isPlaying(turn: turnID) }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !result.summary.isEmpty {
        Text(result.summary).font(Theme.Font.body).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(result.clips.enumerated()), id: \.offset) { index, clip in
          HStack(alignment: .top, spacing: 10) {
            AITimestampPill(text: AITimecode.format(clip.start) + "–" + AITimecode.format(clip.end),
              seekable: result.valid && panel.isCurrentMedia, highlight: playing && clips.phase.index == index) { seek(clip.start) }
            Text(clip.reason).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineSpacing(3)
              .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
          }
        }
      }
      if result.valid {
        HStack(spacing: 8) {
          Text(totalText).font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
          Spacer(minLength: 4)
          if playing {
            Text("正在播放第 \((clips.phase.index ?? 0) + 1) / \(clips.clipCount) 段").font(Theme.Font.caption2.weight(.semibold))
              .foregroundStyle(Theme.accentText(scheme))
            Button("停止") { clips.stop() }.buttonStyle(AppButtonStyle(size: .small))
          } else {
            Button {
              clips.start(result, media: panel.source.identifier, turnID: turnID)
            } label: { Label("依次播放", systemImage: "play.fill") }
              .buttonStyle(AppButtonStyle(role: .primary, size: .small)).disabled(!panel.isCurrentMedia)
              .help(panel.isCurrentMedia ? "从第一段开始依次播放，最后一段结束后暂停" : "打开这个视频后才能播放")
          }
        }
        if playing {
          Text("播放期间暂停连续播放与自动跳过片头片尾；拖动进度或换视频即退出。")
            .font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
        }
      } else {
        // F4: a result that breaks the rules offers no playback.
        AINoteRow(text: "这组片段不符合要求，不能播放：" + result.problems.joined(separator: "；"), symbol: "exclamationmark.triangle")
      }
    }
  }
  private var totalText: String {
    let total = AITimecode.wholeSeconds(result.totalSeconds)
    let text = total >= 60 ? "\(total / 60) 分 \(total % 60) 秒" : "\(total) 秒"
    return "共 \(result.clips.count) 段 · \(text)"
  }
}

private extension AIClipPlaybackMachine.Phase {
  var index: Int? {
    switch self {
    case .idle: nil
    case .seeking(let index), .playing(let index): index
    }
  }
}

// MARK: - 评论区观点

/// The four sections of the comment-views preset, parsed from its Markdown.
struct AICommentViewsContent: View {
  let sections: AICommentSections
  let seek: ((Double) -> Void)?
  let duration: Double?
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(sections.sections.enumerated()), id: \.offset) { _, section in
        VStack(alignment: .leading, spacing: 4) {
          Text(section.title).font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(tint(section.title))
          AIMarkdownView(text: section.body.isEmpty ? "（没有）" : section.body, seek: seek, duration: duration, compact: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Text("评论代表观众看法，不等于事实。").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
    }
  }
  private func tint(_ title: String) -> Color {
    if title.contains("认同") { return Theme.success(scheme) }
    if title.contains("分歧") { return Theme.warning(scheme) }
    if title.contains("勘误") || title.contains("补充") { return Theme.accentText(scheme) }
    return Theme.tertiaryText(scheme)
  }
}

// MARK: - 官方总结

/// Bilibili's own summary in its three states (F15).
struct AIOfficialSummaryCard: View {
  let state: AIPanelModel.Official
  let seek: ((Double) -> Void)?
  let retry: () -> Void
  let configure: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("哔哩哔哩官方总结", systemImage: "text.badge.checkmark").font(Theme.Font.caption.weight(.semibold))
        .foregroundStyle(Theme.accentText(scheme))
      switch state {
      case .idle, .loading:
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取官方总结…").font(Theme.Font.caption) }
          .foregroundStyle(Theme.secondaryText(scheme))
      case .loaded(.available(let summary, let outline)):
        if !summary.isEmpty {
          Text(summary).font(Theme.Font.body).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if let outline, !outline.isEmpty {
          FlowLayout(spacing: 8) {
            ForEach(outline, id: \.id) { section in
              HStack(spacing: 6) {
                AITimestampPill(text: AITimecode.format(section.start), seekable: seek != nil) { seek?(section.start) }
                Text(section.title).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
              }
            }
          }
        }
      case .loaded(.unavailable(let reason)):
        Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      case .loaded(.retryableError(let reason)):
        HStack(spacing: 8) {
          Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
          Spacer(minLength: 4)
          Button("重试", action: retry).buttonStyle(AppButtonStyle(size: .small))
        }
      }
      Hairline()
      HStack(spacing: 8) {
        Text("配置一个 AI 服务，或使用 Apple 智能，就能追问和使用更多预设。").font(Theme.Font.caption)
          .foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button("配置", action: configure).buttonStyle(AppButtonStyle(role: .primary, size: .small))
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
  }
}

// MARK: - Markdown

/// Block Markdown for answers: headings, paragraphs, bullet and numbered lists, code blocks,
/// tables, quotes and rules; inline emphasis, code and links. mm:ss times become seek links
/// when the answer belongs to the media playing now and the time lies inside it.
struct AIMarkdownView: View {
  let text: String
  let seek: ((Double) -> Void)?
  let duration: Double?
  var compact = false
  @State private var parsing = AIMarkdownParseCache()
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 4 : 8) {
      ForEach(Array(parsing.blocks(text).enumerated()), id: \.offset) { _, block in
        view(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
    .tint(Theme.accentText(scheme))
    .environment(\.openURL, OpenURLAction { url in
      guard url.scheme == AIMarkdownBlock.seekScheme else { return .systemAction }
      if let seconds = Double(url.host ?? ""), let seek { seek(seconds) }
      return .handled
    })
  }

  @ViewBuilder private func view(_ block: AIMarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      inline(text).font(level <= 2 ? Theme.Font.headline : Theme.Font.caption.weight(.semibold)).padding(.top, compact ? 0 : 4)
    case .paragraph(let text):
      inline(text).font(compact ? Theme.Font.caption : Theme.Font.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    case .list(let items, let ordered):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(ordered ? "\(index + 1)." : "•").font((compact ? Theme.Font.caption : Theme.Font.body).monospacedDigit())
              .foregroundStyle(Theme.tertiaryText(scheme))
            inline(item.text).font(compact ? Theme.Font.caption : Theme.Font.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
          }.padding(.leading, CGFloat(item.depth) * 14)
        }
      }
    case .code(let code):
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code).font(.system(size: 12, design: .monospaced)).padding(10)
      }
      .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    case .quote(let text):
      HStack(alignment: .top, spacing: 8) {
        Capsule().fill(Theme.accent.opacity(0.5)).frame(width: 3)
        inline(text).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
      }
    case .table(let header, let rows):
      ScrollView(.horizontal, showsIndicators: false) {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
          GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, cell in inline(cell).font(Theme.Font.caption.weight(.semibold)) } }
          Divider()
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in inline(cell).font(Theme.Font.caption) } }
          }
        }.padding(10)
      }
      .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    case .rule:
      Hairline()
    }
  }

  private func inline(_ source: String) -> Text {
    Text(parsing.inline(source, seekable: seek != nil, duration: duration))
  }
}
