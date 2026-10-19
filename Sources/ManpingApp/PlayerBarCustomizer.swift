import AppKit
import ManpingCore
import SwiftUI

// 设置 › 控制条: a simulated picture with the glass control bar on it, a width slider, and the
// items that can go on the bar. Items are dragged by hand-rolled gestures in one coordinate space,
// so the floating thumbnail and the drop zones (替换 / 插入 / 移除) are exact; the bar folds with
// the same `PlayerBarLayout.fit` the player uses.

struct PlayerBarCustomizer: View {
  @ObservedObject private var store = PlayerBarStore.shared
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Simulated picture width; nil follows the card. Wider than the card, the bar is scaled down.
  @State private var simulatedWidth: CGFloat? = Self.debugWidth
  @State private var cardWidth: CGFloat = 560
  /// The box the preview bar sits in at the bottom of the card, in `space` (unscaled).
  @State private var barBox: CGRect = .zero
  @State private var drag: Drag?
  @State private var ghostScale: CGFloat = 1
  @State private var ghostOpacity: Double = 1
  @State private var hover: PlayerBarItem?
  @State private var hoverTask: Task<Void, Never>?
  @State private var debugApplied = false

  nonisolated static let space = "playerBarEditor"
  private let metrics = PlayerBarLayout.Metrics()
  /// 播放、下一个、时间、弹幕开关 in the preview (`PlayerBarPreview.leading`).
  static let leadingWidth: CGFloat = 40 + 6 + 32 + 6 + 96 + 6 + 32
  /// The bar's horizontal padding (as `PlayerControlPanel`).
  static let barPadding: CGFloat = 12
  private static let minimumWidth: CGFloat = 480
  private static let maximumWidth: CGFloat = 1440

  struct Drag: Equatable {
    var id = UUID()
    var item: PlayerBarItem
    var fromBar: Bool
    /// Where it was picked up; a drop on no target flies back here.
    var origin: CGPoint
    var location: CGPoint
    var target: PlayerBarDrop?
    /// Insertion line, in the bar row's coordinates.
    var caret: CGFloat?
    var settling = false
  }

  /// One visible item on the preview bar: its index in `store.items` and its extent in the row.
  struct Slot {
    let index: Int
    let item: PlayerBarItem
    let start: CGFloat
    let end: CGFloat
  }

  // MARK: Geometry

  private var pictureWidth: CGFloat {
    min(Self.maximumWidth, max(Self.minimumWidth, simulatedWidth ?? cardWidth))
  }
  /// The bar shrinks to fit the card when the simulated picture is wider than the card.
  private var barScale: CGFloat { min(1, max(0.2, (cardWidth - 32) / (pictureWidth - PlayerPanelLayout.inset * 2))) }
  /// The preview bar as drawn, in `space`.
  private var barFrame: CGRect {
    let scale = barScale
    return CGRect(x: barBox.minX, y: barBox.maxY - 52 * scale, width: (pictureWidth - PlayerPanelLayout.inset * 2) * scale, height: 52 * scale)
  }
  private var rowWidth: CGFloat { pictureWidth - PlayerPanelLayout.inset * 2 - Self.barPadding * 2 }
  private var fit: PlayerBarFit {
    PlayerBarLayout.fit(store.items, rowWidth: Double(rowWidth), leadingWidth: Double(Self.leadingWidth), hasInput: true, metrics: metrics)
  }
  private var slots: [Slot] {
    let fit = fit
    var end = rowWidth - CGFloat(metrics.moreWidth + metrics.gap)
    var result: [Slot] = []
    for (offset, item) in fit.visible.enumerated().reversed() {
      let width = CGFloat(metrics.width(of: item))
      result.append(Slot(index: fit.firstVisible + offset, item: item, start: end - width, end: end))
      end -= width + CGFloat(metrics.gap)
    }
    return result.reversed()
  }
  private var rowOrigin: CGFloat { barFrame.minX + Self.barPadding * barScale }

  /// The drop under `point` (in `space`): the middle half of an item replaces it, its outer
  /// quarters insert beside it, and anywhere 46pt above or below the bar removes a bar item.
  private func target(at point: CGPoint, fromBar: Bool) -> (PlayerBarDrop?, CGFloat?) {
    let near = point.y > barFrame.minY - 46 && point.y < barFrame.maxY + 46
      && point.x > barFrame.minX - 30 && point.x < barFrame.maxX + 30
    guard near else { return (fromBar ? .remove : nil, nil) }
    let x = (point.x - rowOrigin) / barScale
    let slots = slots
    guard let first = slots.first, x >= first.start else {
      // The fixed group takes no drops: snap to the customisable group's left edge.
      let edge = slots.first?.start ?? rowWidth - CGFloat(metrics.moreWidth + metrics.gap) + 3
      return (.insert(fit.firstVisible), edge - 2)
    }
    for slot in slots {
      let quarter = (slot.end - slot.start) * 0.25
      if x >= slot.start + quarter && x <= slot.end - quarter { return (.replace(slot.index), nil) }
      if x < slot.start + quarter { return (.insert(slot.index), slot.start - 2) }
    }
    let last = slots[slots.count - 1]
    return (.insert(last.index + 1), last.end + 1)
  }

  // MARK: Body

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        previewCard
        widthRow
        palette
        footer
      }
      .padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 24)
      .overlay { ghost }
      .coordinateSpace(.named(Self.space))
    }
    .scrollDisabled(drag != nil)
    .task {
      guard Self.debugDrag != nil else { return }
      try? await Task.sleep(for: .seconds(1))
      applyDebugDrag()
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Text("拖动排序，拖进来添加，拖出去移除；放在图标上替换，放在两个图标之间插入。")
        .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
      Spacer(minLength: 0)
      Button("恢复默认") { withAnimation(.spring(duration: 0.25)) { store.reset() } }
        .buttonStyle(AppButtonStyle(size: .small)).disabled(store.isDefault)
    }
  }

  // MARK: Preview

  private var previewCard: some View {
    let fit = fit
    return ZStack(alignment: .topLeading) {
      PlayerBarBackdrop()
      Text("模拟窗口宽度 \(Int(pictureWidth)) pt · 收起 \(fit.hidden.count) 项")
        .font(Theme.Font.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 10).frame(height: 24).background(.black.opacity(0.45), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .trailing).padding(14)
        .contentTransition(.numericText())
      if drag?.target == .remove {
        Text("松手即从控制条移除").font(Theme.Font.caption.weight(.bold)).foregroundStyle(Theme.danger(.dark))
          .padding(.horizontal, 12).frame(height: 26)
          .background(Theme.danger(.dark).opacity(0.2), in: Capsule())
          .overlay(Capsule().strokeBorder(Theme.danger(.dark).opacity(0.5)))
          .frame(maxWidth: .infinity).padding(.top, 104)
          .transition(.opacity)
      }
      VStack {
        Spacer(minLength: 0)
        previewBar(fit).frame(width: pictureWidth - PlayerPanelLayout.inset * 2)
          .scaleEffect(barScale, anchor: .bottomLeading)
          .frame(width: max(0, cardWidth - 32), height: 52, alignment: .bottomLeading)
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
            barBox = frame
          }
          .padding(.leading, 16).padding(.bottom, 16)
      }
    }
    .frame(height: 224)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    .environment(\.colorScheme, .dark)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
    .animation(.easeOut(duration: 0.15), value: drag?.target == .remove)
  }

  private func previewBar(_ fit: PlayerBarFit) -> some View {
    HStack(spacing: CGFloat(metrics.gap)) {
      PlayerBarPreviewLeading().frame(width: Self.leadingWidth)
      if fit.compactInput {
        Image(systemName: "pencil.line").font(.system(size: 13, weight: .medium))
          .frame(width: 32, height: 32).background(.white.opacity(0.18), in: Circle())
          .transition(.opacity)
      } else {
        Text("发一条友善的弹幕").font(Theme.Font.caption2).foregroundStyle(.white.opacity(0.55))
          .padding(.leading, 12).frame(width: CGFloat(metrics.inputWidth), height: 30, alignment: .leading)
          .background(.white.opacity(0.12), in: Capsule())
          .transition(.opacity)
      }
      Spacer(minLength: CGFloat(metrics.spacerMinimum))
      ForEach(Array(fit.visible.enumerated()), id: \.element) { offset, item in
        previewItem(item, index: fit.firstVisible + offset, count: store.items.count)
      }
      Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
        .frame(width: 32, height: 32).background(.white.opacity(0.1), in: Circle())
        .overlay(alignment: .topTrailing) {
          if !fit.hidden.isEmpty {
            Text("\(fit.hidden.count)").font(.system(size: 9, weight: .heavy).monospacedDigit()).foregroundStyle(Theme.onAccent)
              .padding(.horizontal, 3).frame(minWidth: 15, minHeight: 15).background(Capsule().fill(Theme.accent))
              .offset(x: 3, y: -2)
          }
        }
        .help(fit.hidden.isEmpty ? "更多" : "已收起：" + fit.hidden.map(\.title).joined(separator: "、"))
        .accessibilityElement().accessibilityLabel("更多")
        .accessibilityValue(fit.hidden.isEmpty ? "" : "已收起 " + fit.hidden.map(\.title).joined(separator: "、"))
    }
    .foregroundStyle(.white)
    .padding(.horizontal, Self.barPadding).frame(height: 52)
    .glassEffect(.regular.tint(.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    .overlay(alignment: .topLeading) {
      if let caret = drag?.caret, !(drag?.settling ?? false) {
        Capsule().fill(Theme.accent).frame(width: 3, height: 32)
          .shadow(color: Theme.accent.opacity(0.8), radius: 5)
          .offset(x: Self.barPadding + caret - 1.5, y: 10)
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.2, anchor: .center)))
      }
    }
    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.2), value: store.items)
    .animation(.easeOut(duration: 0.25), value: pictureWidth)
    .animation(.easeOut(duration: 0.14), value: drag?.caret)
  }

  private func previewItem(_ item: PlayerBarItem, index: Int, count: Int) -> some View {
    let target = drag?.target
    let dragged = drag?.fromBar == true && drag?.item == item
    let replaced = target == .replace(index) && !dragged
    var shift: CGFloat = 0
    if case .insert(let at) = target, !reduceMotion { shift = index >= at ? 6 : -4 }
    return PlayerBarPreviewItem(item: item, width: CGFloat(metrics.width(of: item)))
      .background(Capsule().fill(replaced ? Theme.accent.opacity(0.22) : .clear))
      .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: replaced ? 2 : 0))
      .opacity(dragged ? (target == .remove ? 0.15 : 0.3) : replaced ? 0.55 : 1)
      .offset(x: shift)
      .animation(.easeOut(duration: 0.18), value: shift)
      .animation(.easeOut(duration: 0.15), value: replaced)
      .overlay(alignment: .top) {
        if hover == item && drag == nil {
          Text(item.title).font(Theme.Font.caption2.weight(.semibold)).foregroundStyle(.white).fixedSize()
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color(white: 0.14).opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
            .offset(y: -32)
            .transition(.opacity.combined(with: .offset(y: 4)))
            .allowsHitTesting(false)
        }
      }
      .contentShape(Capsule())
      .onHover { inside in hovering(item, inside) }
      .gesture(dragGesture(item, fromBar: true))
      .contextMenu {
        Button("左移") { move(item, by: -1) }.disabled(index == 0)
        Button("右移") { move(item, by: 1) }.disabled(index == count - 1)
        Divider()
        Button("从控制条移除") { remove(item) }
      }
      .accessibilityElement()
      .accessibilityLabel("\(item.title)，第 \(index + 1) 项，共 \(count) 项")
      .accessibilityAction(named: "左移") { move(item, by: -1) }
      .accessibilityAction(named: "右移") { move(item, by: 1) }
      .accessibilityAction(named: "从控制条移除") { remove(item) }
  }

  private var widthRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 14) {
        Text("预览窗口宽度").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme)).fixedSize()
        Slider(value: Binding(get: { pictureWidth }, set: { simulatedWidth = ($0 / 10).rounded() * 10 }),
          in: Self.minimumWidth...Self.maximumWidth)
          .frame(maxWidth: 320).controlSize(.small).tint(Theme.accent)
          .accessibilityLabel("预览窗口宽度").accessibilityValue("\(Int(pictureWidth)) pt")
        if simulatedWidth != nil {
          Button("跟随设置窗口") { withAnimation(.easeOut(duration: 0.25)) { simulatedWidth = nil } }
            .buttonStyle(AppButtonStyle(role: .plain, size: .small))
        }
      }
      Text("窗口变窄时，弹幕输入框先缩成按钮，右侧项目再从最左边一项开始依次收进「更多」；最靠右的项目保留得最久。")
        .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Palette

  private var palette: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("可添加的项目").font(Theme.Font.section).foregroundStyle(Theme.text(scheme))
        Text("不在控制条上的项目，始终可以在「更多」菜单里找到。").font(Theme.Font.caption)
          .foregroundStyle(Theme.tertiaryText(scheme))
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
        ForEach(PlayerBarItem.allCases, id: \.self) { item in paletteCard(item) }
      }
    }
  }

  private func paletteCard(_ item: PlayerBarItem) -> some View {
    let onBar = store.items.contains(item)
    let lifted = drag?.item == item && drag?.fromBar == false
    return PlayerBarPaletteCard(item: item, onBar: onBar, lifted: lifted)
      .gesture(dragGesture(item, fromBar: false), including: onBar ? .none : .all)
      .contextMenu {
        Button("添加到控制条") { add(item) }.disabled(onBar)
      }
      .focusable(!onBar)
      .onKeyPress(.return) {
        guard !onBar else { return .ignored }
        add(item); return .handled
      }
      .accessibilityElement()
      .accessibilityLabel(item.title).accessibilityValue(onBar ? "已在控制条上" : item.note)
      .accessibilityAddTraits(onBar ? [] : .isButton)
      .accessibilityAction(named: "添加到控制条") { add(item) }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("固定在左侧：播放、下一个、时间、弹幕开关、弹幕输入框。")
      Text("「更多」菜单固定在最右，最后一项是「自定义控制条…」。直播间会跳过不支持的项目。")
    }.font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
  }

  // MARK: Floating thumbnail

  @ViewBuilder private var ghost: some View {
    if let drag {
      let removing = drag.target == .remove
      PlayerBarGlyph(item: drag.item, size: 14)
        .foregroundStyle(removing ? Color(red: 0.165, green: 0.04, blue: 0.03) : Theme.onAccent)
        .frame(width: 38, height: 38)
        .background(Circle().fill(removing ? Theme.danger(.dark).opacity(0.88) : Theme.accent.opacity(0.94)))
        .overlay(Circle().strokeBorder(.white.opacity(0.3)))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 10)
        .scaleEffect(ghostScale).opacity(ghostOpacity)
        .animation(.easeOut(duration: 0.12), value: removing)
        .position(drag.location)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  // MARK: Dragging

  private func dragGesture(_ item: PlayerBarItem, fromBar: Bool) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .onChanged { value in
        if drag == nil || drag?.settling == true || drag?.item != item { begin(item, fromBar: fromBar, at: value.startLocation) }
        update(to: value.location)
      }
      .onEnded { _ in end() }
  }

  /// 按下即拿起: the card shrinks into a 38pt thumbnail under the pointer (1.7 → 1, 0.16 s).
  private func begin(_ item: PlayerBarItem, fromBar: Bool, at point: CGPoint) {
    hoverTask?.cancel(); hover = nil
    drag = Drag(item: item, fromBar: fromBar, origin: point, location: point)
    ghostOpacity = reduceMotion ? 0 : 0.6
    ghostScale = reduceMotion ? 1 : 1.7
    withAnimation(.easeOut(duration: 0.16)) { ghostScale = 1; ghostOpacity = 1 }
  }

  private func update(to point: CGPoint) {
    guard var current = drag, !current.settling else { return }
    current.location = point
    let (target, caret) = target(at: point, fromBar: current.fromBar)
    if target != current.target, target != nil {
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    current.target = target
    current.caret = caret
    drag = current
  }

  private func end() {
    guard var current = drag, !current.settling else { return }
    current.settling = true
    let id = current.id
    switch current.target {
    case nil:
      // Not on a valid place: fly back (0.2 s), or just fade with 减弱动态效果.
      drag = current
      withAnimation(.easeOut(duration: 0.2)) {
        if reduceMotion { ghostOpacity = 0 } else { drag?.location = current.origin; ghostScale = 0.9 }
      }
      finish(id, after: 0.2)
    case .remove:
      drag = current
      withAnimation(.easeIn(duration: 0.14)) { ghostScale = reduceMotion ? 1 : 0.4; ghostOpacity = 0 }
      withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.2)) {
        store.set(PlayerBarLayout.applying(.remove, item: current.item, to: store.items))
      }
      finish(id, after: 0.14)
    case .some(let target):
      drag = current
      withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.2)) {
        store.set(PlayerBarLayout.applying(target, item: current.item, to: store.items))
      }
      withAnimation(.easeOut(duration: 0.16)) { ghostOpacity = 0; if !reduceMotion { ghostScale = 0.8 } }
      finish(id, after: 0.16)
    }
  }

  private func finish(_ id: UUID, after delay: Double) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      if drag?.id == id { drag = nil; ghostScale = 1; ghostOpacity = 1 }
    }
  }

  /// Names show 0.14 s after the pointer settles on a preview item, never while dragging.
  private func hovering(_ item: PlayerBarItem, _ inside: Bool) {
    hoverTask?.cancel()
    guard inside, drag == nil else {
      if hover == item || !inside { withAnimation(.easeOut(duration: 0.1)) { hover = nil } }
      return
    }
    hoverTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(140))
      guard !Task.isCancelled, drag == nil else { return }
      withAnimation(.easeOut(duration: 0.14)) { hover = item }
    }
  }

  // MARK: Keyboard and VoiceOver edits

  private func move(_ item: PlayerBarItem, by offset: Int) {
    withAnimation(.spring(duration: 0.2)) { store.set(PlayerBarLayout.moving(item, by: offset, in: store.items)) }
  }
  private func remove(_ item: PlayerBarItem) {
    withAnimation(.spring(duration: 0.2)) { store.set(PlayerBarLayout.applying(.remove, item: item, to: store.items)) }
  }
  private func add(_ item: PlayerBarItem) {
    withAnimation(.spring(duration: 0.2)) { store.set(PlayerBarLayout.adding(item, to: store.items)) }
  }

  // MARK: Screenshot checks

  #if DEBUG
  /// `--ui-bar-drag insert|replace|remove`: holds one drag state still for screenshots.
  static let debugDrag: String? = {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--ui-bar-drag"), index + 1 < args.count else { return nil }
    return args[index + 1]
  }()
  /// `--ui-bar-width 1000`: the simulated picture width to start with.
  static let debugWidth: CGFloat? = {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--ui-bar-width"), index + 1 < args.count, let value = Double(args[index + 1]) else { return nil }
    return CGFloat(value)
  }()
  #else
  static let debugDrag: String? = nil
  static let debugWidth: CGFloat? = nil
  #endif

  private func applyDebugDrag() {
    guard let mode = Self.debugDrag, !debugApplied, barBox.width > 0 else { return }
    let slots = slots
    guard slots.count >= 2 else { return }
    debugApplied = true
    let item: PlayerBarItem = PlayerBarItem.allCases.first { !store.items.contains($0) } ?? .screenshot
    let point: CGPoint
    var fromBar = false
    var dragged = item
    switch mode {
    case "replace":
      point = CGPoint(x: rowOrigin + ((slots[1].start + slots[1].end) / 2 + 6) * barScale, y: barFrame.midY + 12)
    case "remove":
      fromBar = true; dragged = slots[0].item
      point = CGPoint(x: rowOrigin + (slots[0].end + 40) * barScale, y: barFrame.minY - 64)
    default:
      point = CGPoint(x: rowOrigin + (slots[1].start - 1) * barScale, y: barFrame.midY + 24)
    }
    drag = Drag(item: dragged, fromBar: fromBar, origin: point, location: point)
    update(to: point)
  }
}

// MARK: - Preview pieces

/// The simulated picture behind the preview bar: a lake at dusk with two comments on it.
private struct PlayerBarBackdrop: View {
  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack(alignment: .topLeading) {
        RadialGradient(colors: [Color(red: 0.24, green: 0.56, blue: 0.69), Color(red: 0.11, green: 0.27, blue: 0.35),
          Color(red: 0.04, green: 0.09, blue: 0.13)], center: UnitPoint(x: 0.25, y: 0.3), startRadius: 0,
          endRadius: max(size.width, size.height) * 0.95)
        Path { path in
          let points: [(CGFloat, CGFloat)] = [(0, 0.8), (0.15, 0.47), (0.24, 0.68), (0.37, 0.34), (0.52, 0.72), (0.66, 0.51), (1, 0.85)]
          path.move(to: CGPoint(x: 0, y: size.height))
          for point in points { path.addLine(to: CGPoint(x: point.0 * size.width, y: point.1 * size.height)) }
          path.addLine(to: CGPoint(x: size.width, y: size.height))
          path.closeSubpath()
        }.fill(Color(red: 0.05, green: 0.14, blue: 0.19).opacity(0.8))
        Circle().fill(Color(red: 0.95, green: 0.91, blue: 0.82).opacity(0.8)).frame(width: 60, height: 60)
          .position(x: size.width * 0.7, y: 74)
        comment("这段配乐好舒服", color: Theme.mist).position(x: size.width * 0.5, y: 34)
        comment("前方高能", color: Theme.accentText(.dark)).position(x: size.width * 0.2, y: 66)
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
  private func comment(_ text: String, color: Color) -> some View {
    Text(text).font(.system(size: 17, weight: .bold)).foregroundStyle(color).fixedSize()
      .shadow(color: .black, radius: 1).shadow(color: .black, radius: 1)
  }
}

/// 播放、下一个、时间、弹幕开关, drawn like the player's but inert.
private struct PlayerBarPreviewLeading: View {
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "pause.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.backdrop(.dark))
        .frame(width: 40, height: 40).background(Circle().fill(Theme.mist.opacity(0.92)))
      Image(systemName: "forward.end.fill").font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32)
      Text("06:12 / 18:24").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.86))
        .lineLimit(1).frame(width: 96)
      DanmakuSymbol().fill(Theme.onAccent).frame(width: 18, height: 18)
        .frame(width: 32, height: 32).background(Circle().fill(Theme.accent))
    }.accessibilityElement(children: .ignore).accessibilityLabel("固定在左侧：播放、下一个、时间、弹幕开关")
  }
}

/// One item on the preview bar: 画质 and 倍速 as text, the rest as symbols.
private struct PlayerBarPreviewItem: View {
  let item: PlayerBarItem
  let width: CGFloat
  var body: some View {
    Group {
      switch item {
      case .quality: Text("1080P").font(.system(size: 12, weight: .semibold))
      case .speed: Text("1.0×").font(.system(size: 12, weight: .semibold).monospacedDigit())
      default: PlayerBarGlyph(item: item)
      }
    }
    .frame(width: width, height: 32)
  }
}

/// A card in 「可添加的项目」: symbol, name and one line; dimmed with 「已在控制条上」 once added,
/// and a dashed placeholder while it is being dragged.
private struct PlayerBarPaletteCard: View {
  let item: PlayerBarItem
  let onBar: Bool
  let lifted: Bool
  @Environment(\.colorScheme) private var scheme
  @State private var hovering = false
  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous) }
  var body: some View {
    HStack(spacing: 12) {
      PlayerBarGlyph(item: item, size: 14).foregroundStyle(Theme.text(scheme))
        .frame(width: 36, height: 36)
        .background(Circle().fill(Theme.fillHover(scheme)))
        .overlay(Circle().strokeBorder(Theme.separator(scheme)))
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(Theme.Font.headline).foregroundStyle(Theme.text(scheme)).lineLimit(1)
        Text(onBar ? "已在控制条上" : item.note).font(Theme.Font.caption2)
          .foregroundStyle(onBar ? Theme.accentText(scheme) : Theme.secondaryText(scheme)).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12).frame(height: 64)
    .background(shape.fill(onBar ? Theme.fill(scheme) : hovering ? Theme.raised(scheme) : Theme.card(scheme)))
    .overlay(shape.strokeBorder(Theme.separator(scheme), style: StrokeStyle(lineWidth: 1, dash: lifted ? [4, 3] : [])))
    .opacity(onBar ? 0.5 : lifted ? 0.35 : 1)
    .contentShape(shape)
    .onHover { value in withAnimation(Theme.hoverAnimation) { hovering = value && !onBar } }
    .onContinuousHover { phase in
      if case .active = phase, !onBar { NSCursor.openHand.set() } else if !onBar { NSCursor.arrow.set() }
    }
    .animation(.easeOut(duration: 0.15), value: onBar)
    .animation(.easeOut(duration: 0.15), value: lifted)
  }
}
