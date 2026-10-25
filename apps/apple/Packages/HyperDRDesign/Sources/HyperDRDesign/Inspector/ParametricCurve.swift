import HyperDRRecipe
import SwiftUI

/// The parametric curve's picture: four zones (shadows, darks, lights,
/// highlights) split by three boundaries, each zone lifted or pressed by its
/// amount, black and SDR white fixed, the zones blending smoothly. The values
/// are the renderer's own curve; the plot only keeps them monotone.
struct ParametricCurvePreview: Equatable {
    /// Shadows, darks, lights, highlights, −100…+100.
    var amounts: [Double]
    /// The three boundaries in percent, increasing.
    var splits: [Double]

    static let neutral = ParametricCurvePreview(amounts: [0, 0, 0, 0], splits: [25, 50, 75])

    var isIdentity: Bool { amounts.allSatisfy { $0 == 0 } }

    /// The renderer's own curve (HyperDRRecipe's `ParametricCurve`), so the
    /// plot shows what the photo gets.
    func value(at x: Double) -> Double {
        guard amounts.count == 4, splits.count == 3 else { return min(max(x, 0), 1) }
        return ParametricCurve.value(at: x, highlights: amounts[3], lights: amounts[2], darks: amounts[1],
                                     shadows: amounts[0], splits: splits)
    }

    /// `count` samples across 0…1, made monotone.
    func samples(count: Int) -> [Double] {
        var highest = 0.0
        return (0..<count).map { i in
            highest = max(highest, min(max(value(at: Double(i) / Double(count - 1)), 0), 1))
            return highest
        }
    }

    /// The boundary at `index` moved to `percent`, kept between its
    /// neighbours with a gap of `minimumGap` percent.
    static func moved(_ splits: [Double], index: Int, to percent: Double, minimumGap: Double = 5) -> [Double] {
        guard splits.indices.contains(index) else { return splits }
        var splits = splits
        let lower = (index > 0 ? splits[index - 1] : 0) + minimumGap
        let upper = (index + 1 < splits.count ? splits[index + 1] : 100) - minimumGap
        splits[index] = min(max(percent, lower), max(lower, upper)).rounded()
        return splits
    }
}

/// The parametric curve as a plot with its three zone boundaries under it
/// (adjust-tools §2.1). The plot is a picture; the boundaries are the
/// draggable part, one undo step per drag, and double-click or double-tap
/// puts one back where it started.
struct ParametricCurveEditor: View {
    let preview: ParametricCurvePreview
    let style: AdjustmentControlStyle
    let moveSplit: (Int, Double) -> Void
    let onEditingChanged: (Int, Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled

    private static let inset: CGFloat = 12
    private static let space = "hyperdr.parametricPlot"

    var body: some View {
        VStack(spacing: 0) {
            plot.aspectRatio(1, contentMode: .fit)
            GeometryReader { geometry in
                let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.inset, dy: 0)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<3, id: \.self) { index in
                        SplitHandle(index: index, percent: preview.splits[index], rect: rect, style: style,
                                    space: Self.space, move: moveSplit, onEditingChanged: onEditingChanged)
                    }
                }
                .coordinateSpace(.named(Self.space))
            }
            .frame(height: style == .touch ? 40 : 26)
        }
    }

    private var plot: some View {
        Canvas { context, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: Self.inset, dy: Self.inset)
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: r.minX + r.width * x, y: r.maxY - r.height * y)
            }
            var grid = Path()
            for i in 1..<4 {
                let t = Double(i) / 4
                grid.move(to: point(t, 0)); grid.addLine(to: point(t, 1))
                grid.move(to: point(0, t)); grid.addLine(to: point(1, t))
            }
            context.stroke(grid, with: .color(.hdr.histogramGrid), lineWidth: 1)
            var zones = Path()
            for edge in preview.splits {
                zones.move(to: point(edge / 100, 0)); zones.addLine(to: point(edge / 100, 1))
            }
            context.stroke(zones, with: .color(.hdr.lineStrong), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            var diagonal = Path()
            diagonal.move(to: point(0, 0)); diagonal.addLine(to: point(1, 1))
            context.stroke(diagonal, with: .color(.hdr.lineStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let samples = preview.samples(count: 192)
            var curve = Path()
            for (i, value) in samples.enumerated() {
                let p = point(Double(i) / Double(samples.count - 1), value)
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }
            context.stroke(curve, with: .color(.hdr.accent),
                           style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
        }
        .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.hdr.line) }
        .accessibilityHidden(true)
    }

    /// One zone boundary: a small cap under the plot at its place.
    private struct SplitHandle: View {
        let index: Int
        let percent: Double
        let rect: CGRect
        let style: AdjustmentControlStyle
        let space: String
        let move: (Int, Double) -> Void
        let onEditingChanged: (Int, Bool) -> Void

        @State private var start: Double?
        @State private var bracket = EditingBracket()
        @Environment(\.isEnabled) private var isEnabled

        private static let defaults = [25.0, 50, 75]

        var body: some View {
            let x = rect.minX + rect.width * percent / 100
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: style == .touch ? 18 : 12))
                .foregroundStyle(isEnabled ? (start == nil ? Color.hdr.inkMuted : Color.hdr.accent) : Color.hdr.inkDisabled)
                .padding(style == .touch ? 12 : 6)
                .contentShape(.rect)
                .position(x: x, y: style == .touch ? 20 : 13)
                .gesture(drag)
                .simultaneousGesture(TapGesture(count: 2).onEnded { move(index, Self.defaults[index]) })
                .onDisappear { finish() }
                .accessibilityElement()
                .accessibilityLabel(Text("design.curve.split \(String(index + 1))", bundle: .module))
                .accessibilityValue(Text(verbatim: "\(Int(percent.rounded()))%"))
                .accessibilityAdjustableAction { direction in
                    move(index, percent + (direction == .increment ? 1 : -1))
                }
        }

        private var drag: some Gesture {
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { drag in
                    guard isEnabled, isPrimaryPointerEvent else { return }
                    if start == nil {
                        start = percent
                        bracket.begin { onEditingChanged(index, $0) }
                    }
                    move(index, (start ?? percent) + drag.translation.width / rect.width * 100)
                }
                .onEnded { _ in finish() }
        }

        private func finish() {
            start = nil
            bracket.finish { onEditingChanged(index, $0) }
        }
    }
}
