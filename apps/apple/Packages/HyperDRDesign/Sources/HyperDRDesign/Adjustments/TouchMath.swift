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

/// The iPhone ruler (p7-adjustments §5.4): a scale that fills the ruler's
/// width, with a needle that follows the finger.
///
/// - The whole range is one width, so the scale has no empty half: a signed
///   control has its zero in the middle, a one-sided one starts at the left.
/// - Drags are relative (touching never jumps), the needle moving with the
///   finger; `FineTune` slows them down.
/// - The value holds at the default for `detentPoints` of finger travel
///   either side.
public struct RulerScale: Equatable, Sendable {
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double?
    public let majorTick: Double
    /// Points from the lower to the upper bound.
    public let length: Double

    /// Space left and right of the scale, so the needle stays whole at the ends.
    public static let inset: CGFloat = 14
    /// How far either side of the default the value holds there, in finger points.
    public static let detentPoints: CGFloat = 5

    public init(range: ClosedRange<Double>, step: Double, defaultValue: Double?, majorTick: Double, length: CGFloat) {
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.majorTick = majorTick
        self.length = Double(max(length, 1))
    }

    /// For a declared parameter: exposure has a major tick every 1 EV, ±100
    /// and percent controls every 10, stops every 0.5, kelvin every 1000.
    /// `width` is the ruler's, insets included.
    public init?(_ control: AdjustmentControl, width: CGFloat) {
        guard let range = control.declaration.range, let spec = control.spec else { return nil }
        let major: Double
        switch control.declaration.format {
        case .ev: major = 1
        case .stops: major = 0.5
        case .kelvin: major = 1000
        default: major = 10 * spec.step
        }
        self.init(range: range, step: spec.step, defaultValue: control.defaultNumber, majorTick: major,
                  length: width - 2 * Self.inset)
    }

    /// Points the needle moves per unit of the value.
    public var pointsPerUnit: Double { length / (range.upperBound - range.lowerBound) }

    /// Points from the lower bound; values outside the range sit at its ends.
    public func position(of value: Double) -> Double {
        (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) * pointsPerUnit
    }

    // MARK: Dragging

    /// The value after the finger moved `translation` points from where the
    /// value was `start`: right raises it. `speed` is the fine-tune factor.
    /// Clamped and held at the default, not yet snapped.
    public func value(from start: Double, translation: CGFloat, speed: Double = 1) -> Double {
        let clamped = min(max(start, range.lowerBound), range.upperBound)
        let raw = min(max(clamped + Double(translation) * speed / pointsPerUnit, range.lowerBound), range.upperBound)
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

    /// The spacing of the small ticks: a tenth of a major tick, or a fifth,
    /// a half or the major tick itself when that would put them closer than 4 pt.
    public var minorTick: Double {
        [10.0, 5, 2, 1].lazy.map { majorTick / $0 }.first { $0 * pointsPerUnit >= 4 } ?? majorTick
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
