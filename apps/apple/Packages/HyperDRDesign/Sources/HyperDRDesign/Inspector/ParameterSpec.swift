import Foundation

/// How a numeric inspector parameter is shown, stepped and typed (the web's
/// control schema in `js/settings/schema.js`): its range, the step the slider
/// and the arrow keys snap to, the value a reset returns to, where the track's
/// fill starts, and how the readout prints it.
///
/// A spec is plain data; the value itself lives with the caller, one binding
/// per control (S12: a control observes only its own value).
public struct ParameterSpec: Sendable {
    public var range: ClosedRange<Double>
    public var step: Double
    public var defaultValue: Double
    /// Where the fill starts. The lower bound for a one-sided parameter; a
    /// value inside the range, usually 0, for a signed one, which then fills
    /// from its centre outwards and marks that point on the track.
    public var origin: Double
    public var format: ParameterFormat

    public init(range: ClosedRange<Double>, step: Double, defaultValue: Double,
                origin: Double? = nil, format: ParameterFormat = .number(fractionDigits: 2)) {
        precondition(step > 0 && range.upperBound > range.lowerBound, "empty range or step")
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.origin = min(max(origin ?? range.lowerBound, range.lowerBound), range.upperBound)
        self.format = format
    }

    /// A signed parameter filled from zero, as exposure or tint.
    public static func signed(_ range: ClosedRange<Double>, step: Double, defaultValue: Double = 0,
                              format: ParameterFormat) -> ParameterSpec {
        ParameterSpec(range: range, step: step, defaultValue: defaultValue, origin: 0, format: format)
    }

    /// Whether the fill starts inside the range rather than at its lower bound.
    public var isCentred: Bool { origin > range.lowerBound }

    // MARK: Values

    /// `value` on the step grid (counted from the lower bound) and in range.
    public func snapped(_ value: Double) -> Double {
        let lower = range.lowerBound
        let snapped = lower + ((value - lower) / step).rounded() * step
        // Rounded to 1e-6, so steps of 0.05 do not drift into 0.30000000000000004.
        return (min(max(snapped, lower), range.upperBound) * 1e6).rounded() / 1e6
    }

    /// `value` moved by `steps` steps (negative for down), snapped and clamped.
    public func stepped(_ value: Double, by steps: Int) -> Double {
        snapped(value + Double(steps) * step)
    }

    /// Position of `value` along the track, 0…1.
    public func fraction(of value: Double) -> Double {
        min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    /// The snapped value at a position along the track, 0…1.
    public func value(atFraction fraction: Double) -> Double {
        snapped(range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound))
    }

    /// The filled part of the track for `value`: from the origin to the value,
    /// as positions 0…1 with `lower ≤ upper`.
    public func fill(for value: Double) -> ClosedRange<Double> {
        let a = fraction(of: origin), b = fraction(of: value)
        return min(a, b)...max(a, b)
    }

    // MARK: Text

    /// The readout: "+0.30 EV", "25%".
    public func formatted(_ value: Double) -> String { format.display(value) }

    /// The text a value is edited as: the displayed number without its unit
    /// or grouping, to the step's precision ("0.30", "25").
    public func editableText(_ value: Double) -> String {
        let scaled = step * format.scale
        let digits = max(0, -Int((log10(scaled) + 1e-9).rounded(.down)))
        return String(format: "%.\(digits)f", value * format.scale)
    }

    /// A typed value as a stored one, snapped and clamped; nil when nothing
    /// numeric was typed. What is typed is the number as displayed, so a
    /// percentage takes 25 for 0.25. Units are ignored ("+0.30 EV" works), a
    /// comma is a decimal point, and the typographic minus and en dash count
    /// as minus. Port of the web's `parseTypedValue`.
    public func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
        guard let match = cleaned.firstMatch(of: /[-+]?(?:\d+\.?\d*|\.\d+)/),
              let typed = Double(match.output), typed.isFinite else { return nil }
        return snapped(typed / format.scale)
    }
}

/// How a parameter's readout prints its value.
public struct ParameterFormat: Sendable {
    /// Displayed numbers are the stored value times this: 100 for a percentage.
    public let scale: Double
    public let display: @Sendable (Double) -> String

    public init(scale: Double = 1, display: @escaping @Sendable (Double) -> String) {
        self.scale = scale
        self.display = display
    }

    /// "0.50".
    public static func number(fractionDigits: Int) -> ParameterFormat {
        ParameterFormat { $0.formatted(.number.precision(.fractionLength(fractionDigits))) }
    }

    /// "+0.30 EV", "−1.0": always signed, zero shown as "0". `suffix` is
    /// appended after a space; pass it already localized.
    public static func signed(fractionDigits: Int, suffix: String? = nil) -> ParameterFormat {
        ParameterFormat { value in
            let zero = abs(value) < 0.5 * pow(10, -Double(fractionDigits))
            let number = (zero ? 0 : value).formatted(.number.precision(.fractionLength(fractionDigits))
                .sign(strategy: zero ? .never : .always()))
            return suffix.map { "\(number) \($0)" } ?? number
        }
    }

    /// "25%" for 0.25.
    public static var percent: ParameterFormat {
        ParameterFormat(scale: 100) { "\(Int(($0 * 100).rounded()))%" }
    }
}
