import AppKit
import ManpingCore
import SwiftUI

struct MomentVideoCard: View {
  let item: RPCDynamic
  @ObservedObject var feed: MomentFeedModel
  @ObservedObject var model: AppModel
  let showComments: () -> Void
  @State private var showingDescription = false
  @Environment(\.colorScheme) private var scheme
  private var media: MomentMedia? { MomentMedia.find(item.content) }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        MomentAuthor(item: item, model: model)
        if !item.text.isEmpty {
          Button { showingDescription.toggle() } label: {
            Image(systemName: "text.bubble").font(.system(size: 12)).frame(width: 26, height: 26)
          }.buttonStyle(ChromeButtonStyle(icon: true, capsule: true)).help("动态描述")
            .popover(isPresented: $showingDescription) {
              MomentRichText(text: item.text, emotes: item.emotes, maxLines: nil).padding(16).frame(width: 400)
            }
        }
      }
      if let media {
        Button { media.open(model: model) } label: {
          CachedImage(url: media.cover).aspectRatio(16 / 9, contentMode: .fit).clipped()
            .overlay(alignment: .bottomTrailing) {
              if let duration = media.duration { MediaBadge(text: Self.duration(duration)).padding(8) }
            }.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }.buttonStyle(CardPressStyle())
        Button { media.open(model: model) } label: {
          Text(media.title).font(Theme.Font.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
      }
      Spacer(minLength: 0)
      MomentOperationRow(item: item, feed: feed, model: model, showComments: showComments)
    }.padding(16).frame(minHeight: 280, alignment: .topLeading)
      .foregroundStyle(Theme.text(scheme)).cardSurface(scheme)
      .contextMenu { MomentMenu(item: item, model: model) }
  }
  private static func duration(_ value: Int64) -> String { String(format: "%02lld:%02lld", value / 60, value % 60) }
}

struct MomentFullCard: View {
  let item: RPCDynamic
  @ObservedObject var feed: MomentFeedModel
  @ObservedObject var model: AppModel
  let showComments: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      MomentAuthor(item: item, model: model)
      if !item.text.isEmpty { MomentRichText(text: item.text, emotes: item.emotes) }
      MomentContent(content: item.content, model: model)
      MomentOperationRow(item: item, feed: feed, model: model, showComments: showComments)
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(Theme.text(scheme)).cardSurface(scheme)
      .contextMenu { MomentMenu(item: item, model: model) }
  }
}

private struct MomentAuthor: View {
  let item: RPCDynamic
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 12) {
      Button { if let mid = item.author?.mid, mid > 0 { model.openOverlay(.userSpace(mid)) } } label: {
        CachedImage(url: item.author?.avatar).frame(width: 36, height: 36).clipShape(Circle())
      }.buttonStyle(.plain).disabled((item.author?.mid ?? 0) <= 0)
      VStack(alignment: .leading, spacing: 2) {
        Button { if let mid = item.author?.mid, mid > 0 { model.openOverlay(.userSpace(mid)) } } label: {
          Text(item.author?.name ?? "动态").font(Theme.Font.headline).lineLimit(1)
        }.buttonStyle(.plain).disabled((item.author?.mid ?? 0) <= 0)
        Text(item.timeLabel).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct MomentRichText: View {
  let text: String
  let emotes: [RPCEmote]
  var maxLines: Int? = 4
  var body: some View { InlineEmoteText(text: text, emotes: emotes, maxLines: maxLines) }
}

private struct MomentOperationRow: View {
  let item: RPCDynamic
  @ObservedObject var feed: MomentFeedModel
  @ObservedObject var model: AppModel
  let showComments: () -> Void
  var body: some View {
    HStack(spacing: 12) {
      Button { Task { await feed.toggleLike(item) { model.showingLogin = true } } } label: {
        HStack(spacing: 8) {
          if feed.busy.contains(item.id) { ProgressView().controlSize(.mini) }
          else { Image(systemName: feed.isLiked(item) ? "hand.thumbsup.fill" : "hand.thumbsup") }
          Text("\(feed.likeCount(item))").monospacedDigit()
        }.font(Theme.Font.caption).frame(height: 28).padding(.horizontal, 10)
      }.buttonStyle(ChromeButtonStyle(selected: feed.isLiked(item), capsule: true)).disabled(!feed.canLike(item)).help("点赞")
      Button(action: showComments) {
        Label("\(item.replies)", systemImage: "bubble.right").font(Theme.Font.caption)
          .frame(height: 28).padding(.horizontal, 10)
      }.buttonStyle(ChromeButtonStyle(capsule: true)).disabled(M4CommentTarget(dynamic: item) == nil).help("评论")
      Spacer(minLength: 0)
    }
  }
}

private enum MomentMedia {
  case video(Video), episode(RPCEpisodeCard)
  static func find(_ content: RPCDynamicContent, depth: Int = 0) -> Self? {
    guard depth <= 8 else { return nil }
    switch content {
    case .video(let card):
      if case .video(let video) = LibraryEntry.rpcVideo(card).destination { return .video(video) }
      return nil
    case .episode(let episode): return .episode(episode)
    case .forward(let original): return find(original.content, depth: depth + 1)
    default: return nil
    }
  }
  var title: String { switch self { case .video(let video): video.title; case .episode(let episode): episode.title } }
  var cover: URL? { switch self { case .video(let video): video.cover; case .episode(let episode): episode.cover } }
  var duration: Int64? { if case .video(let video) = self { return Int64(video.duration) }; return nil }
  @MainActor func open(model: AppModel) {
    switch self {
    case .video(let video): model.open(video)
    case .episode(let episode):
      model.openPGC(PGCSelection(seasonID: episode.seasonID > 0 ? episode.seasonID : nil,
        episodeID: episode.episodeID > 0 ? episode.episodeID : nil))
    }
  }
}

private struct MomentContent: View {
  let content: RPCDynamicContent
  @ObservedObject var model: AppModel
  var depth = 0
  @Environment(\.colorScheme) private var scheme
  var body: some View { rendered(content, depth: depth) }
  // Type erasure bounds recursive forwards without recursively expanding the SwiftUI body type.
  private func rendered(_ content: RPCDynamicContent, depth: Int) -> AnyView {
    guard depth <= 8 else { return AnyView(Text("转发层级过多")) }
    switch content {
    case .video, .episode:
      guard let media = MomentMedia.find(content) else { return AnyView(EmptyView()) }
      return AnyView(Button { media.open(model: model) } label: {
        HStack(spacing: 12) {
          CachedImage(url: media.cover).frame(width: 160, height: 90).clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
          Text(media.title).font(Theme.Font.body).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "play.circle").font(.system(size: 22)).foregroundStyle(Theme.secondaryText(scheme))
        }.padding(8).background(Theme.fill(scheme)).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
      }.buttonStyle(CardPressStyle()))
    case .images(let images): return AnyView(MomentImages(images: images))
    case .article(let article):
      return AnyView(Button {
        model.openOverlay(.article(article.id))
      } label: {
        HStack(spacing: 12) {
          if let image = article.covers.first {
            CachedImage(url: image).frame(width: 120, height: 76).clipped()
              .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
          }
          VStack(alignment: .leading, spacing: 6) {
            Text(article.title).font(Theme.Font.headline).lineLimit(2)
            Text(article.text).font(Theme.Font.caption).lineLimit(2).foregroundStyle(Theme.secondaryText(scheme))
          }.frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "arrow.up.right.square")
        }.padding(10).background(Theme.fill(scheme)).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
      }.buttonStyle(CardPressStyle()))
    case .forward(let original):
      return AnyView(VStack(alignment: .leading, spacing: 12) {
        Button {
          if let mid = original.author?.mid, mid > 0 { model.openOverlay(.userSpace(mid)) }
        } label: { Text(original.author.map { "@\($0.name)" } ?? "转发动态").font(Theme.Font.headline).foregroundStyle(Theme.accentText(scheme)) }
          .buttonStyle(.plain)
        if !original.text.isEmpty { MomentRichText(text: original.text, emotes: original.emotes) }
        rendered(original.content, depth: depth + 1)
      }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.fill(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)))
    case .unsupported: return AnyView(Text("此类动态可通过菜单在浏览器查看").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)))
    case .text: return AnyView(EmptyView())
    }
  }
}

private struct MomentImages: View {
  let images: [URL]
  @State private var selected: Int?
  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(3, max(1, images.count))), spacing: 8) {
      ForEach(Array(images.enumerated()), id: \.offset) { index, url in
        Button { selected = index } label: {
          CachedImage(url: url).aspectRatio(1, contentMode: .fit).clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }.buttonStyle(CardPressStyle()).help("查看图片")
      }
    }.frame(maxWidth: 600)
      .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
        MomentImageGallery(images: images, index: selected ?? 0)
      }
  }
}

private struct MomentImageGallery: View {
  let images: [URL]
  @State var index: Int
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
          .buttonStyle(AppButtonStyle(size: .small, iconOnly: true)).disabled(index == 0)
        Text("\(index + 1) / \(images.count)").font(Theme.Font.caption.monospacedDigit())
        Button { index = min(images.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }
          .buttonStyle(AppButtonStyle(size: .small, iconOnly: true)).disabled(index >= images.count - 1)
        Spacer()
        Button("查看原图") { if images.indices.contains(index) { NSWorkspace.shared.open(images[index]) } }
          .buttonStyle(AppButtonStyle(size: .small))
        Button("关闭") { dismiss() }.buttonStyle(AppButtonStyle(role: .primary, size: .small)).keyboardShortcut(.cancelAction)
      }
      if images.indices.contains(index) {
        CachedImage(url: images[index]).scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.padding(16).frame(width: 760, height: 620).foregroundStyle(Theme.text(scheme))
  }
}

/// 拷贝链接 / 在浏览器中打开 — 进入 UP 主空间.
private struct MomentMenu: View {
  let item: RPCDynamic
  let model: AppModel
  var body: some View {
    Button("拷贝链接") { copyMomentURL(item) }
    Button("在浏览器中打开") { openMomentInBrowser(item) }
    if let mid = item.author?.mid, mid > 0 {
      Divider()
      Button("进入 UP 主空间") { model.openOverlay(.userSpace(mid)) }
    }
  }
}
private func openMomentInBrowser(_ item: RPCDynamic) {
  if let url = URL(string: "https://t.bilibili.com/\(item.id)") { NSWorkspace.shared.open(url) }
}
private func copyMomentURL(_ item: RPCDynamic) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString("https://t.bilibili.com/\(item.id)", forType: .string)
}
