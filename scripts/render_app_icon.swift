// Companion to make_app_icon.py. The app icon itself is the Icon Composer document
// Resources/AppIcon/AppIcon.icon (exported to AppIcon.png by ictool); this script only
//   - composes AppIconDebug.png: AppIcon.png plus a DEBUG badge (bottom right),
//   - writes StoreLogo.png (128 px, sidebar brand) by scaling AppIcon.png,
//   - draws MenuBarIcon.png (36 px template, 18 pt @2x): the three solid streaks.
import AppKit

guard CommandLine.arguments.count == 3 else {
  fatalError("Usage: render_app_icon.swift <icon-directory> <app-resources-directory>")
}
let iconDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let resourceDirectory = URL(fileURLWithPath: CommandLine.arguments[2])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
          blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

/// Renders into a Display P3 bitmap (the colour space ictool exports), so the icon keeps its gamut.
func render(side: Int, _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
  let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.displayP3)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  NSGraphicsContext.current?.imageInterpolation = .high
  draw(CGFloat(side))
  NSGraphicsContext.restoreGraphicsState()
  return NSBitmapImageRep(cgImage: context.makeImage()!)
}

func save(_ bitmap: NSBitmapImageRep, _ url: URL) {
  try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

guard let base = NSImage(contentsOf: iconDirectory.appendingPathComponent("AppIcon.png")) else {
  fatalError("AppIcon.png is missing; run scripts/make_app_icon.py")
}

func drawBase(side: CGFloat) {
  base.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
}

func debugIcon(side: CGFloat) {
  drawBase(side: side)
  let scale = side / 1024
  let badge = NSRect(x: 640 * scale, y: 112 * scale, width: 250 * scale, height: 84 * scale)
  color(0xE5426A, 0.95).setFill()
  NSBezierPath(roundedRect: badge, xRadius: 42 * scale, yRadius: 42 * scale).fill()
  let text = NSAttributedString(string: "DEBUG", attributes: [
    .font: NSFont.systemFont(ofSize: 46 * scale, weight: .heavy), .foregroundColor: NSColor.white,
    .kern: 2 * scale,
  ])
  let size = text.size()
  text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
}

/// Monochrome template for the menu bar: three solid streaks. Paths are SVG in an 18 pt box (y down):
/// move, cubic, half-circle cap, cubic, close.
func menuBarIcon(side: CGFloat) {
  let unit = side / 18
  let streaks = [
    "M5,4.6 C9,4.6 12,4 13.6,4 A1.3,1.3 0 0 1 13.6,6.6 C12,6.6 9,5.9 5,5.9 Z",
    "M1.5,8.3 C6,8.3 10,7.3 12.6,7.3 A2,2 0 0 1 12.6,11.3 C10,11.3 6,10 1.5,10 Z",
    "M6,13 C9,13 12,12.3 14.4,12.3 A1.6,1.6 0 0 1 14.4,15.5 C12,15.5 9,14.6 6,14.6 Z",
  ]
  func point(_ x: String, _ y: String) -> NSPoint { NSPoint(x: Double(x)! * unit, y: (18 - Double(y)!) * unit) }
  NSColor.black.setFill()
  for svg in streaks {
    let path = NSBezierPath()
    var tokens = svg.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
    var current = NSPoint.zero
    while !tokens.isEmpty {
      let token = tokens.removeFirst()
      let letter = token.first!
      var numbers = token.count > 1 ? [String(token.dropFirst())] : []
      let count = ["M": 2, "C": 6, "A": 7, "Z": 0][letter]!
      while numbers.count < count { numbers.append(tokens.removeFirst()) }
      switch letter {
      case "M":
        current = point(numbers[0], numbers[1]); path.move(to: current)
      case "C":
        let end = point(numbers[4], numbers[5])
        path.curve(to: end, controlPoint1: point(numbers[0], numbers[1]), controlPoint2: point(numbers[2], numbers[3]))
        current = end
      case "A":
        // Every cap here is a half circle whose chord is its diameter; sweep 1 in SVG (y down) runs
        // top to bottom through the right side, which is clockwise in this y-up bitmap.
        let end = point(numbers[5], numbers[6])
        let centre = NSPoint(x: (current.x + end.x) / 2, y: (current.y + end.y) / 2)
        let start = atan2(current.y - centre.y, current.x - centre.x) * 180 / .pi
        let finish = atan2(end.y - centre.y, end.x - centre.x) * 180 / .pi
        path.appendArc(withCenter: centre, radius: Double(numbers[0])! * unit, startAngle: start, endAngle: finish,
                       clockwise: true)
        current = end
      default:
        path.close()
      }
    }
    path.fill()
  }
}

save(render(side: 1024) { debugIcon(side: $0) }, iconDirectory.appendingPathComponent("AppIconDebug.png"))
save(render(side: 128) { drawBase(side: $0) }, resourceDirectory.appendingPathComponent("StoreLogo.png"))
save(render(side: 36) { menuBarIcon(side: $0) }, resourceDirectory.appendingPathComponent("MenuBarIcon.png"))
