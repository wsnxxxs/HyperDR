import HyperDRDesign
import SwiftUI

/// The ruler under the iPhone's ring row (p7-adjustments §5.4): the control's
/// whole range laid across the ruler, and a needle at the value.
///
/// - A signed control has its zero in the middle, a one-sided one starts at
///   the left end; the ticks between the default and the value are lit.
/// - Dragging anywhere moves the needle with the finger, from where it was:
///   touching never jumps. Moving the finger 40 pt above or below the ruler
///   halves the speed, 100 pt quarters it, with a hint while that lasts.
/// - The value holds at the default for a few points, with a light tap; a
///   major tick gives a selection tick, an end of the range a firmer one.
/// - Double-tap resets.
///
/// The math is `RulerScale` (HyperDRDesign, unit-tested); this view draws
/// it and turns gestures into values.
struct AdjustmentRuler: View {
    let control: AdjustmentControl
    let write: (Double) -> Void
    let reset: () -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The unsnapped value while a drag is under way, so the needle follows
    /// the finger between steps.
    @State private var moving: Double?
    /// Where the current speed took over: the value then and the finger's x.
    @State private var anchor: (value: Double, x: CGFloat)?
    @State private var speed = FineTune.full
    @State private var tickHits = 0
    @State private var defaultHits = 0
    @State private var limitHits = 0
    @Environment(\.isEnabled) private var isEnabled

    private var tint: Color { control.group == .hdr ? Color.hdr.amber : Color.hdr.accent }

    private var value: Double {
        moving ?? control.number ?? control.defaultNumber ?? control.declaration.range?.lowerBound ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            if let scale = RulerScale(control, width: geometry.size.width) {
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
                    .accessibilityLabel(AdjustmentText.label(control.declaration))
                    .accessibilityValue(Text(verbatim: control.readout()))
                    .accessibilityAdjustableAction { direction in
                        let step = control.spec?.step ?? scale.step
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
        if settled != control.number { write(settled) }
    }

    // MARK: Drawing

    private func draw(_ scale: RulerScale, in context: inout GraphicsContext, size: CGSize) {
        let depth = size.height
        let left = Double(RulerScale.inset)
        let x = { (value: Double) in left + scale.position(of: value) }
        // Lit from the default (else the fill's origin) to the value.
        let base = scale.defaultValue ?? control.spec?.origin ?? scale.range.lowerBound
        let lit = control.isAutomatic ? nil : (min(base, value)...max(base, value))
        var ticks = Path(), majors = Path(), litTicks = Path()
        for tick in scale.ticks {
            let extent = depth * (tick.isMajor ? 0.5 : 0.28)
            let at = x(tick.value)
            let line = Path {
                $0.move(to: CGPoint(x: at, y: (depth - extent) / 2))
                $0.addLine(to: CGPoint(x: at, y: (depth + extent) / 2))
            }
            if let lit, lit.contains(tick.value), lit.lowerBound != lit.upperBound {
                litTicks.addPath(line)
            } else if tick.isMajor {
                majors.addPath(line)
            } else {
                ticks.addPath(line)
            }
        }
        context.stroke(ticks, with: .color(.white.opacity(0.3)), lineWidth: 1)
        context.stroke(majors, with: .color(.white.opacity(0.65)), lineWidth: 1)
        context.stroke(litTicks, with: .color(tint.opacity(0.85)), lineWidth: 1)
        if let defaultValue = scale.defaultValue {
            let at = x(defaultValue)
            context.fill(Path(ellipseIn: CGRect(x: at - 2, y: depth * 0.1 - 2, width: 4, height: 4)),
                         with: .color(.white.opacity(0.9)))
        }
        // Auto has no value of its own to hold: a quieter needle at what it resolves to.
        let needle = Path(roundedRect: CGRect(x: x(value) - 1.5, y: depth * 0.18, width: 3, height: depth * 0.64),
                          cornerRadius: 1.5)
        context.fill(needle, with: .color(control.isAutomatic ? .white.opacity(0.55) : tint))
    }
}
