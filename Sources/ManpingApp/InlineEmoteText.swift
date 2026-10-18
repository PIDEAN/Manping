import AppKit
import ManpingCore
import SwiftUI

/// TextKit keeps emotes in the same selectable, wrapping text flow as surrounding text.
@MainActor struct InlineEmoteText: NSViewRepresentable {
  let text: String
  let emotes: [RPCEmote]
  var maxLines: Int? = nil
  @Environment(\.colorScheme) private var scheme

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> EmoteTextView {
    let view = EmoteTextView()
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  func updateNSView(_ view: EmoteTextView, context: Context) {
    let coordinator = context.coordinator
    let signature = Signature(text: text, emotes: emotes, maxLines: maxLines, dark: scheme == .dark)
    guard coordinator.signature != signature else { return }
    coordinator.signature = signature
    coordinator.task?.cancel()
    let revision = UUID(); coordinator.revision = revision
    view.textContainer?.maximumNumberOfLines = maxLines ?? 0
    view.textContainer?.lineBreakMode = maxLines == nil ? .byWordWrapping : .byTruncatingTail
    let segments = RPCEmoteTextSegment.parse(text, emotes: emotes)
    view.textStorage?.setAttributedString(Self.attributed(segments, images: [:], dark: signature.dark))
    view.invalidateIntrinsicContentSize()
    coordinator.task = Task { @MainActor [weak view, weak coordinator] in
      var images: [URL: NSImage] = [:]
      for segment in segments {
        guard case .emote(_, let url) = segment, images[url] == nil else { continue }
        do {
          let decoded = try await ImageCache.shared.imageForReader(for: url)
          try Task.checkCancellation()
          guard coordinator?.revision == revision, let view else { return }
          images[url] = NSImage(cgImage: decoded, size: NSSize(width: 20, height: 20))
          view.textStorage?.setAttributedString(Self.attributed(segments, images: images, dark: signature.dark))
          view.invalidateIntrinsicContentSize()
        } catch is CancellationError { return } catch { /* Keep the exact token when an image fails. */ }
      }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: EmoteTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0, width.isFinite else { return nil }
    return nsView.measuredSize(width: width)
  }
  static func dismantleNSView(_ nsView: EmoteTextView, coordinator: Coordinator) {
    coordinator.revision = UUID(); coordinator.task?.cancel(); coordinator.task = nil
    nsView.textStorage?.setAttributedString(NSAttributedString(string: ""))
  }
  private static func attributed(_ segments: [RPCEmoteTextSegment], images: [URL: NSImage], dark: Bool) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 24; paragraph.maximumLineHeight = 24
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14), .foregroundColor: dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.10, alpha: 1),
      .paragraphStyle: paragraph,
    ]
    let result = NSMutableAttributedString(string: "")
    for segment in segments {
      switch segment {
      case .text(let text): result.append(NSAttributedString(string: text, attributes: attributes))
      case .emote(let token, let url):
        if let image = images[url] {
          // XAML inline image: 20×20, horizontal margin 2, vertical offset -4.
          let padded = NSImage(size: NSSize(width: 24, height: 20))
          padded.lockFocus()
          image.draw(in: NSRect(x: 2, y: 0, width: 20, height: 20))
          padded.unlockFocus()
          let attachment = NSTextAttachment()
          attachment.image = padded
          attachment.bounds = NSRect(x: 0, y: -4, width: 24, height: 20)
          let run = NSMutableAttributedString(attachment: attachment)
          run.addAttributes(attributes, range: NSRange(location: 0, length: run.length))
          result.append(run)
        } else { result.append(NSAttributedString(string: token, attributes: attributes)) }
      }
    }
    return result
  }
  struct Signature: Equatable {
    let text: String
    let emotes: [RPCEmote]
    let maxLines: Int?
    let dark: Bool
  }
  @MainActor final class Coordinator {
    var signature: Signature?
    var revision = UUID()
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
  }
}

@MainActor final class EmoteTextView: NSTextView {
  func measuredSize(width: CGFloat) -> CGSize {
    guard let textContainer, let layoutManager else { return CGSize(width: width, height: 24) }
    textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    return CGSize(width: width, height: max(24, ceil(layoutManager.usedRect(for: textContainer).height)))
  }
  override var intrinsicContentSize: NSSize {
    measuredSize(width: max(1, bounds.width))
  }
}
