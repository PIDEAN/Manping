import AppKit
import ManpingCore
import SwiftUI

struct LibraryResults: View {
  @ObservedObject var library: LibraryModel
  @ObservedObject var model: AppModel
  @StateObject private var relations: UserRelationsModel
  var showAllUsers: () -> Void = {}
  init(library: LibraryModel, model: AppModel, showAllUsers: @escaping () -> Void = {}) {
    self.library = library; self.model = model; self.showAllUsers = showAllUsers
    _relations = StateObject(wrappedValue: UserRelationsModel(service: model.service))
  }
  @Environment(\.colorScheme) private var scheme
  private var isEmpty: Bool { library.entries.isEmpty && library.users.isEmpty && library.relatedUsers.isEmpty }
  var body: some View {
    Group {
      if isEmpty && library.isLoading {
        PageStateView(.loading, title: "正在加载…")
      } else if isEmpty, let error = library.error {
        PageStateView(.error, title: "没能加载内容", message: error, icon: "wifi.exclamationmark", actionTitle: "重试") {
          Task { await library.loadNext() }
        }
      } else if isEmpty {
        PageStateView(title: "没有找到内容", message: "换个关键词或筛选条件试试。")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
          if !library.relatedUsers.isEmpty {
            SearchUserStrip(users: library.relatedUsers, relations: relations, model: model, showAll: showAllUsers)
            Hairline()
          }
          if !library.users.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
              ForEach(library.users) { user in
                M3UserCard(user: user, relations: relations, model: model)
              }
            }
          } else if library.entries.allSatisfy({ if case .user = $0.destination { return true }; return false }) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
              ForEach(library.entries) { entry in
                if case .user(let mid) = entry.destination {
                  LibraryUserCard(user: LibraryUser(id: mid, name: entry.title, avatar: entry.cover,
                    signature: entry.subtitle)) { model.openOverlay(.userSpace(mid)) }
                }
              }
            }
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
              ForEach(library.entries) { entry in
                if case .video(let video) = entry.destination {
                  VideoCard(video: video) { model.open(video) }
                    .help(entry.subtitle)
                } else { LibraryEntryCard(entry: entry) { model.open(entry) } }
              }
            }
          }
          }.cardGridContent()
          if let error = library.error {
            PageStateView(.error, title: "没能加载更多", message: error, actionTitle: "重试") {
              Task { await library.loadNext() }
            }
          } else if library.hasMore {
            LoadMoreFooter(isLoading: library.isLoading) { Task { await library.loadNext() } }
          }
        }.cardGrid().performanceScrollProbe(page: "search").padding(Theme.gridPadding)
      }
    }.foregroundStyle(Theme.text(scheme)).onDisappear { relations.cancel() }
  }
}

struct LibraryEntryCard: View {
  let entry: LibraryEntry
  let action: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(action: action) {
        VStack(alignment: .leading, spacing: Theme.cardTitleGap) {
          Color.clear.aspectRatio(16 / 9, contentMode: .fit)
            .overlay { CachedImage(url: entry.cover) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
          Text(entry.title).font(Theme.Font.headline).lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.contentShape(Rectangle())
      }.buttonStyle(CardPressStyle())
      // A video's subtitle starts with its UP 主: that name opens their space.
      if case .video(let video) = entry.destination, !video.author.isEmpty, entry.subtitle.hasPrefix(video.author) {
        CardMetadataLine(author: video.author, authorID: video.authorID,
          rest: String(entry.subtitle.dropFirst(video.author.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ·")),
          action: action)
      } else {
        Button(action: action) {
          Text(entry.subtitle).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
      if case .web = entry.destination {
        Label("在浏览器中打开", systemImage: "arrow.up.right.square").font(Theme.Font.caption)
          .foregroundStyle(Theme.accentText(scheme))
      }
    }.foregroundStyle(Theme.text(scheme)).cardHover().disabled(entry.destination == .unavailable)
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

struct SearchUserStrip: View {
  let users: [LibraryUser]
  @ObservedObject var relations: UserRelationsModel
  @ObservedObject var model: AppModel
  let showAll: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("相关 UP 主").font(Theme.Font.caption.weight(.semibold))
        Spacer()
        Button("查看全部用户 ›", action: showAll).buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accentText(scheme))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(Array(users.prefix(8))) { user in
            HStack(spacing: 10) {
              Button { model.openOverlay(.userSpace(user.id)) } label: {
                HStack(spacing: 10) {
                  CachedImage(url: user.avatar).frame(width: 36, height: 36).clipShape(Circle())
                    .overlay(alignment: .bottom) {
                      if user.isLive { Text("直播中").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).background(Theme.live, in: Capsule()).offset(y: 5) }
                    }
                  VStack(alignment: .leading, spacing: 3) {
                    Text(user.name).font(Theme.Font.headline).lineLimit(1)
                    Text(subtitle(user)).font(Theme.Font.caption2).lineLimit(1)
                      .foregroundStyle(verified(user) ? Theme.highlight : Theme.secondaryText(scheme))
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
              }.buttonStyle(.plain)
              M3UserFollowButton(mid: user.id, relations: relations, model: model, compact: true)
            }.padding(.horizontal, 12).frame(width: 236, height: 60).cardSurface(scheme)
              .task(id: "\(user.id):\(relations.identityVersion)") { await relations.load(mid: user.id) }
          }
        }.padding(.vertical, 2)
      }
    }
  }
  private func verified(_ user: LibraryUser) -> Bool { (user.officialType ?? -1) >= 0 && !(user.officialDescription ?? "").isEmpty }
  private func subtitle(_ user: LibraryUser) -> String {
    if verified(user) { return user.officialDescription ?? "" }
    return "\(user.isUpUser ? "UP 主" : "用户") · \(user.followers.map(String.init) ?? "—") 粉丝"
  }
}
