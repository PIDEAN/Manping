import AppKit
import ManpingCore
import SwiftUI

struct LibraryResults: View {
  @ObservedObject var library: LibraryModel
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Group {
      if library.entries.isEmpty && library.users.isEmpty && library.isLoading {
        PageStateView(.loading, title: "正在加载…")
      } else if library.entries.isEmpty && library.users.isEmpty, let error = library.error {
        PageStateView(.error, title: "没能加载内容", message: error, icon: "wifi.exclamationmark", actionTitle: "重试") {
          Task { await library.loadNext() }
        }
      } else if library.entries.isEmpty && library.users.isEmpty {
        PageStateView(title: "没有找到内容", message: "换个关键词或筛选条件试试。")
      } else {
        ScrollView {
          if !library.users.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
              ForEach(library.users) { user in
                LibraryUserCard(user: user) { model.openOverlay(.userSpace(user.id)) }
              }
            }.cardGridContent()
          } else if library.entries.allSatisfy({ if case .user = $0.destination { return true }; return false }) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
              ForEach(library.entries) { entry in
                if case .user(let mid) = entry.destination {
                  LibraryUserCard(user: LibraryUser(id: mid, name: entry.title, avatar: entry.cover,
                    signature: entry.subtitle)) { model.openOverlay(.userSpace(mid)) }
                }
              }
            }.cardGridContent()
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
              ForEach(library.entries) { entry in
                if case .video(let video) = entry.destination {
                  VideoCard(video: video) { model.open(video) }
                    .help(entry.subtitle)
                } else { LibraryEntryCard(entry: entry) { model.open(entry) } }
              }
            }.cardGridContent()
          }
          if let error = library.error {
            PageStateView(.error, title: "没能加载更多", message: error, actionTitle: "重试") {
              Task { await library.loadNext() }
            }
          } else if library.hasMore {
            LoadMoreFooter(isLoading: library.isLoading) { Task { await library.loadNext() } }
          }
        }.cardGrid().performanceScrollProbe(page: "search").padding(Theme.gridPadding)
      }
    }.foregroundStyle(Theme.text(scheme))
  }
}

struct LibraryEntryCard: View {
  let entry: LibraryEntry
  let action: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: Theme.cardTitleGap) {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
          .overlay { CachedImage(url: entry.cover) }
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.title).font(Theme.Font.headline).lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .topLeading)
          Text(entry.subtitle).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
          if case .web = entry.destination {
            Label("在浏览器中打开", systemImage: "arrow.up.right.square").font(Theme.Font.caption)
              .foregroundStyle(Theme.accentText(scheme))
          }
        }
      }.foregroundStyle(Theme.text(scheme)).contentShape(Rectangle()).cardHover()
    }.buttonStyle(CardPressStyle()).disabled(entry.destination == .unavailable)
  }
}

struct LibraryUserCard: View {
  let user: LibraryUser
  let action: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 12) {
        CachedImage(url: user.avatar).frame(width: 44, height: 44).clipShape(Circle())
          .overlay(Circle().strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
        VStack(alignment: .leading, spacing: 4) {
          Text(user.name).font(Theme.Font.headline).lineLimit(1)
          Text(user.signature.isEmpty ? "UID \(user.id)" : user.signature)
            .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.padding(12)
        .frame(minWidth: 220, minHeight: 72, alignment: .leading)
        .foregroundStyle(Theme.text(scheme)).cardSurface(scheme).cardHover(outset: 0, radius: Theme.Radius.md)
    }.buttonStyle(CardPressStyle())
  }
}
