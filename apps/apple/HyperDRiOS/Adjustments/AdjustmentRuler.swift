import HyperDRDesign
import SwiftUI

/// The ruler under the iPhone's ring row (p7-adjustments §5.4): a fixed needle
/// over a scale that the finger drags left and right, the full range about
/// two and a half widths of the ruler (also in the standing bar of landscape). It keeps moving after a flick and settles on the step
/// grid; passing the default gives a light tap and holds there for 2 pt,
/// passing a major tick a selection tick. Double-tap resets.
///
/// The math is `RulerScale` (HyperDRDesign, unit-tested); this view draws
/// it and turns gestures into values.
struct AdjustmentRuler: View {
    let control: AdjustmentControl
    let write: (Double) -> Void
    let reset: () -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The unsnapped value while a drag or a flick is under way, so the scale
    /// follows the finger between steps.
    @State private var moving: Double?
    @State private var dragStart: Double?
    @State private var flick: Task<Void, Never>?
    /// Between the first touch and the end of the flick: one editing session,
    /// also when a new drag catches the scale mid-flick.
    @State private var editing = false
    @State private var tickHits = 0
    @State private var defaultHits = 0
    @Environment(\.isEnabled) private var isEnabled

    private var value: Double {
        moving ?? control.number ?? control.defaultNumber ?? control.declaration.range?.lowerBound ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            if let scale = RulerScale(control, referenceWidth: geometry.size.width) {
                Canvas { context, size in draw(scale, in: &context, size: size) }
                    .contentShape(.rect)
                    .gesture(drag(scale))
                    .onTapGesture(count: 2) {
                        stop()
                        reset()
                        defaultHits += 1
                    }
                    .mask(fade)
                    .accessibilityElement()
                    .accessibilityLabel(AdjustmentText.label(control.declaration))
                    .accessibilityValue(Text(verbatim: control.readout()))
                    .accessibilityAdjustableAction { direction in
                        let step = control.spec?.step ?? scale.step
                        write(value + (direction == .increment ? step : -step))
                    }
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .onDisappear(perform: stop)
        .sensoryFeedback(.selection, trigger: tickHits)
        .sensoryFeedback(.impact(weight: .light), trigger: defaultHits)
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                               .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }

    // MARK: Gesture

    private func drag(_ scale: RulerScale) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                if dragStart == nil {
                    flick?.cancel()
                    dragStart = value
                    if !editing {
                        editing = true
                        onEditingChanged(true)
                    }
                }
                guard let dragStart else { return }
                move(to: scale.value(from: dragStart, translation: drag.translation.width), scale)
            }
            .onEnded { drag in
                guard let start = dragStart else { return }
                dragStart = nil
                let target = scale.settled(scale.value(from: start, translation: drag.predictedEndTranslation.width))
                let from = value
                flick = Task { @MainActor in
                    // A short ease-out from where the finger left to where the flick ends.
                    let frames = abs(target - from) * scale.pointsPerUnit > 8 ? 20 : 1
                    for frame in 1...frames {
                        let t = Double(frame) / Double(frames)
                        move(to: from + (target - from) * (1 - pow(1 - t, 3)), scale)
                        if frame < frames { try? await Task.sleep(for: .milliseconds(16)) }
                        if Task.isCancelled { return }
                    }
                    stop()
                }
            }
    }

    /// Ends the flick and the editing session, if any.
    private func stop() {
        flick?.cancel()
        flick = nil
        moving = nil
        dragStart = nil
        if editing {
            editing = false
            onEditingChanged(false)
        }
    }

    private func move(to raw: Double, _ scale: RulerScale) {
        let old = value
        let new = DefaultDetent.apply(raw, defaultValue: scale.defaultValue, pointsPerUnit: scale.pointsPerUnit)
        moving = new
        let crossing = scale.crossing(from: old, to: new)
        if crossing.defaultValue { defaultHits += 1 } else if crossing.majorTick { tickHits += 1 }
        write(new)
    }

    // MARK: Drawing

    private func draw(_ scale: RulerScale, in context: inout GraphicsContext, size: CGSize) {
        let depth = size.height
        let centre = size.width / 2
        let ppu = scale.pointsPerUnit
        let position = { (tick: Double) in centre + (tick - value) * ppu }
        let lowest = max(scale.range.lowerBound, value - Double(centre) / ppu)
        let highest = min(scale.range.upperBound, value + Double(centre) / ppu)
        let minor = scale.minorTick
        var index = ((lowest - scale.range.lowerBound) / minor).rounded(.up)
        var tick = scale.range.lowerBound + index * minor
        var ticks = Path(), majors = Path()
        while tick <= highest + 1e-9 {
            let ratio = tick / scale.majorTick
            let isMajor = abs(ratio - ratio.rounded()) < 1e-6
            let extent = depth * (isMajor ? 0.5 : 0.28)
            let at = position(tick)
            let line = Path {
                $0.move(to: CGPoint(x: at, y: (depth - extent) / 2))
                $0.addLine(to: CGPoint(x: at, y: (depth + extent) / 2))
            }
            if isMajor { majors.addPath(line) } else { ticks.addPath(line) }
            index += 1
            tick = scale.range.lowerBound + index * minor
        }
        context.stroke(ticks, with: .color(.white.opacity(0.35)), lineWidth: 1)
        context.stroke(majors, with: .color(.white.opacity(0.75)), lineWidth: 1)
        if let defaultValue = scale.defaultValue, (lowest...highest).contains(defaultValue) {
            let at = position(defaultValue)
            context.fill(Path(ellipseIn: CGRect(x: at - 2, y: depth * 0.12 - 2, width: 4, height: 4)), with: .color(.white))
        }
        context.fill(Path(CGRect(x: centre - 1, y: 0, width: 2, height: depth)), with: .color(control.group == .hdr ? Color.hdr.amber : Color.hdr.accent))
    }
}
