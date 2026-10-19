import Foundation

/// Everything gathered for one source before switches and budget are applied.
public struct AIMaterialBundle: Sendable, Equatable {
  public var source: AISource
  public var transcript: AITranscript?
  /// Why no transcript is available (no track, AI subtitles hidden, download failed…).
  public var transcriptNote: String?
  public var viewPoints: [AIViewPoint]
  /// "official" (player view_points) or "player" (mpv chapter list fallback supplied by the UI).
  public var viewPointSource: String
  public var official: AIOfficialSummary?
  public var danmaku: AIDanmakuDigest?
  public var danmakuNote: String?
  public var comments: AICommentDigest?
  public var commentsNote: String?
  /// A material failed for a reason that may pass (network, server); such a bundle is not cached,
  /// so the next run or 重试 fetches again.
  public var transient = false
  public init(source: AISource, transcript: AITranscript? = nil, transcriptNote: String? = nil, viewPoints: [AIViewPoint] = [],
    viewPointSource: String = "official", official: AIOfficialSummary? = nil, danmaku: AIDanmakuDigest? = nil,
    danmakuNote: String? = nil, comments: AICommentDigest? = nil, commentsNote: String? = nil) {
    self.source = source; self.transcript = transcript; self.transcriptNote = transcriptNote; self.viewPoints = viewPoints
    self.viewPointSource = viewPointSource; self.official = official; self.danmaku = danmaku; self.danmakuNote = danmakuNote
    self.comments = comments; self.commentsNote = commentsNote
  }
}

public enum AIContextTag: String, Codable, Sendable, CaseIterable {
  case metadata, chapters, officialSummary = "official_summary", transcript, segmentSummaries = "segment_summaries", article
  case danmakuDigest = "danmaku_digest", comments, viewer
}

public struct AIContextLayer: Sendable, Equatable {
  public let tag: AIContextTag
  public let material: AIMaterialKind
  public let body: String
  public let rendered: String
  public let tokens: Int
  /// SHA-256 of the rendered layer: what the cache key sees of this material.
  public let digest: String
  public init(tag: AIContextTag, material: AIMaterialKind, attributes: [(String, String)] = [], body: String) {
    self.tag = tag; self.material = material; self.body = body
    let attributeText = attributes.map { "\($0.0)=\"\(Self.escapeAttribute($0.1))\"" }
    let open = ([tag.rawValue] + attributeText).joined(separator: " ")
    rendered = "<\(open)>\n\(Self.neutralized(body, tag: tag))\n</\(tag.rawValue)>"
    tokens = AITokenEstimator.estimate(rendered)
    digest = AIHash.sha256(rendered)
  }
  static func escapeAttribute(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
  }
  /// Material cannot close its own tag or the context block early.
  static func neutralized(_ body: String, tag: AIContextTag) -> String {
    var text = body
    for name in ["context", "history_summary"] + AIContextTag.allCases.map(\.rawValue) {
      text = text.replacingOccurrences(of: "</\(name)", with: "<\\/\(name)", options: .caseInsensitive)
    }
    return text
  }
}

/// One segment summary that replaces the transcript or article body of a long source.
public struct AISegmentSummary: Sendable, Equatable, Codable {
  public let id: String
  public let start: Double
  public let end: Double
  /// For articles: the paragraph range, e.g. "p3-p9".
  public let label: String?
  public let text: String
  public init(id: String, start: Double, end: Double, label: String? = nil, text: String) {
    self.id = id; self.start = start; self.end = end; self.label = label; self.text = text
  }
}

/// The layered context of one request, rendered as the XML-tagged block of design 05.
public struct AIContextPack: Sendable, Equatable {
  public let source: AISource
  public private(set) var layers: [AIContextLayer]
  public private(set) var evidence: AIEvidenceIndex
  /// Kinds that are not in the pack and why (switched off, not available).
  public private(set) var notes: [AIMaterialKind: String]
  /// Which kinds' content is in the pack.
  public var materials: Set<AIMaterialKind> { Set(layers.map(\.material)) }
  public var tokens: Int { layers.reduce(0) { $0 + $1.tokens } + 8 }

  public func rendered() -> String {
    "<context>\n" + layers.map(\.rendered).joined(separator: "\n") + "\n</context>"
  }
  public func layer(_ tag: AIContextTag) -> AIContextLayer? { layers.first { $0.tag == tag } }
  public func without(_ tags: Set<AIContextTag>) -> AIContextPack {
    var copy = self; copy.layers.removeAll { tags.contains($0.tag) }; return copy
  }
  /// The same pack with the transcript or article body replaced by segment summaries.
  public func replacingBody(with summaries: [AISegmentSummary], coverageNote: String?) -> AIContextPack {
    var copy = self
    guard let index = copy.layers.firstIndex(where: { $0.tag == .transcript || $0.tag == .article }) else { return copy }
    let old = copy.layers[index]
    var attributes: [(String, String)] = [("source", old.tag == .article ? "article" : "transcript"), ("parts", String(summaries.count))]
    if let coverageNote { attributes.append(("coverage", coverageNote)) }
    let body = summaries.map { summary in
      "[\(summary.id) " + (summary.label ?? "\(AITimecode.format(summary.start))-\(AITimecode.format(summary.end))") + "]\n" + summary.text
    }.joined(separator: "\n\n")
    copy.layers[index] = AIContextLayer(tag: .segmentSummaries, material: old.material, attributes: attributes, body: body)
    for summary in summaries where summary.label == nil { copy.evidence.add(summary.id, start: summary.start, end: summary.end) }
    return copy
  }

  /// Applies the user's switches (plus one-time permissions) and the preset's material list.
  public static func build(_ bundle: AIMaterialBundle, preset: AIPreset, settings: AIMaterialSettings,
    oneTime: Set<AIMaterialKind> = [], viewerPosition: Double? = nil) -> AIContextPack {
    let wanted = Set(preset.materials)
    var layers: [AIContextLayer] = [], evidence = AIEvidenceIndex(), notes: [AIMaterialKind: String] = [:]
    func allowed(_ kind: AIMaterialKind) -> Bool {
      guard wanted.contains(kind) else { return false }
      guard settings.allows(kind, oneTime: oneTime) else { notes[kind] = "已关闭发送"; return false }
      return true
    }
    layers.append(AIContextLayer(tag: .metadata, material: .metadata, body: metadata(bundle.source)))
    let source = bundle.source
    if source.kind.isTimeline {
      if allowed(.officialSummary) {
        if !bundle.viewPoints.isEmpty {
          let body = bundle.viewPoints.map { "[\($0.id) \(AITimecode.format($0.start))-\(AITimecode.format($0.end))] \($0.title)" }
            .joined(separator: "\n")
          layers.append(AIContextLayer(tag: .chapters, material: .officialSummary, attributes: [("source", bundle.viewPointSource)], body: body))
          for point in bundle.viewPoints { evidence.add(point.id, start: point.start, end: point.end) }
        }
        if let official = bundle.official, let body = official.render() {
          layers.append(AIContextLayer(tag: .officialSummary, material: .officialSummary, body: body))
          addOutlineEvidence(official, duration: source.duration, to: &evidence)
        } else if bundle.viewPoints.isEmpty {
          if case .unavailable(let reason)? = bundle.official { notes[.officialSummary] = reason }
          else if case .retryableError(let reason)? = bundle.official { notes[.officialSummary] = reason }
          else { notes[.officialSummary] = "没有官方章节或总结" }
        }
      }
      if allowed(.subtitles) {
        if let transcript = bundle.transcript, !transcript.cues.isEmpty {
          var attributes = [("source", transcript.isAI ? "ai_subtitle" : "cc"), ("lang", transcript.language)]
          if transcript.isAI { attributes.append(("note", "AI 字幕，可能有识别错误")) }
          layers.append(AIContextLayer(tag: .transcript, material: .subtitles, attributes: attributes, body: AITranscript.render(transcript.cues)))
          for cue in transcript.cues { evidence.add(cue.id, start: cue.start, end: cue.end) }
        } else {
          notes[.subtitles] = bundle.transcriptNote ?? "没有可用字幕"
        }
      }
      if allowed(.danmaku) {
        if let digest = bundle.danmaku {
          layers.append(AIContextLayer(tag: .danmakuDigest, material: .danmaku,
            attributes: [("window", "\(Int(digest.window))s"), ("loaded", String(digest.loadedCount)), ("note", "基于已加载弹幕")],
            body: digest.render()))
          for peak in digest.peaks { evidence.add(peak.id, start: peak.start, end: peak.end) }
          for quote in digest.allQuotes { evidence.add(quote.id, start: quote.time, end: quote.time) }
        } else { notes[.danmaku] = bundle.danmakuNote ?? "弹幕太少" }
      }
    } else if case .article(let info) = source {
      let body = AIArticleText.render(AIArticleText.identified(info))
      layers.append(AIContextLayer(tag: .article, material: .articleBody, attributes: [("paragraphs", String(info.paragraphs.count))], body: body))
    }
    if allowed(.comments) {
      if let digest = bundle.comments {
        var attributes: [(String, String)] = [("pages", String(digest.pagesLoaded))]
        if digest.partial { attributes.append(("note", "只读取到第一页")) }
        layers.append(AIContextLayer(tag: .comments, material: .comments, attributes: attributes, body: digest.render()))
      } else { notes[.comments] = bundle.commentsNote ?? "没有评论" }
    }
    if source.kind.isTimeline, preset.style == .conversation, let position = viewerPosition, position.isFinite, position >= 0,
      allowed(.viewerPosition) {
      // Subtitle text around the position goes only when subtitles may be sent too.
      var body = "当前播放位置 \(AITimecode.format(position))"
      if settings.allows(.subtitles, oneTime: oneTime), let transcript = bundle.transcript {
        let window = transcript.cues(in: max(0, position - 45)...(position + 45))
        if !window.isEmpty { body = AITranscript.render(window) }
      }
      layers.append(AIContextLayer(tag: .viewer, material: .viewerPosition, attributes: [("position", AITimecode.format(position))], body: body))
    }
    return AIContextPack(source: source, layers: layers, evidence: evidence, notes: notes)
  }

  static func addOutlineEvidence(_ official: AIOfficialSummary, duration: Double?, to evidence: inout AIEvidenceIndex) {
    guard case .available(_, let outline?) = official else { return }
    let end = duration ?? (outline.last.map { $0.start + 600 } ?? 0)
    for (index, section) in outline.enumerated() {
      let sectionEnd = index + 1 < outline.count ? outline[index + 1].start : end
      evidence.add(section.id, start: section.start, end: max(section.start, sectionEnd))
      for (offset, point) in section.points.enumerated() {
        let next = offset + 1 < section.points.count ? section.points[offset + 1].time : sectionEnd
        evidence.add(point.id, start: point.time, end: max(point.time, next))
      }
    }
  }

  static func count(_ value: Int) -> String {
    value >= 10_000 ? String(format: "%.1f 万", Double(value) / 10_000).replacingOccurrences(of: ".0 万", with: " 万") : String(value)
  }
  static func date(_ seconds: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
  }
  static func clipped(_ text: String, _ limit: Int) -> String {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.count > limit ? String(value.prefix(limit)) + "…" : value
  }
  /// Body of `<metadata>`: always sent (title, part, uploader, partition, tags, length, stats, intro).
  public static func metadata(_ source: AISource) -> String {
    var lines: [String] = []
    switch source {
    case .video(let info):
      lines.append("标题：" + info.title)
      if let part = info.partTitle, let index = info.partIndex, let count = info.partCount { lines.append("分 P：第 \(index) 集 \(part)（共 \(count) 集）") }
      if let collection = info.collectionTitle { lines.append("合集：" + collection) }
      if !info.uploaderName.isEmpty {
        let followers = info.followers.map { value -> String in
          let text = count(value)
          return "（" + text + (text.hasSuffix("万") ? "粉丝）" : " 粉丝）")
        }
        lines.append("UP 主：" + info.uploaderName + (followers ?? ""))
      }
      var partition = info.category.map { "分区：" + $0.name } ?? ""
      if !info.tags.isEmpty { partition += (partition.isEmpty ? "" : "   ") + "标签：" + info.tags.prefix(10).joined(separator: "、") }
      if !partition.isEmpty { lines.append(partition) }
      let timing = [info.duration > 0 ? "时长：" + AITimecode.format(info.duration) : nil, info.publishedAt.map { "发布：" + date($0) }].compactMap { $0 }
      if !timing.isEmpty { lines.append(timing.joined(separator: "   ")) }
      let stats = [info.views.map { "播放 \(count($0))" }, info.danmakuCount.map { "弹幕 \(count($0))" }, info.likes.map { "点赞 \(count($0))" }].compactMap { $0 }
      if !stats.isEmpty { lines.append("数据：" + stats.joined(separator: " · ")) }
      if !info.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("简介：" + clipped(info.description, 1_000)) }
    case .pgc(let info):
      lines.append("标题：" + info.seasonTitle)
      lines.append("本集：" + (info.episodeIndex.map { "第 \($0) 话 " } ?? "") + info.episodeTitle + (info.episodeCount.map { "（共 \($0) 话）" } ?? ""))
      lines.append("时长：" + AITimecode.format(info.duration) + (info.score.map { "   评分：\($0)" } ?? ""))
      if !info.staff.isEmpty { lines.append("制作：" + clipped(info.staff, 300)) }
      if !info.actors.isEmpty { lines.append("角色与声优：" + clipped(info.actors, 300)) }
      if !info.description.isEmpty { lines.append("简介：" + clipped(info.description, 1_000)) }
    case .article(let info):
      lines.append("标题：" + info.title)
      if !info.authorName.isEmpty { lines.append("作者：" + info.authorName) }
      if let category = info.category { lines.append("分区：" + category) }
      if !info.tags.isEmpty { lines.append("标签：" + info.tags.prefix(10).joined(separator: "、")) }
    }
    return lines.joined(separator: "\n")
  }
}

/// What the context popover shows for each kind: whether it would be sent and roughly how much.
public struct AIContextPreview: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    case sent
    case switchedOff
    case unavailable(String)
    /// Present but not needed by this preset.
    case notUsed
  }
  public struct Row: Sendable, Equatable, Identifiable {
    public var id: AIMaterialKind { kind }
    public let kind: AIMaterialKind
    public let state: State
    public let tokens: Int
    public let detail: String
  }
  public let rows: [Row]
  public let totalTokens: Int
  public let budget: AIRequestBudget
  /// True when the material exceeds the budget and will be summarized in segments first.
  public let needsSegmentation: Bool
  public let availability: AIPresetAvailability

  /// `history` is what the real assembly does with the thread (`AIPromptAssembler.historyUse`);
  /// history is not a layer of the pack, so without it the row only reflects the switch.
  public static func make(pack: AIContextPack, bundle: AIMaterialBundle, preset: AIPreset, settings: AIMaterialSettings,
    budget: AIRequestBudget, systemPrompt: String, availability: AIPresetAvailability, oneTime: Set<AIMaterialKind> = [],
    history: AIHistoryUse? = nil) -> AIContextPreview {
    var rows: [Row] = []
    let kinds: [AIMaterialKind] = bundle.source.kind == .article
      ? [.metadata, .articleBody, .comments, .history] : [.metadata, .subtitles, .officialSummary, .danmaku, .comments, .viewerPosition, .history]
    for kind in kinds {
      var tokens = pack.layers.filter { $0.material == kind }.reduce(0) { $0 + $1.tokens }
      if kind == .history, let history { tokens = history.turns > 0 ? max(1, history.tokens) : 0 }
      let state: State
      if tokens > 0 { state = .sent }
      else if kind.isSwitchable && !settings.allows(kind, oneTime: oneTime) { state = .switchedOff }
      else if let note = pack.notes[kind] { state = .unavailable(note) }
      else if kind == .history, let note = history?.note { state = .unavailable(note) }
      else { state = .notUsed }
      rows.append(Row(kind: kind, state: state, tokens: tokens, detail: detail(kind, bundle: bundle)))
    }
    let historyTokens = history.map { $0.turns > 0 ? $0.tokens : 0 } ?? 0
    let total = pack.tokens + AITokenEstimator.estimate(systemPrompt) + AITokenEstimator.estimate(preset.taskPrompt) + historyTokens
    return AIContextPreview(rows: rows, totalTokens: total, budget: budget, needsSegmentation: total > budget.inputLimit,
      availability: availability)
  }
  static func detail(_ kind: AIMaterialKind, bundle: AIMaterialBundle) -> String {
    switch kind {
    case .metadata: return "标题、简介、标签、分区、UP 主、统计、分 P 标题（必带）"
    case .articleBody:
      if case .article(let info) = bundle.source { return "正文 \(info.paragraphs.count) 段" }
      return "专栏正文"
    case .subtitles:
      guard let transcript = bundle.transcript else { return bundle.transcriptNote ?? "没有可用字幕" }
      return (transcript.isAI ? "AI 字幕" : "人工字幕") + " · \(transcript.language) · 去重合并后 \(transcript.cues.count) 句，保留时间戳"
    case .officialSummary:
      let chapters = bundle.viewPoints.count
      let summary = bundle.official?.isAvailable == true ? "官方总结" : nil
      return [chapters > 0 ? "章节 \(chapters) 段" : nil, summary].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "哔哩哔哩提供的章节分段与官方总结"
    case .danmaku:
      guard let digest = bundle.danmaku else { return bundle.danmakuNote ?? "弹幕太少" }
      return "密度峰值 \(digest.peaks.count) 段、高频短语、代表弹幕，不发原文（基于已加载的 \(digest.loadedCount) 条）"
    case .comments:
      guard let digest = bundle.comments else { return bundle.commentsNote ?? "没有评论" }
      let pinned = digest.items.filter(\.pinned).count, uploader = digest.items.filter(\.byUploader).count
      return "置顶 \(pinned) 条、精选 \(digest.items.count - pinned) 条（含 UP 主 \(uploader) 条），附点赞数"
    case .viewerPosition: return "问答时附带当前进度前后 90 秒的字幕"
    case .history: return "最近 3 轮原文，更早的轮次压缩后发送"
    }
  }
}

extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
