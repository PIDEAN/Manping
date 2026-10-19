import AppKit
import ManpingCore
import SwiftUI

// Shared by the collection pages and the live page's retry/refresh buttons.
struct M3CollectionButton: View {
  let title: String
  let icon: String
  var destructive = false
  var selected = false
  /// A toolbar action: the 36 pt glass capsule, icon in the text colour (see `toolbarActionStyle`).
  var toolbar = false
  let action: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 12, weight: .medium))
          .foregroundStyle(destructive ? Theme.danger(scheme) : selected ? Theme.accentText(scheme) : toolbar ? Theme.text(scheme) : Theme.accentText(scheme))
        Text(title)
      }
    }.buttonStyle(AppButtonStyle(role: destructive ? .destructive : .secondary, size: toolbar ? .toolbar : .small))
      .overlay { if selected { Capsule().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1) } }
      .help(title).accessibilityLabel(title)
  }
}

/// 「全部播放」: while the whole list is being read it shows how many videos it has and cannot
/// be pressed again.
struct M3PlayAllButton: View {
  @ObservedObject var collection: CollectionActionsModel
  let action: () -> Void
  var body: some View {
    let loading = collection.playAllProgress
    M3CollectionButton(title: loading.map { "正在读取列表（\($0)）…" } ?? "全部播放",
      icon: loading == nil ? "play" : "hourglass", toolbar: true, action: action)
      .disabled(loading != nil || collection.loadedVideos.isEmpty || collection.isMutating)
  }
}

/// After 全部播放 could not read the list to the end: offers to play the videos read so far.
/// Can be closed. (A list cut short at the limit is said beside the player, with its queue.)
struct M3PlayAllNoticeBar: View {
  let notice: CollectionActionsModel.PlayAllNotice
  let playLoaded: () -> Void
  let dismiss: () -> Void
  var body: some View {
    HStack(spacing: 8) {
      InlineErrorText(message: notice.message)
      Spacer(minLength: 8)
      if !notice.videos.isEmpty {
        Button("播放已加载的 \(notice.videos.count) 个", action: playLoaded)
          .buttonStyle(AppButtonStyle(role: .primary, size: .small))
      }
      Button(action: dismiss) { Image(systemName: "xmark") }
        .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("关闭").accessibilityLabel("关闭")
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
  }
}

struct M3CollectionConfirmation: View {
  let title: String
  let detail: String
  let actionTitle: String
  let confirm: () -> Void
  let cancel: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    ZStack {
      Theme.scrim(scheme).contentShape(Rectangle()).onTapGesture(perform: cancel)
      VStack(alignment: .leading, spacing: 12) {
        Text(title).font(Theme.Font.headline).foregroundStyle(Theme.text(scheme))
        Text(detail).font(Theme.Font.body).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("取消", action: cancel).buttonStyle(AppButtonStyle(size: .small)).keyboardShortcut(.cancelAction)
          Button(actionTitle, action: confirm).buttonStyle(AppButtonStyle(role: .destructive, size: .small))
        }.padding(.top, 4)
      }.padding(20).frame(width: 360)
        .floatingGlassPanel(readingTint: Theme.panel(scheme).opacity(0.55))
    }.accessibilityAddTraits(.isModal).onExitCommand(perform: cancel)
  }
}

/// The remove button on a card's corner: it appears while the pointer is over the card (in selection
/// mode the card shows its checkmark instead). The hover state lives here, per card, so moving the
/// pointer never re-renders the grid.
private struct HoverRemoveButton: ViewModifier {
  let enabled: Bool
  let help: String
  let disabled: Bool
  let remove: () -> Void
  @State private var hovering = false
  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topTrailing) {
        if enabled && hovering {
          Button(action: remove) { Image(systemName: "trash") }
            .buttonStyle(ArtworkIconButtonStyle())
            .help(help).accessibilityLabel(help).disabled(disabled).padding(8)
            .transition(.opacity)
        }
      }
      // Follows the card's own lift, so the grid keeps one hover region for all its cards.
      .onPreferenceChange(CardHoveredPreference.self) { value in
        withAnimation(.easeOut(duration: 0.12)) { hovering = value }
      }
  }
}

struct M3CollectionResults: View {
  @ObservedObject var collection: CollectionActionsModel
  @ObservedObject var model: AppModel
  let emptyTitle: String
  let remove: (LibraryEntry) -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(spacing: 0) {
      if let error = collection.actionError {
        HStack(spacing: 12) {
          InlineErrorText(message: error)
          Spacer()
          Button { collection.dismissActionError() } label: { Image(systemName: "xmark") }
            .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("关闭提示")
        }.padding(.horizontal, 16).padding(.vertical, 8).background(Theme.danger(scheme).opacity(0.08))
      }
      if collection.isSelecting {
        HStack(spacing: 12) {
          M3CollectionButton(title: "全选当前列表", icon: "checkmark.square") { collection.selectAllLoaded() }
          Text("已选 \(collection.selectedIDs.count) 项").font(Theme.Font.caption)
          Spacer()
        }.padding(.horizontal, 16).padding(.vertical, 8).background(Theme.selectedFill(scheme).opacity(0.5))
      }
      if collection.entries.isEmpty {
        if collection.isLoading {
          PageStateView(.loading, title: "正在加载\(collection.title)…")
        } else {
          PageStateView(collection.error == nil ? .empty : .error, title: collection.error == nil ? emptyTitle : "没能加载\(collection.title)",
            message: collection.error ?? "添加的视频会出现在这里。", icon: collection.error == nil ? "tray" : "wifi.exclamationmark",
            actionTitle: collection.error == nil ? "刷新" : "重试") { Task { await collection.refresh() } }
        }
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: collection.isPGC ? 148 : Theme.gridMinimum),
            spacing: Theme.gridSpacing)], spacing: collection.isPGC ? 24 : Theme.gridSpacing) {
            ForEach(collection.entries) { entry in
              card(entry).onAppear {
                if entry.id == collection.entries.last?.id, collection.error == nil {
                  Task { await collection.loadNext() }
                }
              }
            }
          }.cardGridContent().padding(Theme.gridPadding)
          if let error = collection.error {
            VStack(spacing: 10) {
              InlineErrorText(message: error)
              Button("重试") { Task { await collection.loadNext() } }.buttonStyle(AppButtonStyle(size: .small))
            }.padding(16)
          } else if collection.hasMore {
            LoadMoreFooter(isLoading: collection.isLoading, autoLoad: false) { Task { await collection.loadNext() } }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).cardGrid()
      }
      if collection.isMutating {
        HStack(spacing: 12) {
          ProgressView().controlSize(.small)
          Text("正在提交…").font(Theme.Font.caption)
          Spacer()
          M3CollectionButton(title: "取消", icon: "xmark") { collection.cancelAction() }
        }.padding(.horizontal, 16).padding(.vertical, 8).overlay(alignment: .top) { Hairline() }
      }
    }.foregroundStyle(Theme.text(scheme))
  }
  @ViewBuilder private func card(_ entry: LibraryEntry) -> some View {
    VStack(spacing: 0) {
      ZStack(alignment: .topLeading) {
        if case .video(let video) = entry.destination {
          videoCard(video, entry: entry)
        } else {
          // The same poster card as the 番剧 timeline: title and detail line under the cover.
          PosterCard(cover: entry.cover, title: entry.title, subtitle: entry.subtitle) { activate(entry) }
        }
        if collection.isSelecting && collection.removable(entry) {
          Button { collection.toggle(entry) } label: {
            Image(systemName: collection.selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 20)).foregroundStyle(collection.selectedIDs.contains(entry.id) ? Theme.accent : .white)
              .background(Circle().fill(.black.opacity(0.45)).padding(2))
          }.buttonStyle(.plain).padding(10).disabled(collection.isMutating).accessibilityLabel("选择 \(entry.title)")
        }
      }.modifier(HoverRemoveButton(
        enabled: collection.removable(entry) && !collection.isSelecting,
        help: collection.isPGC ? "取消追番 / 追剧" : "移除",
        disabled: collection.isMutating || collection.isLoading || collection.isLoadingFolders) { remove(entry) })
    }.opacity(collection.isSelecting && !collection.selectedIDs.contains(entry.id) ? 0.82 : 1)
  }
  private func videoCard(_ video: Video, entry: LibraryEntry) -> some View {
    VideoCard(video: video) { activate(entry) }
      .overlay(alignment: .topLeading) {
        if !collection.isSelecting, let mid = video.authorID, mid > 0 {
          Button { model.openOverlay(.userSpace(mid)) } label: {
            CachedImage(url: video.avatar).frame(width: 26, height: 26).clipShape(Circle())
              .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
          }.buttonStyle(.plain).help(video.author).padding(8)
        }
      }
  }
  private func activate(_ entry: LibraryEntry) {
    if collection.isSelecting { collection.toggle(entry); return }
    guard !collection.isMutating else { return }
    model.open(entry)
  }
}
