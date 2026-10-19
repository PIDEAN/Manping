import AppKit
import ManpingCore
import SwiftUI

struct M3HistoryPage: View {
  @ObservedObject var model: AppModel
  @StateObject private var history: HistoryPageModel
  @State private var tab: HistoryBusiness = .archive
  @State private var searchText = ""
  @State private var consumedScopeRequest: UUID?
  @Environment(\.colorScheme) private var scheme
  init(model: AppModel) {
    self.model = model
    _history = StateObject(wrappedValue: HistoryPageModel(service: model.service, rpc: Self.makeRPC(model)))
  }
  private static func makeRPC(_ model: AppModel) -> LibraryRPCService? {
    // Write only the first time: a defaults write on every init re-renders views that observe
    // defaults (the shell's sidebar preference), which re-creates this view, in a loop.
    let installation: String
    if let saved = UserDefaults.standard.string(forKey: "libraryInstallationID") { installation = saved }
    else { installation = UUID().uuidString; UserDefaults.standard.set(installation, forKey: "libraryInstallationID") }
    if let transport = model.libraryRPCTransport {
      return LibraryRPCService(auth: model.service, transport: transport, installationID: installation)
    } else {
      return try? LibraryRPCService(auth: model.service, installationID: installation)
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      if history.records.isEmpty && history.isLoading {
        PageStateView(.loading, title: "正在加载历史记录…")
      } else if history.records.isEmpty, let error = history.error {
        PageStateView(.error, title: "没能加载历史记录", message: error, icon: "wifi.exclamationmark", actionTitle: "重试") {
          Task { await history.refresh() }
        }
      } else if history.records.isEmpty {
        PageStateView(title: history.keyword.isEmpty ? "历史记录是空的" : "没有找到匹配的记录",
          message: history.keyword.isEmpty ? "看过的视频会出现在这里。" : "换个关键词试试。", icon: "clock.arrow.circlepath")
      } else { results }
    }
      .pageToolbar(title: "历史记录", subtitle: history.keyword.isEmpty ? nil : "搜索「\(history.keyword)」",
        refreshing: history.isLoading && !history.records.isEmpty, refresh: { Task { await history.refresh() } }) { headerControls }
      .task(id: "\(tab.rawValue):\(model.refreshToken)") {
        if let request = model.regionalSearchRequest, request.route == .history,
          consumedScopeRequest != request.revision {
          consumedScopeRequest = request.revision; searchText = request.keyword
          await history.load(business: tab, keyword: request.keyword)
        } else { await history.load(business: tab, keyword: "") }
      }
      .onChange(of: model.regionalSearchRequest?.revision) { _, _ in
        guard let request = model.regionalSearchRequest, request.route == .history else { return }
        consumedScopeRequest = request.revision; searchText = request.keyword
        Task { await history.load(business: tab, keyword: request.keyword) }
      }
      .onDisappear { history.cancelRequests() }
      .confirmationDialog(confirmationTitle, isPresented: Binding(
        get: { history.confirmation != nil }, set: { if !$0 { history.cancelConfirmation() } }
      ), titleVisibility: .visible) {
        Button(confirmationTitle, role: .destructive) { history.confirmInBackground() }
        Button("取消", role: .cancel) { history.cancelConfirmation() }
      } message: { Text("此操作会影响当前账号，无法撤销。") }
  }
  private var confirmationTitle: String {
    if case .remove? = history.confirmation { return "删除这条历史记录" }
    return "清空\(history.business.title)历史"
  }
  @ViewBuilder private var headerControls: some View {
    if history.keyword.isEmpty {
      SegmentedTabs(options: HistoryBusiness.allCases.map { ($0, $0.title) }, selection: $tab)
    } else {
      Button { searchText = ""; Task { await history.exitSearch() } } label: { Label("退出搜索", systemImage: "xmark") }
        .toolbarActionStyle()
    }
    TextField("在历史记录中搜索", text: $searchText).textFieldStyle(AppTextFieldStyle(height: Theme.toolbarControlHeight)).frame(width: 150)
      .onSubmit { Task { await history.load(business: tab, keyword: searchText) } }
    if history.keyword.isEmpty {
      Button { history.requestClear() } label: { Label("清空", systemImage: "trash") }
        .toolbarActionStyle(.destructive).disabled(history.records.isEmpty || history.busy || history.isLoading)
    }
  }
  private var results: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        ForEach(HistoryDateSection.grouped(history.records)) { section in
          Text(section.title()).font(Theme.Font.headline).foregroundStyle(Theme.secondaryText(scheme)).padding(.top, 4)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
            ForEach(section.records) { record in historyCard(record) }
          }
        }
        if let error = history.error {
          InlineErrorText(message: error)
          Button("重试") { Task { await history.loadNext() } }.buttonStyle(AppButtonStyle(size: .small))
        } else if history.isLoading || history.hasMore {
          LoadMoreFooter(isLoading: history.isLoading, autoLoad: false) { Task { await history.loadNext() } }
        }
      }.cardGridContent().padding(Theme.gridPadding)
    }.cardGrid().prefetchOnScroll(enabled: history.hasMore && !history.isLoading && !history.busy && history.error == nil) {
      Task { await history.loadNext() }
    }
  }
  @ViewBuilder private func historyCard(_ record: HistoryRecord) -> some View {
    let remove = Button("从历史记录中删除", role: .destructive) { history.requestRemove(record) }
      .disabled(history.busy || history.isLoading)
    if case .video(let video) = record.entry.destination {
      VideoCard(video: video, action: { model.open(video) }, menuExtra: AnyView(remove)).help(record.entry.subtitle)
    } else {
      LibraryEntryCard(entry: record.entry) { model.open(record.entry) }.contextMenu { remove }
    }
  }
}
