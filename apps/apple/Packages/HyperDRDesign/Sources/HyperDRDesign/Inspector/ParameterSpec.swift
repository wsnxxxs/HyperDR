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
    /// Set for a parameter that can also be "Auto": a value below the range
    /// that the control shows as a state of its own instead of a number.
    public var automatic: ParameterAutomatic?
    /// How values spread along the track.
    public var spacing: TrackSpacing

    public init(range: ClosedRange<Double>, step: Double, defaultValue: Double,
                origin: Double? = nil, format: ParameterFormat = .number(fractionDigits: 2),
                automatic: ParameterAutomatic? = nil, spacing: TrackSpacing = .linear) {
        precondition(step > 0 && range.upperBound > range.lowerBound, "empty range or step")
        precondition(automatic.map { $0.value < range.lowerBound } ?? true, "the automatic value is inside the range")
        precondition(spacing == .linear || range.lowerBound > 0, "a reciprocal spacing needs a positive range")
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.origin = min(max(origin ?? range.lowerBound, range.lowerBound), range.upperBound)
        self.format = format
        self.automatic = automatic
        self.spacing = spacing
    }

    /// A signed parameter filled from zero, as exposure or tint.
    public static func signed(_ range: ClosedRange<Double>, step: Double, defaultValue: Double = 0,
                              format: ParameterFormat) -> ParameterSpec {
        ParameterSpec(range: range, step: step, defaultValue: defaultValue, origin: 0, format: format)
    }

    /// Whether the fill starts inside the range rather than at its lower bound.
    public var isCentred: Bool { origin > range.lowerBound }

    // MARK: Automatic

    /// Whether `value` is the automatic state: a value below the range, for a
    /// parameter that has one.
    public func isAutomatic(_ value: Double) -> Bool {
        automatic != nil && value < range.lowerBound
    }

    /// Where a control leaves Auto from a key press or a VoiceOver step: the
    /// parameter's own `resume`, else the middle of the range, on the grid.
    public var resumeValue: Double {
        snapped(automatic?.resume ?? (range.lowerBound + range.upperBound) / 2)
    }

    // MARK: Values

    /// `value` on the step grid (counted from the lower bound) and in range.
    public func snapped(_ value: Double) -> Double { Self.snapped(value, range: range, step: step) }

    static func snapped(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let lower = range.lowerBound
        let snapped = lower + ((value - lower) / step).rounded() * step
        // Rounded to 1e-6, so steps of 0.05 do not drift into 0.30000000000000004.
        return (min(max(snapped, lower), range.upperBound) * 1e6).rounded() / 1e6
    }

    /// `value` moved by `steps` steps (negative for down), snapped and clamped.
    /// From Auto the first step lands on `resumeValue`, whichever way it goes.
    public func stepped(_ value: Double, by steps: Int) -> Double {
        isAutomatic(value) ? resumeValue : snapped(value + Double(steps) * step)
    }

    /// Position of `value` along the track, 0…1.
    public func fraction(of value: Double) -> Double {
        let lower = spacing.position(range.lowerBound), upper = spacing.position(range.upperBound)
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return min(max((spacing.position(clamped) - lower) / (upper - lower), 0), 1)
    }

    /// The snapped value at a position along the track, 0…1.
    public func value(atFraction fraction: Double) -> Double {
        let lower = spacing.position(range.lowerBound), upper = spacing.position(range.upperBound)
        return snapped(spacing.value(atPosition: lower + min(max(fraction, 0), 1) * (upper - lower)))
    }

    /// Where a relative drag lands: `start` moved `points` along a track
    /// `length` points long (times the fine-tune `speed`), snapped, and held
    /// at the default within `DefaultDetent.points` of it on the track.
    /// From Auto pass the value the drag starts from.
    public func dragged(from start: Double, by points: Double, length: Double, speed: Double = 1) -> Double {
        let length = max(length, 1)
        let new = value(atFraction: fraction(of: start) + points / length * speed)
        guard !isAutomatic(defaultValue) else { return new }
        let distance = abs(fraction(of: new) - fraction(of: defaultValue)) * length / max(speed, 1e-3)
        return distance <= Double(DefaultDetent.points) ? defaultValue : new
    }

    /// The filled part of the track for `value`: from the origin to the value,
    /// as positions 0…1 with `lower ≤ upper`.
    public func fill(for value: Double) -> ClosedRange<Double> {
        let a = fraction(of: origin), b = fraction(of: value)
        return min(a, b)...max(a, b)
    }

    // MARK: Text

    /// The readout: "+0.30 EV", "25%", or "Auto" in the language of `locale`;
    /// "Auto · 2.4" when the automatic value is known.
    public func formatted(_ value: Double, locale: Locale = .current) -> String {
        guard isAutomatic(value) else { return format.display(value) }
        guard let resolved = automatic?.resolved else {
            return DesignStrings.string("design.slider.auto", bundle: .module, locale: locale)
        }
        return String(format: DesignStrings.string("design.slider.autoValue %@", bundle: .module, locale: locale),
                      format.display(resolved))
    }

    /// The text a value is edited as: the displayed number without its unit
    /// or grouping, to the step's precision ("0.30", "25"); empty for Auto.
    public func editableText(_ value: Double) -> String {
        if isAutomatic(value) { return "" }
        return String(format: "%.\(Self.fractionDigits(step * format.scale))f", value * format.scale)
    }

    /// The fewest decimals that write a step exactly: 1 needs none, .25 two, .1 one.
    static func fractionDigits(_ step: Double) -> Int {
        (0...6).first { digits in
            let shifted = step * pow(10, Double(digits))
            return abs(shifted - shifted.rounded()) < 1e-9 * max(1, shifted)
        } ?? 6
    }

    /// A typed value as a stored one, snapped and clamped; nil when nothing
    /// numeric was typed. What is typed is the number as displayed, so a
    /// percentage takes 25 for 0.25. Units are ignored ("+0.30 EV" works), a
    /// comma is a decimal point, and the typographic minus and en dash count
    /// as minus. Port of the web's `parseTypedValue`.
    ///
    /// A parameter with an Auto state also takes an empty field, "auto" in
    /// any case and the localized word for it, and returns that state.
    public func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let automatic {
            if trimmed.isEmpty || trimmed.lowercased() == "auto" || DesignStrings.isAutomaticWord(trimmed) {
                return automatic.value
            }
        }
        let cleaned = trimmed
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
        guard let match = cleaned.firstMatch(of: /[-+]?(?:\d+\.?\d*|\.\d+)/),
              let typed = Double(match.output), typed.isFinite else { return nil }
        return snapped(typed / format.scale)
    }
}

/// How a slider spreads values along its track.
public enum TrackSpacing: Sendable, Equatable {
    /// Evenly.
    case linear
    /// Evenly in the reciprocal, larger values still to the right: kelvin in
    /// mired, so a step looks the same warm or cool and 2000–8000 K keeps
    /// room on a 1000–50000 K track (p7-adjustments §2.5).
    case reciprocal

    /// The value in the track's own units, increasing with the value.
    public func position(_ value: Double) -> Double {
        switch self {
        case .linear: return value
        case .reciprocal: return -1e6 / value
        }
    }

    public func value(atPosition position: Double) -> Double {
        switch self {
        case .linear: return position
        case .reciprocal: return -1e6 / min(position, -1e-9)
        }
    }
}

/// The "Auto" state of a parameter such as the HDR range: a value below the
/// range (the engine's -1) that the control shows as a word and a dashed
/// track, not a number.
public struct ParameterAutomatic: Sendable, Equatable {
    /// The stored value that means Auto.
    public var value: Double
    /// Where the control goes when it leaves Auto by a key press or a
    /// VoiceOver step; the middle of the range when nil.
    public var resume: Double?
    /// What Auto currently resolves to, when the renderer has said; the
    /// readout then shows it after the word.
    public var resolved: Double?

    public init(value: Double = -1, resume: Double? = nil, resolved: Double? = nil) {
        self.value = value
        self.resume = resume
        self.resolved = resolved
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
