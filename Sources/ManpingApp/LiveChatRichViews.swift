import ManpingCore
import SwiftUI

struct LiveRichChatRow: View {
  let line: LiveChatLine
  var reply: (LiveDanmakuReply) -> Void
  @State private var hovered = false
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    row.padding(.vertical, 3)
      .padding(.horizontal, line.isOwn ? 7 : 0)
      .background(
        line.isOwn ? Theme.selectedFill(scheme) : .clear,
        in: RoundedRectangle(cornerRadius: Theme.Radius.sm)
      )
      .overlay(alignment: .leading) {
        if line.isOwn { Capsule().fill(Theme.accent).frame(width: 2).padding(.vertical, 3) }
      }
      .overlay(alignment: .topTrailing) {
        if hovered, let target = line.replyTarget {
          Button("回复") { reply(target) }.font(Theme.Font.caption2).buttonStyle(.plain)
            .padding(4).background(Theme.card(scheme), in: Capsule())
        }
      }
      .onHover { hovered = $0 }
      .onAppear {
        #if DEBUG
          if DebugUIFixtures.liveScene == "reply-hover", line.danmakuID == "fixture-dm-8" {
            hovered = true
          }
        #endif
      }
      .contextMenu {
        if let target = line.replyTarget { Button("回复 @\(target.name)") { reply(target) } }
      }
  }
  @ViewBuilder private var row: some View {
    switch line.kind {
    case .notice:
      Text(line.text).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    case .guardPurchase(let level):
      HStack(spacing: 9) {
        Image(systemName: "shield.fill").foregroundStyle(guardColor(level)).font(.system(size: 22))
        VStack(alignment: .leading, spacing: 4) {
          Text(line.user).font(Theme.Font.headline)
          Text(line.text).font(Theme.Font.caption)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(
          guardColor(level).opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    case .superChat(let price):
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("醒目留言 · \(line.user)").lineLimit(1)
          Spacer()
          Text("¥\(price)").monospacedDigit()
        }.font(Theme.Font.headline)
        Text(line.text).font(Theme.Font.body).fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }.padding(12).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
        .background(superChatColor(price), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    case .gift:
      HStack(alignment: .top, spacing: 5) {
        Image(systemName: "gift.fill").foregroundStyle(Theme.highlight)
        VStack(alignment: .leading, spacing: 3) {
          Text(line.user + " " + line.text).font(Theme.Font.caption).fixedSize(
            horizontal: false, vertical: true)
          if let gift = line.gift, gift.coinType == "gold" {
            Text(gift.hasKnownTotal ? "价值 \(LiveMoney.batteries(gift.totalCoin)) 电池" : "价值未知").font(
              Theme.Font.caption2
            )
            .foregroundStyle(Theme.warning(scheme))
          }
        }
      }
    case .danmaku:
      VStack(alignment: .leading, spacing: 4) {
        InlineEmoteText(
          text: line.roomEmote["url"].string == nil ? line.text : "",
          emotes: line.inlineEmotes,
          liveHeader: LiveInlineHeader(
            medal: line.medal, guardLevel: line.guardLevel, user: line.user, own: line.isOwn,
            reply: line.reply["reply_uname"].string ?? line.reply["uname"].string))
        if let url = line.roomEmote["url"].string.flatMap(URL.init(string:)) {
          CachedImage(url: url).frame(width: 120, height: 76).accessibilityLabel(line.text)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct LiveMedalBadge: View {
  let medal: LiveMedal
  var body: some View {
    HStack(spacing: 3) {
      Text(medal.name).lineLimit(1)
      Text("\(medal.level)").bold().padding(.horizontal, 3).background(
        .white.opacity(0.22), in: Capsule())
    }.font(.system(size: 9)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
      .background(
        LinearGradient(
          colors: medal.lighted
            ? [liveColor(medal.startColor), liveColor(medal.endColor)] : [.gray, .gray],
          startPoint: .leading, endPoint: .trailing), in: Capsule()
      )
      .overlay(
        Capsule().strokeBorder(medal.lighted ? liveColor(medal.borderColor) : .gray, lineWidth: 0.5)
      )
      .help(medal.lighted ? medal.anchorName : "未点亮")
  }
}

struct LiveSuperChatStrip: View {
  @ObservedObject var interaction: LiveInteractionModel
  @State private var selected: LiveSuperChat?
  var body: some View {
    if !interaction.superChats.isEmpty {
      TimelineView(.periodic(from: .now, by: 1)) { time in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 7) {
            ForEach(
              interaction.superChats.filter { Double($0.endTime) > time.date.timeIntervalSince1970 }
            ) { message in
              Button {
                selected = message
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  HStack {
                    Text("¥\(message.price)").bold()
                    Spacer()
                    Text(remaining(message, now: time.date)).monospacedDigit()
                  }
                  Text(message.user).lineLimit(1)
                  GeometryReader { geometry in
                    Capsule().fill(.white.opacity(0.28)).overlay(alignment: .leading) {
                      Capsule().fill(.white.opacity(0.85)).frame(
                        width: geometry.size.width * progress(message, now: time.date))
                    }
                  }.frame(height: 2)
                }.font(Theme.Font.caption2).foregroundStyle(.white).padding(9).frame(width: 112)
                  .background(
                    superChatColor(message.price),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
              }.buttonStyle(.plain).help("查看醒目留言全文")
            }
          }.padding(.horizontal, 12).padding(.vertical, 8)
        }
      }
      .popover(item: $selected) { message in
        VStack(alignment: .leading, spacing: 10) {
          Text("醒目留言 · \(message.user) · ¥\(message.price)").font(Theme.Font.headline)
          Text(message.text).font(Theme.Font.body).textSelection(.enabled).fixedSize(
            horizontal: false, vertical: true)
        }.padding(18).frame(width: 320)
      }
      .onChange(of: interaction.superChats.map(\.id)) { _, ids in
        if let selected, !ids.contains(selected.id) { self.selected = nil }
        #if DEBUG
          if DebugUIFixtures.liveScene == "sc-fulltext", selected == nil {
            selected = interaction.superChats.first
          }
        #endif
      }
      .onAppear {
        #if DEBUG
          if DebugUIFixtures.liveScene == "sc-fulltext" { selected = interaction.superChats.first }
        #endif
      }
      .onChange(of: selected?.id) { _, value in interaction.detailShown = value != nil }
      .onDisappear { interaction.detailShown = false }
    }
  }
  private func progress(_ message: LiveSuperChat, now: Date) -> Double {
    let duration = Double(message.endTime) - Double(message.startTime)
    return duration > 0
      ? min(1, max(0, (Double(message.endTime) - now.timeIntervalSince1970) / duration)) : 0
  }
  private func remaining(_ message: LiveSuperChat, now: Date) -> String {
    let seconds = max(0, Int(Double(message.endTime) - now.timeIntervalSince1970))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

func guardName(_ level: Int64) -> String { level == 1 ? "总督" : level == 2 ? "提督" : "舰长" }
func guardColor(_ level: Int64) -> Color {
  level == 1 ? liveColor(0xffb13b) : level == 2 ? liveColor(0x8d5cd8) : liveColor(0x3e6fd8)
}
func superChatColor(_ price: Int) -> Color {
  liveColor(price >= 100 ? 0xa67525 : price >= 50 ? 0x286987 : 0x2f5aa8)
}
