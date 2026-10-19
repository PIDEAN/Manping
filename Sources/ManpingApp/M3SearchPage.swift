import ManpingCore
import SwiftUI

struct M3SearchPage: View {
  @ObservedObject var model: AppModel
  let term: String
  @StateObject private var library: LibraryModel
  @StateObject private var suggestions: SearchSuggestionModel
  @State private var type: LibrarySearchType = .video
  @State private var order: LibrarySearchOrder = .relevance
  @Environment(\.colorScheme) private var scheme
  private let types: [LibrarySearchType] = [.video, .anime, .cinema, .live, .user, .article]
  init(model: AppModel, term: String) {
    self.model = model; self.term = term
    _library = StateObject(wrappedValue: LibraryModel(model: model))
    _suggestions = StateObject(wrappedValue: SearchSuggestionModel(model: model))
  }
  private var queryID: String { "\(term):\(type.rawValue):\(order.rawValue):\(model.refreshToken)" }
  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 2) {
          SidebarSectionTitle(title: "搜索范围")
          ForEach(types, id: \.self) { item in
            Button { type = item } label: {
              Text(item.title).font(Theme.Font.body).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).frame(height: Theme.rowHeight)
            }.buttonStyle(SidebarRowStyle(selected: type == item))
          }
          Spacer()
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }.frame(width: Theme.secondarySidebarWidth)
      Hairline(axis: .vertical)
      VStack(spacing: 0) {
        if term.isEmpty { discovery }
        else { LibraryResults(library: library, model: model) }
      }
    }
      .pageToolbar(title: term.isEmpty ? "搜索" : "「\(term)」", subtitle: library.total > 0 ? "\(library.total) 个结果" : nil,
        refresh: { if term.isEmpty { suggestions.loadTrending() } else { Task { await library.refresh() } } }) {
        if type == .video && !term.isEmpty {
          Menu {
            Picker("排序", selection: $order) {
              ForEach(LibrarySearchOrder.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
          } label: { MenuLabel(title: order.title) }.appMenuStyle(toolbar: true)
        }
      }
      .task(id: queryID) {
        if term.isEmpty { suggestions.update(""); suggestions.loadTrending() }
        else { await library.load(.search(term, type, order)) }
      }.onDisappear { library.cancel(); suggestions.cancel() }
  }
  private var discovery: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("搜索推荐").font(Theme.Font.headline).foregroundStyle(Theme.secondaryText(scheme))
        if suggestions.isLoading { ProgressView().controlSize(.small) }
        FlowChips(items: suggestions.choices.map { ($0.id, $0.title, $0.keyword) }) { submit($0) }
        Label("热搜榜单", systemImage: "flame").font(Theme.Font.headline).foregroundStyle(Theme.secondaryText(scheme)).padding(.top, 8)
        VStack(spacing: 0) {
          ForEach(suggestions.trending) { item in
            Button { submit(item.keyword) } label: {
              HStack(spacing: 12) {
                Text("\(item.position)").font(Theme.Font.body.monospacedDigit()).fontWeight(item.position <= 3 ? .bold : .regular)
                  .foregroundStyle(item.position <= 3 ? Theme.accentText(scheme) : Theme.tertiaryText(scheme)).frame(width: 24)
                Text(item.title).font(Theme.Font.body).lineLimit(1)
                if let icon = item.icon { CachedImage(url: icon).frame(width: 16, height: 16) }
                Spacer()
              }.padding(.horizontal, 12).frame(height: 40)
            }.buttonStyle(SidebarRowStyle())
          }
        }.padding(6).frame(maxWidth: 640).cardSurface(scheme)
        if let error = suggestions.error {
          InlineErrorText(message: error)
          Button("重试") { suggestions.update(""); suggestions.loadTrending() }.buttonStyle(AppButtonStyle(size: .small))
        }
      }.padding(Theme.gridPadding).foregroundStyle(Theme.text(scheme))
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private func submit(_ keyword: String) { model.search = keyword; model.submitSearch() }
}
