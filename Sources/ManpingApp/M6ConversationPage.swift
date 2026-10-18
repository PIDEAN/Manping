import ManpingCore
import SwiftUI

struct M6ConversationPage: View {
  @ObservedObject var messages: MessagesModel
  @Environment(\.colorScheme) private var scheme
  @State private var emojiPanel = false
  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 8) {
            if messages.selected == nil && !messages.loading {
              PageStateView(title: "选择一位联系人", message: "从左侧会话列表打开私信。", icon: "bubble.left.and.bubble.right").frame(minHeight: 360)
            }
            if messages.selected != nil && messages.hasOlder {
              Button { Task { await messages.loadOlder() } } label: {
                Text(messages.conversationLoading ? "正在加载…" : "加载更早消息")
              }.buttonStyle(AppButtonStyle(role: .plain, size: .small)).disabled(messages.conversationLoading)
            }
            ForEach(messages.messages) { message in
              bubble(message).id(message.id)
            }
          }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
        }.onChange(of: messages.selected?.id) { _, _ in
          if let last = messages.messages.last { reader.scrollTo(last.id, anchor: .bottom) }
        }.onChange(of: messages.messages.last?.id) { _, value in
          if let value { reader.scrollTo(value, anchor: .bottom) }
        }
      }
      if let error = messages.conversationError { InlineErrorText(message: error).padding(8) }
      if messages.selected != nil { composer }
    }
  }
  private func bubble(_ item: ConversationMessage) -> some View {
    let mine = item.senderID == messages.ownID
    return HStack {
      if mine { Spacer(minLength: 80) }
      VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
        Group {
          switch item.kind {
          case .image: CachedImage(url: item.image).frame(width: 220, height: 160).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
          case .withdrawn: Text("消息已撤回").font(Theme.Font.caption).foregroundStyle(Theme.disabledText(scheme))
          // Original ChatMessageItemViewModel shows NotSupportContent for every other msg_type.
          case .unsupported: Text("不受支持的内容").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
          case .text:
            if item.emotes.isEmpty {
              Text(item.text).font(Theme.Font.body).textSelection(.enabled)
            } else {
              // Own bubbles sit on the accent fill with dark text in both themes.
              InlineEmoteText(text: item.text, emotes: item.emotes)
                .environment(\.colorScheme, mine ? .light : scheme)
            }
          }
        }.padding(.horizontal, 12).padding(.vertical, 8)
          .foregroundStyle(mine && item.kind != .withdrawn ? Theme.onAccent : Theme.text(scheme))
          .background(mine && item.kind != .withdrawn ? Theme.accent : Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(mine ? .clear : Theme.separator(scheme), lineWidth: 0.5))
        if item.kind != .withdrawn {
          Text(Date(timeIntervalSince1970: Double(item.timestamp)).formatted(.dateTime.month().day().hour().minute()))
            .font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
        }
      }
      if !mine { Spacer(minLength: 80) }
    }
  }
  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      Button { emojiPanel.toggle() } label: { Image(systemName: "face.smiling") }
        .buttonStyle(AppButtonStyle(role: .plain, iconOnly: true)).help("表情")
        .popover(isPresented: $emojiPanel) {
          LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 6), spacing: 8) {
            ForEach(["😀", "😊", "🥰", "😭", "👍", "🎉", "[doge]", "[妙啊]", "[笑哭]", "[点赞]", "[爱心]", "[打call]"], id: \.self) { emoji in
              Button(emoji) { messages.draft += emoji; emojiPanel = false }
                .buttonStyle(ChromeButtonStyle()).frame(width: 40, height: 36)
            }
          }.padding(12)
        }
      TextField("发送私信…", text: $messages.draft, axis: .vertical)
        .textFieldStyle(.plain).font(Theme.Font.body).lineLimit(1...5).padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minHeight: 32).background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
      Button { Task { await messages.send() } } label: {
        Image(systemName: "paperplane.fill")
      }.buttonStyle(AppButtonStyle(role: .primary, iconOnly: true))
        .disabled(messages.sending || messages.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help("发送")
    }.padding(.horizontal, Theme.gridPadding).padding(.vertical, 12).overlay(alignment: .top) { Hairline() }.disabled(messages.sending)
  }
}
