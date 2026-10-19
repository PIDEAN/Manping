import AppKit
import ManpingCore
import SwiftUI

struct M6MessagePage: View {
  @ObservedObject var model: AppModel
  let onUser: (Int64) -> Void
  let onVideo: (String) -> Void
  @StateObject private var messages: MessagesModel
  @State private var section: MessageSection = .reply
  @State private var appliedDiagnostic = false
  @Environment(\.colorScheme) private var scheme
  init(model: AppModel, onUser: @escaping (Int64) -> Void, onVideo: @escaping (String) -> Void) {
    self.model = model; self.onUser = onUser; self.onVideo = onVideo
    _messages = StateObject(wrappedValue: MessagesModel(service: model.service))
  }
  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Hairline(axis: .vertical)
      VStack(spacing: 0) {
        if case .partialFailure(let message) = messages.markReadState {
          InlineErrorText(message: message).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.gridPadding).padding(.vertical, 12)
        }
        if let error = messages.error {
          HStack(spacing: 12) {
            InlineErrorText(message: error)
            Spacer()
            if error.contains("登录") {
              Button("登录") { model.showingLogin = true }.buttonStyle(AppButtonStyle(role: .primary, size: .small))
            }
          }.padding(.horizontal, Theme.gridPadding).padding(.vertical, 10).background(Theme.danger(scheme).opacity(0.08))
        }
        if section == .chat { M6ConversationPage(messages: messages) }
        else { notificationList }
      }
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: "消息", subtitle: section == .chat ? messages.selected?.user.name ?? "私信" : section.title,
        refreshing: messages.loading, refresh: { Task { await messages.start(section) } }) {
        Button {
          messages.markAllRead(onStart: { model.beginMessageReadOperation() },
            onProgress: { model.updateMessageReadOperation($0, unread: $1) },
            onFinish: { model.finishMessageReadOperation($0, result: $1) })
        } label: {
          if case .running(let completed) = messages.markReadState {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在标记 \(completed)/4") }
          } else {
            Label { Text("全部已读") } icon: {
              ZStack {
                Image(systemName: "checkmark").offset(x: -3)
                Image(systemName: "checkmark").offset(x: 3)
              }.frame(width: 24)
            }
          }
        }.toolbarActionStyle()
          .disabled(!model.messageUnreadCounts.canMarkAllRead(isRunning: messages.markReadState.isRunning,
            needsRetry: messages.markReadState.needsRetry))
          .help("标记回复、@、点赞与私信；执行期间新到的私信仍保留未读")
        if section == .chat, let selected = messages.selected {
          Button { onUser(selected.id) } label: { Label("进入 UP 主空间", systemImage: "person") }
            .toolbarActionStyle()
        }
      }
      .onAppear { applyDiagnostic(); model.refreshMessageUnreadCounts() }
      .task(id: "\(section.rawValue):\(model.refreshToken)") { await messages.start(section) }
      .onDisappear { messages.cancel() }
  }
  private var sidebar: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 2) {
          SidebarSectionTitle(title: "消息类型")
          ForEach(MessageSection.allCases, id: \.self) { item in
            Button { section = item } label: {
              HStack(spacing: 8) {
                Image(systemName: symbol(item)).font(.system(size: 13)).frame(width: 18)
                Text(item.title).font(Theme.Font.body)
                Spacer()
                if let count = model.messageUnreadCounts[item], count > 0 { UnreadBadge(count: Int(clamping: count)) }
              }.padding(.horizontal, 10).frame(height: Theme.rowHeight)
            }.buttonStyle(SidebarRowStyle(selected: section == item))
          }
          if section == .chat {
            SidebarSectionTitle(title: "会话")
            ForEach(messages.sessions) { session in
              Button { Task { await messages.select(session) } } label: {
                HStack(spacing: 10) {
                  CachedImage(url: session.user.avatar).frame(width: 32, height: 32).clipShape(Circle())
                  VStack(alignment: .leading, spacing: 4) {
                    HStack {
                      Text(session.user.name).font(Theme.Font.body).lineLimit(1)
                      Spacer(minLength: 4)
                      if session.unread > 0 {
                        UnreadBadge(count: Int(session.unread))
                      }
                    }
                    Text(session.lastMessage.kind == .image ? "[图片]" : session.lastMessage.kind == .withdrawn ? "消息已撤回" : session.lastMessage.text)
                      .font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
                  }
                }.padding(.horizontal, 10).padding(.vertical, 7)
              }.buttonStyle(SidebarRowStyle(selected: messages.selected?.id == session.id))
            }
            if messages.hasMore && messages.error == nil {
              Color.clear.frame(height: 1).task(id: messages.sessions.count) { await messages.loadNext() }
            }
          }
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }
      if messages.loading { ProgressView().controlSize(.small).padding(12) }
    }.frame(width: Theme.secondarySidebarWidth)
  }
  private var notificationList: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        if messages.notifications.isEmpty && !messages.loading && messages.error == nil {
          PageStateView(title: "消息是空的", message: "新的\(section.title)会显示在这里。", icon: symbol(section)).frame(minHeight: 360)
        }
        ForEach(messages.notifications) { item in
          M6NotificationCard(item: item, onUser: onUser) { open(item) }
        }
        if messages.loading { ProgressView().padding(16) }
        if messages.hasMore && messages.error == nil {
          Color.clear.frame(height: 1).task(id: messages.notifications.count) { await messages.loadNext() }
        }
      }.padding(Theme.gridPadding).frame(maxWidth: 820).frame(maxWidth: .infinity)
    }
  }
  private func open(_ item: NotifyMessage) {
    guard let url = item.sourceURL else { return }
    if let bvid = url.pathComponents.first(where: { $0.hasPrefix("BV") }), url.host == "www.bilibili.com" {
      onVideo(bvid)
    } else { NSWorkspace.shared.open(url) }
  }
  private func symbol(_ item: MessageSection) -> String {
    switch item { case .reply: "arrowshape.turn.up.left"; case .at: "at"; case .like: "hand.thumbsup"; case .chat: "bubble.left.and.bubble.right" }
  }
  private func applyDiagnostic() {
    guard !appliedDiagnostic else { return }; appliedDiagnostic = true
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    if args.contains("--ui-fixture"), let state = ProcessInfo.processInfo.environment["MANPING_UI_MESSAGE_STATE"] {
      messages.applyMarkReadFixture(state)
    }
    if let index = args.firstIndex(of: "--ui-page"), index + 1 < args.count,
      let value = args[index + 1].split(separator: ":").dropFirst().first,
      let item = MessageSection(rawValue: String(value)) { section = item }
    #endif
  }
}

private struct M6NotificationCard: View {
  let item: NotifyMessage
  let onUser: (Int64) -> Void
  let onOpen: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if let user = item.users.first {
          Button { onUser(user.id) } label: {
            HStack(spacing: 8) {
              CachedImage(url: user.avatar).frame(width: 32, height: 32).clipShape(Circle())
              Text(user.name).font(Theme.Font.headline)
            }
          }.buttonStyle(.plain)
          if item.users.count > 1 { Text("等 \(max(Int64(item.users.count), item.count)) 人").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)) }
        }
        Spacer()
        Text(Date(timeIntervalSince1970: Double(item.timestamp)), style: .relative)
          .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      }
      if item.section == .like {
        Text("赞了你的\(item.business)").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      } else if !item.text.isEmpty { Text(item.text).font(Theme.Font.body).lineLimit(6).textSelection(.enabled) }
      if !item.source.isEmpty {
        Button(action: onOpen) {
          Text(item.source).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
            .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }.buttonStyle(.plain).disabled(item.sourceURL == nil)
      }
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(scheme)
  }
}
