import Foundation

// MARK: Materials

/// Reads the materials of a source. Only the requested kinds are fetched, so a switched-off kind
/// is never even downloaded.
public protocol AIMaterialProvider: Sendable {
  func gather(source: AISource, kinds: Set<AIMaterialKind>, settings: AIMaterialSettings, identity: AuthSnapshot?,
    fallbackChapters: [AIViewPoint], loadedDanmaku: [DanmakuComment]?) async throws -> AIMaterialBundle
}

/// Live materials: one player-metadata request (subtitles + chapters), the subtitle body, the
/// official summary (videos), danmaku and two hot comment pages read in order. Identity changes
/// and cancellation propagate; any other failure becomes a note on that material.
public struct AIBiliMaterialProvider: AIMaterialProvider {
  let service: BiliService
  let rpc: (any BiliRPCService)?
  public init(service: BiliService, rpc: (any BiliRPCService)?) { self.service = service; self.rpc = rpc }

  public func gather(source: AISource, kinds: Set<AIMaterialKind>, settings: AIMaterialSettings, identity: AuthSnapshot?,
    fallbackChapters: [AIViewPoint], loadedDanmaku: [DanmakuComment]?) async throws -> AIMaterialBundle {
    guard let identity else { throw CancellationError() }
    try source.validate()
    var bundle = AIMaterialBundle(source: source)
    let service = self.service
    @Sendable func check() async throws { try Task.checkCancellation(); try await service.checkAIIdentity(identity) }
    if let (aid, cid) = source.media {
      var metadata: PlayerMetadata?
      if kinds.contains(.subtitles) || kinds.contains(.officialSummary) {
        do { metadata = try await service.playerMetadata(aid: aid, cid: cid, expectedIdentity: identity) }
        catch is CancellationError { throw CancellationError() }
        catch { try await check(); bundle.transcriptNote = "没能读取字幕信息"; bundle.transient = true }
      }
      if kinds.contains(.subtitles), let metadata {
        if let tracks = metadata.subtitles {
          if let track = AITranscriptSelector.choose(tracks, settings: settings) {
            do {
              let cues = try await service.downloadSubtitleCues(track: track, expectedIdentity: identity)
              try await check()
              let transcript = AITranscript.clean(cues, language: track.language, isAI: track.isAI)
              if transcript.cues.isEmpty { bundle.transcriptNote = "字幕内容为空" } else { bundle.transcript = transcript }
            } catch is CancellationError { throw CancellationError() }
            catch { try await check(); bundle.transcriptNote = "字幕下载失败"; bundle.transient = true }
          } else {
            bundle.transcriptNote = tracks.contains(where: \.isAI) && settings.excludeAISubtitles
              ? "只有 AI 字幕，已按「隐藏 AI 字幕」设置不使用" : "没有可用字幕"
          }
        } else { bundle.transcriptNote = "没能读取字幕信息" }
      }
      // Chapters come with the same metadata answer; they are sent only as the officialSummary
      // kind, but also serve as segment cut points so every preset segments the same way.
      if kinds.contains(.subtitles) || kinds.contains(.officialSummary) {
        let points = metadata?.viewPoints ?? []
        bundle.viewPoints = points.isEmpty ? fallbackChapters : points
        bundle.viewPointSource = points.isEmpty ? "player" : "official"
      }
      if kinds.contains(.officialSummary) {
        if case .video(let info) = source {
          bundle.official = try await service.officialSummary(aid: aid, cid: cid, bvid: info.bvid, uploaderMid: info.uploaderMid,
            expectedIdentity: identity)
          try await check()
          if case .retryableError = bundle.official { bundle.transient = true }
        }
      }
      if kinds.contains(.danmaku) {
        do {
          let comments: [DanmakuComment]
          if let loadedDanmaku { comments = loadedDanmaku } else { comments = try await service.comments(cid: cid, expectedIdentity: identity) }
          try await check()
          bundle.danmaku = AIDanmakuDigest.make(comments, duration: source.duration ?? 0)
          if bundle.danmaku == nil { bundle.danmakuNote = "弹幕太少（已加载 \(comments.count) 条）" }
        } catch is CancellationError { throw CancellationError() }
        catch { try await check(); bundle.danmakuNote = "没能读取弹幕"; bundle.transient = true }
      }
    }
    if kinds.contains(.comments) {
      if let rpc {
        let target = source.commentTarget
        do {
          let result = try await AICommentFetcher.fetch(rpc: rpc, oid: target.oid, targetType: target.type) { try await check() }
          bundle.comments = AICommentDigest.make(pages: result.pages, uploaderMid: source.uploaderMid, partial: result.partial)
          // Keep the first page; retry the bundle only when the second page may recover.
          if result.transient { bundle.transient = true }
          if bundle.comments == nil { bundle.commentsNote = "没有评论" }
        } catch is CancellationError { throw CancellationError() }
        catch { try await check(); bundle.commentsNote = "没能读取评论"; if AICommentFetcher.isTransient(error) { bundle.transient = true } }
      } else { bundle.commentsNote = "评论服务不可用" }
    }
    try await check()
    return bundle
  }
}

extension BiliService {
  /// Identity check for AI work that runs outside a single request.
  public func checkAIIdentity(_ snapshot: AuthSnapshot) throws { try checkRESTIdentity(snapshot) }
}

// MARK: Models

/// What determines a backend's answers, for cache keys and text-only output decisions.
public struct AIBackendDescriptor: Sendable, Equatable {
  public let provider: AIProvider
  public let model: AIModel
  public let endpoint: String
  public let apiVersion: String?
  /// Configuration revision the backend was created from; a change cancels running answers.
  public let revision: UInt64
  public init(provider: AIProvider, model: AIModel, endpoint: String, apiVersion: String?, revision: UInt64) {
    self.provider = provider; self.model = model; self.endpoint = endpoint; self.apiVersion = apiVersion
    self.revision = revision
  }
  /// Text-only answering: the on-device model gets Markdown prompts.
  public var textOnly: Bool { provider == .appleLocal }
}

public protocol AIModelBackend: Sendable {
  var descriptor: AIBackendDescriptor { get }
  func budget(desiredOutput: Int) -> AIRequestBudget
  func stream(_ request: AIConversationRequest, options: AIResponseOptions, streaming: Bool) -> AsyncThrowingStream<String, Error>
}

public protocol AIBackendFactory: Sendable {
  func backend(provider: AIProvider, modelID: String) async throws -> any AIModelBackend
  /// Current configuration revision; answers stop when it moves.
  func revision() async -> UInt64
}

/// Real services through `AIChatClient`; credentials stay in the configuration snapshot.
public struct AILiveBackendFactory: AIBackendFactory {
  let configuration: AIConfigurationStore
  let client: AIChatClient
  public init(configuration: AIConfigurationStore, client: AIChatClient = AIChatClient()) {
    self.configuration = configuration; self.client = client
  }
  public func revision() async -> UInt64 { await configuration.revision }
  public func backend(provider: AIProvider, modelID: String) async throws -> any AIModelBackend {
    let snapshot = try await configuration.snapshot(for: provider)
    guard let model = snapshot.configuration.availableModels(for: provider).first(where: { $0.id == modelID }) else {
      throw AIConfigurationError.invalidConfiguration
    }
    let endpoint = provider == .appleLocal ? "on-device" : (snapshot.configuration.endpoint ?? provider.defaultEndpoint ?? "")
    let descriptor = AIBackendDescriptor(provider: provider, model: model, endpoint: endpoint, apiVersion: snapshot.configuration.apiVersion,
      revision: snapshot.revision)
    let refresh: (@Sendable () async throws -> String)? = provider == .chatGPTPlan
      ? configuration.chatGPT.map { auth in { try await auth.refreshAfterRejection() } } : nil
    return AILiveBackend(descriptor: descriptor, snapshot: snapshot, client: client, refresh: refresh)
  }
}

struct AILiveBackend: AIModelBackend {
  let descriptor: AIBackendDescriptor
  let snapshot: AIConfigurationSnapshot
  let client: AIChatClient
  let refresh: (@Sendable () async throws -> String)?
  func budget(desiredOutput: Int) -> AIRequestBudget {
    if descriptor.provider == .appleLocal { return AppleLocalModel.requestBudget() }
    // Current Claude models and other reasoning models spend thinking out of the output cap;
    // keep a 16K floor (still capped by the model's own limit).
    let reasoning = (descriptor.provider == .anthropic && AIChatRequestPlanner.isCurrentClaude(descriptor.model.id))
      || AIModelCapacity.isReasoning(descriptor.model.id)
    let desired = reasoning ? max(desiredOutput, 16_000) : desiredOutput
    return descriptor.model.requestBudget(desiredOutput: desired)
  }
  func stream(_ request: AIConversationRequest, options: AIResponseOptions, streaming: Bool) -> AsyncThrowingStream<String, Error> {
    client.response(provider: descriptor.provider, configuration: snapshot.configuration, secrets: snapshot.secrets,
      model: descriptor.model.id, conversation: request, streaming: streaming, options: options, refreshBearer: refresh)
  }
}

// MARK: Fixtures

/// Offline materials for UI screenshots and tests: no network, no account.
public struct AIFixtureMaterialProvider: AIMaterialProvider {
  public init() {}
  public static let cues: [DownloadSubtitleCue] = [
    .init(start: 12, end: 18, text: "这次我们从成都出发，沿 318 国道往西走。"),
    .init(start: 19.5, end: 24, text: "第一天的目标是翻过折多山，到新都桥看日出。"),
    .init(start: 232, end: 240, text: "折多山垭口海拔四千二百九十八米，风非常大。"),
    .init(start: 241.5, end: 250, text: "经幡被吹得横飞，大家都在喊前方高能。"),
    .init(start: 482, end: 490, text: "路边的牦牛完全不怕人，就站在路中间。"),
    .init(start: 610, end: 618, text: "凌晨五点我们到了观景台，开始等日出。"),
    .init(start: 619.5, end: 630, text: "等了三个小时，就为这一下，光打在山尖上。"),
    .init(start: 640, end: 652, text: "观景台现在收费，每人二十元，记得提前准备。"),
  ]
  /// The official summary the fixture video shows when no AI service is configured.
  public static let officialSummary = AIOfficialSummary.available(
    summary: "UP 主从成都出发，沿 318 国道记录前往新都桥的第一天，包括翻越折多山与等待日出。",
    outline: [AIOfficialOutlineSection(id: "o1", title: "出发与准备", start: 0, points: []),
      AIOfficialOutlineSection(id: "o2", title: "翻越折多山", start: 232, points: []),
      AIOfficialOutlineSection(id: "o3", title: "新都桥日出", start: 618, points: [])])
  public static func danmaku() -> [DanmakuComment] {
    var result: [DanmakuComment] = []
    for second in stride(from: 0.0, to: 1104, by: 9) { result.append(DanmakuComment(time: second, text: "打卡", userHash: "u\(Int(second))")) }
    for index in 0..<40 { result.append(DanmakuComment(time: 615 + Double(index % 25), text: index % 2 == 0 ? "这光绝了" : "值了", weight: 8, userHash: "p\(index)")) }
    for index in 0..<24 { result.append(DanmakuComment(time: 240 + Double(index % 20), text: "前方高能", weight: 7, userHash: "w\(index)")) }
    return result
  }
  public func gather(source: AISource, kinds: Set<AIMaterialKind>, settings: AIMaterialSettings, identity: AuthSnapshot?,
    fallbackChapters: [AIViewPoint], loadedDanmaku: [DanmakuComment]?) async throws -> AIMaterialBundle {
    try source.validate()
    var bundle = AIMaterialBundle(source: source)
    if source.kind.isTimeline {
      if kinds.contains(.subtitles) { bundle.transcript = AITranscript.clean(Self.cues, language: "zh-CN", isAI: false) }
      if kinds.contains(.subtitles) || kinds.contains(.officialSummary) {
        bundle.viewPoints = [AIViewPoint(id: "ch1", start: 0, end: 232, title: "出发"), AIViewPoint(id: "ch2", start: 232, end: 618, title: "翻越折多山"),
          AIViewPoint(id: "ch3", start: 618, end: source.duration ?? 1104, title: "新都桥的日出")]
      }
      if kinds.contains(.officialSummary) {
        bundle.official = .available(summary: "UP 主从成都出发，沿 318 国道记录前往新都桥的第一天，包括翻越折多山与等待日出。", outline: nil)
      }
      if kinds.contains(.danmaku) { bundle.danmaku = AIDanmakuDigest.make(loadedDanmaku ?? Self.danmaku(), duration: source.duration ?? 1104) }
    }
    if kinds.contains(.comments) {
      let user = RPCUser(mid: 1, name: "fixture", avatar: nil), up = RPCUser(mid: source.uploaderMid ?? 2, name: "UP", avatar: nil)
      let pinned = RPCComment(id: 10, root: 10, author: up, text: "观景台已改为收费，2026 年起每人 20 元。", emotes: [], createdAt: 0,
        likes: 860, replyCount: 0, liked: false, pinned: true, replies: [])
      let hot = RPCComment(id: 11, root: 11, author: user, text: "看完决定明年也去一趟", emotes: [], createdAt: 0, likes: 3_200,
        replyCount: 1, liked: false, pinned: false, replies: [])
      let page = RPCCommentPage(oid: source.commentTarget.oid, targetType: source.commentTarget.type, comments: [hot], pinned: pinned, next: 0, isEnd: true)
      bundle.comments = AICommentDigest.make(pages: [page], uploaderMid: source.uploaderMid ?? 2)
    }
    return bundle
  }
}

/// Answers with fixed Markdown or JSON (matching the fixture materials) without any network.
public struct AIFixtureBackendFactory: AIBackendFactory {
  public init() {}
  public func revision() async -> UInt64 { 0 }
  public func backend(provider: AIProvider, modelID: String) async throws -> any AIModelBackend {
    AIFixtureBackend(descriptor: AIBackendDescriptor(provider: provider, model: AIModel(id: modelID, name: "本地样本模型", contextTokens: 128_000,
      maxOutputTokens: 8_192), endpoint: "fixture", apiVersion: nil, revision: 0))
  }
}

public struct AIFixtureBackend: AIModelBackend {
  public let descriptor: AIBackendDescriptor
  /// Optional override used by tests; receives each request and returns the full answer.
  let answer: (@Sendable (AIConversationRequest) async throws -> String)?
  public init(descriptor: AIBackendDescriptor, answer: (@Sendable (AIConversationRequest) async throws -> String)? = nil) {
    self.descriptor = descriptor; self.answer = answer
  }
  public func budget(desiredOutput: Int) -> AIRequestBudget { descriptor.model.requestBudget(desiredOutput: desiredOutput) }
  public func stream(_ request: AIConversationRequest, options: AIResponseOptions, streaming: Bool) -> AsyncThrowingStream<String, Error> {
    let answer = self.answer
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let text = try await answer?(request) ?? Self.cannedAnswer(request)
          for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            continuation.yield(String(piece) + "\n")
            try await Task.sleep(for: .milliseconds(20))
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error is CancellationError ? CancellationError() : error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
  /// Picks the canned answer from the task prompt in the last user message.
  public static func cannedAnswer(_ request: AIConversationRequest) -> String {
    let text = request.messages.last?.text ?? ""
    if text.contains("\"chapters\"") {
      return #"{"overview":"UP 主从成都出发翻越折多山，在新都桥等到日出。","chapters":[{"start":"00:12","end":"00:24","title":"出发","points":["沿 318 国道往西"],"highlight":false,"evidence":["c1","ch1"]},{"start":"03:52","end":"04:10","title":"翻越折多山","points":["垭口海拔 4298 米"],"highlight":true,"evidence":["c3","ch2"]},{"start":"10:18","end":"10:52","title":"新都桥的日出","points":["等了三个小时","观景台收费 20 元"],"highlight":true,"evidence":["c6","ch3"]}],"sources":["cc","chapters","danmaku"],"insufficient":false}"#
    }
    if text.contains("\"clips\"") {
      return #"{"clips":[{"start":"03:52","end":"04:10","reason":"翻越垭口，风最大的时候","evidence":["c3","c4"]},{"start":"10:18","end":"10:52","reason":"等到日出的那一刻","evidence":["c6","c7","c8"]}],"summary":"两段看完翻山与日出。"}"#
    }
    if text.contains("\"moments\"") {
      return #"{"moments":[{"peak":"d1","start":"04:00","end":"04:20","title":"垭口的风","why":"「前方高能」刷屏，经幡被吹得横飞。","quotes":["q1"],"evidence":["c4"]},{"peak":"d2","start":"10:15","end":"10:40","title":"日出那一刻","why":"全片弹幕最密的一段。","quotes":["q3","q4"],"evidence":["c6"]}]}"#
    }
    if text.contains("分段") || text.contains("部分") && text.contains("要点") {
      return "- [00:12] 从成都出发\n- [03:52] 翻越折多山"
    }
    if request.messages.contains(where: { $0.text.contains("回答用户关于这个视频的问题") }) {
      return "在新都桥镇外的观景台（10:10 UP 主说「凌晨五点我们到了观景台」），评论区置顶也补充了：观景台现在收费，每人 20 元。"
    }
    if text.contains("弹幕都在聊什么") {
      return "## 话题\n- **日出**（10:15–10:40）：「这光绝了」「值了」\n- **垭口**（04:00–04:20）：「前方高能」\n\n这些来自已加载弹幕的统计，代表观众反应。"
    }
    if text.contains("评论区的观点") {
      return "## 多数人认同\n节奏慢但不拖沓。\n## 有分歧\n高反提示偏轻。\n## 补充与勘误\n置顶评论（UP 主）：观景台已改为收费，每人 20 元。\n## 代表评论\n- 「看完决定明年也去一趟」· 赞 3200"
    }
    return "根据材料，这是本地样本回答，未连接任何 AI 服务。"
  }
}
