import AppKit
import ManpingCore
import SwiftUI

/// Badges are attachments so the entire chat line wraps in one selectable TextKit flow.
struct LiveInlineHeader: Equatable {
  let medal: LiveMedal?
  let guardLevel: Int64
  let user: String
  let own: Bool
  let reply: String?

  @MainActor func attributed(dark: Bool, attributes: [NSAttributedString.Key: Any])
    -> NSAttributedString
  {
    let result = NSMutableAttributedString(string: "")
    func appendImage(_ image: NSImage, size: NSSize) {
      let attachment = NSTextAttachment()
      attachment.image = image
      attachment.bounds = NSRect(origin: NSPoint(x: 0, y: -3), size: size)
      let run = NSMutableAttributedString(attachment: attachment)
      run.addAttributes(attributes, range: NSRange(location: 0, length: run.length))
      result.append(run)
      result.append(NSAttributedString(string: " ", attributes: attributes))
    }
    if let medal {
      let text = medal.name + " " + String(medal.level)
      let font = NSFont.systemFont(ofSize: 9, weight: .medium)
      let size = NSSize(
        width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12, height: 17)
      let image = NSImage(size: size, flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        let start = medal.lighted ? Self.color(medal.startColor) : .gray
        let end = medal.lighted ? Self.color(medal.endColor) : .gray
        NSGradient(starting: start, ending: end)?.draw(in: path, angle: 0)
        (medal.lighted ? Self.color(medal.borderColor) : .gray).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        (text as NSString).draw(
          at: NSPoint(x: 6, y: 3), withAttributes: [.font: font, .foregroundColor: NSColor.white])
        return true
      }
      appendImage(image, size: size)
    }
    if guardLevel > 0,
      let symbol = NSImage(
        systemSymbolName: "shield.fill", accessibilityDescription: guardName(guardLevel))
    {
      let tint = Self.color(guardLevel == 1 ? 0xffb13b : guardLevel == 2 ? 0x8d5cd8 : 0x3e6fd8)
      let image = NSImage(size: NSSize(width: 12, height: 14), flipped: false) { rect in
        symbol.draw(in: rect)
        tint.setFill()
        rect.fill(using: .sourceAtop)
        return true
      }
      appendImage(image, size: NSSize(width: 12, height: 14))
    }
    var nameAttributes = attributes
    nameAttributes[.font] = NSFont.systemFont(ofSize: 13, weight: .semibold)
    nameAttributes[.foregroundColor] = NSColor(Theme.accentText(dark ? .dark : .light))
    result.append(NSAttributedString(string: user, attributes: nameAttributes))
    if own {
      result.append(NSAttributedString(string: " ", attributes: attributes))
      let image = NSImage(size: NSSize(width: 19, height: 15), flipped: false) { rect in
        Self.color(0x2ec0f7).withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        ("我" as NSString).draw(
          at: NSPoint(x: 5, y: 2),
          withAttributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor(Theme.accentText(dark ? .dark : .light)),
          ])
        return true
      }
      appendImage(image, size: NSSize(width: 19, height: 15))
    }
    result.append(NSAttributedString(string: "：", attributes: nameAttributes))
    if let reply, !reply.isEmpty {
      var replyAttributes = attributes
      replyAttributes[.foregroundColor] = NSColor(Theme.tertiaryText(dark ? .dark : .light))
      result.append(NSAttributedString(string: "@" + reply + " ", attributes: replyAttributes))
    }
    return result
  }

  private static func color(_ value: Int64) -> NSColor {
    NSColor(
      srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
      blue: Double(value & 255) / 255, alpha: 1)
  }
}
