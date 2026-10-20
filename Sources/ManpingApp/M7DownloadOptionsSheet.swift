import AppKit
import ManpingCore
import SwiftUI

/// Groups follow DownloadButton's Quality / BatchDownload / Extra flyout at UI 896a062.
struct M7DownloadOptionsSheet: View {
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  @State private var quality = 80
  @State private var codec = DownloadCodec.avc
  @State private var content = DownloadContent.video
  @State private var allPages = false
  @State private var selectedPages = "1"
  @State private var directory = ""
  @State private var includeDanmaku = false
  @State private var filterAISubtitle = true
  @State private var initialized = false
  @State private var validationError: String?
  @State private var subtitleTracks: [DownloadSubtitleTrack] = []
  @State private var subtitleID = ""
  @State private var subtitleError: String?
  private var availableTracks: [DownloadSubtitleTrack] { DownloadSubtitleTrack.filtered(subtitleTracks, filterAI: filterAISubtitle) }
  private var aid: Int64? { model.pgcPlayback?.episode?.aid ?? model.selected?.aid }
  private var manifest: PlaybackManifest? { model.pgcPlayback?.manifest ?? model.manifest }
  private var qualities: [(id: Int, title: String)] {
    var result: [(id: Int, title: String)] = []
    for format in manifest?.formats ?? [] where !result.contains(where: { $0.id == format.quality }) {
      result.append((format.quality, format.description))
    }
    for stream in manifest?.video ?? [] where !result.contains(where: { $0.id == stream.quality }) {
      result.append((stream.quality, stream.label))
    }
    return result.sorted { $0.id > $1.id }
  }
  private var pageCount: Int {
    if let pgc = model.pgcPlayback { return max(1, pgc.details?.episodes.count ?? 1) }
    return max(1, model.videoDetails?.parts.count ?? 1)
  }
  private var currentPage: Int {
    if let pgc = model.pgcPlayback, let index = pgc.details?.episodes.firstIndex(where: { $0.id == pgc.episode?.id }) { return index + 1 }
    return model.videoDetails?.parts.first(where: { $0.cid == model.selected?.cid })?.page ?? 1
  }
  private var title: String { model.pgcPlayback?.episode?.title ?? model.selected?.title ?? "下载选项" }
  private var cid: Int64? { model.pgcPlayback?.episode?.cid ?? model.selected?.cid }
  private var cover: URL? { model.pgcPlayback?.episode?.cover ?? model.selected?.cover }
  private var canSave: Bool {
    switch content {
    case .video: return !(manifest?.video.isEmpty ?? true)
    case .audio: return !(manifest?.audio.isEmpty ?? true)
    case .cover: return cover != nil
    case .danmaku: return cid != nil
    case .subtitle: return availableTracks.contains { $0.id == subtitleID }
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "下载选项", symbol: "arrow.down.circle") {
        Button { model.showingDownloadOptions = false } label: { Image(systemName: "xmark") }
          .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).help("关闭")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(title).font(Theme.Font.headline).lineLimit(2)
          section("画质") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
              ForEach(qualities, id: \.id) { value in
                choice(value.title, selected: quality == value.id) { quality = value.id }
              }
            }
            if qualities.isEmpty { unavailable("当前没有可用的视频流") }
            HStack(spacing: 6) {
              ForEach(DownloadCodec.allCases, id: \.self) { value in
                choice(value.title, selected: codec == value) { codec = value }
              }
            }
          }
          if pageCount > 1 {
            section("批量下载") {
              HStack(spacing: 8) {
                choice("下载所有分集（\(pageCount)）", selected: allPages) { allPages = true }
                choice("选择分集下载", selected: !allPages) { allPages = false }
              }
              if !allPages {
                HStack(spacing: 10) {
                  Text("分集序号").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
                  TextField("例如 1,3,5-8", text: $selectedPages, prompt: Text("例如 1,3,5-8")).labelsHidden().textFieldStyle(AppTextFieldStyle())
                }
              }
              if content != .video { unavailable("批量选择用于视频下载；其他内容导出当前分集。") }
            }
          }
          section("其他") {
            HStack(spacing: 6) {
              ForEach(DownloadContent.allCases, id: \.self) { value in
                choice(value == .video ? "视频" : value.title, selected: content == value) { content = value }
              }
            }
            if content == .video { check("同时下载弹幕", value: $includeDanmaku) }
            if content == .subtitle {
              check("过滤 AI 字幕", value: $filterAISubtitle)
              HStack(spacing: 6) {
                ForEach(availableTracks) { track in
                  choice(track.title + (track.isAI ? " · AI" : ""), selected: subtitleID == track.id) { subtitleID = track.id }
                }
              }
              if availableTracks.isEmpty { unavailable(subtitleError ?? "当前没有可用的字幕；可拷贝 BBDown 命令由外部工具获取。") }
            } else if !canSave {
              unavailable(content == .audio ? "当前没有可用的音频流" : content == .cover ? "当前没有封面地址" : "当前没有可下载的弹幕")
            }
          }
          section("保存位置") {
            HStack(spacing: 10) {
              Text(directory.isEmpty ? "请选择文件夹" : directory).font(Theme.Font.caption)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
              Button { chooseDirectory() } label: { Label("选择…", systemImage: "folder") }
                .buttonStyle(AppButtonStyle(size: .small))
            }
          }
          if let validationError { InlineErrorText(message: validationError) }
        }.padding(Theme.gridPadding)
      }
      Hairline()
      HStack(spacing: 10) {
        Button { execute(copy: true) } label: { Label("拷贝 BBDown 命令", systemImage: "doc.on.doc") }
          .buttonStyle(AppButtonStyle(role: .plain))
        Spacer()
        Button("取消") { model.showingDownloadOptions = false }.buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
        Button(content == .video || content == .audio ? "开始下载" : "保存") { execute(copy: false) }
          .buttonStyle(AppButtonStyle(role: .primary)).keyboardShortcut(.defaultAction).disabled(!canSave)
      }.padding(.horizontal, Theme.gridPadding).padding(.vertical, 14)
    }.frame(width: 760, height: 620).foregroundStyle(Theme.text(scheme))
      .onAppear { initialize() }
      .task(id: cid) { await loadSubtitles() }
      .onChange(of: filterAISubtitle) { _, _ in
        if !availableTracks.contains(where: { $0.id == subtitleID }) { subtitleID = availableTracks.first?.id ?? "" }
      }
  }
  private func section<Content: View>(_ title: String, @ViewBuilder body: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(Theme.tertiaryText(scheme)).padding(.horizontal, 4)
      VStack(alignment: .leading, spacing: 10) { body() }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).cardSurface(scheme)
    }
  }
  private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(title, action: action).buttonStyle(ChipStyle(selected: selected))
  }
  private func check(_ title: String, value: Binding<Bool>) -> some View {
    Toggle(title, isOn: value).toggleStyle(.checkbox).font(Theme.Font.body)
  }
  private func unavailable(_ message: String) -> some View {
    Text(message).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
  }
  private func initialize() {
    guard !initialized else { return }; initialized = true
    let settings = MacSettings.load(from: PerformanceEnvironment.defaults)
    directory = model.usesUIFixtures ? "/tmp/Bili Downloads" : settings.text(.downloadDirectory)
    if directory.isEmpty {
      directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Bili Downloads").path ?? ""
    }
    codec = settings.text(.codec) == "hevc" ? .hevc : settings.text(.codec) == "av1" ? .av1 : .avc
    includeDanmaku = settings.bool(.downloadDanmaku); filterAISubtitle = settings.bool(.filterAISubtitle)
    quality = model.pgcPlayback?.selectedStream?.quality ?? model.selectedStream?.quality ?? qualities.first?.id ?? 80
    selectedPages = String(currentPage)
  }
  private func chooseDirectory() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.canCreateDirectories = true; panel.prompt = "选择下载文件夹"
    if !directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory) }
    panel.begin { response in
      MainActor.assumeIsolated { if response == .OK, let url = panel.url { directory = url.path } }
    }
  }
  private func loadSubtitles() async {
    subtitleTracks = []; subtitleID = ""; subtitleError = nil
    guard let aid, let cid else { return }
    let snapshot = await model.service.authSnapshot()
    do {
      let tracks = try await model.service.downloadSubtitleTracks(aid: aid, cid: cid, expectedIdentity: snapshot)
      try Task.checkCancellation()
      let current = await model.service.authSnapshot()
      guard !Task.isCancelled, current.epoch == snapshot.epoch, current.identityRevision == snapshot.identityRevision else { return }
      subtitleTracks = tracks; subtitleID = availableTracks.first?.id ?? ""
    } catch is CancellationError {} catch { if !Task.isCancelled { subtitleError = error.localizedDescription } }
  }
  private func execute(copy: Bool) {
    validationError = nil
    do {
      guard copy || canSave else { return }
      guard !directory.isEmpty else { throw BiliError.invalidResponse("请选择下载文件夹") }
      let pages = content == .video && pageCount > 1 && !allPages
        ? try DownloadOptions.parsePages(selectedPages, count: pageCount) : [currentPage]
      let options = DownloadOptions(cid: cid, episodeID: model.pgcPlayback?.episode?.id,
        quality: quality, codec: codec, content: content, pages: pages,
        allPages: content == .video && pageCount > 1 && allPages, directory: directory,
        includeDanmaku: includeDanmaku, filterAISubtitle: filterAISubtitle,
        subtitleID: content == .subtitle ? subtitleID : nil,
        subtitleLanguage: content == .subtitle ? availableTracks.first(where: { $0.id == subtitleID })?.language : nil)
      if copy { model.copyDownloadCommand(options: options) }
      else { model.startDownload(options: options) }
    } catch { validationError = error.localizedDescription }
  }
}
