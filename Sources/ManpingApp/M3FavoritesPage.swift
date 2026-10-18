import ManpingCore
import SwiftUI

struct M3FavoritesPage: View {
  @ObservedObject var model: AppModel
  @StateObject private var collection: CollectionActionsModel
  @AppStorage("m3FavoriteSidebarWidth") private var storedWidth = 240.0
  @AppStorage("m3FavoriteSidebarHidden") private var sidebarHidden = false
  @State private var pendingAction: CollectionActionsModel.PendingAction?
  @State private var showsStatus = false
  @State private var playbackError: String?
  @Environment(\.colorScheme) private var scheme
  private var sidebarWidth: CGFloat { min(420, max(180, CGFloat(storedWidth))) }
  init(model: AppModel) {
    self.model = model
    _collection = StateObject(wrappedValue: CollectionActionsModel(model: model, page: .favorites))
  }
  var body: some View {
    HStack(spacing: 0) {
      if !sidebarHidden {
        sidebar.frame(width: sidebarWidth).transition(.move(edge: .leading).combined(with: .opacity))
        SidebarResizeHandle(width: $storedWidth, range: 180...420)
      }
      VStack(spacing: 0) {
        if let playbackError { InlineErrorText(message: playbackError).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8) }
        if let notice = collection.playAllNotice {
          M3PlayAllNoticeBar(notice: notice, playLoaded: {
            collection.playLoaded { await open($0) }
          }, dismiss: collection.dismissPlayAllNotice)
        }
        M3CollectionResults(collection: collection, model: model,
          emptyTitle: collection.isPGC ? "还没有追番或追剧" : "这个收藏夹是空的") {
            pendingAction = collection.prepareRemoval([$0])
          }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: "收藏", subtitle: subtitle,
        refreshing: collection.isLoading && !collection.entries.isEmpty, refresh: { Task { await collection.refresh() } }) { headerControls }
      .overlay {
        if let pendingAction {
          M3CollectionConfirmation(title: pendingAction.isPGC ? "取消 \(pendingAction.count) 项追番 / 追剧？" : "移除 \(pendingAction.count) 个视频？",
            detail: pendingAction.isPGC ? "所选内容将从当前账号的追番 / 追剧列表中移除。" : "所选视频将从这个收藏夹中移除。",
            actionTitle: "确认移除") {
              let confirmed = pendingAction
              self.pendingAction = nil
              Task { await collection.perform(confirmed) }
            } cancel: { self.pendingAction = nil }
        }
      }
      .task(id: model.refreshToken) {
        await collection.start()
        if let intent = model.pgcFavoriteIntent { await collection.select(intent.cinema ? .cinema : .anime) }
        #if DEBUG
        let arguments = CommandLine.arguments
        if model.usesUIFixtures, let index = arguments.firstIndex(of: "--ui-page"),
          arguments.indices.contains(index + 1), arguments[index + 1] == "favorites:11" {
          await collection.select(.folder(11))
        }
        #endif
      }
      .onChange(of: model.pgcFavoriteIntent?.revision) { _, _ in
        if let intent = model.pgcFavoriteIntent { Task { await collection.select(intent.cinema ? .cinema : .anime) } }
      }
      .onChange(of: collection.actionContextGeneration) { _, _ in pendingAction = nil }
      .onChange(of: collection.identityVersion) { _, _ in pendingAction = nil; showsStatus = false; playbackError = nil }
      .onDisappear { pendingAction = nil; showsStatus = false; collection.stop() }
  }
  private var sidebar: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          SidebarSectionTitle(title: "追番与追剧")
          sectionRow(title: "我的追番", icon: "sparkles.tv", section: .anime)
          sectionRow(title: "我的追剧", icon: "film", section: .cinema)
          ForEach(["我创建的", "我收藏的"], id: \.self) { group in
            let folders = collection.folders.filter { $0.group == group && !$0.isSeason }
            if !folders.isEmpty {
              SidebarSectionTitle(title: group)
              ForEach(folders) { folder in folderRow(folder) }
            }
          }
          let seasons = collection.folders.filter(\.isSeason)
          if !seasons.isEmpty {
            SidebarSectionTitle(title: "收藏的合集")
            ForEach(seasons) { folder in folderRow(folder) }
          }
          let others = collection.folders.filter { !$0.isSeason && $0.group != "我创建的" && $0.group != "我收藏的" }
          ForEach(others) { folder in folderRow(folder) }
          if collection.hasMoreFolders {
            if collection.isLoadingFolders { ProgressView().frame(maxWidth: .infinity).padding(8) }
            else {
              Button("加载更多收藏夹") { Task { await collection.loadMoreFolders() } }
                .buttonStyle(AppButtonStyle(size: .small)).disabled(collection.isMutating).frame(maxWidth: .infinity).padding(.top, 6)
            }
          }
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }
    }
  }
  private var subtitle: String {
    collection.isPGC || collection.total <= 0 ? collection.title : "\(collection.title) · \(collection.total) 个视频"
  }
  @ViewBuilder private var headerControls: some View {
      SidebarToggleButton(hidden: $sidebarHidden)
      if !collection.isPGC && collection.selectedFolder?.isSeason != true {
        M3PlayAllButton(collection: collection) { playAll() }
      }
      if collection.isPGC { statusPicker }
      if collection.canRemove {
        M3CollectionButton(title: collection.isSelecting ? "退出多选" : "多选", icon: "checkmark.square", selected: collection.isSelecting) {
          collection.toggleSelectionMode()
        }.disabled(collection.entries.isEmpty || collection.isMutating)
        if collection.isSelecting {
          M3CollectionButton(title: "移除所选", icon: "trash", destructive: true) {
            pendingAction = collection.prepareRemoval(collection.removableSelected)
          }
            .disabled(collection.removableSelected.isEmpty || collection.isLoading || collection.isMutating)
        }
      }
  }
  private var statusPicker: some View {
    Menu {
      ForEach(1...3, id: \.self) { value in
        Toggle(statusTitle(value), isOn: Binding(get: { collection.status == value },
          set: { if $0 { Task { await collection.selectStatus(value) } } }))
      }
    } label: { MenuLabel(title: statusTitle(collection.status)) }
      .appMenuStyle().disabled(collection.isMutating || collection.loadedIdentity == nil)
  }
  private func sectionRow(title: String, icon: String, section: CollectionActionsModel.Section) -> some View {
    Button { Task { await collection.select(section) } } label: {
      HStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
        Text(title).font(Theme.Font.body).lineLimit(1)
        Spacer(minLength: 0)
      }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
    }.buttonStyle(SidebarRowStyle(selected: collection.section == section))
      .disabled(collection.isMutating || collection.loadedIdentity == nil)
  }
  private func folderRow(_ folder: LibraryFolder) -> some View {
    Button { Task { await collection.select(.folder(folder.id)) } } label: {
      HStack(spacing: 8) {
        Image(systemName: folder.isSeason ? "rectangle.stack" : "folder").font(.system(size: 13)).frame(width: 18)
        Text(folder.title).font(Theme.Font.body).lineLimit(1)
        Spacer(minLength: 0)
        Text(String(folder.count)).font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
      }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
    }.buttonStyle(SidebarRowStyle(selected: collection.section == .folder(folder.id)))
      .disabled(collection.isMutating || collection.loadedIdentity == nil)
      .help(folder.isSeason ? "\(folder.title) · 合集" : folder.title)
  }
  private func statusTitle(_ value: Int) -> String { value == 1 ? "想看" : value == 3 ? "已看" : "在看" }
  /// Reads the whole folder (not only the scrolled part), then plays it as one queue.
  private func playAll() {
    playbackError = nil
    collection.playAll { await open($0) }
  }
  /// Starts the queue; false when it could not or the list went stale before it changed (the
  /// reason is shown unless the account changed). A note such as a cut-short list goes with
  /// the queue and is shown beside the player.
  private func open(_ handoff: PlaylistHandoff) async -> Bool {
    do { try await model.openPlaylist(handoff); return true }
    catch is CancellationError { return false }
    catch {
      let current = await model.service.authSnapshot()
      let expected = handoff.identity
      if current.epoch == expected.epoch, current.identityRevision == expected.identityRevision { playbackError = error.localizedDescription }
      return false
    }
  }
}
