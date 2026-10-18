import Foundation
import HyperDREngine

/// One continuous inspector control (slider + number field). The engine
/// schema has only its own vocabulary; grouping, steps, formats, masks and
/// string keys live here. Discrete options are `ChoiceSpec`s (batch4 §2.1).
public struct ControlSpec: Sendable, Hashable {
    public enum Group: String, Sendable { case lut, tone, model, region }
    public enum Format: String, Sendable {
        case ev, signed, percent, fixed2, stops1, stopsOrAuto1, percentOrAuto, integer
    }
    public enum Mask: String, Sendable { case gain, gainFull, participation, coverage }

    /// The panel vocabulary key, which is also the name sent in a request.
    public let key: String
    public let group: Group
    /// The static range. `hdrRange` and `aiHdrRange` are narrowed further by
    /// the output format (`EditDefaults.maxRange(for:)`).
    public let range: ClosedRange<Double>
    public let step: Double
    /// The panel-v1 adapter's default for this key (model-mode and
    /// format-dependent defaults are applied by `EditDefaults`).
    public let defaultValue: Double
    public let format: Format
    /// The readout is ×100, so a typed 25 means 0.25.
    public let isPercent: Bool
    /// A negative value means "automatic".
    public let allowsAuto: Bool
    public let mask: Mask?
    /// Keys in `Localizable.xcstrings`: `ctrl.<key>.label` / `.help`.
    public let labelKey: String
    public let helpKey: String?

    static func range(_ key: String, _ group: Group, _ range: ClosedRange<Double>, step: Double,
                      default value: Double, format: Format, percent: Bool = false,
                      auto: Bool = false, mask: Mask? = nil) -> ControlSpec {
        ControlSpec(key: key, group: group, range: range, step: step,
                    defaultValue: value, format: format, isPercent: percent, allowsAuto: auto,
                    mask: mask, labelKey: "ctrl.\(key).label", helpKey: "ctrl.\(key).help")
    }
}

/// The inspector's continuous controls. This table is the specification
/// (batch4 §2.1, §8): ranges must lie inside the engine schema and defaults
/// equal the panel-v1 adapter's; the Web `CONTROLS` was only its starting
/// point. `highlightRecovery`, `contrast`, `vibrance` and `quality` have no
/// control and are left out of requests; the adapter supplies them.
public enum EditControls {
    public static let all: [ControlSpec] = [
        .range("lutStrength", .lut, 0...1, step: 0.01, default: 1, format: .percent, percent: true),
        .range("brightness", .tone, -2...2, step: 0.05, default: 0.6, format: .ev),
        .range("hdrStrength", .tone, 0...1, step: 0.05, default: 0.4, format: .percent,
               percent: true, mask: .gain),
        // Upper bound 4 (Web: 3): the widest format ceiling. The effective
        // range is narrowed per output format (§2.2); a static 3 hid PQ's 4.
        .range("hdrRange", .tone, 0...4, step: 0.1, default: 2.5, format: .stops1, mask: .gainFull),
        .range("modelStrength", .model, 0...1, step: 0.05, default: 1, format: .percent, percent: true),
        .range("aiBrightness", .model, -1...1, step: 0.05, default: 0, format: .ev),
        .range("aiContrast", .model, 0.8...1.35, step: 0.01, default: 1, format: .fixed2),
        .range("aiShadows", .model, -1...1, step: 0.05, default: 0, format: .ev),
        .range("aiHighlights", .model, -1...1, step: 0.05, default: 0, format: .ev),
        .range("aiHdrRange", .model, -1...4, step: 0.1, default: -1, format: .stopsOrAuto1, auto: true),
        .range("aiExpansionStart", .model, -1...0.75, step: 0.01, default: -1, format: .percentOrAuto,
               percent: true, auto: true),
        .range("expansionStart", .region, 0.18...0.75, step: 0.01, default: 0.25, format: .percent,
               percent: true, mask: .participation),
        .range("areaCoverage", .region, 0...1, step: 0.05, default: 1, format: .percent,
               percent: true, mask: .coverage),
    ]

    public static let byKey: [String: ControlSpec] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
}

/// One discrete setting. The request value is the option's string id.
/// Which options are enabled, and why not, is the editor model's business.
public struct ChoiceSpec: Sendable, Hashable {
    public struct Option: Sendable, Hashable {
        public let id: String
        /// `choice.<key>.<id>` in `Localizable.xcstrings`.
        public let labelKey: String
    }

    public let key: String
    /// The static set, in display order.
    public let options: [Option]
    /// The panel-v1 adapter's default.
    public let defaultID: String

    init(_ key: String, _ ids: [String], default defaultID: String) {
        self.key = key
        self.options = ids.map { Option(id: $0, labelKey: "choice.\(key).\($0)") }
        self.defaultID = defaultID
    }
}

public enum EditChoices {
    public static let all: [ChoiceSpec] = [
        ChoiceSpec("encoding", ["adaptive", "iso-gainmap-jpeg", "pq", "hlg", "avif-pq", "avif-hlg",
                                "sdr-jpeg", "sdr-tiff"], default: "adaptive"),
        ChoiceSpec("colorGamut", ["srgb", "p3", "rec2020"], default: "srgb"),
        ChoiceSpec("outputGamut", ["auto", "srgb", "p3"], default: "auto"),
        ChoiceSpec("hevcPreset", ["slow", "medium"], default: "slow"),
        ChoiceSpec("lutInput", ["srgb", "p3", "rec709", "hlg", "pq", "slog3-sgamut3cine"],
                   default: "srgb"),
        ChoiceSpec("lutOutput", ["srgb", "p3", "rec709", "hlg", "pq", "slog3-sgamut3cine"],
                   default: "srgb"),
    ]

    public static let byKey: [String: ChoiceSpec] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
}
