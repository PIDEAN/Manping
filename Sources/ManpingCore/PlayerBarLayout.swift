import Foundation

/// One control the viewer can put on the right side of the player's control bar (设置 › 控制条).
/// The left group (播放、下一个、时间、弹幕开关、弹幕输入框) and 「更多」 on the far right are fixed
/// and never listed here.
public enum PlayerBarItem: String, CaseIterable, Codable, Sendable {
  case quality, speed, subtitle, volume, danmakuSettings, screenshot, network, enhance, audioOnly, download
  case mini, detached, fullscreen

  /// The name in the bar's hover bubble, the 「更多」 menu and VoiceOver.
  public var title: String {
    switch self {
    case .quality: "画质"
    case .speed: "倍速"
    case .subtitle: "字幕"
    case .volume: "音量"
    case .danmakuSettings: "弹幕设置"
    case .screenshot: "截取画面"
    case .network: "网络与节点"
    case .enhance: "画面增强"
    case .audioOnly: "只听声音"
    case .download: "下载"
    case .mini: "小窗"
    case .detached: "独立窗口"
    case .fullscreen: "全屏"
    }
  }

  /// One line under the name in 「可添加的项目」.
  public var note: String {
    switch self {
    case .quality: "切换清晰度与编码"
    case .speed: "0.5× – 3.0×"
    case .subtitle: "选择或关闭字幕"
    case .volume: "调节音量与静音"
    case .danmakuSettings: "字号、区域与屏蔽"
    case .screenshot: "保存当前画面"
    case .network: "测速与切换节点"
    case .enhance: "超分与锐化着色器"
    case .audioOnly: "关掉画面更省电"
    case .download: "下载视频与弹幕"
    case .mini: "悬浮小窗继续看"
    case .detached: "在独立窗口播放"
    case .fullscreen: "进入或退出全屏幕"
    }
  }

  /// SF Symbol for the item. 弹幕设置 draws the app's danmaku mark with a gear instead.
  public var symbol: String {
    switch self {
    case .quality: "4k.tv"
    case .speed: "gauge.with.dots.needle.67percent"
    case .subtitle: "captions.bubble"
    case .volume: "speaker.wave.2"
    case .danmakuSettings: "slider.horizontal.below.square.and.square.filled"
    case .screenshot: "camera"
    case .network: "antenna.radiowaves.left.and.right"
    case .enhance: "sparkles"
    case .audioOnly: "headphones"
    case .download: "arrow.down.circle"
    case .mini: "pip.enter"
    case .detached: "macwindow.on.rectangle"
    case .fullscreen: "arrow.up.left.and.arrow.down.right"
    }
  }
}

/// Where a dragged item lands on the bar (indices into the full item list).
public enum PlayerBarDrop: Equatable, Sendable {
  /// Between two items: the item goes in at this index.
  case insert(Int)
  /// On an item: from the bar the two swap places, from 「可添加的项目」 it takes the place.
  case replace(Int)
  /// Dragged off the bar.
  case remove
}

/// What fits the panel's row: the comment field first shrinks to a 「发弹幕」 button, then the
/// right group folds into 「更多」 from its leftmost item, so the rightmost item stays longest.
public struct PlayerBarFit: Equatable, Sendable {
  public let visible: [PlayerBarItem]
  public let hidden: [PlayerBarItem]
  public let compactInput: Bool
  /// Index in the laid-out list of the first visible item (= number hidden).
  public var firstVisible: Int { hidden.count }
}

public enum PlayerBarLayout {
  public static let storageKey = "Manping.playerBarItems"
  public static let defaultItems: [PlayerBarItem] = [.quality, .speed, .subtitle, .volume, .mini, .fullscreen]

  // MARK: Persistence

  /// Stored ids → items: nil (never customised, or not a string list) gives the defaults;
  /// unknown ids and repeats are dropped. An empty list is a real choice and stays empty.
  public static func decode(_ stored: Any?) -> [PlayerBarItem] {
    guard let raw = stored as? [String] else { return defaultItems }
    var seen = Set<PlayerBarItem>()
    return raw.compactMap(PlayerBarItem.init(rawValue:)).filter { seen.insert($0).inserted }
  }

  public static func encode(_ items: [PlayerBarItem]) -> [String] { items.map(\.rawValue) }

  // MARK: Editing

  /// The list after dropping `item` at `drop`. An item already on the bar moves; one from
  /// 「可添加的项目」 is added (and, on `replace`, the item it lands on goes back to the list).
  public static func applying(_ drop: PlayerBarDrop, item: PlayerBarItem, to items: [PlayerBarItem]) -> [PlayerBarItem] {
    var result = items
    let from = result.firstIndex(of: item)
    switch drop {
    case .remove:
      if let from { result.remove(at: from) }
    case .replace(let index):
      guard result.indices.contains(index) else { return result }
      let victim = result[index]
      guard victim != item else { return result }
      if let from { result.swapAt(from, index) } else { result[index] = item }
    case .insert(var index):
      index = min(max(0, index), result.count)
      if let from {
        result.remove(at: from)
        if from < index { index -= 1 }
      }
      result.insert(item, at: index)
    }
    return result
  }

  /// 左移 / 右移 from the keyboard and context menus; no change at either end.
  public static func moving(_ item: PlayerBarItem, by offset: Int, in items: [PlayerBarItem]) -> [PlayerBarItem] {
    guard let from = items.firstIndex(of: item) else { return items }
    let to = from + offset
    guard items.indices.contains(to) else { return items }
    var result = items
    result.swapAt(from, to)
    return result
  }

  /// 添加到控制条: at the right end, unless it is already there.
  public static func adding(_ item: PlayerBarItem, to items: [PlayerBarItem]) -> [PlayerBarItem] {
    items.contains(item) ? items : items + [item]
  }

  // MARK: Folding

  /// Nominal widths of the panel's controls, shared by the player and the settings preview.
  public struct Metrics: Equatable, Sendable {
    /// Spacing between controls in the row.
    public var gap: Double = 6
    /// 「更多」.
    public var moreWidth: Double = 32
    /// The comment field at a comfortable width, and the 「发弹幕」 button it shrinks to.
    public var inputWidth: Double = 180
    public var compactInputWidth: Double = 32
    /// The spacer between the left group and the right group never gets narrower than this.
    public var spacerMinimum: Double = 6
    public init() {}

    public func width(of item: PlayerBarItem) -> Double {
      switch item {
      case .quality: 72
      case .speed: 50
      default: 32
      }
    }
  }

  /// Which items fit a row `rowWidth` wide whose fixed left group (without the comment field) is
  /// `leadingWidth`. `hasInput` is false where there is no comment field (live rooms).
  ///
  /// The row is laid out as `[leading] [input] [spacer] [item]… [更多]` with `gap` between
  /// neighbours, so the right group needs `width + gap` per item.
  public static func fit(_ items: [PlayerBarItem], rowWidth: Double, leadingWidth: Double, hasInput: Bool,
    metrics: Metrics = Metrics(), width: ((PlayerBarItem) -> Double)? = nil) -> PlayerBarFit {
    let widthOf = width ?? metrics.width(of:)
    func room(input: Double?) -> Double {
      rowWidth - leadingWidth - (input.map { metrics.gap + $0 } ?? 0)
        - metrics.gap - metrics.spacerMinimum - metrics.gap - metrics.moreWidth
    }
    let needed = items.reduce(0) { $0 + widthOf($1) + metrics.gap }
    if hasInput, needed <= room(input: metrics.inputWidth) + 0.5 {
      return PlayerBarFit(visible: items, hidden: [], compactInput: false)
    }
    let available = room(input: hasInput ? metrics.compactInputWidth : nil)
    var used = 0.0
    var first = items.count
    for index in items.indices.reversed() {
      let need = widthOf(items[index]) + metrics.gap
      if used + need > available + 0.5 { break }
      used += need
      first = index
    }
    return PlayerBarFit(visible: Array(items[first...]), hidden: Array(items[..<first]), compactInput: hasInput)
  }
}
