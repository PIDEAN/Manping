import AppKit
import ManpingCore
import SwiftUI

@MainActor private final class ArticleReaderModel: ObservableObject {
  @Published private(set) var detail: ArticleDetail?
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  @Published private(set) var busy = false
  @Published private(set) var mutationError: String?
  @Published private(set) var liked = false
  @Published private(set) var favorited = false
  @Published private(set) var following = false
  @Published private(set) var likes = 0
  @Published private(set) var favorites = 0
  @Published private(set) var comments: [RPCComment] = []
  @Published private(set) var pinned: RPCComment?
  @Published private(set) var commentSort: RPCCommentSort = .hot
  @Published private(set) var commentsLoading = false
  @Published private(set) var commentsEnd = false
  @Published private(set) var commentsError: String?
  @Published private(set) var thread: RPCComment?
  @Published private(set) var replies: [RPCComment] = []
  @Published private(set) var replyingTo: RPCComment?
  @Published private(set) var commentLikes: [Int64: Bool] = [:]
  @Published private(set) var commentCounts: [Int64: Int64] = [:]
  @Published var commentsOpened = false
  @Published var draft = ""
  private let service: BiliService
  private let rpc: (any BiliRPCService)?
  private var id: Int64 = 0
  private var expected: AuthSnapshot?
  private var generation = UUID()
  private var commentRevision = UUID()
  private var next: Int64 = 0
  private var flight: Task<Void, Never>?
  private var commentFlight: Task<Void, Never>?
  private var mutation: Task<Void, Never>?
  private var observer: Task<Void, Never>?
  var canInteract: Bool { expected?.token != nil && detail?.interactionStateAvailable == true && !busy && !loading }
  var canComment: Bool { expected?.token != nil && detail != nil && !busy && !loading }
  init(service: BiliService, rpc: (any BiliRPCService)?) {
    self.service = service; self.rpc = rpc
    observer = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled, let expected = self.expected else { continue }
        if event.epoch != expected.epoch || event.identityRevision != expected.identityRevision {
          self.cancel(); self.expected = nil; self.detail = nil
          self.error = "登录状态已改变，请重新加载文章。"
        }
      }
    }
  }
  deinit { observer?.cancel(); flight?.cancel(); commentFlight?.cancel(); mutation?.cancel() }
  func cancel() {
    generation = UUID(); commentRevision = UUID()
    flight?.cancel(); commentFlight?.cancel(); mutation?.cancel()
    flight = nil; commentFlight = nil; mutation = nil
    loading = false; busy = false; commentsLoading = false
    comments = []; replies = []; pinned = nil; thread = nil; replyingTo = nil
    commentLikes = [:]; commentCounts = [:]; draft = ""; commentsOpened = false
  }
  func load(id: Int64) async {
    cancel(); self.id = id; detail = nil; error = nil; mutationError = nil
    loading = true; let revision = generation
    let snapshot = await service.authSnapshot()
    guard revision == generation, !Task.isCancelled else {
      if revision == generation { loading = false }
      return
    }
    expected = snapshot
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let value = try await service.articleDetail(id: id, expectedIdentity: snapshot)
        try await check(revision, snapshot)
        detail = value; liked = value.isLiked; favorited = value.isFavorited; following = value.isFollowing
        likes = value.article.stats.likes; favorites = value.article.stats.favorites
      } catch is CancellationError {} catch { if revision == generation { self.error = error.localizedDescription } }
      if revision == generation { loading = false; flight = nil }
    }
    flight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  func toggleComments() async {
    commentsOpened.toggle()
    if commentsOpened && comments.isEmpty { await refreshComments() }
  }
  func changeSort(_ sort: RPCCommentSort) async {
    guard !busy, commentSort != sort else { return }
    commentSort = sort; thread = nil; await refreshComments()
  }
  func refreshComments() async {
    guard !busy else { return }
    commentRevision = UUID(); commentFlight?.cancel(); commentFlight = nil
    commentsLoading = false; commentsEnd = false; commentsError = nil; next = 0
    if thread == nil { comments = []; pinned = nil } else { replies = [] }
    await loadComments()
  }
  func openThread(_ comment: RPCComment) async {
    guard !busy else { return }
    thread = comment; replyingTo = comment; await refreshComments()
  }
  func closeThread() async {
    guard !busy else { return }
    thread = nil; replyingTo = nil; replies = []; await refreshComments()
  }
  func reply(to comment: RPCComment?) { guard !busy else { return }; replyingTo = comment }
  func loadComments() async {
    guard !commentsLoading, !commentsEnd, let expected, detail != nil else { return }
    let revision = generation; let request = commentRevision; let cursor = next
    let root = thread.map { $0.root > 0 ? $0.root : $0.id }; let sort = commentSort; let id = id
    commentsLoading = true; commentsError = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let rpc else { throw BiliError.dependency("评论服务暂不可用") }
        try await check(revision, expected)
        let page: RPCCommentPage
        if let root { page = try await rpc.commentDetails(oid: id, targetType: 12, root: root, sort: .time, next: cursor) }
        else { page = try await rpc.comments(oid: id, targetType: 12, sort: sort, next: cursor) }
        try await check(revision, expected)
        guard request == commentRevision else { throw CancellationError() }
        guard page.oid == id, page.targetType == 12 else { throw BiliError.invalidResponse("Article comment target mismatch") }
        var known = Set((root == nil ? comments : replies).map(\.id))
        let fresh = page.comments.filter { $0.id != root && known.insert($0.id).inserted }
        if root == nil { comments += fresh; if let value = page.pinned { pinned = value } }
        else { replies += fresh }
        next = page.next; commentsEnd = page.isEnd || page.next <= cursor
      } catch is CancellationError {} catch { if revision == generation && request == commentRevision { commentsError = error.localizedDescription } }
      if revision == generation && request == commentRevision { commentsLoading = false; commentFlight = nil }
    }
    commentFlight = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private enum Write: Sendable { case like(Bool), favorite(Bool), follow(Bool), comment(String, Int64, Int64), commentLike(RPCComment) }
  func toggleLike(onLogin: @escaping () -> Void) async {
    guard detail?.interactionStateAvailable == true else { return }
    await write(.like(!liked), onLogin: onLogin)
  }
  func toggleFavorite(onLogin: @escaping () -> Void) async {
    guard detail?.interactionStateAvailable == true else { return }
    await write(.favorite(!favorited), onLogin: onLogin)
  }
  func toggleFollow(onLogin: @escaping () -> Void) async {
    guard detail?.interactionStateAvailable == true, (detail?.article.author.id ?? 0) > 0 else { return }
    await write(.follow(!following), onLogin: onLogin)
  }
  func send(onLogin: @escaping () -> Void) async {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 1000 else { return }
    let parent = replyingTo?.id ?? 0
    let root = replyingTo.map { $0.root > 0 ? $0.root : $0.id } ?? 0
    await write(.comment(text, root, parent), onLogin: onLogin)
  }
  func toggleCommentLike(_ comment: RPCComment, onLogin: @escaping () -> Void) async {
    await write(.commentLike(comment), onLogin: onLogin)
  }
  private func write(_ operation: Write, onLogin: @escaping () -> Void) async {
    guard !busy, !loading, detail != nil, let expected else { return }
    guard expected.token != nil else { onLogin(); return }
    let revision = generation; let id = id; let authorID = detail?.article.author.id ?? 0
    busy = true; mutationError = nil
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let authorized = try await service.authorizeAppInteraction(expectedIdentity: expected)
        try await check(revision, authorized)
        switch operation {
        case .like(let state):
          try await service.setArticleLiked(id: id, liked: state, expectedIdentity: authorized)
          try await check(revision, authorized)
          likes = max(0, likes + (state ? 1 : -1)); liked = state
        case .favorite(let state):
          try await service.setArticleFavorited(id: id, favorited: state, expectedIdentity: authorized)
          try await check(revision, authorized)
          favorites = max(0, favorites + (state ? 1 : -1)); favorited = state
        case .follow(let state):
          try await service.setFollowing(mid: authorID, following: state, expectedIdentity: authorized)
          try await check(revision, authorized)
          following = state
        case .comment(let text, let root, let parent):
          try await service.sendArticleComment(id: id, message: text, root: root, parent: parent, expectedIdentity: authorized)
          try await check(revision, authorized)
          draft = ""; replyingTo = nil
        case .commentLike(let comment):
          let state = !(commentLikes[comment.id] ?? comment.liked)
          try await service.setArticleCommentLiked(id: id, replyID: comment.id, liked: state, expectedIdentity: authorized)
          try await check(revision, authorized)
          commentCounts[comment.id] = max(0, (commentCounts[comment.id] ?? comment.likes) + (state ? 1 : -1))
          commentLikes[comment.id] = state
        }
      } catch is CancellationError {} catch AuthFailure.needsLogin {
        if revision == generation { mutationError = "请先登录。"; onLogin() }
      } catch { if revision == generation { mutationError = error.localizedDescription } }
      if revision == generation { busy = false; mutation = nil }
    }
    mutation = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    if case .comment = operation, revision == generation, mutationError == nil { await refreshComments() }
  }
  private func check(_ revision: UUID, _ expected: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    guard revision == generation, current.epoch == expected.epoch,
      current.identityRevision == expected.identityRevision else { throw CancellationError() }
  }
}

struct ArticleReaderPage: View {
  let id: Int64
  let onUser: (Int64) -> Void
  let onVideo: (Video) -> Void
  let onArticle: (Int64) -> Void
  let onLogin: () -> Void
  var aiContent: ((ArticleDetail) -> AnyView)?
  @State private var showingAI = false
  @State private var showingTranslation = false
  @AppStorage(ArticleFormat.fontSizeKey) private var fontSize = ArticleFormat.defaultFontSize
  // Held, never read, here: only ArticleProgressBar observes it, so scrolling does not redraw the page.
  @State private var progress = ArticleReadingProgress()
  @StateObject private var reader: ArticleReaderModel
  @Environment(\.colorScheme) private var scheme
  init(service: BiliService, id: Int64, rpc: (any BiliRPCService)? = nil,
    onUser: @escaping (Int64) -> Void, onVideo: @escaping (Video) -> Void,
    onArticle: @escaping (Int64) -> Void = { _ in }, onLogin: @escaping () -> Void = {},
    aiContent: ((ArticleDetail) -> AnyView)? = nil) {
    self.id = id; self.onUser = onUser; self.onVideo = onVideo; self.onArticle = onArticle; self.onLogin = onLogin
    self.aiContent = aiContent
    _reader = StateObject(wrappedValue: ArticleReaderModel(service: service, rpc: rpc))
  }
  var body: some View {
    HStack(spacing: 0) {
      reading
      if reader.detail != nil {
        if showingAI, let detail = reader.detail, let aiContent {
          VStack(spacing: 0) {
            HStack {
              Label("AI 助手", systemImage: "sparkles").font(Theme.Font.section)
              Spacer()
              Button { showingAI = false } label: { Image(systemName: "xmark") }
                .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("关闭")
            }.padding(.leading, 16).padding(.trailing, 10).frame(height: Theme.pageHeaderHeight)
            Hairline()
            ScrollView { aiContent(detail).padding(16) }
          }.frame(width: 340).overlay(alignment: .leading) { Hairline(axis: .vertical) }
        } else if reader.commentsOpened { commentPanel.frame(width: 380) }
      }
    }.foregroundStyle(Theme.text(scheme))
      .animation(.snappy(duration: 0.25), value: showingAI)
      .animation(.snappy(duration: 0.25), value: reader.commentsOpened)
      .task(id: id) { await reader.load(id: id) }.onDisappear { reader.cancel() }
      .onChange(of: reader.detail?.article.id) { _, value in
        #if DEBUG
        if value != nil, DebugUIFixtures.enabled, ProcessInfo.processInfo.arguments.contains("--ui-ai-preview") { showingAI = true }
        #if DEBUG
        if value != nil, ProcessInfo.processInfo.arguments.contains("--ui-translate") {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showingTranslation = true }
        }
        #endif
        #endif
      }
      .environment(\.openURL, OpenURLAction { routeLink($0) })
  }
  /// Header, text and the action rail floating over the text.
  private var reading: some View {
    VStack(spacing: 0) {
      readerHeader
      content
    }.overlay(alignment: .topTrailing) {
      if reader.detail != nil { actionRail.padding(.trailing, 20).padding(.top, Theme.pageHeaderHeight + 128) }
    }
  }
  private var readerHeader: some View {
    HStack(spacing: 8) {
      Text(reader.detail?.article.partition.map { "专栏 · \($0.title)" } ?? "专栏").font(Theme.Font.body)
        .foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
      Spacer(minLength: 8)
      if reader.detail != nil { ArticleFontSizeControl(size: $fontSize) }
    }.padding(.leading, 24).padding(.trailing, 16).frame(height: Theme.pageHeaderHeight)
      .overlay(alignment: .bottom) { Hairline() }
      .overlay(alignment: .bottom) { if reader.detail != nil { ArticleProgressBar(progress: progress) } }
  }
  private var content: some View {
    Group {
      if reader.loading { ProgressView("正在加载文章…").frame(maxWidth: .infinity, maxHeight: .infinity) }
      else if let detail = reader.detail { articleBody(detail) }
      else {
        PageStateView(.error, title: "没能加载文章", message: reader.error ?? "文章内容暂不可用。", icon: "doc.text", actionTitle: "重试") {
          Task { await reader.load(id: id) }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func articleBody(_ detail: ArticleDetail) -> some View {
    let size = min(ArticleFormat.fontSizeRange.upperBound, max(ArticleFormat.fontSizeRange.lowerBound, fontSize))
    return ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text(detail.article.title).font(.system(size: 28, weight: .bold)).lineSpacing(3).textSelection(.enabled)
        authorRow(detail)
        if let warning = detail.metadataWarning {
          Text(warning).font(Theme.Font.caption).foregroundStyle(Theme.warning(scheme)).textSelection(.enabled)
        }
        if let error = reader.mutationError {
          InlineErrorText(message: error)
        }
        Hairline()
        ForEach(Array(detail.blocks.enumerated()), id: \.offset) { _, block in bodyBlock(block, size: size) }
        if !detail.tags.isEmpty {
          Text(detail.tags.map { "#" + $0 }.joined(separator: "   ")).font(Theme.Font.caption).foregroundStyle(Theme.accentText(scheme))
        }
        Text("\(detail.article.wordCount) 字 · \(detail.article.stats.coins) 硬币")
          .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      }.frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 48)
    }.onScrollGeometryChange(for: Double.self) { geometry in
      let range = Double(geometry.contentSize.height - geometry.containerSize.height)
      guard range > 1 else { return 0 }
      let offset = Double(geometry.contentOffset.y + geometry.contentInsets.top)
      // Quantised so a long article does not publish a new value for every pixel.
      let fraction: Double = min(max(offset / range, 0), 1)
      return (fraction * 500).rounded() / 500
    } action: { _, value in progress.value = value }
  }
  private func authorRow(_ detail: ArticleDetail) -> some View {
    let characters = detail.article.wordCount > 0 ? detail.article.wordCount : Self.characterCount(detail.blocks)
    var meta: [String] = []
    if let stamp = detail.article.publishedAt { meta.append(ArticleFormat.date(stamp)) }
    meta.append("约 \(ArticleFormat.readMinutes(characters: characters)) 分钟读完")
    meta.append("\(ArticleFormat.count(detail.article.stats.reads)) 阅读")
    return HStack(spacing: 10) {
      Button { onUser(detail.article.author.id) } label: {
        HStack(spacing: 10) {
          CachedImage(url: detail.article.author.avatar).frame(width: 28, height: 28).clipShape(Circle())
          Text(detail.article.author.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text(scheme))
        }
      }.buttonStyle(.plain).disabled(detail.article.author.id <= 0)
      Text(meta.joined(separator: "  ·  ")).lineLimit(1)
      Spacer(minLength: 0)
      if detail.article.author.id > 0 {
        Button { Task { await reader.toggleFollow(onLogin: onLogin) } } label: { Text(reader.following ? "已关注" : "关注") }
          .buttonStyle(AppButtonStyle(role: reader.following ? .secondary : .primary, size: .small))
          .disabled(!reader.canInteract)
      }
    }.font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
  }
  /// Title and paragraphs as plain text, for the system translation popover.
  private var articlePlainText: String {
    guard let detail = reader.detail else { return "" }
    let paragraphs = detail.blocks.compactMap { block -> String? in
      if case .text(let runs, _) = block { return runs.map(\.text).joined() }
      return nil
    }
    return ([detail.article.title] + paragraphs).joined(separator: "\n\n")
  }
  private static func characterCount(_ blocks: [ArticleBodyBlock]) -> Int {
    blocks.reduce(0) { total, block in
      if case .text(let runs, _) = block { return total + runs.reduce(0) { $0 + $1.text.count } }
      return total
    }
  }
  @ViewBuilder private func bodyBlock(_ block: ArticleBodyBlock, size: Double) -> some View {
    switch block {
    case .text(let runs, let heading):
      // 1.75 line height at the body size; headings keep a tighter fixed leading.
      Text(attributed(runs)).font(.system(size: heading.map { $0 <= 2 ? size + 4 : size + 2 } ?? size,
        weight: heading == nil ? .regular : .semibold)).lineSpacing(heading == nil ? size * 0.75 : 6)
        .foregroundStyle(Theme.text(scheme)).tint(Theme.accentText(scheme)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, heading == nil ? 0 : 6)
    case .image(let url, let caption):
      VStack(spacing: 8) {
        ArticleReaderImage(url: url)
        if let caption {
          Text(caption).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).multilineTextAlignment(.center)
        }
      }.frame(maxWidth: .infinity).padding(.vertical, 4)
    case .divider: Hairline().padding(.vertical, 6)
    }
  }
  private func attributed(_ runs: [ArticleInlineText]) -> AttributedString {
    var result = AttributedString()
    for run in runs {
      var text = AttributedString(run.text)
      var intent: InlinePresentationIntent = []
      if run.bold { intent.insert(.stronglyEmphasized) }
      if run.italic { intent.insert(.emphasized) }
      text.inlinePresentationIntent = intent
      text.link = run.link
      result += text
    }
    return result
  }
  private var actionRail: some View {
    var items: [ArticleActionRail.Item] = [
      .init(id: "like", label: "点赞", icon: reader.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
        detail: ArticleFormat.count(reader.likes), selected: reader.liked, disabled: !reader.canInteract) {
          Task { await reader.toggleLike(onLogin: onLogin) }
        },
      .init(id: "favorite", label: "收藏", icon: reader.favorited ? "bookmark.fill" : "bookmark",
        detail: ArticleFormat.count(reader.favorites), selected: reader.favorited, disabled: !reader.canInteract) {
          Task { await reader.toggleFavorite(onLogin: onLogin) }
        },
      .init(id: "comments", label: "评论", icon: "text.bubble",
        detail: reader.detail.map { ArticleFormat.count($0.article.stats.replies) }, selected: reader.commentsOpened) {
          showingAI = false; Task { await reader.toggleComments() }
        },
    ]
    if aiContent != nil {
      items.append(.init(id: "ai", label: "AI 总结", icon: "sparkles", detail: "AI", selected: showingAI) {
        showingAI.toggle(); reader.commentsOpened = false
      })
    }
    if reader.detail != nil {
      items.append(.init(id: "translate", label: "翻译", icon: "translate", detail: "翻译", selected: showingTranslation) {
        showingTranslation = true
      })
    }
    items.append(.init(id: "refresh", label: "刷新", icon: "arrow.clockwise", disabled: reader.busy) {
      Task { await reader.load(id: id) }
    })
    return ArticleActionRail(items: items, busy: reader.busy)
      .translationSheet(isPresented: $showingTranslation, text: articlePlainText)
  }
  private var commentPanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        if reader.thread != nil {
          Button { Task { await reader.closeThread() } } label: { Image(systemName: "chevron.left") }
            .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true))
          Text("楼中楼").font(Theme.Font.section)
          Spacer(minLength: 0)
          closeCommentsButton
        } else {
          CommentSectionHeader(total: reader.detail.map { Int64($0.article.stats.replies) }, sort: Binding(
            get: { reader.commentSort }, set: { sort in Task { await reader.changeSort(sort) } }),
            sortDisabled: reader.busy) { closeCommentsButton }
        }
      }.padding(.leading, 16).padding(.trailing, 10).frame(height: Theme.pageHeaderHeight)
      Hairline()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if let thread = reader.thread { commentRow(thread); ForEach(reader.replies, id: \.id) { commentRow($0) } }
          else {
            if let pinned = reader.pinned { commentRow(pinned) }
            ForEach(reader.comments.filter { $0.id != reader.pinned?.id }, id: \.id) { commentRow($0) }
          }
          if reader.commentsLoading { ProgressView("正在加载评论…").frame(maxWidth: .infinity).padding(.vertical, 12) }
          else if let error = reader.commentsError {
            VStack(alignment: .leading, spacing: 8) {
              InlineErrorText(message: error)
              Button("重试") { Task { await reader.loadComments() } }.buttonStyle(AppButtonStyle(size: .small))
            }.padding(.vertical, 12)
          } else if !reader.commentsEnd {
            LoadMoreFooter(isLoading: false) { Task { await reader.loadComments() } }
          } else if reader.comments.isEmpty && reader.thread == nil {
            Text("还没有评论").font(Theme.Font.body).foregroundStyle(Theme.tertiaryText(scheme)).frame(maxWidth: .infinity).padding(.top, 40)
          }
        }.padding(.horizontal, 16)
      }
      composer
    }.overlay(alignment: .leading) { Hairline(axis: .vertical) }
  }
  private var closeCommentsButton: some View {
    Button { reader.commentsOpened = false } label: { Image(systemName: "xmark") }
      .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("关闭评论")
  }
  private func commentRow(_ comment: RPCComment) -> some View {
    CommentCell(comment: comment, pinned: reader.pinned?.id == comment.id, ownerMid: reader.detail?.article.author.id,
      likes: reader.commentCounts[comment.id] ?? comment.likes, liked: reader.commentLikes[comment.id] ?? comment.liked,
      showsReplies: reader.thread == nil, canReply: reader.canComment,
      onAuthor: { onUser(comment.author.mid) },
      onLike: { Task { await reader.toggleCommentLike(comment, onLogin: onLogin) } }, canLike: reader.canComment,
      onReply: { reader.reply(to: comment) },
      onOpenReplies: { Task { await reader.openThread(comment) } })
  }
  private var composer: some View {
    CommentComposerBar(draft: $reader.draft, replyingTo: reader.replyingTo?.author.name,
      signedIn: reader.canComment || reader.busy, busy: reader.busy,
      canSend: reader.canComment && !reader.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reader.draft.count <= 1000,
      error: reader.mutationError, notice: nil,
      cancelReply: { reader.reply(to: nil) }, send: { Task { await reader.send(onLogin: onLogin) } }, login: onLogin)
  }
  private func routeLink(_ url: URL) -> OpenURLAction.Result {
    let host = url.host?.lowercased() ?? ""
    let parts = url.pathComponents.filter { $0 != "/" }
    if url.scheme?.lowercased() == "bilibili" {
      if host == "space", let mid = parts.first.flatMap(Int64.init), mid > 0 { onUser(mid); return .handled }
      if host == "video", let value = parts.first, let video = linkedVideo(value) { onVideo(video); return .handled }
      if host == "article", let article = parts.first.flatMap(Int64.init), article > 0 { onArticle(article); return .handled }
      return .discarded
    }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
    if host == "space.bilibili.com", let mid = parts.first.flatMap(Int64.init), mid > 0 { onUser(mid); return .handled }
    if host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
      if parts.first == "video", parts.count > 1, let video = linkedVideo(parts[1]) { onVideo(video); return .handled }
      if parts.first == "read", parts.count > 1 {
        if parts[1].hasPrefix("cv"), let value = Int64(parts[1].dropFirst(2)), value > 0 { onArticle(value); return .handled }
        if parts[1] == "native", let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int64.init), value > 0 {
          onArticle(value); return .handled
        }
      }
    }
    return .systemAction
  }
  private func linkedVideo(_ value: String) -> Video? {
    if value.hasPrefix("BV"), value.count == 12 { return Video(bvid: value, title: "专栏关联视频") }
    let raw = value.hasPrefix("av") ? String(value.dropFirst(2)) : value
    guard let aid = Int64(raw), aid > 0 else { return nil }
    return Video(bvid: "", title: "专栏关联视频", aid: aid)
  }
}

private struct ArticleReaderImage: View {
  let url: URL
  @State private var image: NSImage?
  @State private var failed = false
  var body: some View {
    Group {
      #if DEBUG
      if DebugUIFixtures.enabled && url.host == "fixture.invalid" {
        DebugFixtureImage(index: Int(url.lastPathComponent) ?? 0, avatar: false).aspectRatio(16 / 9, contentMode: .fit)
      } else { loadedImage }
      #else
      loadedImage
      #endif
    }.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)).task(id: url) {
      image = nil; failed = false
      #if DEBUG
      if DebugUIFixtures.enabled && url.host == "fixture.invalid" { return }
      #endif
      do {
        let result = try await ImageCache.shared.imageForReader(for: url)
        try Task.checkCancellation()
        image = NSImage(cgImage: result, size: .zero)
      } catch is CancellationError {} catch { failed = true }
    }
  }
  @ViewBuilder private var loadedImage: some View {
    if let image { Image(nsImage: image).resizable().scaledToFit() }
    else {
      VStack(spacing: 8) {
        if failed { Image(systemName: "photo.badge.exclamationmark"); Text("图片暂不可用").font(Theme.Font.caption) }
        else { ProgressView() }
      }.frame(maxWidth: .infinity).frame(height: 180).background(.gray.opacity(0.08))
    }
  }
}
