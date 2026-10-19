import ManpingCore
import SwiftUI

struct M3ViewLaterPage: View {
  @ObservedObject var model: AppModel
  @StateObject private var collection: CollectionActionsModel
  @State private var pendingAction: CollectionActionsModel.PendingAction?
  @State private var playbackError: String?
  @Environment(\.colorScheme) private var scheme
  init(model: AppModel) {
    self.model = model
    _collection = StateObject(wrappedValue: CollectionActionsModel(model: model, page: .later))
  }
  var body: some View {
    VStack(spacing: 0) {
      if let playbackError { InlineErrorText(message: playbackError).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8) }
      if let notice = collection.playAllNotice {
        M3PlayAllNoticeBar(notice: notice, playLoaded: {
          collection.playLoaded { await open($0) }
        }, dismiss: collection.dismissPlayAllNotice)
      }
      M3CollectionResults(collection: collection, model: model, emptyTitle: "稍后再看是空的") {
        pendingAction = collection.prepareRemoval([$0])
      }
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: "稍后再看", subtitle: collection.total > 0 ? "\(collection.total) 个视频" : nil,
        refreshing: collection.isLoading && !collection.entries.isEmpty, refresh: { Task { await collection.refresh() } }) {
        M3PlayAllButton(collection: collection) { playAll() }
        M3CollectionButton(title: collection.isSelecting ? "退出多选" : "多选", icon: "checkmark.square", selected: collection.isSelecting, toolbar: true) {
          collection.toggleSelectionMode()
        }.disabled(collection.entries.isEmpty || collection.isMutating)
        if collection.isSelecting {
          M3CollectionButton(title: "移除所选", icon: "trash", destructive: true, toolbar: true) {
            pendingAction = collection.prepareRemoval(collection.removableSelected)
          }
            .disabled(collection.removableSelected.isEmpty || collection.isLoading || collection.isMutating)
        }
        M3CollectionButton(title: "清空", icon: "trash", destructive: true, toolbar: true) { pendingAction = collection.prepareClearAll() }
          .disabled(collection.entries.isEmpty || collection.isLoading || collection.isMutating)
      }
      .overlay {
        if let pendingAction {
          M3CollectionConfirmation(title: pendingAction.clearsAll ? "清空稍后再看？" : "移除 \(pendingAction.count) 个视频？",
            detail: pendingAction.clearsAll ? "这会移除账号中的全部稍后再看视频，包括尚未加载的内容。" : "所选视频将从稍后再看中移除。",
            actionTitle: pendingAction.clearsAll ? "清空" : "移除") {
              let confirmed = pendingAction
              self.pendingAction = nil
              Task { await collection.perform(confirmed) }
            } cancel: { self.pendingAction = nil }
        }
      }
      .task(id: model.refreshToken) { await collection.start() }
      .onChange(of: collection.actionContextGeneration) { _, _ in pendingAction = nil }
      .onChange(of: collection.identityVersion) { _, _ in pendingAction = nil; playbackError = nil }
      .onDisappear { pendingAction = nil; collection.stop() }
  }
  /// Reads the whole list (not only the scrolled part), then plays it as one queue.
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
