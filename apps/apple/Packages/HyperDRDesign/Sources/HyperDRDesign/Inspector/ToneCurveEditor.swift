import HyperDRRecipe
import SwiftUI

/// The geometry of a tone curve's points (adjust-controls F3), in the curve's
/// own coordinates: `[x0, y0, x1, y1, …]`, both axes the sRGB-encoded luminance
/// 0…1, the end points (0, 0) and (1, 1) fixed. Pure functions, so the editor's
/// rules can be tested without a view.
enum ToneCurvePoints {
    /// The most points a curve keeps, end points included (`ToneCurve` takes 16).
    static let maxCount = 16
    /// The least distance in x between two points, so a drag never makes
    /// `ToneCurve`'s strictly increasing x fail.
    static let gap = 0.02

    static func points(_ coordinates: [Double]) -> [CGPoint] {
        stride(from: 0, to: coordinates.count - 1, by: 2).map { CGPoint(x: coordinates[$0], y: coordinates[$0 + 1]) }
    }

    static func flat(_ points: [CGPoint]) -> [Double] { points.flatMap { [Double($0.x), Double($0.y)] } }

    /// The curve a list of coordinates draws; identity when they are not a valid curve.
    static func curve(_ coordinates: [Double]) -> ToneCurve { (try? ToneCurve(coordinates)) ?? ToneCurve() }

    /// A point added at `point` (clamped to 0…1), with its index; nil when the
    /// curve is full or the point lies within `gap` of another in x.
    static func inserted(_ coordinates: [Double], at point: CGPoint) -> (coordinates: [Double], index: Int)? {
        var points = points(coordinates)
        guard points.count < maxCount else { return nil }
        let x = min(max(Double(point.x), 0), 1), y = min(max(Double(point.y), 0), 1)
        guard points.allSatisfy({ abs(Double($0.x) - x) >= gap }) else { return nil }
        let index = points.firstIndex { Double($0.x) > x } ?? points.count
        points.insert(CGPoint(x: x, y: y), at: index)
        return (flat(points), index)
    }

    /// The point at `index` moved to `point`: y in 0…1, x between its
    /// neighbours. The end points do not move.
    static func moved(_ coordinates: [Double], index: Int, to point: CGPoint) -> [Double] {
        var points = points(coordinates)
        guard points.indices.contains(index), index > 0, index < points.count - 1 else { return coordinates }
        let lower = Double(points[index - 1].x) + gap, upper = Double(points[index + 1].x) - gap
        points[index] = CGPoint(x: min(max(Double(point.x), lower), max(lower, upper)),
                                y: min(max(Double(point.y), 0), 1))
        return flat(points)
    }

    /// The curve without the point at `index`; the end points stay.
    static func removed(_ coordinates: [Double], index: Int) -> [Double] {
        var points = points(coordinates)
        guard points.indices.contains(index), index > 0, index < points.count - 1 else { return coordinates }
        points.remove(at: index)
        return flat(points)
    }
}

/// The SDR tone curve as a plot you edit with the pointer or a finger
/// (adjust-controls F3, p7-adjustments §2.5): input across, output up, the
/// identity diagonal dashed, the curve drawn from `ToneCurve.samples`, the
/// same Fritsch–Carlson curve the renderer bakes.
///
/// - Drag a point to move it; one drag is one undo step (`onEditingChanged`
///   brackets it). The end points are fixed: Whites and Black Point move them.
/// - Click or tap empty space to add a point there; double-click or
///   double-tap a point to delete it.
///
/// Only the points take drags, so on the iPad the panel still scrolls under a
/// finger that starts anywhere else.
public struct ToneCurveEditor: View {
    private let coordinates: [Double]
    private let style: AdjustmentControlStyle
    private let write: ([Double]) -> Void
    private let onEditingChanged: (Bool) -> Void

    @State private var dragged: Int?
    @State private var dragStart: CGPoint?
    @State private var bracket = EditingBracket()
    @Environment(\.isEnabled) private var isEnabled

    static let inset: CGFloat = 12
    private static let space = "hyperdr.toneCurvePlot"

    /// `write` takes the whole curve after each change; `onEditingChanged`
    /// brackets a drag (a point added by a tap, or deleted, is one write).
    public init(coordinates: [Double], style: AdjustmentControlStyle, write: @escaping ([Double]) -> Void,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.coordinates = coordinates
        self.style = style
        self.write = write
        self.onEditingChanged = onEditingChanged
    }

    private var touch: Bool { style == .touch }
    private var dot: CGFloat { touch ? 16 : 11 }

    public var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.inset, dy: Self.inset)
            let points = ToneCurvePoints.points(coordinates)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(&context, rect: rect) }
                    .contentShape(.rect)
                    .gesture(SpatialTapGesture().onEnded { add(at: $0.location, in: rect) })
                    .accessibilityHidden(true)
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    let fixed = index == 0 || index == points.count - 1
                    handle(index: index, fixed: fixed, in: rect)
                        .position(view(point, in: rect))
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.hdr.line) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("ctrl.tone.curve.label", bundle: .module))
        .onDisappear { finishDrag() }
        .onChange(of: isEnabled) { if !isEnabled { finishDrag() } }
    }

    // MARK: Coordinates

    private func view(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * point.x, y: rect.maxY - rect.height * point.y)
    }

    private func unit(_ location: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (location.x - rect.minX) / rect.width, y: (rect.maxY - location.y) / rect.height)
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, rect r: CGRect) {
        var grid = Path()
        for i in 1..<4 {
            let t = Double(i) / 4
            grid.move(to: CGPoint(x: r.minX + r.width * t, y: r.minY)); grid.addLine(to: CGPoint(x: r.minX + r.width * t, y: r.maxY))
            grid.move(to: CGPoint(x: r.minX, y: r.minY + r.height * t)); grid.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * t))
        }
        context.stroke(grid, with: .color(.hdr.histogramGrid), lineWidth: 1)
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: r.minX, y: r.maxY)); diagonal.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        context.stroke(diagonal, with: .color(.hdr.lineStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let samples = ToneCurvePoints.curve(coordinates).samples(count: 256)
        var curve = Path()
        for (i, value) in samples.enumerated() {
            let p = view(CGPoint(x: Double(i) / Double(samples.count - 1), y: value), in: r)
            i == 0 ? curve.move(to: p) : curve.addLine(to: p)
        }
        context.stroke(curve, with: .color(.hdr.accent),
                       style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }

    // MARK: Points

    @ViewBuilder private func handle(index: Int, fixed: Bool, in rect: CGRect) -> some View {
        let active = dragged == index
        if fixed {
            Circle()
                .strokeBorder(Color.hdr.inkMuted, lineWidth: 1.5)
                .background(Circle().fill(Color.hdr.surfaceCard))
                .frame(width: 8, height: 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(active ? Color.hdr.inkStrong : Color.hdr.surfaceCard)
                .overlay { Circle().strokeBorder(isEnabled ? Color.hdr.accent : Color.hdr.inkDisabled, lineWidth: 1.5) }
                .frame(width: dot, height: dot)
                // A larger target than the dot.
                .padding(touch ? 14 : 6)
                .contentShape(.circle)
                .gesture(drag(index: index, in: rect))
                .simultaneousGesture(TapGesture(count: 2).onEnded { remove(index) })
                .accessibilityElement()
                .accessibilityLabel(Text("design.curve.point \(String(index))", bundle: .module))
                .accessibilityValue(Text("design.curve.pointValue \(percent(coordinates[index * 2])) \(percent(coordinates[index * 2 + 1]))",
                                         bundle: .module))
                .accessibilityAdjustableAction { direction in
                    let y = coordinates[index * 2 + 1] + (direction == .increment ? 0.02 : -0.02)
                    write(ToneCurvePoints.moved(coordinates, index: index,
                                                to: CGPoint(x: coordinates[index * 2], y: y)))
                }
                .accessibilityAction(named: Text("design.curve.removePoint", bundle: .module)) { remove(index) }
        }
    }

    private func percent(_ value: Double) -> String { String(Int((value * 100).rounded())) }

    private func drag(index: Int, in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { drag in
                guard isEnabled, isPrimaryPointerEvent else { return }
                if dragged == nil {
                    dragged = index
                    dragStart = ToneCurvePoints.points(coordinates)[index]
                    bracket.begin(onEditingChanged)
                }
                guard dragged == index, let start = dragStart else { return }
                // By the distance travelled, so the point keeps its grab offset.
                let moved = ToneCurvePoints.moved(coordinates, index: index, to: CGPoint(
                    x: start.x + drag.translation.width / rect.width,
                    y: start.y - drag.translation.height / rect.height))
                if moved != coordinates { write(moved) }
            }
            .onEnded { _ in finishDrag() }
    }

    /// Ends the drag if one is open: normal end, the view removed or disabled. Idempotent.
    private func finishDrag() {
        dragged = nil
        dragStart = nil
        bracket.finish(onEditingChanged)
    }

    private func add(at location: CGPoint, in rect: CGRect) {
        guard isEnabled, rect.contains(location) || rect.insetBy(dx: -Self.inset, dy: -Self.inset).contains(location),
              let added = ToneCurvePoints.inserted(coordinates, at: unit(location, in: rect)) else { return }
        write(added.coordinates)
    }

    private func remove(_ index: Int) {
        guard isEnabled else { return }
        let removed = ToneCurvePoints.removed(coordinates, index: index)
        if removed != coordinates { write(removed) }
    }
}

/// The "Curve" section of the Light controls: its title, Reset Curve once the
/// curve has a point, and the editor under them. On the Mac it folds away (open
/// while the curve is changed); on the iPad it stays open. The curve is
/// written as one value, so its undo steps are the editor's drags and
/// single edits.
public struct ToneCurveSection: View {
    @Binding private var recipe: Recipe
    private let control: AdjustmentControl
    private let panel: AdjustmentPanel
    private let style: AdjustmentControlStyle
    private let onEditingChanged: (ParameterDeclaration, Bool) -> Void

    @State private var isExpanded: Bool

    public init(recipe: Binding<Recipe>, control: AdjustmentControl, panel: AdjustmentPanel,
                style: AdjustmentControlStyle, onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in }) {
        _recipe = recipe
        self.control = control
        self.panel = panel
        self.style = style
        self.onEditingChanged = onEditingChanged
        _isExpanded = State(initialValue: style == .touch || !control.isDefault)
    }

    private var coordinates: [Double] {
        if case .curve(let values) = control.value { return values }
        return ToneCurve().coordinates
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            header
            if isExpanded {
                ToneCurveEditor(coordinates: coordinates, style: style,
                                write: { panel.set(control.id, curve: $0, in: &recipe) },
                                onEditingChanged: { onEditingChanged(control.declaration, $0) })
                    .frame(maxWidth: style == .touch ? 320 : 240)
                Text(style == .touch ? "design.curve.hint.touch" : "design.curve.hint.pointer", bundle: .module)
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .disabled(!control.isAvailable)
    }

    private var header: some View {
        HStack(spacing: Space.s2) {
            Button {
                withHDRAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: Space.s1) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(style == .touch ? 0 : 1)
                        .frame(width: style == .touch ? 0 : 10)
                    AdjustmentText.label(control.declaration)
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkStrong)
                }
                .frame(minHeight: style == .touch ? 44 : 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(style == .touch)
            .accessibilityValue(Text(isExpanded ? "design.group.expanded" : "design.group.collapsed", bundle: .module))
            Spacer(minLength: 0)
            if !control.isDefault {
                Button { panel.reset(control.id, in: &recipe) } label: {
                    Text("design.curve.reset", bundle: .module)
                        .font(.system(size: TypeScale.Size.caption, weight: .medium))
                        .foregroundStyle(Color.hdr.accent)
                        .frame(minHeight: style == .touch ? 44 : 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
