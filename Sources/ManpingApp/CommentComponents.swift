import AppKit
import ManpingCore
import SwiftUI

// Shared comment presentation. The video, bangumi, moment and article comment surfaces each keep
// their own model; these views only draw, so one style covers all four.

enum CommentFormat {
  /// Relative for the last day ("3 小时前"), then "10 月 9 日", with the year once it is not this year.
  static func time(_ stamp: Int64, now: Date = Date()) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(stamp))
    let age = now.timeIntervalSince(date)
    if age < 60 { return "刚刚" }
    if age < 3_600 { return "\(Int(age / 60)) 分钟前" }
    if age < 86_400 { return "\(Int(age / 3_600)) 小时前" }
    let calendar = Calendar.current
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
    if year == calendar.component(.year, from: now) { return "\(month) 月 \(day) 日" }
    return "\(year) 年 \(month) 月 \(day) 日"
  }

  static func count(_ value: Int64) -> String { value.formatted(.number) }
}

/// Small accent capsule for "置顶" and "UP 主".
struct CommentPill: View {
  let text: String
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText(scheme))
      .padding(.horizontal, 5).frame(height: 15).background(Theme.selectedFill(scheme), in: Capsule())
  }
}

/// Comment text with inline emotes, drawn as SwiftUI text so size and line spacing follow the comment style.
/// A bracketed token stays visible as text until its image has loaded, or when the image fails.
struct CommentBodyText: View {
  let text: String
  let emotes: [RPCEmote]
  var size: CGFloat = 13
  var lineSpacing: CGFloat = 5
  var prefix: Text? = nil
  var lineLimit: Int? = nil
  @State private var images: [URL: NSImage] = [:]
  @Environment(\.colorScheme) private var scheme

  private var segments: [RPCEmoteTextSegment] { RPCEmoteTextSegment.parse(text, emotes: emotes) }

  var body: some View {
    composed.font(.system(size: size)).lineSpacing(lineSpacing).foregroundStyle(Theme.text(scheme))
      .lineLimit(lineLimit).multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
      .task(id: emotes) { await loadImages() }
  }

  private var composed: Text {
    var result = prefix ?? Text(verbatim: "")
    for segment in segments {
      switch segment {
      case .text(let value): result = Text("\(result)\(Text(verbatim: value))")
      case .emote(let token, let url):
        if let image = images[url] { result = Text("\(result)\(Text(Image(nsImage: image)))") }
        else { result = Text("\(result)\(Text(verbatim: token))") }
      }
    }
    return result
  }

  private func loadImages() async {
    let side = size + 5
    for case .emote(_, let url) in segments where images[url] == nil {
      do {
        let decoded = try await ImageCache.shared.imageForReader(for: url)
        try Task.checkCancellation()
        images[url] = NSImage(cgImage: decoded, size: NSSize(width: side, height: side))
      } catch is CancellationError { return } catch { /* Keep the token as text when an image fails. */ }
    }
  }
}

/// "评论 1,234" on the left, the hot/new switch on the right, optional trailing controls.
struct CommentSectionHeader<Trailing: View>: View {
  var total: Int64?
  @Binding var sort: RPCCommentSort
  var sortDisabled = false
  @ViewBuilder var trailing: () -> Trailing
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 8) {
      Text("评论").font(Theme.Font.headline)
      if let total { Text(CommentFormat.count(total)).font(Theme.Font.body.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme)) }
      Spacer(minLength: 8)
      SegmentedTabs(options: [(RPCCommentSort.hot, "最热"), (RPCCommentSort.time, "最新")], selection: $sort)
        .disabled(sortDisabled)
      trailing()
    }.foregroundStyle(Theme.text(scheme))
  }
}

extension CommentSectionHeader where Trailing == EmptyView {
  init(total: Int64?, sort: Binding<RPCCommentSort>, sortDisabled: Bool = false) {
    self.init(total: total, sort: sort, sortDisabled: sortDisabled) { EmptyView() }
  }
}

/// One comment: avatar, name and badges, time on the right, body, action row, and (for top-level
/// comments) a tinted block with the first replies and a link into the full thread.
struct CommentCell: View {
  let comment: RPCComment
  var pinned = false
  /// Marks comments written by this account (the uploader or article author) with a "UP 主" pill.
  var ownerMid: Int64?
  let likes: Int64
  let liked: Bool
  /// Reply preview and "view all" link; off inside a thread.
  var showsReplies = true
  var canReply = true
  var onAuthor: (() -> Void)?
  var onLike: (() -> Void)?
  var canLike = true
  var onReply: (() -> Void)?
  var onOpenReplies: (() -> Void)?
  @Environment(\.colorScheme) private var scheme

  private var previews: [RPCComment] { Array(comment.replies.filter { $0.id != comment.id }.prefix(2)) }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      avatar
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(comment.author.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
          if pinned || comment.pinned { CommentPill(text: "置顶") }
          if let ownerMid, ownerMid > 0, comment.author.mid == ownerMid { CommentPill(text: "UP 主") }
          Spacer(minLength: 4)
          Text(CommentFormat.time(comment.createdAt)).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
        }
        CommentBodyText(text: comment.text, emotes: comment.emotes).translatable(comment.text)
        actions
        if showsReplies, comment.replyCount > 0 || !previews.isEmpty { replyBlock }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(.vertical, 12).foregroundStyle(Theme.text(scheme))
      .overlay(alignment: .bottom) { Hairline() }
  }

  @ViewBuilder private var avatar: some View {
    let image = CachedImage(url: comment.author.avatar).frame(width: 32, height: 32).clipShape(Circle())
    if let onAuthor, comment.author.mid > 0 { Button(action: onAuthor) { image }.buttonStyle(.plain) }
    else { image }
  }

  private var actions: some View {
    HStack(spacing: 14) {
      let like = HStack(spacing: 4) {
        Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup").font(.system(size: 11))
        Text(CommentFormat.count(likes)).monospacedDigit()
      }.foregroundStyle(liked ? Theme.accentText(scheme) : Theme.tertiaryText(scheme))
      if let onLike {
        Button(action: onLike) { like.contentShape(Rectangle()) }.buttonStyle(.plain).disabled(!canLike).help("点赞")
      } else { like }
      if let onReply {
        Button(action: onReply) { Text("回复").contentShape(Rectangle()) }.buttonStyle(.plain).disabled(!canReply)
          .foregroundStyle(canReply ? Theme.tertiaryText(scheme) : Theme.disabledText(scheme))
      }
    }.font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
  }

  private var replyBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(previews, id: \.id) { reply in
        CommentBodyText(text: "：" + reply.text, emotes: reply.emotes, size: 12, lineSpacing: 4,
          prefix: replyName(reply), lineLimit: 2)
      }
      if let onOpenReplies {
        Button(action: onOpenReplies) {
          Text("查看全部 \(max(comment.replyCount, Int64(previews.count))) 条回复 ›").font(Theme.Font.caption)
            .foregroundStyle(Theme.accentText(scheme)).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
    }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
      .padding(.top, 4)
  }

  private func replyName(_ reply: RPCComment) -> Text {
    let name = Text(verbatim: reply.author.name).foregroundStyle(Theme.accentText(scheme))
    guard let ownerMid, ownerMid > 0, reply.author.mid == ownerMid else { return name }
    let owner = Text(verbatim: " UP").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accentText(scheme))
    return Text("\(name)\(owner)")
  }
}

/// Bottom comment bar: a rounded input with a send button. Signed-out viewers get a login prompt in the same shape.
struct CommentComposerBar: View {
  @Binding var draft: String
  var replyingTo: String?
  var signedIn: Bool
  var busy = false
  var canSend: Bool
  var error: String?
  var notice: String?
  let cancelReply: () -> Void
  let send: () -> Void
  let login: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let notice { Text(notice).font(Theme.Font.caption).foregroundStyle(Theme.accentText(scheme)) }
      if let error { InlineErrorText(message: error) }
      if let replyingTo {
        HStack {
          Text("回复 @\(replyingTo)").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
          Spacer()
          Button("取消", action: cancelReply).buttonStyle(AppButtonStyle(role: .plain, size: .small)).disabled(busy)
        }
      }
      HStack(alignment: .bottom, spacing: 8) {
        if signedIn {
          TextField("发一条友善的评论", text: $draft, axis: .vertical).textFieldStyle(.plain).font(Theme.Font.body)
            .lineLimit(1...4).onSubmit { if canSend { send() } }.disabled(busy)
            .padding(.horizontal, 12).padding(.vertical, 7).frame(minHeight: 32)
            .background(field)
          Button(action: send) {
            if busy { ProgressView().controlSize(.small) } else { Text("发送") }
          }.buttonStyle(AppButtonStyle(role: .primary)).disabled(!canSend)
        } else {
          Text("登录后可发表评论").font(Theme.Font.body).foregroundStyle(Theme.tertiaryText(scheme))
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(field)
          Button("登录", action: login).buttonStyle(AppButtonStyle(role: .primary))
        }
      }
      if draft.count > 800 {
        Text("\(draft.count)/1000").font(Theme.Font.caption2.monospacedDigit())
          .foregroundStyle(draft.count > 1000 ? Theme.danger(scheme) : Theme.tertiaryText(scheme))
      }
    }.padding(.horizontal, 12).padding(.vertical, 10).overlay(alignment: .top) { Hairline() }
  }

  private var field: some View {
    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(Theme.fill(scheme))
      .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
  }
}
