import ManpingCore
import SwiftUI

struct M4CommentPanel: View {
  @ObservedObject var comments: M4CommentModel
  @ObservedObject var model: AppModel
  let close: () -> Void
  /// Total comment count for the header, when the caller knows it.
  var total: Int64?
  /// Author of the post, used to mark their own comments with a "UP 主" pill.
  var ownerMid: Int64?
  @Environment(\.colorScheme) private var scheme

  init(comments: M4CommentModel, model: AppModel, close: @escaping () -> Void, total: Int64? = nil, ownerMid: Int64? = nil) {
    self.comments = comments; self.model = model; self.close = close; self.total = total; self.ownerMid = ownerMid
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Hairline()
      ScrollView {
        M4CommentList(comments: comments, model: model, ownerMid: ownerMid).padding(.horizontal, 16)
      }
      composer
    }.frame(width: 380).frame(maxHeight: .infinity).foregroundStyle(Theme.text(scheme))
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
      .floatingGlassPanel(readingTint: Theme.panel(scheme).opacity(0.82))
  }
  private var header: some View {
    HStack(spacing: 8) {
      if comments.thread != nil {
        Button { comments.closeThread() } label: { Image(systemName: "chevron.left") }
          .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("返回评论")
        Text("楼中楼").font(Theme.Font.section)
        Spacer(minLength: 0)
        closeButton
      } else {
        CommentSectionHeader(total: total, sort: Binding(
          get: { comments.sort }, set: { value in Task { await comments.setSort(value) } }),
          sortDisabled: comments.busy) {
          Button { Task { await comments.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).disabled(comments.busy).help("刷新评论")
          closeButton
        }
      }
    }.padding(.leading, 16).padding(.trailing, 10).frame(height: Theme.pageHeaderHeight)
  }
  private var closeButton: some View {
    Button(action: close) { Image(systemName: "xmark") }
      .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("关闭评论")
  }
  private var composer: some View { M4CommentComposer(comments: comments, model: model) }
}

/// Comment rows for a target: the list (pinned first) or, inside a thread, the root and its
/// replies. Shared by the moment panel and the video / PGC side panels.
struct M4CommentList: View {
  @ObservedObject var comments: M4CommentModel
  @ObservedObject var model: AppModel
  var ownerMid: Int64?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      if let root = comments.thread {
        row(root)
        ForEach(comments.replies, id: \.id) { row($0) }
        if let error = comments.repliesError { failure(error) { await comments.loadReplies() } }
        else if comments.repliesLoading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12) }
        else if comments.replies.isEmpty { Text("还没有回复").foregroundStyle(Theme.secondaryText(scheme)).padding(.vertical, 12) }
        if !comments.repliesEnd && !comments.repliesLoading && comments.repliesError == nil {
          more { await comments.loadReplies() }
        }
      } else {
        if let pinned = comments.pinned { row(pinned) }
        ForEach(comments.comments.filter { $0.id != comments.pinned?.id }, id: \.id) { row($0) }
        if let error = comments.error { failure(error) { await comments.loadNext() } }
        else if comments.loading { ProgressView("正在加载评论…").frame(maxWidth: .infinity).padding(.vertical, 12) }
        else if comments.comments.isEmpty { Text("还没有评论").foregroundStyle(Theme.secondaryText(scheme)).padding(.vertical, 12) }
        if !comments.isEnd && !comments.loading && comments.error == nil {
          more { await comments.loadNext() }
        }
      }
    }
  }
  private func row(_ comment: RPCComment) -> some View {
    CommentCell(comment: comment, pinned: comments.pinned?.id == comment.id, ownerMid: ownerMid,
      likes: comments.likeCount(comment), liked: comments.isLiked(comment), showsReplies: comments.thread == nil,
      canReply: comments.canInteract && !comments.busy,
      onAuthor: { model.openOverlay(.userSpace(comment.author.mid)) },
      onLike: { Task { await comments.toggleLike(comment) { model.showingLogin = true } } },
      canLike: comments.canLike(comment),
      onReply: { comments.reply(to: comment) },
      onOpenReplies: { Task { await comments.openThread(comment) } })
  }
  private func more(action: @escaping () async -> Void) -> some View {
    LoadMoreFooter(isLoading: false) { Task { await action() } }
  }
  private func failure(_ error: String, action: @escaping () async -> Void) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      InlineErrorText(message: error)
      Button("重试") { Task { await action() } }.buttonStyle(AppButtonStyle(size: .small))
    }.padding(.vertical, 12)
  }
}

/// Bottom composer: sign-in prompt, reply target, send.
struct M4CommentComposer: View {
  @ObservedObject var comments: M4CommentModel
  @ObservedObject var model: AppModel
  var body: some View {
    CommentComposerBar(draft: $comments.draft, replyingTo: comments.replyingTo, signedIn: comments.canInteract,
      busy: comments.busy, canSend: comments.canSend, error: comments.mutationError, notice: comments.notice,
      cancelReply: { comments.cancelReply() },
      send: { Task { await comments.send { model.showingLogin = true } } },
      login: { model.showingLogin = true })
  }
}

/// The 评论 tab of the video and PGC side panels: header with count and sort (or the thread's
/// back row) above the shared list. Loads when the target changes; the page pins the composer.
struct M4EmbeddedComments: View {
  @ObservedObject var comments: M4CommentModel
  @ObservedObject var model: AppModel
  let target: M4CommentTarget?
  var total: Int64?
  var ownerMid: Int64?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if comments.thread != nil {
        HStack(spacing: 8) {
          Button { comments.closeThread() } label: { Label("返回评论", systemImage: "chevron.left") }
            .buttonStyle(AppButtonStyle(role: .plain, size: .small))
          Spacer(minLength: 0)
          Text("楼中楼").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        }.padding(.bottom, 4)
      } else {
        CommentSectionHeader(total: total, sort: Binding(
          get: { comments.sort }, set: { value in Task { await comments.setSort(value) } }),
          sortDisabled: comments.busy).padding(.bottom, 4)
      }
      if target == nil {
        Text("正在获取评论编号…").foregroundStyle(Theme.tertiaryText(scheme)).padding(.vertical, 12)
      } else {
        M4CommentList(comments: comments, model: model, ownerMid: ownerMid)
      }
    }
    .font(Theme.Font.body).foregroundStyle(Theme.text(scheme))
    .task(id: target?.oid) {
      guard let target, comments.target != target else { return }
      await comments.select(target, sort: comments.sort)
    }
  }
}
