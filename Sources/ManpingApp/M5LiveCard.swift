import AppKit
import ManpingCore
import SwiftUI

// Cover badges follow the live design: 直播中 top-left, partition bottom-left, viewers bottom-right.
// Tapping a card goes through `play` (which honours 「直播间在浏览器打开」); the context menu can
// always force the in-app player (`watch`) or the web page.
struct M5LiveCard: View {
  let room: LiveRoom
  var recommendation = true
  var play: ((Int64) -> Void)?
  /// Always plays in the app, whatever the browser setting says. Falls back to `play`.
  var watch: ((Int64) -> Void)?
  let openUser: (Int64) -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: Theme.cardTitleGap) {
      Button { openRoom() } label: {
        // A 16:9 box sized by the grid cell, like VideoCard; no GeometryReader per card.
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
          .overlay { CachedImage(url: room.cover) }
          .overlay(alignment: .topLeading) { LiveBadge(status: .live).padding(8) }
          .overlay(alignment: .bottomLeading) {
            if !room.subtitle.isEmpty { MediaBadge(text: room.subtitle).lineLimit(1).padding(8) }
          }
          .overlay(alignment: .bottomTrailing) {
            if let viewers = room.viewers { MediaBadge(text: Self.viewerText(viewers), systemImage: "person.fill").padding(8).help("观看人数") }
          }
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
      }.buttonStyle(.plain).accessibilityLabel("打开直播间：\(room.title)")
        .demoAnchor("live.\(room.id)")
      HStack(alignment: .top, spacing: 10) {
        if room.avatar != nil || !recommendation {
          Button { if let mid = room.authorID, mid > 0 { openUser(mid) } } label: {
            CachedImage(url: room.avatar).frame(width: 32, height: 32).clipShape(Circle())
          }.buttonStyle(.plain).disabled((room.authorID ?? 0) <= 0).help(room.author)
        }
        Button { openRoom() } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(room.title).font(Theme.Font.headline).foregroundStyle(Theme.text(scheme))
              .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .topLeading)
            Text(room.author).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
    }.cardHover()
      .contextMenu { LiveRoomMenu(room: room, play: watch ?? play, openUser: openUser) }
  }
  static func viewerText(_ viewers: Double) -> String {
    viewers >= 100_000_000 ? String(format: "%.1f 亿", viewers / 100_000_000) :
      viewers >= 10_000 ? String(format: "%.1f 万", viewers / 10_000) : String(format: "%.0f", viewers)
  }
  private func openRoom() {
    if let play { play(room.id) } else { openWeb() }
  }
  private func openWeb() {
    if let url = room.webURL { NSWorkspace.shared.open(url) }
  }
}

/// The live room context menu: 进入直播间 / 小窗播放 — 拷贝链接 / 在浏览器中打开 —
/// 进入主播空间 / 固定到菜单栏. `play` always plays in the app.
private struct LiveRoomMenu: View {
  let room: LiveRoom
  let play: ((Int64) -> Void)?
  let openUser: ((Int64) -> Void)?
  @ObservedObject private var pins = PinnedLiveStore.shared
  @Environment(\.cardActions) private var actions
  var body: some View {
    Button("进入直播间") { play?(room.id) }.disabled(play == nil)
    if let actions { Button("小窗播放") { actions.playLiveCompact(room.id) } }
    Divider()
    Button("拷贝链接") { if let url = room.webURL { CardActions.copy(url) } }.disabled(room.webURL == nil)
    Button("在浏览器中打开") { if let url = room.webURL { NSWorkspace.shared.open(url) } }.disabled(room.webURL == nil)
    Divider()
    if let openUser, let mid = room.authorID, mid > 0 { Button("进入主播空间") { openUser(mid) } }
    Button(pins.contains(room.id) ? "从菜单栏取消固定" : "固定到菜单栏") { pins.toggle(room) }
  }
}

struct M5FollowLiveRow: View {
  let room: LiveRoom
  var play: ((Int64) -> Void)?
  /// Always plays in the app, whatever the browser setting says. Falls back to `play`.
  var watch: ((Int64) -> Void)?
  @ObservedObject private var pins = PinnedLiveStore.shared
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Button { if let play { play(room.id) } else { openWeb() } } label: {
      HStack(spacing: 12) {
        CachedImage(url: room.avatar).frame(width: 40, height: 40).clipShape(Circle())
        VStack(alignment: .leading, spacing: 4) {
          Text(room.author).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
          Text(room.title).font(Theme.Font.body).foregroundStyle(Theme.text(scheme)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.padding(.horizontal, 10).padding(.vertical, 8)
    }.buttonStyle(SidebarRowStyle())
      .contextMenu { LiveRoomMenu(room: room, play: watch ?? play, openUser: nil) }
  }
  private func openWeb() {
    if let url = room.webURL { NSWorkspace.shared.open(url) }
  }
}
