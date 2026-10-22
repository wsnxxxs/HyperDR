import HyperDRDesign
import SwiftUI

/// The ruler under the iPhone's ring row (p7-adjustments §5.4): a fixed
/// needle in the middle over a tape of the control's range.
///
/// One rule for every range: the tape runs from the lower bound on the left
/// to the upper bound on the right and stops there, so the empty side of the
/// needle says the value cannot go further that way. 0 of 0…100 has tape on
/// the right only, 0 of ±100 on both sides, a strength at its 100 default on
/// the left only. The ticks between the default (a dot) and the needle are
/// lit; when the default is off the ruler, the dot waits at that edge with a
/// chevron, so the way back is always in sight. An Auto default is no
/// exception: its dot is what Auto resolves to, and dragging back onto it is
/// Auto again.
///
/// - Dragging anywhere moves the tape with the finger, from where it was:
///   touching never jumps, the finger never covers the needle, and every
///   control takes the same travel from its default to its far end. Moving
///   the finger 40 pt above or below the ruler halves the speed, 100 pt
///   quarters it, with a hint while that lasts.
/// - The value holds at the default for a few points, with a light tap; a
///   major tick gives a selection tick, an end of the range a firmer one.
/// - Double-tap resets.
///
/// The math is `RulerScale` (HyperDRDesign, unit-tested); this view draws
/// it and turns gestures into values.
struct AdjustmentRuler: View {
    let control: RulerControl
    let write: (Double) -> Void
    let reset: () -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    init(control: RulerControl, write: @escaping (Double) -> Void, reset: @escaping () -> Void,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.control = control
        self.write = write
        self.reset = reset
        self.onEditingChanged = onEditingChanged
    }

    init(control: AdjustmentControl, write: @escaping (Double) -> Void, reset: @escaping () -> Void,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(control: RulerControl(control), write: write, reset: reset, onEditingChanged: onEditingChanged)
    }

    /// The unsnapped value while a drag is under way, so the tape follows
    /// the finger between steps.
    @State private var moving: Double?
    /// Where the current speed took over: the value then and the finger's x.
    @State private var anchor: (value: Double, x: CGFloat)?
    @State private var speed = FineTune.full
    @State private var tickHits = 0
    @State private var defaultHits = 0
    @State private var limitHits = 0
    @Environment(\.isEnabled) private var isEnabled

    private var tint: Color { control.tint }
    private var followsAutomatic: Bool { control.followsAutomatic }

    private var value: Double { moving ?? control.value }

    var body: some View {
        GeometryReader { geometry in
            if let scale = control.scale(geometry.size.width) {
                Canvas { context, size in draw(scale, in: &context, size: size) }
                    .contentShape(.rect)
                    .gesture(drag(scale, height: geometry.size.height))
                    .onTapGesture(count: 2) {
                        end()
                        reset()
                        defaultHits += 1
                    }
                    .overlay(alignment: .top) { hint }
                    .accessibilityElement()
                    .accessibilityLabel(control.label)
                    .accessibilityValue(Text(verbatim: control.readout))
                    .accessibilityAdjustableAction { direction in
                        let step = control.step ?? scale.step
                        write(scale.settled(value + (direction == .increment ? step : -step)))
                    }
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .onDisappear(perform: end)
        .sensoryFeedback(.selection, trigger: tickHits)
        .sensoryFeedback(.impact(weight: .light), trigger: defaultHits)
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: limitHits)
    }

    @ViewBuilder private var hint: some View {
        if anchor != nil, let hint = speed.hint {
            hint
                .font(.caption2.weight(.medium))
                .padding(.horizontal, Space.s2)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: .capsule)
                .fixedSize()
                .offset(y: -24)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: Gesture

    private func drag(_ scale: RulerScale, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                if anchor == nil {
                    anchor = (value, drag.startLocation.x)
                    onEditingChanged(true)
                }
                // A new speed applies from where the finger is now, not to the whole drag.
                let newSpeed = FineTune(verticalDistance: drag.location.y - height / 2)
                if newSpeed != speed {
                    speed = newSpeed
                    anchor = (value, drag.location.x)
                }
                guard let anchor else { return }
                move(to: scale.value(from: anchor.value, translation: drag.location.x - anchor.x, speed: speed.factor),
                     scale)
            }
            .onEnded { _ in end() }
    }

    /// Ends the drag, if any, leaving the value on the step grid.
    private func end() {
        guard anchor != nil else { return }
        anchor = nil
        speed = .full
        moving = nil
        onEditingChanged(false)
    }

    private func move(to raw: Double, _ scale: RulerScale) {
        let old = value
        moving = raw
        let crossing = scale.crossing(from: old, to: raw)
        if crossing.defaultValue { defaultHits += 1 } else if crossing.limit { limitHits += 1 } else if crossing.majorTick { tickHits += 1 }
        let settled = scale.settled(raw)
        if followsAutomatic, settled == scale.defaultValue {
            // Back on the dot of an Auto default is Auto again, not its number of the moment.
            if !control.isAutomatic { reset() }
        } else if settled != control.number || control.isAutomatic {
            write(settled)
        }
    }

    // MARK: Drawing

    private func draw(_ scale: RulerScale, in context: inout GraphicsContext, size: CGSize) {
        let depth = size.height, width = size.width
        let centre = width / 2, needle = value
        let x = { (value: Double) in centre + scale.offset(of: value, needle: needle) }
        // Ticks fade out over the last stretch before either edge.
        let fade = max(width * 0.14, 1)
        let opacity = { (at: CGFloat) in min(1, max(0, min(at, width - at) / fade)) }
        // Lit from the default (else the fill's origin) to the value; an Auto
        // default not yet resolved has nothing to light from.
        let base = scale.defaultValue ?? (followsAutomatic ? nil : control.origin ?? scale.range.lowerBound)
        let lit = control.isAutomatic ? nil : base.flatMap { $0 == value ? nil : min($0, value)...max($0, value) }
        for tick in scale.ticks {
            let at = x(tick.value)
            let alpha = opacity(at)
            guard alpha > 0 else { continue }
            let isBound = tick.value == scale.range.lowerBound || tick.value == scale.range.upperBound
            let extent = depth * (isBound ? 0.56 : tick.isMajor ? 0.46 : 0.26)
            let line = Path {
                $0.move(to: CGPoint(x: at, y: (depth - extent) / 2))
                $0.addLine(to: CGPoint(x: at, y: (depth + extent) / 2))
            }
            let color: Color = if let lit, lit.contains(tick.value) {
                tint.opacity(0.9)
            } else {
                .white.opacity(tick.isMajor ? 0.7 : 0.32)
            }
            context.stroke(line, with: .color(color.opacity(alpha)),
                           style: StrokeStyle(lineWidth: isBound ? 2 : 1.5, lineCap: .round))
        }
        if let defaultValue = scale.defaultValue {
            drawDefault(at: x(defaultValue), in: &context, width: width, depth: depth)
        }
        // Auto has no value of its own to hold: an open needle, as its ring is dashed,
        // in the control's colour so it never reads as one of the ticks.
        if control.isAutomatic {
            let mark = Path(roundedRect: CGRect(x: centre - 2.25, y: depth * 0.14, width: 4.5, height: depth * 0.72),
                            cornerRadius: 2.25)
            context.fill(mark, with: .color(.black))
            context.stroke(mark, with: .color(tint), lineWidth: 1.5)
        } else {
            let mark = Path(roundedRect: CGRect(x: centre - 1.5, y: depth * 0.16, width: 3, height: depth * 0.68),
                            cornerRadius: 1.5)
            context.fill(mark, with: .color(tint))
        }
    }

    /// The default's dot over its tick, or at the edge it lies beyond with a
    /// chevron pointing there.
    private func drawDefault(at position: CGFloat, in context: inout GraphicsContext, width: CGFloat, depth: CGFloat) {
        let margin: CGFloat = 6
        let y = depth * 0.06
        let dot = { (at: CGFloat) in Path(ellipseIn: CGRect(x: at - 2, y: y - 2, width: 4, height: 4)) }
        if position >= margin, position <= width - margin {
            context.fill(dot(position), with: .color(.white.opacity(0.9)))
            return
        }
        let leading = position < margin
        let at = leading ? margin + 6 : width - margin - 6
        context.fill(dot(at), with: .color(.white.opacity(0.9)))
        let tip = leading ? at - 7 : at + 7, back = leading ? tip + 3 : tip - 3
        let chevron = Path {
            $0.move(to: CGPoint(x: back, y: y - 3))
            $0.addLine(to: CGPoint(x: tip, y: y))
            $0.addLine(to: CGPoint(x: back, y: y + 3))
        }
        context.stroke(chevron, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

/// What the ruler draws and sets: a declared parameter's control, or one of
/// the crop pane's (straightening, perspective).
struct RulerControl {
    /// The number shown, Auto resolved included.
    let value: Double
    /// The number stored, when there is one (not Auto).
    let number: Double?
    let isAutomatic: Bool
    /// The default is Auto: the ruler's default is what it resolves to.
    let followsAutomatic: Bool
    let tint: Color
    let label: Text
    let readout: String
    /// The accessibility step; the scale's when nil.
    let step: Double?
    /// Where the fill grows from without a default.
    let origin: Double?
    /// The scale for a ruler `width` points wide.
    let scale: (CGFloat) -> RulerScale?

    init(value: Double, number: Double?, isAutomatic: Bool = false, followsAutomatic: Bool = false, tint: Color,
         label: Text, readout: String, step: Double?, origin: Double?, scale: @escaping (CGFloat) -> RulerScale?) {
        self.value = value
        self.number = number
        self.isAutomatic = isAutomatic
        self.followsAutomatic = followsAutomatic
        self.tint = tint
        self.label = label
        self.readout = readout
        self.step = step
        self.origin = origin
        self.scale = scale
    }

    init(_ control: AdjustmentControl) {
        self.init(value: control.number ?? control.defaultNumber ?? control.declaration.range?.lowerBound ?? 0,
                  number: control.number, isAutomatic: control.isAutomatic,
                  followsAutomatic: control.kind == .floatOrAuto && control.defaultNumber == nil,
                  tint: control.group == .hdr ? Color.hdr.amber : Color.hdr.accent,
                  label: AdjustmentText.label(control.declaration), readout: control.readout(),
                  step: control.spec?.step, origin: control.spec?.origin,
                  scale: { RulerScale(control, width: $0) })
    }
}
