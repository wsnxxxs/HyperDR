import HyperDRRecipe
import SwiftUI

/// The geometry of a tone curve's points, in the curve's own coordinates:
/// `[x0, y0, x1, y1, …]`. The SDR segment is the sRGB-encoded luminance 0…1;
/// a curve with an HDR segment (adjust-tools §2.1) goes on past the fixed
/// point (1, 1) in stops above SDR white, `1 + s`, up to `1 + 4`. The points
/// (0, 0) and (1, 1) are fixed. Pure functions, so the editor's rules can be
/// tested without a view.
enum ToneCurvePoints {
    /// The most points a curve keeps, fixed points and the HDR segment's included.
    static let maxCount = 16
    /// The least distance in x between two points of the SDR segment, so a
    /// drag never makes the curve's strictly increasing x fail.
    static let gap = 0.02
    /// The same in the HDR segment, which is measured in stops and drawn narrower.
    static let hdrGap = 0.08

    static func points(_ coordinates: [Double]) -> [CGPoint] {
        stride(from: 0, to: coordinates.count - 1, by: 2).map { CGPoint(x: coordinates[$0], y: coordinates[$0 + 1]) }
    }

    static func flat(_ points: [CGPoint]) -> [Double] { points.flatMap { [Double($0.x), Double($0.y)] } }

    /// The curve a list of coordinates draws; identity when they are not a valid
    /// SDR-only curve. 
    static func curve(_ coordinates: [Double]) -> ToneCurve { (try? ToneCurve(coordinates)) ?? ToneCurve() }

    /// The curve's output at `input`, as the renderer's own `ToneCurve` has it
    /// (SDR and HDR segments interpolated apart, meeting at SDR white);
    /// the identity for coordinates it does not accept.
    static func value(_ coordinates: [Double], at input: Double) -> Double {
        (try? ToneCurve(coordinates))?.value(at: input) ?? input
    }

    /// The fixed points: the black and the SDR white.
    static func isFixed(_ point: CGPoint) -> Bool {
        (point.x == 0 && point.y == 0) || (point.x == 1 && point.y == 1)
    }

    static func gap(hdr: Bool) -> Double { hdr ? hdrGap : gap }

    /// The output range of a point: an SDR point stays below white, an HDR
    /// point above it.
    /// With `liftsOnly` (the HDR-only curve's SDR segment) an SDR point
    /// cannot go below the diagonal: that curve only brightens below white.
    private static func yRange(hdr: Bool, maxValue: Double, x: Double = 0, liftsOnly: Bool = false) -> ClosedRange<Double> {
        hdr ? 1...max(1, maxValue) : (liftsOnly ? min(max(x, 0), 1) : 0)...1
    }

    /// A point added at `point` (clamped to the plot, 0…`maxValue`), with its
    /// index; nil when the curve is full or the point lies within the gap of
    /// another in x.
    static func inserted(_ coordinates: [Double], at point: CGPoint,
                         maxValue: Double = 1, liftsOnly: Bool = false) -> (coordinates: [Double], index: Int)? {
        var points = points(coordinates)
        guard points.count < maxCount else { return nil }
        let x = min(max(Double(point.x), 0), max(maxValue, 1))
        let range = yRange(hdr: x > 1, maxValue: maxValue, x: x, liftsOnly: liftsOnly)
        let y = min(max(Double(point.y), range.lowerBound), range.upperBound)
        let needed = gap(hdr: x > 1)
        guard points.allSatisfy({ abs(Double($0.x) - x) >= needed }) else { return nil }
        let index = points.firstIndex { Double($0.x) > x } ?? points.count
        points.insert(CGPoint(x: x, y: y), at: index)
        return (flat(points), index)
    }

    /// The point at `index` moved to `point`: y inside its segment, x between
    /// its neighbours (an HDR point may go as far as `maxValue`). The fixed
    /// points do not move.
    static func moved(_ coordinates: [Double], index: Int, to point: CGPoint, maxValue: Double = 1,
                      liftsOnly: Bool = false) -> [Double] {
        var points = points(coordinates)
        guard points.indices.contains(index), index > 0, !isFixed(points[index]) else { return coordinates }
        let hdr = points[index].x > 1
        let needed = gap(hdr: hdr)
        let lower = Double(points[index - 1].x) + needed
        let upper = index + 1 < points.count ? Double(points[index + 1].x) - needed : max(maxValue, 1)
        let x = min(max(Double(point.x), lower), max(lower, upper))
        let range = yRange(hdr: hdr, maxValue: maxValue, x: x, liftsOnly: liftsOnly)
        points[index] = CGPoint(x: x, y: min(max(Double(point.y), range.lowerBound), range.upperBound))
        return flat(points)
    }

    /// A point in the middle of the widest gap between two points (or, with an
    /// HDR segment, between the last point and the plot's end), on the curve
    /// as it is, so the picture does not change: how a VoiceOver user makes
    /// the first point (they cannot tap the plot). Nil when the curve is full
    /// or no gap is wide enough.
    static func insertedInWidestGap(_ coordinates: [Double], maxValue: Double = 1,
                                    liftsOnly: Bool = false) -> (coordinates: [Double], index: Int)? {
        let points = points(coordinates)
        guard points.count < maxCount, let last = points.last else { return nil }
        var edges = points.map { Double($0.x) }
        if maxValue > 1, Double(last.x) < maxValue { edges.append(maxValue) }
        guard let widest = edges.indices.dropLast().max(by: { edges[$0 + 1] - edges[$0] < edges[$1 + 1] - edges[$1] })
        else { return nil }
        let x = (edges[widest] + edges[widest + 1]) / 2
        guard edges[widest + 1] - edges[widest] >= 2 * gap(hdr: x > 1) else { return nil }
        return inserted(coordinates, at: CGPoint(x: x, y: value(coordinates, at: x)), maxValue: maxValue,
                        liftsOnly: liftsOnly)
    }

    /// The curve without the point at `index`; the fixed points stay.
    static func removed(_ coordinates: [Double], index: Int) -> [Double] {
        var points = points(coordinates)
        guard points.indices.contains(index), index > 0, !isFixed(points[index]) else { return coordinates }
        points.remove(at: index)
        return flat(points)
    }

    /// The position of the rightmost point above SDR white in stops, 0 when
    /// the curve has no HDR segment.
    static func hdrExtent(_ coordinates: [Double]) -> Double {
        max(0, (points(coordinates).last.map { Double($0.x) } ?? 1) - 1)
    }
}

/// How the plot is laid out: the SDR range 0…1 across and up, and past SDR
/// white (when the curve has an HDR segment) a strip of `stops` stops, each
/// `stopWidth` of the SDR range wide, in both directions, so the identity
/// stays a straight diagonal. The reachable HDR part is the square above and
/// to the right of white.
struct ToneCurvePlotLayout {
    /// One stop's width, relative to the whole SDR range.
    static let stopWidth = 0.3

    let rect: CGRect
    let stops: Double

    var extent: Double { 1 + stops * Self.stopWidth }
    var maxValue: Double { 1 + stops }
    /// Pixels in the whole SDR range.
    var sdr: CGFloat { rect.width / extent }

    func offset(_ value: Double) -> CGFloat {
        value <= 1 ? value * sdr : sdr * (1 + (value - 1) * Self.stopWidth)
    }

    func value(atOffset offset: CGFloat) -> Double {
        let units = Double(offset / sdr)
        return units <= 1 ? units : 1 + (units - 1) / Self.stopWidth
    }

    func view(_ point: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + offset(Double(point.x)), y: rect.maxY - offset(Double(point.y)))
    }

    func unit(_ location: CGPoint) -> CGPoint {
        CGPoint(x: value(atOffset: location.x - rect.minX), y: value(atOffset: rect.maxY - location.y))
    }

    /// The HDR square: above SDR white, right of it.
    var hdrRect: CGRect? {
        guard stops > 0 else { return nil }
        return CGRect(x: rect.minX + sdr, y: rect.minY, width: rect.width - sdr, height: rect.height - sdr)
    }
}

/// The colours a curve is drawn in: its SDR part, and past SDR white.
struct ToneCurveTint {
    var sdr: Color
    var hdr: Color = .hdr.amber
}

/// A tone curve as a plot you edit with the pointer or a finger
/// (adjust-controls F3, adjust-tools §2): input across, output up, the
/// identity diagonal dashed, the curve drawn from the same Fritsch–Carlson
/// interpolation the renderer bakes.
///
/// - Drag a point to move it; one drag is one undo step (`onEditingChanged`
///   brackets it). The end points are fixed: Whites and Black Point move them.
/// - Click or tap empty space to add a point there; double-click or
///   double-tap a point to delete it.
/// - With `hdrStops`, the plot goes on past SDR white into an amber HDR
///   segment, in stops above white: a point there lifts or lowers the
///   highlights of the HDR version.
///
/// Only the points take drags, so on the iPad the panel still scrolls under a
/// finger that starts anywhere else.
public struct ToneCurveEditor: View {
    private let coordinates: [Double]
    private let style: AdjustmentControlStyle
    private let hdrStops: Double?
    private let marker: Double?
    private let tint: ToneCurveTint
    private let liftsOnly: Bool
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
    /// `hdrStops` is the width of the HDR segment, nil for a curve that has
    /// none; `marker` is an input the photo's picked pixel has, drawn as a line.
    public init(coordinates: [Double], style: AdjustmentControlStyle, hdrStops: Double? = nil, marker: Double? = nil,
                write: @escaping ([Double]) -> Void, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(coordinates: coordinates, style: style, hdrStops: hdrStops, marker: marker,
                  tint: ToneCurveTint(sdr: .hdr.accent), write: write, onEditingChanged: onEditingChanged)
    }

    /// `liftsOnly`: the SDR segment's points stay on or above the diagonal
    /// (the HDR-only curve brightens below white, never darkens).
    init(coordinates: [Double], style: AdjustmentControlStyle, hdrStops: Double?, marker: Double?,
         tint: ToneCurveTint, liftsOnly: Bool = false, write: @escaping ([Double]) -> Void,
         onEditingChanged: @escaping (Bool) -> Void) {
        self.liftsOnly = liftsOnly
        self.coordinates = coordinates
        self.style = style
        self.hdrStops = hdrStops.map { max($0, 0) }
        self.marker = marker
        self.tint = tint
        self.write = write
        self.onEditingChanged = onEditingChanged
    }

    private var touch: Bool { style == .touch }
    private var dot: CGFloat { touch ? 16 : 11 }

    /// The stops the plot shows: the range, or further when a point is.
    private var stops: Double {
        guard let hdrStops else { return 0 }
        return min(max(hdrStops, ToneCurvePoints.hdrExtent(coordinates)), 4)
    }

    public var body: some View {
        GeometryReader { geometry in
            let layout = ToneCurvePlotLayout(rect: CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.inset, dy: Self.inset),
                                             stops: stops)
            let points = ToneCurvePoints.points(coordinates)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(&context, layout: layout) }
                    .contentShape(.rect)
                    .gesture(SpatialTapGesture().onEnded { add(at: $0.location, layout: layout) })
                    .accessibilityHidden(true)
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    handle(index: index, fixed: ToneCurvePoints.isFixed(point), layout: layout)
                        .position(layout.view(point))
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.hdr.line) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("ctrl.tone.curve.label", bundle: .module))
        .accessibilityAction(named: Text("design.curve.addPoint", bundle: .module)) {
            guard isEnabled, let added = ToneCurvePoints.insertedInWidestGap(coordinates, maxValue: 1 + stops, liftsOnly: liftsOnly) else { return }
            write(added.coordinates)
        }
        .onDisappear { finishDrag() }
        .onChange(of: isEnabled) { if !isEnabled { finishDrag() } }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, layout l: ToneCurvePlotLayout) {
        let r = l.rect
        if let hdr = l.hdrRect {
            context.fill(Path(hdr), with: .color(.hdr.amberSoft))
            context.stroke(Path(hdr), with: .color(.hdr.amberBorder), lineWidth: 1)
        }
        var grid = Path()
        for i in 1..<4 {
            let t = Double(i) / 4
            let at = l.offset(t)
            grid.move(to: CGPoint(x: r.minX + at, y: r.maxY)); grid.addLine(to: CGPoint(x: r.minX + at, y: r.maxY - l.sdr))
            grid.move(to: CGPoint(x: r.minX, y: r.maxY - at)); grid.addLine(to: CGPoint(x: r.minX + l.sdr, y: r.maxY - at))
        }
        context.stroke(grid, with: .color(.hdr.histogramGrid), lineWidth: 1)
        var stopGrid = Path()
        var stop = 1.0
        while stop < l.stops - 0.01 {
            let at = l.offset(1 + stop)
            stopGrid.move(to: CGPoint(x: r.minX + at, y: r.maxY - l.sdr)); stopGrid.addLine(to: CGPoint(x: r.minX + at, y: r.minY))
            stopGrid.move(to: CGPoint(x: r.minX + l.sdr, y: r.maxY - at)); stopGrid.addLine(to: CGPoint(x: r.maxX, y: r.maxY - at))
            stop += 1
        }
        context.stroke(stopGrid, with: .color(.hdr.amberBorder), lineWidth: 0.5)
        if let hdr = l.hdrRect {
            // The scale lies in the corner no curve reaches, under the HDR square.
            let font = Font.system(size: 9, weight: .medium)
            func label(_ text: Text, at point: CGPoint, anchor: UnitPoint) {
                context.draw(context.resolve(text.font(font).foregroundStyle(Color.hdr.inkMuted)), at: point, anchor: anchor)
            }
            label(Text("design.curve.hdrAxis", bundle: .module), at: CGPoint(x: hdr.minX + 4, y: hdr.minY + 3), anchor: .topLeading)
            label(Text("design.curve.sdrWhite", bundle: .module), at: CGPoint(x: r.minX + l.sdr - 3, y: r.maxY - 3), anchor: .bottomTrailing)
            var tick = 1.0
            while tick < l.stops + 0.01 {
                label(Text(verbatim: "+\(Int(tick))"), at: CGPoint(x: r.minX + l.offset(1 + tick) - 2, y: r.maxY - 3), anchor: .bottomTrailing)
                tick += 1
            }
        }
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: r.minX, y: r.maxY)); diagonal.addLine(to: l.view(CGPoint(x: l.maxValue, y: l.maxValue)))
        context.stroke(diagonal, with: .color(.hdr.lineStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        if let marker, marker >= 0, marker <= l.maxValue {
            var line = Path()
            let x = r.minX + l.offset(marker)
            line.move(to: CGPoint(x: x, y: r.maxY)); line.addLine(to: CGPoint(x: x, y: r.minY))
            context.stroke(line, with: .color(.hdr.inkMuted), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        let curve = (try? ToneCurve(coordinates)) ?? ToneCurve()
        func trace(_ from: Double, _ to: Double, count: Int, color: Color) {
            var path = Path()
            let samples = curve.samples(count: count + 1, from: from, through: to)
            for (i, value) in samples.enumerated() {
                let x = from + (to - from) * Double(i) / Double(count)
                let p = l.view(CGPoint(x: x, y: min(max(value, 0), l.maxValue)))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
        }
        trace(0, 1, count: 192, color: tint.sdr)
        if l.stops > 0 { trace(1, l.maxValue, count: 96, color: tint.hdr) }
    }

    // MARK: Points

    @ViewBuilder private func handle(index: Int, fixed: Bool, layout: ToneCurvePlotLayout) -> some View {
        let active = dragged == index
        let ring = coordinates[index * 2] > 1 ? tint.hdr : tint.sdr
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
                .overlay { Circle().strokeBorder(isEnabled ? ring : Color.hdr.inkDisabled, lineWidth: 1.5) }
                .frame(width: dot, height: dot)
                // A larger target than the dot.
                .padding(touch ? 14 : 6)
                .contentShape(.circle)
                .gesture(drag(index: index, layout: layout))
                .simultaneousGesture(TapGesture(count: 2).onEnded { remove(index) })
                .accessibilityElement()
                .accessibilityLabel(Text("design.curve.point \(String(index))", bundle: .module))
                .accessibilityValue(valueText(index))
                .accessibilityAdjustableAction { direction in
                    let step = coordinates[index * 2] > 1 ? 0.1 : 0.02
                    let y = coordinates[index * 2 + 1] + (direction == .increment ? step : -step)
                    write(ToneCurvePoints.moved(coordinates, index: index,
                                                to: CGPoint(x: coordinates[index * 2], y: y), maxValue: 1 + stops,
                                                liftsOnly: liftsOnly))
                }
                .accessibilityAction(named: Text("design.curve.removePoint", bundle: .module)) { remove(index) }
        }
    }

    private func valueText(_ index: Int) -> Text {
        let x = coordinates[index * 2], y = coordinates[index * 2 + 1]
        if x > 1 {
            return Text("design.curve.hdrPointValue \(stopsText(x - 1)) \(stopsText(y - 1))", bundle: .module)
        }
        return Text("design.curve.pointValue \(percent(x)) \(percent(y))", bundle: .module)
    }

    private func percent(_ value: Double) -> String { String(Int((value * 100).rounded())) }
    private func stopsText(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }

    private func drag(index: Int, layout: ToneCurvePlotLayout) -> some Gesture {
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
                let from = layout.view(start)
                let to = layout.unit(CGPoint(x: from.x + drag.translation.width, y: from.y + drag.translation.height))
                let moved = ToneCurvePoints.moved(coordinates, index: index, to: to, maxValue: layout.maxValue, liftsOnly: liftsOnly)
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

    private func add(at location: CGPoint, layout: ToneCurvePlotLayout) {
        guard isEnabled, layout.rect.insetBy(dx: -Self.inset, dy: -Self.inset).contains(location),
              let added = ToneCurvePoints.inserted(coordinates, at: layout.unit(location), maxValue: layout.maxValue,
                                                liftsOnly: liftsOnly)
        else { return }
        write(added.coordinates)
    }

    private func remove(_ index: Int) {
        guard isEnabled else { return }
        let removed = ToneCurvePoints.removed(coordinates, index: index)
        if removed != coordinates { write(removed) }
    }
}
