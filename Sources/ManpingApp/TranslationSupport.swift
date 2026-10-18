import AppKit
import SwiftUI
import Translation

/// System translation (Translation framework): a popover that detects the language and lets the
/// viewer pick the target, translated on device where the language pack is installed.
/// Selectable text already offers 翻译 in its own context menu; this covers the rest.
private struct TranslatableModifier: ViewModifier {
  let text: String
  @State private var showing = false
  func body(content: Content) -> some View {
    content
      .contextMenu {
        Button("翻译") { showing = true }
        Button("拷贝文本") {
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
      }
      .translationPresentation(isPresented: $showing, text: String(text.prefix(TranslationLimits.characters)))
  }
}

enum TranslationLimits {
  /// The system popover is meant for passages, not books.
  static let characters = 6_000
}

extension View {
  /// Adds 翻译 / 拷贝文本 to the context menu of non-selectable text.
  func translatable(_ text: String) -> some View { modifier(TranslatableModifier(text: text)) }
  /// Presents the system translation popover for `text` while `isPresented` is true.
  func translationSheet(isPresented: Binding<Bool>, text: String) -> some View {
    translationPresentation(isPresented: isPresented, text: String(text.prefix(TranslationLimits.characters)))
  }
}

/// A small 翻译 link for a passage (video or episode descriptions).
struct TranslateLink: View {
  let text: String
  @State private var showing = false
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Button { showing = true } label: { Label("翻译", systemImage: "translate").font(Theme.Font.caption) }
      .buttonStyle(.borderless).foregroundStyle(Theme.accentText(scheme))
      .help("用系统翻译查看这段文字")
      .translationSheet(isPresented: $showing, text: text)
  }
}
