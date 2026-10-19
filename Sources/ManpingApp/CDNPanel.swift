import ManpingCore
import SwiftUI

/// Dot on the player’s More button while playback runs short of buffer; the button's menu
/// opens the panel (「网络与节点…」). It is the only control-panel view observing the CDN
/// controller, so relay statistics refresh without re-rendering the player page.
struct CDNHealthDot: View {
  @ObservedObject var cdn: CDNController
  var body: some View {
    let health = CDNHealth(bufferAhead: cdn.bufferAhead)
    if cdn.activeHost != nil, health != .smooth {
      Circle().fill(health.color(.dark)).frame(width: 6, height: 6)
        .accessibilityLabel("播放状态：\(health.title)")
    }
  }
}

/// Three-step playback health derived from the forward buffer; the control-bar dot and the panel pill share it.
enum CDNHealth {
  case smooth, tight, stalled

  init(bufferAhead: Double) {
    if bufferAhead <= 0.5 { self = .stalled }
    else { self = bufferAhead < 8 ? .tight : .smooth }
  }

  var title: String {
    switch self {
    case .smooth: "流畅"
    case .tight: "偏紧"
    case .stalled: "卡顿"
    }
  }

  func color(_ scheme: ColorScheme) -> Color {
    switch self {
    case .smooth: Theme.success(scheme)
    case .tight: Theme.warning(scheme)
    case .stalled: Theme.danger(scheme)
    }
  }
}

struct CDNPanel: View {
  #if DEBUG
  /// `--ui-cdn-panel`: opens the panel on launch for screenshot checks (live data only).
  static let debugOpen = DebugUIFixtures.enabled == false && ProcessInfo.processInfo.arguments.contains("--ui-cdn-panel")
  #else
  static let debugOpen = false
  #endif
  @ObservedObject var cdn: CDNController
  let setSetting: (MacSettingKey, Bool) -> Void
  var setProxyRoute: (MediaRoute) -> Void = { _ in }
  @State private var customHost = ""
  @State private var customError = false
  @State private var eventsExpanded = true
  @Environment(\.colorScheme) private var scheme

  private struct Row: Identifiable {
    let id: String
    let label: String
    /// The caption in front of the host: "测速", "自定义" or "经代理".
    let source: String
    let result: CDNBenchmarkResult?
    let live: RelayHostStats?
    let disabled: Bool
    let inPool: Bool
    let custom: Bool
    var proxied: Bool { MediaRelay.isProxyKey(id) }
    var host: String { MediaRelay.hostName(ofKey: id) }
  }

  private var rows: [Row] {
    var keys: [String] = []
    for candidate in cdn.candidates where !keys.contains(candidate.host.name) { keys.append(candidate.host.name) }
    for result in cdn.results where !keys.contains(result.host) { keys.append(result.host) }
    let results = Dictionary(cdn.results.map { ($0.host, $0) }, uniquingKeysWith: { $1 })
    let live = Dictionary(cdn.snapshot.hosts.map { ($0.host, $0) }, uniquingKeysWith: { $1 })
    let candidates = Dictionary(cdn.candidates.map { ($0.host.name, $0) }, uniquingKeysWith: { $1 })
    return keys.map { key in
      Row(id: key, label: cdn.label(MediaRelay.hostName(ofKey: key)),
        source: MediaRelay.isProxyKey(key) ? "经代理" : candidates[key]?.source == .custom ? "自定义" : "测速",
        result: results[key], live: live[key], disabled: candidates[key]?.disabled ?? false,
        inPool: cdn.poolHosts.contains(key) || cdn.proxiedPoolHosts.contains(key) || cdn.activeHost == key,
        custom: candidates[key]?.source == .custom)
    }.sorted { lhs, rhs in
      if lhs.inPool != rhs.inPool { return lhs.inPool }
      return (lhs.result?.ok == true ? lhs.result?.mbps ?? 0 : -1) > (rhs.result?.ok == true ? rhs.result?.mbps ?? 0 : -1)
    }
  }

  private var health: CDNHealth { CDNHealth(bufferAhead: cdn.bufferAhead) }
  private var proxyConfigured: Bool { cdn.proxyStatus != "未配置" }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text("网络与节点").font(Theme.Font.section)
        healthPill
        Spacer()
        if cdn.probing { ProgressView().controlSize(.small) }
        Button("重新测速") { cdn.reprobe() }.buttonStyle(AppButtonStyle(size: .small)).disabled(cdn.probing)
      }
      summary
      switchGroup
      HStack {
        Text("节点").font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(Theme.tertiaryText(scheme))
        Spacer()
        if cdn.manualHost != nil {
          Button("恢复自动") { cdn.select(host: nil) }.buttonStyle(AppButtonStyle(role: .plain, size: .small))
        } else {
          Text("点击只用此节点 · 右键停用").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
        }
      }
      // A ScrollView in a popover has no ideal height; size it to its rows (up to six).
      let nodes = rows
      ScrollView {
        VStack(spacing: 2) { ForEach(nodes) { row in nodeRow(row) } }
      }.frame(height: nodes.isEmpty ? 44 : min(CGFloat(nodes.count) * 48, 6 * 48))
        .overlay { if nodes.isEmpty { Text("播放视频后显示候选节点").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme)) } }
      HStack(spacing: 6) {
        TextField("自定义节点，例如 upos-sz-mirrorhw.bilivideo.com", text: $customHost)
          .textFieldStyle(AppTextFieldStyle(height: Theme.compactControlHeight))
          .onSubmit(addCustom)
        Button("添加", action: addCustom).buttonStyle(AppButtonStyle(role: .primary, size: .small))
          .disabled(customHost.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if customError { InlineErrorText(message: "只接受 *.bilivideo.com 主机名，不要带协议、端口或路径。") }
      if !cdn.events.isEmpty { eventsSection }
    }.padding(16).frame(width: 400).foregroundStyle(Theme.text(scheme))
      // Danmaku keep moving under the panel; a near-opaque surface keeps the small host names
      // legible over bright lines.
      .presentationBackground(Theme.panel(scheme).opacity(0.97))
      // AppKit focuses the first text field of a new popover; nobody opens this to type a host.
      .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
  }

  private var healthPill: some View {
    let color = health.color(scheme)
    return HStack(spacing: 5) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(health.title).font(Theme.Font.caption2.weight(.semibold))
    }.foregroundStyle(color).padding(.horizontal, 8).frame(height: 20)
      .background(color.opacity(0.16), in: Capsule())
      .accessibilityElement(children: .combine).accessibilityLabel("播放状态：\(health.title)")
  }

  private var summary: some View {
    HStack(spacing: 0) {
      metric("前向缓冲", String(format: "%.0f 秒", cdn.bufferAhead))
      Hairline(axis: .vertical).frame(height: 30)
      metric("实时速度", cdn.snapshot.combinedMbps > 0 ? String(format: "%.1f Mbps", cdn.snapshot.combinedMbps) : "—")
      Hairline(axis: .vertical).frame(height: 30)
      metric("直连 + 代理", "\(cdn.poolHosts.count) + \(cdn.proxiedPoolHosts.count)")
      Hairline(axis: .vertical).frame(height: 30)
      metric("卡顿", "\(cdn.stalls) 次")
    }.padding(.vertical, 8).cardSurface(scheme)
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(spacing: 2) {
      Text(value).font(Theme.Font.section.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
      Text(title).font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
    }.frame(maxWidth: .infinity)
  }

  /// The three switches and the proxy concurrency control, grouped in one rounded block.
  private var switchGroup: some View {
    VStack(spacing: 0) {
      toggleRow("自动优选节点", key: .cdnAuto, value: cdn.settings.auto)
      Hairline()
      toggleRow("多节点同时缓冲", key: .cdnMultiSource, value: cdn.settings.multiSource)
      Hairline()
      toggleRow("卡顿时自动重新优选", key: .cdnStallRecovery, value: cdn.settings.stallRecovery)
      Hairline()
      proxyRow
    }.background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
  }

  /// Whether proxied CDN routes join from the start or after a stall.
  private var proxyRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "shield").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accentText(scheme))
        Text("代理 / VPN 并发").font(Theme.Font.headline)
        Spacer(minLength: 8)
        Text(proxyConfigured && cdn.proxyActive ? "\(cdn.proxyStatus) · 本次已启用" : cdn.proxyStatus)
          .font(Theme.Font.caption2).lineLimit(1)
          .foregroundStyle(proxyConfigured && cdn.proxyActive ? Theme.success(scheme) : Theme.tertiaryText(scheme))
      }
      SegmentedTabs(options: MediaRoute.allCases.map { ($0, $0.shortTitle) },
        selection: Binding(get: { cdn.mediaRoute }, set: { setProxyRoute($0) }))
        .disabled(!proxyConfigured).opacity(proxyConfigured ? 1 : 0.5)
      if !proxyConfigured {
        Text("在 设置 › 网络 › 代理 中配置").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
      }
    }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
  }

  private func toggleRow(_ title: String, key: MacSettingKey, value: Bool) -> some View {
    HStack {
      Text(title).font(Theme.Font.body)
      Spacer()
      Toggle(title, isOn: Binding(get: { value }, set: { setSetting(key, $0) }))
        .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
    }.padding(.horizontal, 12).frame(height: 36)
  }

  /// The last three events, collapsible; open by default.
  private var eventsSection: some View {
    DisclosureGroup(isExpanded: $eventsExpanded) {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(cdn.events.suffix(3)) { event in
          HStack(alignment: .top, spacing: 6) {
            Text(event.at.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(Theme.tertiaryText(scheme))
            Text(event.text).foregroundStyle(Theme.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true)
          }
        }
      }.font(Theme.Font.caption2).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    } label: {
      Text("最近事件").font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(Theme.tertiaryText(scheme))
    }
  }

  private func nodeRow(_ row: Row) -> some View {
    let selected = cdn.manualHost == row.id
    return Button { if !row.disabled, !row.proxied { cdn.select(host: selected ? nil : row.id) } } label: {
      HStack(spacing: 8) {
        Circle().fill(statusColor(row)).frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 5) {
            Text(row.label).font(Theme.Font.body).lineLimit(1)
            if row.proxied { proxyTag }
            if row.inPool { tag("在用") }
            if selected { tag("手动") }
            if row.disabled { tag("已停用") }
            if row.live?.coolingDown == true { tag("冷却中") }
          }
          Text("\(row.source) · \(row.host)").font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme)).lineLimit(1)
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 1) {
          if let live = row.live, live.recentMbps > 0 {
            Text(String(format: "%.1f Mbps", live.recentMbps)).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.accentText(scheme))
          } else if let result = row.result {
            Text(result.ok ? String(format: "%.1f Mbps", result.mbps) : (result.error ?? "失败"))
              .font(Theme.Font.caption.monospacedDigit())
              .foregroundStyle(result.ok ? Theme.text(scheme) : Theme.danger(scheme))
          } else {
            Text("未测速").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
          }
          if let result = row.result, result.ok {
            Text(String(format: "首包 %.0f ms", result.ttfbMs)).font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
          }
        }
      }.padding(.horizontal, 8).padding(.vertical, 6).opacity(row.disabled ? 0.55 : 1)
    }.buttonStyle(SidebarRowStyle(selected: selected))
      .contextMenu {
        Button(selected ? "取消手动选择" : "只使用此节点") { cdn.select(host: selected ? nil : row.id) }.disabled(row.disabled || row.proxied)
        if CDNHost(row.id) != nil {
          Button(row.disabled ? "启用节点" : "停用节点") { cdn.setDisabled(row.id, !row.disabled) }
        }
        if row.custom { Button("移除自定义节点", role: .destructive) { cdn.removeCustom(row.id) } }
      }
      .help("点击只使用此节点；右键可停用")
  }

  private func tag(_ text: String) -> some View {
    Text(text).font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(Theme.text(scheme))
      .padding(.horizontal, 5).frame(height: 15).background(Theme.fillPressed(scheme), in: Capsule())
  }

  /// Marks a route that goes through the proxy / VPN tunnel.
  private var proxyTag: some View {
    HStack(spacing: 3) {
      Image(systemName: "shield").font(.system(size: 8, weight: .bold))
      Text("代理")
    }.font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(Theme.accentText(scheme))
      .padding(.horizontal, 5).frame(height: 15).background(Theme.selectedFill(scheme), in: Capsule())
  }

  private func statusColor(_ row: Row) -> Color {
    if row.disabled { return Theme.tertiaryText(scheme) }
    if row.live?.coolingDown == true { return Theme.warning(scheme) }
    guard let result = row.result else { return Theme.tertiaryText(scheme) }
    return result.ok ? Theme.success(scheme) : Theme.danger(scheme)
  }

  private func addCustom() {
    customError = !cdn.addCustom(customHost)
    if !customError { customHost = "" }
  }
}
