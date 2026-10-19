import ManpingCore
import SwiftUI

struct M3FollowingPage: View {
  @ObservedObject var model: AppModel
  let mid: Int64
  @StateObject private var library: LibraryModel
  @StateObject private var relations: UserRelationsModel
  @State private var groupID: Int64?
  @AppStorage("m3FollowingSidebarHidden") private var sidebarHidden = false
  @AppStorage("m3FollowingSidebarWidth") private var storedWidth = Double(Theme.secondarySidebarWidth)
  private var sidebarWidth: CGFloat { min(400, max(180, CGFloat(storedWidth))) }
  @Environment(\.colorScheme) private var scheme

  init(model: AppModel, mid: Int64) {
    self.model = model; self.mid = mid
    _library = StateObject(wrappedValue: LibraryModel(model: model))
    _relations = StateObject(wrappedValue: UserRelationsModel(service: model.service))
    _groupID = State(initialValue: M3FollowSelection.read(mid: mid))
  }
  var body: some View {
    HStack(spacing: 0) {
      if !sidebarHidden {
        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 2) {
              SidebarSectionTitle(title: "关注分组")
              ForEach(library.groups) { group in
                Button {
                  groupID = group.id; M3FollowSelection.save(group.id, mid: mid)
                } label: {
                  HStack(spacing: 8) {
                    Text(group.title).font(Theme.Font.body).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(group.count)").font(Theme.Font.caption2.monospacedDigit())
                      .foregroundStyle(Theme.tertiaryText(scheme))
                  }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
                }.buttonStyle(SidebarRowStyle(selected: library.selectionID == group.id))
              }
            }.padding(.horizontal, 10).padding(.bottom, 12)
          }
        }.frame(width: sidebarWidth).transition(.move(edge: .leading).combined(with: .opacity))
        SidebarResizeHandle(width: $storedWidth, range: 180...400)
      }
      VStack(spacing: 0) {
        M3UserResults(library: library, relations: relations, model: model, emptyText: "这个分组还没有关注的人")
      }
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: mid == model.accountMID ? "我的关注" : "关注",
        subtitle: library.groups.first(where: { $0.id == library.selectionID })?.title,
        refresh: { Task { await library.refresh() } }) {
        SidebarToggleButton(hidden: $sidebarHidden)
      }
      .task(id: "\(mid):\(groupID.map(String.init) ?? "default"):\(model.refreshToken):\(library.identityVersion)") {
        await library.load(.following(mid, groupID ?? M3FollowSelection.read(mid: mid)))
        if let selected = library.selectionID { M3FollowSelection.save(selected, mid: mid) }
      }
      .onChange(of: mid) { _, value in groupID = M3FollowSelection.read(mid: value) }
      .onDisappear { library.cancel(); relations.cancel() }
  }
}

struct M3FollowersPage: View {
  @ObservedObject var model: AppModel
  let mid: Int64
  @StateObject private var library: LibraryModel
  @StateObject private var relations: UserRelationsModel
  init(model: AppModel, mid: Int64) {
    self.model = model; self.mid = mid
    _library = StateObject(wrappedValue: LibraryModel(model: model))
    _relations = StateObject(wrappedValue: UserRelationsModel(service: model.service))
  }
  var body: some View {
    VStack(spacing: 0) {
      M3UserResults(library: library, relations: relations, model: model, emptyText: "还没有粉丝")
    }
      .pageToolbar(title: mid == model.accountMID ? "我的粉丝" : "粉丝", subtitle: "\(library.total) 位粉丝",
        refresh: { Task { await library.refresh() } })
      .task(id: "\(mid):\(model.refreshToken)") { await library.load(.followers(mid)) }
      .onDisappear { library.cancel(); relations.cancel() }
  }
}

private enum M3FollowSelection {
  static func read(mid: Int64) -> Int64? {
    let key = "following.selectedGroup.\(mid)"
    guard let value = UserDefaults.standard.object(forKey: key) as? NSNumber else { return nil }
    return value.int64Value
  }
  static func save(_ group: Int64, mid: Int64) {
    UserDefaults.standard.set(group, forKey: "following.selectedGroup.\(mid)")
  }
}


struct M3UserResults: View {
  @ObservedObject var library: LibraryModel
  @ObservedObject var relations: UserRelationsModel
  @ObservedObject var model: AppModel
  let emptyText: String
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Group {
      if library.users.isEmpty && library.isLoading {
        PageStateView(.loading, title: "正在加载用户…")
      } else if library.users.isEmpty, let error = library.error {
        PageStateView(.error, title: "没能加载用户", message: error, icon: "wifi.exclamationmark", actionTitle: "重试") {
          Task { await library.loadNext() }
        }
      } else if library.users.isEmpty {
        PageStateView(title: emptyText, message: "稍后刷新试试。", icon: "person.2")
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
            ForEach(library.users) { user in
              M3UserCard(user: user, relations: relations, model: model)
            }
          }.padding(Theme.gridPadding)
          if let error = library.error {
            PageStateView(.error, title: "没能加载更多用户", message: error, actionTitle: "重试") {
              Task { await library.loadNext() }
            }
          } else if library.hasMore {
            LoadMoreFooter(isLoading: library.isLoading) { Task { await library.loadNext() } }
          }
        }
      }
    }.foregroundStyle(Theme.text(scheme)).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct M3UserCard: View {
  let user: LibraryUser
  @ObservedObject var relations: UserRelationsModel
  @ObservedObject var model: AppModel
  @ObservedObject private var pins = PinnedUserStore.shared
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Button { model.openOverlay(.userSpace(user.id)) } label: {
        CachedImage(url: user.avatar).frame(width: 44, height: 44).clipShape(Circle())
          .overlay(Circle().strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
      }.buttonStyle(.plain)
      VStack(alignment: .leading, spacing: 4) {
        Button { model.openOverlay(.userSpace(user.id)) } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(user.name).font(Theme.Font.headline).lineLimit(1)
            Text(user.signature.isEmpty ? "UP 主空间" : user.signature).font(Theme.Font.caption)
              .foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        HStack(spacing: 6) {
          Text(String(user.id)).font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
            .textSelection(.enabled).lineLimit(1)
          Spacer(minLength: 0)
          Button { pins.toggle(user) } label: {
            Image(systemName: pins.contains(user.id) ? "pin.fill" : "pin").font(.system(size: 10))
              .frame(width: 24, height: 24)
          }.buttonStyle(ChromeButtonStyle(selected: pins.contains(user.id), icon: true, capsule: true)).help(pins.contains(user.id) ? "从账号菜单取消固定" : "固定到账号菜单")
          M3UserFollowButton(mid: user.id, relations: relations, model: model, compact: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(12)
      .frame(minWidth: 220, maxWidth: .infinity, minHeight: 80, maxHeight: 80, alignment: .leading)
      .foregroundStyle(Theme.text(scheme)).cardSurface(scheme)
      .task(id: "\(user.id):\(relations.identityVersion)") { await relations.load(mid: user.id) }
      .contextMenu {
        Button("进入 UP 主空间") { model.openOverlay(.userSpace(user.id)) }
        Button(pins.contains(user.id) ? "从账号菜单取消固定" : "固定到账号菜单") { pins.toggle(user) }
        Button("刷新关注状态") { relations.refresh(mid: user.id) }
      }
  }
}

/// The compact heart is a small chrome capsule in a card; the 36 pt one in the toolbar is a glass circle.
private struct FollowButtonStyle: ViewModifier {
  let compact: Bool
  let followed: Bool
  func body(content: Content) -> some View {
    if compact { content.buttonStyle(ChromeButtonStyle(selected: followed, icon: true, capsule: true)) }
    else { content.toolbarIconStyle() }
  }
}

struct M3UserFollowButton: View {
  @Environment(\.colorScheme) private var scheme
  let mid: Int64
  @ObservedObject var relations: UserRelationsModel
  @ObservedObject var model: AppModel
  var compact = false
  private var followed: Bool { relations.relations[mid]?.isFollowing == true }
  var body: some View {
    Button { Task { await relations.toggle(mid: mid) { model.showingLogin = true } } } label: {
      Group {
        if relations.busy.contains(mid) { ProgressView().controlSize(.mini) }
        else if compact { Image(systemName: followed ? "heart.fill" : "heart").font(.system(size: 10)) }
        else { ToolbarIcon(followed ? "heart.fill" : "heart").foregroundStyle(followed ? Theme.accentText(scheme) : Theme.text(scheme)) }
      }.frame(width: compact ? 24 : nil, height: compact ? 24 : nil)
    }.modifier(FollowButtonStyle(compact: compact, followed: followed))
      .disabled(!relations.canToggle(mid))
      .help(relations.errors[mid] ?? (mid == relations.selfID ? "当前账号" :
        relations.relations[mid]?.isFollowing == nil ? "关注状态尚未确认；可在菜单刷新" : followed ? "取消关注" : "关注"))
  }
}
