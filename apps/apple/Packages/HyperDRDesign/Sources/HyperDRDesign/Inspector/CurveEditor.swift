import SwiftUI

/// A handle on a `CurveEditor`: one parameter, moved along one axis of the
/// plot.
///
/// The value is in plot units along that axis: a horizontal handle's value
/// is an SDR level 0…1, a vertical one's is stops on the editor's gain axis.
/// `at` is the other coordinate, which the caller works out (for instance
/// the curve's height at the handle).
public struct CurveHandle: Identifiable {
    public enum Axis: Sendable { case horizontal, vertical }

    public let id: String
    public let title: LocalizedStringKey
    public let axis: Axis
    public let value: Binding<Double>
    public let spec: ParameterSpec
    public let at: Double

    public init(id: String, title: LocalizedStringKey, axis: Axis, value: Binding<Double>,
                spec: ParameterSpec, at: Double) {
        self.id = id
        self.title = title
        self.axis = axis
        self.value = value
        self.spec = spec
        self.at = at
    }

    /// The handle's point in plot units: x an SDR level, y stops.
    var point: CGPoint {
        axis == .horizontal ? CGPoint(x: value.wrappedValue, y: at) : CGPoint(x: at, y: value.wrappedValue)
    }
}

/// The gain curve: how many stops above SDR each SDR level is lifted.
///
/// Appearance and interaction only. The curve is whatever `samples` the
/// caller passes -- in M2 the engine's `hyperdr_curve_json` (`gain_stops` at
/// evenly spaced SDR levels 0…1) -- and the handles edit parameters the
/// caller turns back into samples. The editor does no curve maths.
///
/// - The plot is square: SDR level across, 0 at the left to SDR white at the
///   right; stops up, 0 (the SDR rendition, drawn as the baseline) to
///   `stopsRange.upperBound`. The curve is amber, the extended-range colour.
/// - Drag a handle along its axis; double-click it to reset. With keyboard
///   navigation on, each handle takes focus and the arrow keys along its
///   axis step it (Shift: ten steps).
/// - VoiceOver sees the plot as a group named `title` and each handle as a
///   slider with the formatted value and Reset to Default.
public struct CurveEditor: View {
    private let title: LocalizedStringKey
    private let samples: [Double]
    private let stopsRange: ClosedRange<Double>
    private let handles: [CurveHandle]
    private let onEditingChanged: (String, Bool) -> Void

    static let inset: CGFloat = 10

    /// `onEditingChanged(handle id, editing)` brackets each pointer drag of a
    /// handle (`beginAdjusting` / `endAdjusting`); keyboard steps and resets
    /// are single writes outside it, as on `ParameterSlider`.
    public init(_ title: LocalizedStringKey, samples: [Double], stopsRange: ClosedRange<Double>,
                handles: [CurveHandle] = [], onEditingChanged: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.title = title
        self.samples = samples
        self.stopsRange = stopsRange
        self.handles = handles
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            GeometryReader { geometry in
                let plot = CurvePlot(size: geometry.size, inset: Self.inset, stops: stopsRange)
                ZStack(alignment: .topLeading) {
                    CurveCanvas(plot: plot, samples: samples)
                        .accessibilityHidden(true)
                    ForEach(handles) { handle in
                        CurveHandleView(handle: handle, plot: plot) { onEditingChanged(handle.id, $0) }
                    }
                }
                .coordinateSpace(.named(CurvePlot.space))
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                // The top of the gain axis.
                Text("design.curve.stops \(stopsRange.upperBound.formatted(.number.precision(.fractionLength(0...1))))",
                     bundle: .module)
                    .font(.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .padding(.leading, Self.inset + Space.s1)
                    .padding(.top, Self.inset + 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.md))
            .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.hdr.line) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title))
            scale
        }
    }

    /// 0 · SDR 100% under the plot, as the histogram's scale (CSS `.scope-scale`).
    private var scale: some View {
        HStack {
            Text(verbatim: "0")
            Spacer()
            Text("design.curve.sdrWhite", bundle: .module)
        }
        .font(.hdr.caption)
        .foregroundStyle(Color.hdr.inkMuted)
        .accessibilityHidden(true)
    }
}

/// Plot ↔ view coordinates. The plot keeps `inset` clear on every side so
/// handles at the edges are whole.
struct CurvePlot {
    /// Drags are measured here: the handle moves under the pointer, so its
    /// own coordinates would shift during the drag.
    static let space = "hyperdr.curvePlot"

    let size: CGSize
    let inset: CGFloat
    let stops: ClosedRange<Double>

    var rect: CGRect { CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset) }

    func point(_ p: CGPoint) -> CGPoint {
        let r = rect
        let t = (p.y - stops.lowerBound) / (stops.upperBound - stops.lowerBound)
        return CGPoint(x: r.minX + r.width * p.x, y: r.maxY - r.height * t)
    }

    /// Plot units per point along an axis.
    func unitsPerPoint(_ axis: CurveHandle.Axis) -> Double {
        axis == .horizontal ? 1 / rect.width : (stops.upperBound - stops.lowerBound) / rect.height
    }
}

private struct CurveCanvas: View {
    let plot: CurvePlot
    let samples: [Double]

    var body: some View {
        Canvas { context, _ in
            let r = plot.rect
            // Quarters across; whole stops up.
            var grid = Path()
            for i in 1..<4 {
                let x = r.minX + r.width * Double(i) / 4
                grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY))
            }
            var stop = plot.stops.lowerBound.rounded(.up)
            while stop <= plot.stops.upperBound {
                if stop > plot.stops.lowerBound {
                    let y = plot.point(CGPoint(x: 0, y: stop)).y
                    grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y))
                }
                stop += 1
            }
            context.stroke(grid, with: .color(.hdr.histogramGrid), lineWidth: 1)

            // The SDR rendition: no gain.
            let base = plot.point(CGPoint(x: 0, y: max(0, plot.stops.lowerBound))).y
            var baseline = Path()
            baseline.move(to: CGPoint(x: r.minX, y: base)); baseline.addLine(to: CGPoint(x: r.maxX, y: base))
            context.stroke(baseline, with: .color(.hdr.lineStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            guard samples.count > 1 else { return }
            var curve = Path()
            for (i, gain) in samples.enumerated() {
                let p = plot.point(CGPoint(x: Double(i) / Double(samples.count - 1),
                                           y: min(max(gain, plot.stops.lowerBound), plot.stops.upperBound)))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }
            var area = curve
            area.addLine(to: CGPoint(x: r.maxX, y: base))
            area.addLine(to: CGPoint(x: r.minX, y: base))
            area.closeSubpath()
            context.fill(area, with: .color(.hdr.amberSoft))
            context.stroke(curve, with: .color(.hdr.histogramOutput),
                           style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct CurveHandleView: View {
    let handle: CurveHandle
    let plot: CurvePlot
    let onEditingChanged: (Bool) -> Void

    @State private var hovered = false
    @State private var start: Double?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    static let size: CGFloat = 11

    var body: some View {
        let center = plot.point(handle.point)
        let active = start != nil || focused
        ZStack(alignment: .topLeading) {
            if hovered || active {
                guide(at: center)
            }
            dot(active: active)
                .position(center)
        }
        .hdrAnimation(Motion.fast, value: hovered)
    }

    /// The handle itself, carrying its gestures, focus and accessibility, so
    /// they cover the dot rather than the plot.
    private func dot(active: Bool) -> some View {
        Circle()
            .fill(active ? Color.hdr.inkStrong : Color.hdr.surfaceCard)
            .overlay { Circle().strokeBorder(isEnabled ? Color.hdr.ink : Color.hdr.inkDisabled, lineWidth: 1.5) }
            .frame(width: Self.size, height: Self.size)
            .background { Circle().fill(Color.hdr.controlTrack).padding(hovered || start != nil ? -4 : 0) }
            .overlay { if focused { Circle().stroke(Color.hdr.focus, lineWidth: 2).padding(-4) } }
            // A larger target than the dot.
            .padding(6)
            .contentShape(.circle)
            .onHover { hovered = isEnabled && $0 }
            .gesture(drag)
            .simultaneousGesture(TapGesture(count: 2).onEnded { set(handle.spec.defaultValue) })
            .focusable(interactions: .activate)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: keys, phases: [.down, .repeat]) { press in
                let up = press.key == .rightArrow || press.key == .upArrow
                set(handle.spec.stepped(handle.value.wrappedValue,
                                        by: (up ? 1 : -1) * (press.modifiers.contains(.shift) ? 10 : 1)))
                return .handled
            }
            .help(Text(handle.title))
            .accessibilityRepresentation {
                Slider(value: Binding(get: { handle.value.wrappedValue },
                                      set: { set(handle.spec.snapped($0)) }),
                       in: handle.spec.range, step: handle.spec.step) { Text(handle.title) }
                    .accessibilityValue(Text(verbatim: handle.spec.formatted(handle.value.wrappedValue)))
                    .accessibilityAction(named: Text("design.slider.reset", bundle: .module)) {
                        set(handle.spec.defaultValue)
                    }
            }
    }

    private var keys: Set<KeyEquivalent> {
        handle.axis == .horizontal ? [.leftArrow, .rightArrow] : [.upArrow, .downArrow]
    }

    /// A dashed line across the plot through the handle, along its axis.
    private func guide(at center: CGPoint) -> some View {
        Path { path in
            let r = plot.rect
            if handle.axis == .horizontal {
                path.move(to: CGPoint(x: center.x, y: r.minY)); path.addLine(to: CGPoint(x: center.x, y: r.maxY))
            } else {
                path.move(to: CGPoint(x: r.minX, y: center.y)); path.addLine(to: CGPoint(x: r.maxX, y: center.y))
            }
        }
        .stroke(Color.hdr.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CurvePlot.space))
            .onChanged { drag in
                // Secondary clicks and drags belong to the context menu.
                guard isPrimaryPointerEvent else { return }
                if start == nil {
                    start = handle.value.wrappedValue
                    onEditingChanged(true)
                }
                let units = plot.unitsPerPoint(handle.axis)
                let delta = handle.axis == .horizontal ? drag.translation.width * units : -drag.translation.height * units
                let new = handle.spec.snapped((start ?? 0) + delta)
                if new != handle.value.wrappedValue { handle.value.wrappedValue = new }
            }
            .onEnded { _ in
                // Nothing began (a secondary click): nothing to end.
                guard start != nil else { return }
                start = nil
                onEditingChanged(false)
            }
    }

    /// A single write outside any drag: one undo step of its own.
    private func set(_ new: Double) {
        if new != handle.value.wrappedValue { handle.value.wrappedValue = new }
    }
}
