import CoreGraphics
import HyperDRRecipe

/// The curve eyedropper's edit (adjust-tools §2.2): the user presses a
/// pixel of the photo and drags up or down, and the curve is raised or
/// lowered at that pixel's input. If a point of the curve already sits at
/// the input it is the one that moves; otherwise a point is added on the
/// curve where it is, and moved. One value of the pick is one start; the
/// drag asks for the curve again with each new distance.
public struct CurveTargetedEdit: Sendable {
    private let base: [Double]
    private let input: Double
    private let maxValue: Double
    private let liftsOnly: Bool

    /// What one canvas point of drag does to the output: a full SDR range
    /// per `sdrReach` points, a stop per `hdrReach` points in the HDR segment.
    static let sdrReach: Double = 240
    static let hdrReach: Double = 90

    /// `coordinates` is the curve being edited and `input` the picked input
    /// on its axis (0…1 in the SDR segment, above 1 in the HDR one).
    public init(coordinates: [Double], input: Double, maxValue: Double = 5, liftsOnly: Bool = false) {
        self.liftsOnly = liftsOnly
        base = coordinates
        self.input = input
        self.maxValue = maxValue
    }

    /// Whether the pick can edit the curve: not at black or SDR white, which
    /// are fixed, and not when the curve is full.
    public var canEdit: Bool {
        guard input.isFinite, input > 0, input < maxValue else { return false }
        return target != nil
    }

    /// The point that moves, and the curve it is in.
    private var target: (coordinates: [Double], index: Int)? {
        let points = ToneCurvePoints.points(base)
        let near = ToneCurvePoints.gap(hdr: input > 1)
        if let index = points.indices.first(where: { abs(Double(points[$0].x) - input) < near / 2 }) {
            return ToneCurvePoints.isFixed(points[index]) ? nil : (base, index)
        }
        let y = ToneCurvePoints.value(base, at: input)
        return ToneCurvePoints.inserted(base, at: CGPoint(x: input, y: y), maxValue: maxValue, liftsOnly: liftsOnly)
    }

    /// The curve with the picked point raised by `points` canvas points of
    /// drag (negative lowers); `base` itself when the pick cannot edit.
    public func coordinates(raisedByDrag points: Double) -> [Double] {
        guard let (coordinates, index) = target else { return base }
        let point = ToneCurvePoints.points(coordinates)[index]
        let reach = point.x > 1 ? Self.hdrReach : Self.sdrReach
        return ToneCurvePoints.moved(coordinates, index: index,
                                     to: CGPoint(x: point.x, y: Double(point.y) + points / reach), maxValue: maxValue,
                                     liftsOnly: liftsOnly)
    }
}
