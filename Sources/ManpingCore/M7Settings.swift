import CoreFoundation
import Foundation

/// The nine categories of the settings window, in sidebar order.
public enum MacSettingGroup: String, CaseIterable, Sendable {
  case general = "通用", playback = "播放", danmaku = "弹幕", network = "网络", download = "下载与截图"
  case notifications = "通知", privacy = "隐私", ai = "AI", advanced = "高级"
}
/// Retired keys (Windows-only renderer switches and the old top navigation toggle) are no
/// longer cases here and are never read; values already saved under their UserDefaults keys
/// stay where they are. See `MacSettingsCatalog.retiredKeys`.
public enum MacSettingKey: String, CaseIterable, Sendable {
  case theme = "appTheme", codec = "preferredCodec", quality = "preferredVideoQuality", avoidP2P = "playWithoutP2P"
  case stepForward = "Manping.stepForward", stepBackward = "Manping.stepBackward", temporarySpeed = "Manping.temporarySpeed"
  case globalSpeed = "Manping.globalSpeed", bottomProgress = "Manping.bottomProgress", speed = "Manping.playbackSpeed"
  case reportProgress = "Manping.reportProgress", spotlightIndex = "Manping.spotlightIndex", autoSkipClips = "Manping.autoSkipClips"
  case liveText = "Manping.liveText"
  case volume = "Manping.defaultVolume", danmakuEnabled = "Manping.danmakuEnabled", danmakuFontSize = "Manping.danmakuFontSize"
  case danmakuOpacity = "Manping.danmakuOpacity", danmakuSpeed = "Manping.danmakuSpeed", screenshotFormat = "Manping.screenshotFormat"
  case hideMainOnPlay = "Manping.hideMainOnPlay", integratedPlayer = "Manping.integratedPlayer", decode = "Manping.decode"
  case displayMode = "Manping.displayMode", skipNextPrompt = "Manping.skipNextPrompt", autoNextRelated = "Manping.autoNextRelated"
  case endWithPlaylist = "Manping.endWithPlaylist", liveWebPlayer = "Manping.liveWebPlayer"
  case autoLoadHistory = "autoLoadHistory"
  case customMpv = "Manping.customMpv", customLibMpv = "Manping.customLibMpv"
  case audioExclusive = "Manping.audioExclusive", audioChannels = "Manping.audioChannels", mpvProfile = "Manping.mpvProfile"
  case preciseSeek = "Manping.preciseSeek", cacheMB = "Manping.cacheMB", backCacheMB = "Manping.backCacheMB"
  case cacheSeconds = "Manping.cacheSeconds", diskCache = "Manping.diskCache", diskCacheDirectory = "Manping.diskCacheDirectory"
  case maxVolume = "Manping.maxVolume", screenshotDirectory = "Manping.screenshotDirectory", screenshotAction = "Manping.screenshotAction"
  case downloadDirectory = "Manping.downloadDirectory", downloadDanmaku = "Manping.downloadDanmaku"
  case filterAISubtitle = "Manping.filterAISubtitle", openDownloadFolder = "Manping.openDownloadFolder"
  case externalBBDown = "Manping.externalBBDown", copyDownloadCommand = "Manping.copyDownloadCommand", bbdownPath = "Manping.bbdownPath"
  case navPopular = "Manping.navPopular", navMoment = "Manping.navMoment"
  case navVideo = "Manping.navVideo", navLive = "Manping.navLive", navAnime = "Manping.navAnime", navCinema = "Manping.navCinema", navArticle = "Manping.navArticle"
  case scrollAcceleration = "Manping.scrollAcceleration", searchSuggestions = "Manping.searchSuggestions"
  case notifications = "Manping.notifications", momentNotifications = "Manping.momentNotifications", logLevel = "Manping.mpvLogLevel"
  case liveNotifications = "Manping.liveNotifications", dockBadge = "Manping.dockBadge", menuBarItem = "Manping.menuBarItem"
  case cdnAuto = "Manping.cdnAuto", cdnMultiSource = "Manping.cdnMultiSource", cdnStallRecovery = "Manping.cdnStallRecovery"
  case cdnRefresh = "Manping.cdnRefresh", smartCache = "Manping.smartCache", adaptiveQuality = "Manping.adaptiveQuality"
}
public enum MacSettingValue: Sendable, Equatable { case bool(Bool), number(Double), text(String) }
public enum MacSettingControl: Sendable {
  case toggle, choice([MacSettingChoice]), number(ClosedRange<Double>, step: Double), directory, executable
}
public struct MacSettingChoice: Sendable {
  public let value: MacSettingValue
  public let title: String
  public init(_ value: MacSettingValue, _ title: String) { self.value = value; self.title = title }
}
public struct MacSettingDescriptor: Identifiable, Sendable {
  public var id: MacSettingKey { key }
  public let key: MacSettingKey
  public let group: MacSettingGroup
  /// The titled section inside the group (one `Form` section in the settings window).
  public let section: String
  public let title: String
  /// One sentence ending with 。 that says what happens; may be empty.
  public let detail: String
  public let control: MacSettingControl
  public let defaultValue: MacSettingValue
  /// Fixed platform constraints cannot be overridden by an application capability declaration.
  public let unavailableReason: String?
  init(_ key: MacSettingKey, _ group: MacSettingGroup, _ section: String, _ title: String, _ detail: String = "",
    _ control: MacSettingControl, _ defaultValue: MacSettingValue, unavailable: String? = nil) {
    self.key = key; self.group = group; self.section = section; self.title = title; self.detail = detail
    self.control = control; self.defaultValue = defaultValue; unavailableReason = unavailable
  }
}
/// 「打开视频时」: one choice in the settings window, stored in the two original keys
/// (`integratedPlayer` and `displayMode`) so the saved values keep their meaning.
public enum MacOpenMode: String, CaseIterable, Sendable {
  case mainWindow, fullScreen, compact, detached
  public var title: String {
    switch self {
    case .mainWindow: "在主窗口"
    case .fullScreen: "全屏"
    case .compact: "小窗"
    case .detached: "独立窗口"
    }
  }
  public init(_ settings: MacSettings) {
    if !settings.bool(.integratedPlayer) { self = .detached; return }
    switch settings.text(.displayMode) {
    case "fullscreen": self = .fullScreen
    case "compact": self = .compact
    default: self = .mainWindow
    }
  }
  /// The values this choice writes to the two underlying keys.
  public var values: [(MacSettingKey, MacSettingValue)] {
    switch self {
    case .mainWindow: [(.integratedPlayer, .bool(true)), (.displayMode, .text("default"))]
    case .fullScreen: [(.integratedPlayer, .bool(true)), (.displayMode, .text("fullscreen"))]
    case .compact: [(.integratedPlayer, .bool(true)), (.displayMode, .text("compact"))]
    case .detached: [(.integratedPlayer, .bool(false)), (.displayMode, .text("default"))]
    }
  }
}
public enum MacSettingsCatalog {
  private static func options(_ values: [(String, String)]) -> MacSettingControl {
    .choice(values.map { MacSettingChoice(.text($0.0), $0.1) })
  }
  /// UserDefaults keys of removed settings. They are never read and never deleted, so values
  /// saved by an older build stay intact.
  public static let retiredKeys: Set<String> = [
    "Manping.d3d11", "Manping.d3d12", "Manping.nvdec", "Manping.vulkan", "Manping.topNavigation",
  ]
  /// Shown together as the single 「打开视频时」 choice (`MacOpenMode`) instead of two rows.
  public static let openModeKeys: Set<MacSettingKey> = [.integratedPlayer, .displayMode]
  public static let descriptors: [MacSettingDescriptor] = [
    // 通用
    .init(.theme, .general, "外观", "外观", "", options([("跟随系统", "跟随系统"), ("浅色", "浅色"), ("深色", "深色")]), .text("跟随系统")),
    .init(.navPopular, .general, "侧边栏项目", "首页", "", .toggle, .bool(true)),
    .init(.navVideo, .general, "侧边栏项目", "分区", "", .toggle, .bool(true)),
    .init(.navLive, .general, "侧边栏项目", "直播", "", .toggle, .bool(true)),
    .init(.navAnime, .general, "侧边栏项目", "番剧", "", .toggle, .bool(true)),
    .init(.navCinema, .general, "侧边栏项目", "影视", "", .toggle, .bool(true)),
    .init(.navArticle, .general, "侧边栏项目", "专栏", "", .toggle, .bool(true)),
    .init(.navMoment, .general, "侧边栏项目", "动态", "", .toggle, .bool(true)),
    .init(.searchSuggestions, .general, "搜索建议", "显示搜索建议", "在搜索框下方列出热搜和输入补全。", .toggle, .bool(false)),
    .init(.scrollAcceleration, .general, "滚动加速", "滚动加速", "连续转动鼠标滚轮时滚得更快，触控板和惯性滚动不受影响。", .toggle, .bool(true)),
    // 播放
    .init(.quality, .playback, "画质与编码", "首选画质", "视频没有这一档时选用最接近的画质。", .choice([MacSettingChoice(.number(0), "自动（沿用上次）"), MacSettingChoice(.number(127), "最高画质"), MacSettingChoice(.number(120), "4K 优先"), MacSettingChoice(.number(80), "1080P 优先"), MacSettingChoice(.number(64), "720P")]), .number(0)),
    .init(.codec, .playback, "画质与编码", "首选编码", "视频提供这种编码时优先使用它。", options([("h264", "H.264"), ("hevc", "HEVC"), ("av1", "AV1")]), .text("h264")),
    .init(.stepForward, .playback, "进度与倍速", "快进时长（秒）", "按右方向键时前进的秒数。", .number(1...600, step: 1), .number(30)),
    .init(.stepBackward, .playback, "进度与倍速", "快退时长（秒）", "按左方向键时后退的秒数。", .number(1...600, step: 1), .number(10)),
    .init(.temporarySpeed, .playback, "进度与倍速", "长按倍速", "在画面上按住时临时加速，松开后恢复原速。", .number(1.1...4, step: 0.1), .number(3)),
    .init(.globalSpeed, .playback, "进度与倍速", "记住倍速", "之后打开的视频都使用默认倍速。", .toggle, .bool(true)),
    .init(.speed, .playback, "进度与倍速", "默认倍速", "开启「记住倍速」后生效。", .number(0.25...4, step: 0.25), .number(1)),
    .init(.bottomProgress, .playback, "进度与倍速", "控件隐藏时显示细进度条", "播放控件隐藏后，画面底边保留一条进度。", .toggle, .bool(true)),
    .init(.volume, .playback, "进度与倍速", "默认音量", "新打开的视频从这个音量开始。", .number(0...100, step: 5), .number(80)),
    .init(.skipNextPrompt, .playback, "连续播放", "直接播放下一个", "不显示 8 秒倒计时提示。", .toggle, .bool(false)),
    .init(.autoNextRelated, .playback, "连续播放", "列表播完后播放相关推荐", "当前列表结束后继续播放推荐视频。", .toggle, .bool(false)),
    .init(.endWithPlaylist, .playback, "连续播放", "列表播完后停止", "不进入列表之外的推荐视频。", .toggle, .bool(true)),
    .init(.integratedPlayer, .playback, "打开方式", "在主窗口中播放", "关闭后视频在独立窗口中播放。", .toggle, .bool(true)),
    .init(.displayMode, .playback, "打开方式", "播放显示模式", "打开视频时窗口的样子。", options([("default", "默认"), ("fullscreen", "全屏"), ("compact", "小窗")]), .text("default")),
    .init(.hideMainOnPlay, .playback, "打开方式", "在独立窗口播放时隐藏主窗口", "视频移到独立窗口后，主窗口自动收起。", .toggle, .bool(true)),
    .init(.liveWebPlayer, .playback, "打开方式", "在浏览器中打开直播间", "点按直播卡片时打开哔哩哔哩网页，而不是在满屏中播放。", .toggle, .bool(false)),
    .init(.autoSkipClips, .playback, "番剧", "自动跳过片头片尾", "标注了片头片尾的番剧直接跳过；关闭时显示「跳过」按钮。", .toggle, .bool(false)),
    .init(.autoLoadHistory, .playback, "番剧", "从上次看到的位置继续", "打开番剧和影视时从账号记录的进度开始播放。", .toggle, .bool(true)),
    // 弹幕
    .init(.danmakuFontSize, .danmaku, "外观", "字号", "", .number(12...48, step: 1), .number(24)),
    .init(.danmakuOpacity, .danmaku, "外观", "不透明度", "只改变文字，描边保持清晰。", .number(0.2...1, step: 0.05), .number(0.9)),
    .init(.danmakuSpeed, .danmaku, "外观", "速度", "数值越大，弹幕越快划过画面。", .number(0.5...2, step: 0.1), .number(1)),
    .init(.danmakuEnabled, .danmaku, "默认显示", "打开视频时显示弹幕", "播放时随时可以用 ⇧⌘D 切换。", .toggle, .bool(true)),
    // 网络
    .init(.cdnAuto, .network, "节点优选", "自动选择最快的节点", "播放前测速候选节点并选用最快的一个，结果按网络记住。", .toggle, .bool(true)),
    .init(.cdnRefresh, .network, "节点优选", "重新测速", "测速结果的有效期，切换网络时总会重新测速。", options([("frequent", "频繁（30 分钟）"), ("balanced", "平衡（90 分钟）"), ("economy", "较少（6 小时）")]), .text("balanced")),
    .init(.cdnStallRecovery, .network, "节点优选", "卡顿时换节点", "缓冲不足或画面卡住时，自动换到其他测速通过的节点。", .toggle, .bool(true)),
    .init(.avoidP2P, .network, "节点优选", "不使用 P2P 节点", "只从普通节点加载视频。", .toggle, .bool(false)),
    .init(.cdnMultiSource, .network, "缓冲", "多节点同时缓冲", "把视频分成小段，从多个节点同时下载并互为备份。", .toggle, .bool(true)),
    .init(.smartCache, .network, "缓冲", "智能缓冲", "按码率和最近的卡顿自动调整预读时长与缓存大小。", .toggle, .bool(true)),
    .init(.adaptiveQuality, .network, "缓冲", "网络较差时降低画质", "多次卡顿且带宽低于当前码率时，自动降低一档画质。", .toggle, .bool(true)),
    // 下载与截图
    .init(.downloadDirectory, .download, "下载", "下载位置", "", .directory, .text("")),
    .init(.downloadDanmaku, .download, "下载", "同时下载弹幕", "随视频保存一份 XML 弹幕文件。", .toggle, .bool(false)),
    .init(.filterAISubtitle, .download, "下载", "隐藏 AI 字幕", "下载和选择字幕时不列出 AI 生成的字幕。", .toggle, .bool(true)),
    .init(.openDownloadFolder, .download, "下载", "下载完成后在 Finder 中显示", "", .toggle, .bool(true)),
    .init(.externalBBDown, .download, "BBDown", "使用 BBDown 下载", "下载时生成 BBDown 命令由你自行运行，满屏不会执行它。", .toggle, .bool(false)),
    .init(.copyDownloadCommand, .download, "BBDown", "只拷贝下载命令", "点按「下载」时把命令拷贝到剪贴板，不开始下载。", .toggle, .bool(false)),
    .init(.bbdownPath, .download, "BBDown", "BBDown 位置", "生成命令时使用的程序，选择文件不会运行它。", .executable, .text("BBDown")),
    .init(.screenshotDirectory, .download, "截图", "截图位置", "", .directory, .text("")),
    .init(.screenshotFormat, .download, "截图", "格式", "每次截取都生成新文件，不覆盖已有图片。", options([("png", "PNG"), ("jpg", "JPEG")]), .text("png")),
    .init(.screenshotAction, .download, "截图", "截取后", "", options([("save", "仅保存"), ("open", "打开图片"), ("copy", "拷贝图片")]), .text("open")),
    // 通知
    .init(.notifications, .notifications, "系统通知", "允许通知", "每 15 分钟检查一次；首次开启时系统会请求授权。", .toggle, .bool(false)),
    .init(.momentNotifications, .notifications, "系统通知", "关注的 UP 主发布新视频", "每次检查最多通知 3 条。", .toggle, .bool(false)),
    .init(.liveNotifications, .notifications, "开播提醒", "关注的主播开播", "每 3 分钟检查一次，点按通知直接进入直播间。", .toggle, .bool(true)),
    .init(.menuBarItem, .notifications, "菜单栏图标", "在菜单栏中显示", "从菜单栏控制播放、查看开播的主播和固定的直播间。", .toggle, .bool(false)),
    .init(.dockBadge, .notifications, "Dock 角标", "在 Dock 图标上显示未读数", "回复、@、赞和私信的未读总数，每 2 分钟更新。", .toggle, .bool(true)),
    // 隐私
    .init(.reportProgress, .privacy, "同步观看进度", "同步观看进度", "把播放进度写入哔哩哔哩历史记录，在其他设备上接着看。", .toggle, .bool(true)),
    .init(.spotlightIndex, .privacy, "聚焦搜索与接力", "聚焦搜索与接力", "看过的内容可在聚焦中搜到（仅本机，90 天后过期），正在看的页面可接力到同一 Apple 账户的其他设备；关闭或退出登录时清除。", .toggle, .bool(true)),
    .init(.liveText, .privacy, "画面文字", "暂停时识别画面文字", "暂停后可直接选中画面中的文字拷贝、查询或翻译，识别在本机完成。", .toggle, .bool(true)),
    // 高级
    .init(.decode, .advanced, "播放引擎 mpv", "解码方式", "「自动」在可用时使用硬件解码（VideoToolbox）。", options([("auto-safe", "自动"), ("videotoolbox", "硬件解码（VideoToolbox）"), ("no", "软件解码")]), .text("auto-safe")),
    .init(.mpvProfile, .advanced, "播放引擎 mpv", "画质配置", "使用 mpv 内置的 high-quality 或 fast 配置，重新打开视频后生效。", options([("high-quality", "高质量"), ("fast", "高性能")]), .text("high-quality")),
    .init(.preciseSeek, .advanced, "播放引擎 mpv", "精确跳转", "对应 mpv 的 hr-seek：开启后拖动进度会落在准确的画面上，但稍慢。", options([("default", "默认"), ("yes", "开启"), ("no", "关闭")]), .text("default")),
    .init(.audioChannels, .advanced, "播放引擎 mpv", "声道", "把输出限制为所选声道布局（mpv audio-channels）。", options([("auto", "自动"), ("stereo", "立体声"), ("5.1", "5.1"), ("7.1", "7.1")]), .text("auto")),
    .init(.audioExclusive, .advanced, "播放引擎 mpv", "独占音频输出", "请求 CoreAudio 独占输出（mpv audio-exclusive），是否支持取决于音频设备。", .toggle, .bool(false)),
    .init(.maxVolume, .advanced, "播放引擎 mpv", "最大音量", "超过 100 时会放大声音，可能失真。", .number(1...200, step: 5), .number(100)),
    .init(.customMpv, .advanced, "播放引擎 mpv", "外部 mpv", "选择 mpv 程序后由它播放，满屏通过 IPC 控制它；留空使用内置播放器。", .executable, .text("")),
    .init(.customLibMpv, .advanced, "播放引擎 mpv", "自定义 libmpv", "选择兼容的 libmpv.dylib，重新打开视频后生效；留空使用内置版本。", .executable, .text("")),
    .init(.cacheMB, .advanced, "缓存", "前向缓存上限（MB）", "mpv demuxer-max-bytes，智能缓冲以此为下限。", .number(1...4096, step: 50), .number(300)),
    .init(.backCacheMB, .advanced, "缓存", "后向缓存上限（MB）", "保留已播放的部分，往回拖动时不用重新下载。", .number(0...4096, step: 50), .number(0)),
    .init(.cacheSeconds, .advanced, "缓存", "预读时长上限（秒）", "mpv demuxer-readahead-secs。", .number(1...3600, step: 30), .number(300)),
    .init(.diskCache, .advanced, "缓存", "使用磁盘缓存", "播放缓冲写入磁盘，减少内存占用。", .toggle, .bool(false)),
    .init(.diskCacheDirectory, .advanced, "缓存", "磁盘缓存位置", "与图片缓存、下载位置分开。", .directory, .text("")),
    .init(.logLevel, .advanced, "日志", "mpv 日志级别", "", options([("no", "关闭"), ("error", "错误"), ("warn", "警告"), ("info", "信息"), ("v", "详细")]), .text("warn")),
  ]
  public static func descriptor(_ key: MacSettingKey) -> MacSettingDescriptor {
    descriptors.first { $0.key == key }!
  }
  /// A group's sections in catalog order, each with its descriptors.
  public static func sections(of group: MacSettingGroup) -> [(title: String, descriptors: [MacSettingDescriptor])] {
    var result: [(title: String, descriptors: [MacSettingDescriptor])] = []
    for descriptor in descriptors where descriptor.group == group {
      if let index = result.firstIndex(where: { $0.title == descriptor.section }) { result[index].descriptors.append(descriptor) }
      else { result.append((descriptor.section, [descriptor])) }
    }
    return result
  }
}

/// Preferences only. This store never contains credentials or a download manifest.
public struct MacSettings: Sendable, Equatable {
  private var values: [MacSettingKey: MacSettingValue] = [:]
  public init() {}
  public subscript(_ key: MacSettingKey) -> MacSettingValue { values[key] ?? MacSettingsCatalog.descriptor(key).defaultValue }
  public func bool(_ key: MacSettingKey) -> Bool { if case .bool(let value) = self[key] { value } else { false } }
  public func number(_ key: MacSettingKey) -> Double { if case .number(let value) = self[key] { value } else { 0 } }
  public func text(_ key: MacSettingKey) -> String { if case .text(let value) = self[key] { value } else { "" } }
  @discardableResult public mutating func set(_ key: MacSettingKey, _ value: MacSettingValue,
    capabilities: Set<MacSettingKey>) -> Bool {
    let descriptor = MacSettingsCatalog.descriptor(key)
    guard capabilities.contains(key), descriptor.unavailableReason == nil,
      let normalized = Self.normalize(value, descriptor: descriptor) else { return false }
    values[key] = normalized; return true
  }
  public static func load(from defaults: UserDefaults) -> Self {
    var settings = Self()
    for descriptor in MacSettingsCatalog.descriptors {
      guard let raw = defaults.object(forKey: descriptor.key.rawValue) else { continue }
      let value: MacSettingValue?
      if let text = raw as? String { value = .text(text) }
      else if let number = raw as? NSNumber {
        value = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
      } else { value = nil }
      if let value, let normalized = normalize(value, descriptor: descriptor) { settings.values[descriptor.key] = normalized }
    }
    return settings
  }
  public func save(_ key: MacSettingKey, to defaults: UserDefaults) {
    if key == .quality, number(.quality) == 0 { defaults.removeObject(forKey: key.rawValue); return }
    switch self[key] {
    case .bool(let value): defaults.set(value, forKey: key.rawValue)
    case .number(let value): defaults.set(value, forKey: key.rawValue)
    case .text(let value): defaults.set(value, forKey: key.rawValue)
    }
  }
  private static func normalize(_ value: MacSettingValue, descriptor: MacSettingDescriptor) -> MacSettingValue? {
    switch (descriptor.control, value) {
    case (.toggle, .bool): return value
    case (.choice(let choices), _): return choices.contains { $0.value == value } ? value : nil
    case (.number(let range, _), .number(let number)):
      guard number.isFinite else { return nil }; return .number(min(range.upperBound, max(range.lowerBound, number)))
    case (.directory, .text(let path)), (.executable, .text(let path)):
      guard path.count <= 4096, !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { return nil }
      if case .directory = descriptor.control, !path.isEmpty, !path.hasPrefix("/") { return nil }
      if [.customMpv, .customLibMpv].contains(descriptor.key), !path.isEmpty, !path.hasPrefix("/") { return nil }
      return .text(path)
    default: return nil
    }
  }
}

extension MacSettings {
  /// Commits one field on top of what is stored now, not on an older in-memory copy, so a
  /// value another part of the app saved meanwhile (the player's codec choice, for example)
  /// is kept. Returns the merged settings, or nil when the key or value is not accepted.
  public static func committing(_ key: MacSettingKey, _ value: MacSettingValue, capabilities: Set<MacSettingKey>,
    to defaults: UserDefaults) -> MacSettings? {
    var latest = load(from: defaults)
    guard latest.set(key, value, capabilities: capabilities) else { return nil }
    latest.save(key, to: defaults)
    return latest
  }
}

extension MacSettingDescriptor {
  /// The accepted range and step of a number setting; nil for other controls.
  public var numberRange: (range: ClosedRange<Double>, step: Double)? {
    if case .number(let range, let step) = control { return (range, step) }
    return nil
  }
}

/// Fields a viewer actually changed in a panel that shows only some settings (the player's
/// danmaku panel). Closing the panel commits these and nothing else, so opening and closing
/// it never rewrites a stored value it merely displayed.
public struct MacSettingsEdits: Sendable, Equatable {
  private var values: [MacSettingKey: MacSettingValue] = [:]
  public init() {}
  public var isEmpty: Bool { values.isEmpty }
  public mutating func record(_ key: MacSettingKey, _ value: MacSettingValue) { values[key] = value }
  public mutating func removeAll() { values = [:] }
  /// The edited fields whose value differs from `stored`, in catalog order.
  public func changes(from stored: MacSettings) -> [(key: MacSettingKey, value: MacSettingValue)] {
    MacSettingsCatalog.descriptors.compactMap { descriptor in
      guard let value = values[descriptor.key], stored[descriptor.key] != value else { return nil }
      return (descriptor.key, value)
    }
  }
}

/// A notification payload holds public display data, never credentials or request URLs.
public struct M7MomentNotification: Sendable, Equatable {
  public let id: String
  public let title: String
  public let publisher: String
  public let page: String
  public let mediaID: String
  public init(id: String, title: String, publisher: String, page: String, mediaID: String) {
    self.id = id; self.title = title; self.publisher = publisher; self.page = page; self.mediaID = mediaID
  }
}

/// Followed rooms going live. The first check only records who is already live, so launching
/// the app never floods; afterwards a room that was not live last time is new (at most three
/// per check). Rooms that went offline drop out, so their next broadcast notifies again.
public enum M7LiveNotificationPolicy {
  public static func plan(_ live: [M7MomentNotification], previousIDs: [String]?)
    -> (notifications: [M7MomentNotification], rememberedIDs: [String]) {
    var seen = Set<String>()
    let current = live.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    let remembered = Array(current.map(\.id).prefix(200))
    guard let previousIDs else { return ([], remembered) }
    let previous = Set(previousIDs)
    return (Array(current.filter { !previous.contains($0.id) }.prefix(3)), remembered)
  }
}

/// Mirrors NotificationViewModel: inspect the first three moments and remember at most ten IDs.
public enum M7MomentNotificationPolicy {
  public static func plan(_ moments: [M7MomentNotification], previousIDs: [String])
    -> (notifications: [M7MomentNotification], rememberedIDs: [String]) {
    var ids = Set<String>()
    let latest = Array(moments.prefix(3)).filter { !$0.id.isEmpty && ids.insert($0.id).inserted }
    let notifications = latest.filter { !previousIDs.contains($0.id) }
    var remembered = latest.map(\.id)
    for id in previousIDs where !id.isEmpty && !remembered.contains(id) {
      if remembered.count == 10 { break }
      remembered.append(id)
    }
    return (notifications, remembered)
  }
}
