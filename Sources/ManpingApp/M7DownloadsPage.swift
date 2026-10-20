import AppKit
import ManpingCore
import SwiftUI

/// The upstream DownloadPage is empty; Mac task rows expose the native queue and recovery actions.
struct M7DownloadsPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject var queue: DownloadCoordinator
  init(model: AppModel) { self.model = model; queue = model.downloadQueue }
  @Environment(\.colorScheme) private var scheme
  @State private var filter = "全部"
  private let filters = ["全部", "进行中", "已完成", "待恢复"]
  private var records: [DownloadRecord] {
    queue.records.filter { record in
      switch filter {
      case "进行中": return ["queued", "downloading", "merging"].contains(record.state)
      case "已完成": return record.state == "complete"
      case "待恢复": return ["cancelled", "failed", "interrupted"].contains(record.state)
      default: return true
      }
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      if records.isEmpty {
        PageStateView(title: filter == "全部" ? "下载是空的" : "没有\(filter)的下载",
          message: "在视频页点按「下载」，选择画质或要导出的内容。", icon: "arrow.down.circle")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(records) { record in taskRow(record) }
          }.padding(Theme.gridPadding).frame(maxWidth: 920).frame(maxWidth: .infinity)
        }
      }
    }.foregroundStyle(Theme.text(scheme))
      .pageToolbar(title: "下载", subtitle: "取消后已下载的部分会保留",
        segments: AnyView(SegmentedTabs(options: filters.map { ($0, $0) }, selection: $filter)))
  }
  private func taskRow(_ record: DownloadRecord) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: record.state == "complete" ? "checkmark.circle" : "arrow.down.to.line")
          .font(.system(size: 16, weight: .medium)).foregroundStyle(record.state == "complete" ? Theme.success(scheme) : Theme.accentText(scheme))
          .frame(width: 36, height: 36)
          .background((record.state == "complete" ? Theme.success(scheme) : Theme.accent).opacity(0.14), in: Circle())
        VStack(alignment: .leading, spacing: 5) {
          Text(record.title).font(Theme.Font.headline).lineLimit(2)
          HStack(spacing: 8) {
            Text(stateName(record.state))
            if let options = record.options {
              Text("·"); Text(options.content.title)
              if options.content == .video { Text("· \(qualityName(options.quality)) · \(options.codec.title)") }
            }
          }.font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
        }.frame(maxWidth: .infinity, alignment: .leading)
        Text(String(format: "%.0f%%", fraction(record) * 100)).font(Theme.Font.caption.monospacedDigit())
          .foregroundStyle(Theme.secondaryText(scheme))
        if ["queued", "downloading", "merging"].contains(record.state) {
          action("取消", icon: "xmark") { model.cancelDownload(record.id) }
        } else if ["cancelled", "failed", "interrupted"].contains(record.state) {
          action("恢复", icon: "arrow.clockwise") { model.retryDownload(record) }
            .disabled(record.options == nil)
            .help(record.options == nil ? "此旧任务没有保存下载选项，请回到播放页重新下载。" : "重新获取下载地址并继续已有数据。")
        } else if record.state == "complete" {
          action("在 Finder 中显示", icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.output)])
          }.disabled(record.output.isEmpty || !FileManager.default.fileExists(atPath: record.output))
        }
      }
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Theme.fill(scheme))
          Capsule().fill(record.state == "complete" ? Theme.success(scheme) : Theme.accent)
            .frame(width: geometry.size.width * fraction(record))
        }
      }.frame(height: 4).animation(.easeOut(duration: 0.3), value: fraction(record))
      if !record.error.isEmpty { InlineErrorText(message: record.error) }
      if record.state == "complete", !record.output.isEmpty {
        Text(record.output).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      } else if ["cancelled", "failed", "interrupted"].contains(record.state), record.options == nil {
        Text("此旧任务无法自动恢复，请从播放页重新选择下载。").font(Theme.Font.caption)
          .foregroundStyle(Theme.secondaryText(scheme))
      }
    }.padding(16).cardSurface(scheme)
  }
  private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
    Button(action: perform) { Label(title, systemImage: icon) }
      .buttonStyle(AppButtonStyle(role: title == "取消" ? .destructive : .secondary, size: .small))
  }
  private func fraction(_ record: DownloadRecord) -> Double {
    record.state == "complete" ? 1 : record.progress.isFinite ? min(1, max(0, record.progress)) : 0
  }
  private func stateName(_ state: String) -> String {
    switch state {
    case "queued": "等待下载"
    case "downloading": "正在下载"
    case "merging": "正在合并"
    case "cancelled": "已取消"
    case "failed": "下载失败"
    case "interrupted": "上次运行中断"
    case "complete": "已完成"
    default: "状态未知"
    }
  }
  private func qualityName(_ quality: Int) -> String {
    [127: "8K", 126: "杜比视界", 125: "HDR", 120: "4K", 116: "1080P 60 帧", 112: "1080P 高码率", 80: "1080P", 74: "720P 60 帧", 64: "720P", 32: "480P", 16: "360P"][quality] ?? "画质 \(quality)"
  }
}

extension DownloadCodec {
  var title: String {
    switch self { case .avc: "H.264"; case .hevc: "HEVC"; case .av1: "AV1" }
  }
}
