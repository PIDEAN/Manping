import Observation
import SwiftUI

// Small views for the article reader chrome: reading progress, type size and the floating action rail.

enum ArticleFormat {
  static let fontSizeKey = "Manping.articleFontSize"
  static let fontSizeRange: ClosedRange<Double> = 14...22
  static let defaultFontSize = 16.0

  /// Reading time in whole minutes at 400 characters per minute, never below one.
  static func readMinutes(characters: Int) -> Int { max(1, Int((Double(characters) / 400).rounded(.up))) }

  static func count(_ value: Int) -> String {
    value >= 10_000 ? String(format: "%.1f 万", Double(value) / 10_000) : String(value)
  }

  static func date(_ stamp: Int64) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(stamp)))
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
    return "\(year) 年 \(month) 月 \(day) 日"
  }
}

/// Scroll position as 0...1. Only `ArticleProgressBar` reads `value`, so scrolling redraws that bar and
/// not the page that owns the tracker.
@MainActor @Observable final class ArticleReadingProgress {
  var value = 0.0
}

/// The 2pt accent line along the bottom edge of the reader header.
struct ArticleProgressBar: View {
  let progress: ArticleReadingProgress
  var body: some View {
    Rectangle().fill(Theme.accent).frame(height: 2).frame(maxWidth: .infinity)
      .scaleEffect(x: max(0, min(1, progress.value)), y: 1, anchor: .leading)
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// "A− / A+" pair that steps the body type size inside `ArticleFormat.fontSizeRange`.
struct ArticleFontSizeControl: View {
  @Binding var size: Double
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 0) {
      step("A−", font: 12, label: "缩小字号", delta: -1, enabled: size > ArticleFormat.fontSizeRange.lowerBound)
      step("A+", font: 15, label: "放大字号", delta: 1, enabled: size < ArticleFormat.fontSizeRange.upperBound)
    }.padding(2).background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
      .accessibilityElement(children: .contain).accessibilityLabel("正文字号")
  }
  private func step(_ title: String, font: CGFloat, label: String, delta: Double, enabled: Bool) -> some View {
    Button {
      size = min(ArticleFormat.fontSizeRange.upperBound, max(ArticleFormat.fontSizeRange.lowerBound, size + delta))
    } label: {
      Text(title).font(.system(size: font)).frame(width: 30, height: 24)
    }.buttonStyle(ChromeButtonStyle()).disabled(!enabled).help(label).accessibilityLabel(label)
  }
}

/// Vertical glass capsule floating over the text: icon over number, accent fill on the active item.
struct ArticleActionRail: View {
  struct Item: Identifiable {
    let id: String
    let label: String
    let icon: String
    var detail: String?
    var selected = false
    var disabled = false
    let action: () -> Void
  }
  let items: [Item]
  var busy = false
  var body: some View {
    VStack(spacing: 2) {
      ForEach(items) { item in
        Button(action: item.action) {
          VStack(spacing: 3) {
            Image(systemName: item.icon).font(.system(size: 15)).frame(height: 16)
            Text(item.detail ?? item.label).font(Theme.Font.caption2).lineLimit(1).minimumScaleFactor(0.8)
          }.frame(width: 44).padding(.vertical, 7)
        }.buttonStyle(ChromeButtonStyle(selected: item.selected)).disabled(item.disabled)
          .help(item.label).accessibilityLabel(item.label)
      }
      if busy { ProgressView().controlSize(.small).padding(.vertical, 6) }
    }.padding(.vertical, 6).frame(width: 52).floatingGlassPanel()
      .accessibilityElement(children: .contain).accessibilityLabel("文章操作")
  }
}
