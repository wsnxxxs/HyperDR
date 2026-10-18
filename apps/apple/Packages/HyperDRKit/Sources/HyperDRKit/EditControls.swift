import Foundation
import HyperDREngine

/// One inspector control, frozen from the Web editor's `CONTROLS`
/// (`apps/panel/web/js/settings/schema.js`). The engine schema has only its own
/// vocabulary; grouping, steps, formats, masks and string keys live here.
public struct ControlSpec: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case range
        /// Choice ids in display order. `range`, `step` and `defaultValue`
        /// then index into this list; `defaultSetting` is the id itself.
        case segmented([String])
    }
    public enum Group: String, Sendable { case lut, tone, model, region, quality, pinned }
    public enum Format: String, Sendable {
        case ev, signed, percent, fixed2, stops1, stopsOrAuto1, percentOrAuto, integer
    }
    public enum Mask: String, Sendable { case gain, gainFull, participation, coverage }

    /// The panel vocabulary key, which is also the name sent in a request.
    public let key: String
    public let kind: Kind
    public let group: Group
    public let range: ClosedRange<Double>
    public let step: Double
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

    /// The default as a request value: a number, or a segmented control's id.
    public var defaultSetting: JSONValue {
        if case .segmented(let choices) = kind { return .string(choices[Int(defaultValue)]) }
        return .number(defaultValue)
    }

    static func range(_ key: String, _ group: Group, _ range: ClosedRange<Double>, step: Double,
                      default value: Double, format: Format, percent: Bool = false,
                      auto: Bool = false, mask: Mask? = nil, help: Bool = true) -> ControlSpec {
        ControlSpec(key: key, kind: .range, group: group, range: range, step: step,
                    defaultValue: value, format: format, isPercent: percent, allowsAuto: auto,
                    mask: mask, labelKey: "ctrl.\(key).label", helpKey: help ? "ctrl.\(key).help" : nil)
    }

    static func segmented(_ key: String, _ group: Group, choices: [String],
                          default choice: String) -> ControlSpec {
        let index = Double(choices.firstIndex(of: choice)!)
        return ControlSpec(key: key, kind: .segmented(choices), group: group,
                           range: 0...Double(choices.count - 1), step: 1, defaultValue: index,
                           format: .integer, isPercent: false, allowsAuto: false, mask: nil,
                           labelKey: "ctrl.\(key).label", helpKey: "ctrl.\(key).help")
    }
}

/// The inspector's single source of truth, in the Web editor's order. The
/// engine schema is the hard constraint; differences from the Web reference
/// are deliberate and listed in `EditControlsTests.intentionalDeviations`.
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
        // Pinned: no widget, still sent (PC J-05). Removed with R2.
        .segmented("highlightRecovery", .pinned,
                   choices: ["blend", "reconstruct", "clip", "unclip"], default: "blend"),
        .range("contrast", .pinned, 0.8...1.35, step: 0.01, default: 1, format: .fixed2, help: false),
        .range("vibrance", .pinned, -0.5...0.5, step: 0.01, default: 0, format: .signed, help: false),
        .range("quality", .quality, 0...100, step: 1, default: 90, format: .integer, help: false),
    ]

    public static let byKey: [String: ControlSpec] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
}
