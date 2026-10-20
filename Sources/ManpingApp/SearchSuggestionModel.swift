import ManpingCore
import SwiftUI

enum M3SearchScope: Equatable { case global, current }
struct M3SearchChoice: Identifiable, Equatable {
  var id: String { "\(scope):\(keyword)" }
  let title: String
  let keyword: String
  let scope: M3SearchScope
}

@MainActor final class SearchSuggestionModel: ObservableObject {
  @Published private(set) var choices: [M3SearchChoice] = []
  @Published private(set) var trending: [SearchDiscoveryItem] = []
  /// True while a trending request is running; an empty result then shows a message, not a spinner.
  @Published private(set) var trendingLoading = false
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  @Published var selectedIndex = -1
  private let service: BiliService
  private let rpc: LibraryRPCService?
  private var request: Task<Void, Never>?
  private var trendingRequest: Task<Void, Never>?
  private var identityTask: Task<Void, Never>?
  private var generation = UUID()
  private var hotGeneration = UUID()
  private var context: AuthSnapshot?
  private var hotContext: AuthSnapshot?
  init(model: AppModel) {
    service = model.service
    let installation = InstallationIdentity.library
    if let transport = model.libraryRPCTransport {
      rpc = LibraryRPCService(auth: model.service, transport: transport, installationID: installation)
    } else { rpc = try? LibraryRPCService(auth: model.service, installationID: installation) }
    identityTask = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        if [self.context, self.hotContext].compactMap({ $0 }).contains(where: {
          $0.epoch != event.epoch || $0.identityRevision != event.identityRevision
        }) {
          self.cancel(); self.trendingRequest?.cancel(); self.trendingRequest = nil; self.hotGeneration = UUID()
          self.choices = []; self.trending = []; self.context = nil; self.hotContext = nil
        }
      }
    }
  }
  deinit { request?.cancel(); trendingRequest?.cancel(); identityTask?.cancel() }
  func cancel() { generation = UUID(); request?.cancel(); request = nil; isLoading = false; selectedIndex = -1 }
  func update(_ keyword: String, currentScopeName: String? = nil) {
    cancel(); choices = []; error = nil
    let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    if let currentScopeName {
      choices = [M3SearchChoice(title: "全站", keyword: term, scope: .global),
        M3SearchChoice(title: currentScopeName, keyword: term, scope: .current)]
      return
    }
    let revision = generation; isLoading = true
    request = Task { [weak self] in
      guard let self else { return }
      do {
        if !term.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
        try Task.checkCancellation()
        let expected = await service.authSnapshot()
        try Task.checkCancellation()
        guard generation == revision else { return }
        context = expected
        let results: [M3SearchChoice]
        if term.isEmpty {
          results = try await service.searchRecommendations().map { M3SearchChoice(title: $0.title, keyword: $0.keyword, scope: .global) }
        } else {
          guard let rpc else { throw BiliError.dependency("无法初始化搜索建议") }
          results = try await rpc.suggestions(keyword: term).map { M3SearchChoice(title: $0.title, keyword: $0.keyword, scope: .global) }
        }
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard generation == revision, current.epoch == expected.epoch, current.identityRevision == expected.identityRevision else { return }
        choices = results; isLoading = false
      } catch is CancellationError {} catch {
        guard generation == revision else { return }
        self.error = error.localizedDescription; isLoading = false
      }
    }
  }
  func loadTrending() {
    guard trendingRequest == nil else { return }
    let revision = hotGeneration
    error = nil; trendingLoading = true
    trendingRequest = Task { [weak self] in
      guard let self else { return }
      defer { if hotGeneration == revision { trendingRequest = nil; trendingLoading = false } }
      do {
        let expected = await service.authSnapshot(); hotContext = expected
        let list = try await service.searchTrending()
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard hotGeneration == revision, current.epoch == expected.epoch, current.identityRevision == expected.identityRevision else { return }
        trending = list
      } catch is CancellationError {} catch {
        if hotGeneration == revision { self.error = error.localizedDescription }
      }
    }
  }
  func moveSelection(_ direction: Int) {
    guard !choices.isEmpty else { return }
    selectedIndex = max(0, min(choices.count - 1, selectedIndex + direction))
  }
  var selected: M3SearchChoice? { choices.indices.contains(selectedIndex) ? choices[selectedIndex] : nil }
}

/// Parent shell owns the text and dispatches global/current searches to its active route.
struct M3SearchBox: View {
  @ObservedObject var suggestions: SearchSuggestionModel
  @Binding var text: String
  var suggestionsEnabled = true
  var currentScopeName: String? = nil
  var focusRequest: Int = 0
  /// 热搜 (⌘K from the 编辑 menu) opens the trending list.
  var hotRequest: Int = 0
  var submit: (String, M3SearchScope) -> Void
  @State private var showingSuggestions = false
  @State private var showingHot = false
  @FocusState private var focused: Bool
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 8) {
      Button { invoke(text, .global) } label: {
        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
          .foregroundStyle(Theme.secondaryText(scheme)).frame(width: 20, height: 28)
      }.buttonStyle(.plain).help("全站搜索")
      TextField("搜索视频、番剧或 UP 主", text: $text, prompt: Text("搜索视频、番剧或 UP 主")).labelsHidden().textFieldStyle(.plain).focused($focused)
        .onChange(of: text) { _, value in if suggestionsEnabled { suggestions.update(value, currentScopeName: currentScopeName) }; showingSuggestions = focused && suggestionsEnabled }
        .onChange(of: focused) { _, value in
          showingSuggestions = value && suggestionsEnabled
          if value && suggestionsEnabled { suggestions.update(text, currentScopeName: currentScopeName) }
        }
        .onSubmit {
          if suggestionsEnabled, let selected = suggestions.selected { invoke(selected.keyword, selected.scope) }
          else { invoke(text, .global) }
        }
        .onMoveCommand { direction in
          if direction == .down { suggestions.moveSelection(1) }
          if direction == .up { suggestions.moveSelection(-1) }
        }
        .onExitCommand { showingSuggestions = false; suggestions.cancel() }
        .popover(isPresented: $showingSuggestions, arrowEdge: .bottom) { suggestionList }
      Button { showingHot.toggle(); if showingHot { suggestions.loadTrending() } } label: {
        Image(systemName: "flame").font(.system(size: 13))
          .foregroundStyle(showingHot ? Theme.accentText(scheme) : Theme.secondaryText(scheme))
          .frame(width: 26, height: 26).contentShape(Circle())
      }.buttonStyle(ChromeButtonStyle(capsule: true)).help("热搜（⌘K）")
        .popover(isPresented: $showingHot, arrowEdge: .bottom) { hotList }
    }.font(Theme.Font.body).padding(.leading, 10).padding(.trailing, 4).frame(height: 36)
      .foregroundStyle(Theme.text(scheme))
      .glassEffect(.regular.interactive(), in: Capsule())
      .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.8) : .clear, lineWidth: 1))
      .animation(Theme.hoverAnimation, value: focused)
      .onChange(of: focusRequest) { _, _ in focused = true }
      .onChange(of: hotRequest) { _, _ in showingSuggestions = false; showingHot = true; suggestions.loadTrending() }
  }
  private var suggestionList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        if suggestions.isLoading { ProgressView().frame(maxWidth: .infinity).padding(12) }
        if let error = suggestions.error { Text(error).font(Theme.Font.caption).padding(8) }
        ForEach(Array(suggestions.choices.enumerated()), id: \.element.id) { index, choice in
          Button { invoke(choice.keyword, choice.scope) } label: {
            HStack {
              Text(currentScopeName == nil ? choice.title : (choice.keyword.isEmpty ? "输入搜索内容" : choice.keyword)).lineLimit(1)
              Spacer()
              if currentScopeName != nil {
                Text("在\(choice.title)搜索").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
              }
            }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
          }.buttonStyle(SidebarRowStyle(selected: index == suggestions.selectedIndex))
        }
      }.padding(6)
    }.frame(width: 360).frame(maxHeight: 320)
  }
  private var hotList: some View {
    ScrollView {
      VStack(spacing: 0) {
        if suggestions.trendingLoading && suggestions.trending.isEmpty { ProgressView().padding(20) }
        else if suggestions.trending.isEmpty && suggestions.error == nil {
          Text("暂时没有热搜").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).padding(20)
        }
        if let error = suggestions.error {
          Text(error).font(Theme.Font.caption).padding(12)
          Button("重试") { suggestions.loadTrending() }.buttonStyle(AppButtonStyle(size: .small))
        }
        ForEach(suggestions.trending) { item in
          Button { invoke(item.keyword, .global) } label: {
            HStack(spacing: 12) {
              Text("\(item.position)").font(Theme.Font.caption.monospacedDigit()).fontWeight(item.position <= 3 ? .semibold : .regular)
                .foregroundStyle(item.position <= 3 ? Theme.accentText(scheme) : Theme.tertiaryText(scheme)).frame(width: 22)
              if let icon = item.icon { CachedImage(url: icon).frame(width: 16, height: 16) }
              Text(item.title).font(Theme.Font.body).lineLimit(1)
              Spacer()
            }.padding(.horizontal, 10).frame(height: 36)
          }.buttonStyle(SidebarRowStyle())
        }
      }.padding(6).foregroundStyle(Theme.text(scheme))
    }.frame(width: 300).frame(maxHeight: 480)
  }
  private func invoke(_ keyword: String, _ scope: M3SearchScope) {
    guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    text = keyword; showingSuggestions = false; showingHot = false; focused = false
    suggestions.cancel(); submit(keyword, scope)
  }
}
