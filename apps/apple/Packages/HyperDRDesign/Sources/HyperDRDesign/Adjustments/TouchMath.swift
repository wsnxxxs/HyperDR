import CoreGraphics
import Foundation
import HyperDRRecipe

/// Touch slider fine-tuning (p7-adjustments §5.4): with the thumb held, moving
/// the finger away from the track slows the slider down, as the system media
/// scrubber does.
public enum FineTune: Equatable, Sendable {
    case full, half, quarter

    /// 40 pt away halves the speed, 100 pt quarters it.
    public init(verticalDistance: CGFloat) {
        let distance = abs(verticalDistance)
        self = distance >= 100 ? .quarter : distance >= 40 ? .half : .full
    }

    public var factor: Double {
        switch self {
        case .full: return 1
        case .half: return 0.5
        case .quarter: return 0.25
        }
    }
}

/// The default detent: a value this close to the default, measured in points
/// along the control, lands on it.
public enum DefaultDetent {
    public static let points: CGFloat = 2

    public static func apply(_ value: Double, defaultValue: Double?, pointsPerUnit: Double,
                             points: CGFloat = points) -> Double {
        guard let defaultValue, pointsPerUnit > 0 else { return value }
        return abs(value - defaultValue) * pointsPerUnit <= Double(points) ? defaultValue : value
    }
}

/// What a value change passes over, for haptic feedback: the default, the
/// ruler's major ticks, and the ends of the range.
public struct DetentCrossing: Equatable, Sendable {
    public var defaultValue = false
    public var majorTick = false
    public var limit = false
    public var any: Bool { defaultValue || majorTick || limit }
}

/// The iPhone ruler (p7-adjustments §5.4): a fixed needle in the middle over
/// a tape that the finger drags, the same rule for every range.
///
/// - The needle is the value. The tape runs from the lower bound on the left
///   to the upper bound on the right, and past a bound there is no tape: at
///   0 of 0…100 the tape starts at the needle, at 100 of 0…100 it ends there,
///   at 0 of −100…+100 it runs both ways.
/// - Every control has the same feel: one `reach` of finger travel covers
///   100 units of a percent or ±100 control, and otherwise the larger side
///   of a signed range or the whole of a one-sided one. So +100 of a ±100
///   control, 100 of 0…100 and 0 of a 100-default strength are all one reach
///   from their defaults, and 1 % is the same distance on every control.
/// - Drags are relative and move the tape with the finger, no momentum:
///   dragging left raises the value. `FineTune` slows them down.
/// - The value holds at the default for `detentPoints` of finger travel
///   either side. A control whose default is Auto takes what Auto resolves
///   to as its default.
public struct RulerScale: Equatable, Sendable {
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double?
    public let majorTick: Double
    /// Points the tape moves per unit of the value.
    public let pointsPerUnit: Double

    /// A reach is this much of the ruler's width, and no less than `minimumReach`.
    public static let reachFraction: CGFloat = 0.75
    public static let minimumReach: CGFloat = 260
    /// How far either side of the default the value holds there, in finger points.
    public static let detentPoints: CGFloat = 5

    public init(range: ClosedRange<Double>, step: Double, defaultValue: Double?, majorTick: Double,
                pointsPerUnit: Double) {
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.majorTick = majorTick
        self.pointsPerUnit = max(pointsPerUnit, 1e-6)
    }

    /// For a declared parameter: exposure has a major tick every 1 EV, ±100
    /// and percent controls every 10, stops every 0.5, kelvin every 1000.
    /// `width` is the ruler's.
    public init?(_ control: AdjustmentControl, width: CGFloat) {
        guard let range = control.declaration.range, let spec = control.spec else { return nil }
        let major: Double
        switch control.declaration.format {
        case .ev: major = 1
        case .stops: major = 0.5
        case .kelvin: major = 1000
        default: major = 10 * spec.step
        }
        let reach = Double(max(width * Self.reachFraction, Self.minimumReach))
        // An Auto default is what Auto resolves to: the dot, the lit span and the detent sit there.
        self.init(range: range, step: spec.step, defaultValue: control.defaultNumber ?? control.automaticNumber,
                  majorTick: major,
                  pointsPerUnit: reach / Self.reachUnits(range, format: control.declaration.format))
    }

    /// The units one reach covers: 100 for percent and ±100 controls, else
    /// the larger side of a range signed about zero or the whole of any
    /// other. It depends on the declaration only, so a source default
    /// (as-shot white balance) never rescales the tape.
    public static func reachUnits(_ range: ClosedRange<Double>, format: HyperDRRecipe.ParameterFormat?) -> Double {
        if format == .percent || format == .signed { return 100 }
        let units = range.lowerBound < 0 && range.upperBound > 0
            ? max(-range.lowerBound, range.upperBound) : range.upperBound - range.lowerBound
        return max(units, 1e-9)
    }

    func clamped(_ value: Double) -> Double { min(max(value, range.lowerBound), range.upperBound) }

    /// Points from the needle to `value` on the tape when the needle is at
    /// `needle`; values outside the range sit at its ends.
    public func offset(of value: Double, needle: Double) -> Double {
        (clamped(value) - clamped(needle)) * pointsPerUnit
    }

    // MARK: Dragging

    /// The value after the finger moved `translation` points from where the
    /// value was `start`: the tape follows the finger, so left raises it.
    /// `speed` is the fine-tune factor. Clamped and held at the default, not
    /// yet snapped.
    public func value(from start: Double, translation: CGFloat, speed: Double = 1) -> Double {
        let raw = clamped(clamped(start) - Double(translation) * speed / pointsPerUnit)
        return DefaultDetent.apply(raw, defaultValue: defaultValue, pointsPerUnit: pointsPerUnit / max(speed, 1e-3),
                                   points: Self.detentPoints)
    }

    /// On the step grid; the default stays as it is, even off the grid.
    public func settled(_ value: Double) -> Double {
        if let defaultValue, value == defaultValue { return value }
        return ParameterSpec.snapped(value, range: range, step: step)
    }

    /// What moving from `old` to `new` passed over or landed on.
    public func crossing(from old: Double, to new: Double) -> DetentCrossing {
        guard old != new else { return DetentCrossing() }
        var crossing = DetentCrossing()
        if let defaultValue {
            let before = (old - defaultValue).sign, after = (new - defaultValue).sign
            crossing.defaultValue = new == defaultValue || (old != defaultValue && before != after)
        }
        let tick = { (value: Double) in (value / majorTick + 1e-9).rounded(.down) }
        // The ends have a feedback of their own.
        crossing.majorTick = tick(old) != tick(new) && new != range.lowerBound && new != range.upperBound
        crossing.limit = new == range.lowerBound || new == range.upperBound
        return crossing
    }

    /// The spacing of the small ticks: a tenth of a major tick, or a fifth, a
    /// quarter, a half or the major tick itself when that would put them
    /// closer than 7 pt.
    public var minorTick: Double {
        [10.0, 5, 4, 2, 1].lazy.map { majorTick / $0 }.first { $0 * pointsPerUnit >= 7 } ?? majorTick
    }

    /// The ticks to draw, the bounds always included as major ones.
    public var ticks: [(value: Double, isMajor: Bool)] {
        let minor = minorTick
        var ticks: [(value: Double, isMajor: Bool)] = [(range.lowerBound, true)]
        var index = (range.lowerBound / minor).rounded(.down) + 1
        while true {
            let value = index * minor
            index += 1
            if value <= range.lowerBound + minor * 1e-6 { continue }
            // Too close to the upper bound's own tick to read as a tick of its own.
            guard (range.upperBound - value) * pointsPerUnit >= 3 else { break }
            let ratio = value / majorTick
            ticks.append((value, abs(ratio - ratio.rounded()) < 1e-6))
        }
        ticks.append((range.upperBound, true))
        return ticks
    }
}
