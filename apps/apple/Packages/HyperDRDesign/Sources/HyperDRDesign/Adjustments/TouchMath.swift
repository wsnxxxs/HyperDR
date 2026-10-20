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

    public static func apply(_ value: Double, defaultValue: Double?, pointsPerUnit: Double) -> Double {
        guard let defaultValue, pointsPerUnit > 0 else { return value }
        return abs(value - defaultValue) * pointsPerUnit <= Double(points) ? defaultValue : value
    }
}

/// What a value change passes over, for haptic feedback: the default, and the
/// ruler's major ticks.
public struct DetentCrossing: Equatable, Sendable {
    public var defaultValue = false
    public var majorTick = false
    public var any: Bool { defaultValue || majorTick }
}

/// The iPhone ruler (p7-adjustments §5.4): the full range is about two and a
/// half screen widths, the value under the fixed needle moves the other way
/// from the finger, and a drag ends on the step grid, with a detent at the
/// default and feedback at it and at every major tick.
public struct RulerScale: Equatable, Sendable {
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double?
    public let majorTick: Double
    /// Points the ruler moves per unit of the value.
    public let pointsPerUnit: Double

    public static let screensPerRange: Double = 2.5

    public init(range: ClosedRange<Double>, step: Double, defaultValue: Double?, majorTick: Double,
                referenceWidth: CGFloat) {
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.majorTick = majorTick
        pointsPerUnit = Self.screensPerRange * Double(max(referenceWidth, 1)) / (range.upperBound - range.lowerBound)
    }

    /// For a declared parameter: exposure has a major tick every 1 EV, ±100
    /// and percent controls every 10, stops every 0.5, kelvin every 1000.
    public init?(_ control: AdjustmentControl, referenceWidth: CGFloat) {
        guard let range = control.declaration.range, let spec = control.spec else { return nil }
        let major: Double
        switch control.declaration.format {
        case .ev: major = 1
        case .stops: major = 0.5
        case .kelvin: major = 1000
        default: major = 10 * spec.step
        }
        self.init(range: range, step: spec.step, defaultValue: control.defaultNumber, majorTick: major,
                  referenceWidth: referenceWidth)
    }

    /// The value after dragging the ruler by `translation` points from where
    /// it was at `start`: dragging left raises it. Clamped, not yet snapped.
    public func value(from start: Double, translation: CGFloat) -> Double {
        min(max(start - Double(translation) / pointsPerUnit, range.lowerBound), range.upperBound)
    }

    /// On the step grid, with the default detent.
    public func settled(_ value: Double) -> Double {
        DefaultDetent.apply(ParameterSpec.snapped(value, range: range, step: step), defaultValue: defaultValue,
                            pointsPerUnit: pointsPerUnit)
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
        crossing.majorTick = tick(old) != tick(new)
        return crossing
    }

    /// The spacing of the small ticks: a tenth of a major tick, or a fifth,
    /// a half or the major tick itself when that would put them closer than 4 pt.
    public var minorTick: Double {
        [10.0, 5, 2, 1].lazy.map { majorTick / $0 }.first { $0 * pointsPerUnit >= 4 } ?? majorTick
    }

    /// Where `value` sits on the ruler, in points from the lower bound.
    public func offset(of value: Double) -> Double { (value - range.lowerBound) * pointsPerUnit }
}
