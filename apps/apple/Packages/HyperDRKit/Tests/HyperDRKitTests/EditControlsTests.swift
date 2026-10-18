import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/web-reference.json")

/// One entry of `controls` in the frozen Web reference
/// (`scripts/freeze_web_reference.mjs`), in `CONTROLS` order.
private struct WebControl: Decodable {
    let key, kind, group, format, label: String
    let min, max, step: Double?
    let `default`: JSONValue
    let percent, auto: Bool
    let mask, help: String?
    let choices: [String]?
}

private func webControls() throws -> [WebControl] {
    struct Document: Decodable { let controls: [WebControl] }
    return try JSONDecoder().decode(Document.self, from: Data(contentsOf: fixture)).controls
}

/// The engine schema's own limits, read from its exact JSON (the Swift
/// `SettingsSchema` keeps only key, kind, choices and default).
private struct EngineSetting: Decodable {
    let key: String
    let minimum, maximum: Double?
    let choices: [String]?
    let `default`: JSONValue?
}

private func engineSettings() throws -> [String: EngineSetting] {
    struct Document: Decodable { let settings: [EngineSetting] }
    let document = try JSONDecoder().decode(Document.self, from: Engine.schema().rawJSON)
    return Dictionary(uniqueKeysWithValues: document.settings.map { ($0.key, $0) })
}

/// Panel key → engine setting, as `normalize_options` (panel-v1) maps it.
/// `equal`: the panel range is the engine's; otherwise it lies inside it.
private let engineMapping: [(panel: String, engine: String, equal: Bool)] = [
    ("lutStrength", "lut_strength", true),
    ("brightness", "exposure_bias", true),
    ("hdrStrength", "gain_strength", false),
    ("hdrRange", "headroom_max", true),
    ("modelStrength", "gain_strength", false),   // sent as hdrStrength in model mode
    ("expansionStart", "expansion_start", true),
    ("areaCoverage", "area_coverage", true),
    ("contrast", "contrast", true),
    ("vibrance", "vibrance", true),
    ("quality", "quality", true),
]
/// AI post-adjustments have no engine setting; the adapter writes them as
/// command flags and checks its own bounds.
private let aiPostFlags = [
    "aiBrightness": "--ai-brightness", "aiContrast": "--ai-contrast",
    "aiShadows": "--ai-shadows", "aiHighlights": "--ai-highlights",
    "aiHdrRange": "--ai-hdr-range", "aiExpansionStart": "--ai-expansion-start",
]

@Suite struct EditControlsTests {
    /// Deliberate differences from the Web `CONTROLS` (user, 2026-10-18:
    /// follow good design, not the old version). Keyed "<control>.<field>";
    /// the value is what the Web had. A listed difference that no longer
    /// differs fails, so this list stays exact.
    static let intentionalDeviations: [String: String] = [
        // The slider's static ceiling is the widest format's (PQ, Ultra HDR,
        // AVIF PQ: 4 stops, the engine's headroom_max); Web capped it at 3,
        // although its own validation allowed 4 for those formats.
        "hdrRange.max": "3.0",
        "aiHdrRange.max": "3.0",
    ]

    @Test func tableMatchesTheFrozenWebControlsExceptListedDeviations() throws {
        let web = try webControls()
        #expect(EditControls.all.map(\.key) == web.map(\.key), "order or set of controls differs")
        var seen: Set<String> = []
        func compare(_ key: String, _ field: String, ours: String, theirs: String) {
            let name = "\(key).\(field)"
            if let recorded = Self.intentionalDeviations[name] {
                seen.insert(name)
                #expect(recorded == theirs && ours != theirs, "stale deviation \(name)")
            } else {
                #expect(ours == theirs, "\(name): ours \(ours), Web \(theirs); list it if intended")
            }
        }
        func text(_ value: Double?) -> String { value.map { String($0) } ?? "nil" }
        for (spec, control) in zip(EditControls.all, web) {
            let key = spec.key
            compare(key, "group", ours: spec.group.rawValue, theirs: control.group)
            compare(key, "format", ours: spec.format.rawValue, theirs: control.format)
            compare(key, "percent", ours: "\(spec.isPercent)", theirs: "\(control.percent)")
            compare(key, "auto", ours: "\(spec.allowsAuto)", theirs: "\(control.auto)")
            compare(key, "mask", ours: spec.mask?.rawValue ?? "nil", theirs: control.mask ?? "nil")
            compare(key, "help", ours: "\(spec.helpKey != nil)", theirs: "\(control.help != nil)")
            compare(key, "default", ours: "\(spec.defaultSetting)", theirs: "\(control.default)")
            switch spec.kind {
            case .range:
                compare(key, "kind", ours: "range", theirs: control.kind)
                compare(key, "min", ours: text(spec.range.lowerBound), theirs: text(control.min))
                compare(key, "max", ours: text(spec.range.upperBound), theirs: text(control.max))
                compare(key, "step", ours: text(spec.step), theirs: text(control.step))
            case .segmented(let choices):
                compare(key, "kind", ours: "segmented", theirs: control.kind)
                compare(key, "choices", ours: "\(choices)", theirs: "\(control.choices ?? [])")
            }
        }
        #expect(seen == Set(Self.intentionalDeviations.keys), "deviation names that match no field")
    }

    /// Internal consistency, independent of the Web.
    @Test func everySpecIsWellFormed() {
        for spec in EditControls.all {
            let key = spec.key
            #expect(spec.labelKey == "ctrl.\(key).label")
            if let helpKey = spec.helpKey { #expect(helpKey == "ctrl.\(key).help") }
            #expect(spec.range.contains(spec.defaultValue), "\(key) default outside its range")
            #expect(spec.step > 0 && spec.step <= spec.range.upperBound - spec.range.lowerBound)
            #expect(!spec.allowsAuto || spec.range.lowerBound < 0, "\(key) auto needs a negative value")
            if case .segmented(let choices) = spec.kind {
                #expect(spec.range == 0...Double(choices.count - 1) && spec.step == 1)
            }
            #expect(EditControls.byKey[key] == spec)
        }
    }

    @Test func defaultsComeFromTheTable() {
        let initial = EditDefaults.initial(encoding: "pq", sourceDomain: nil, unadjusted: nil)
        for spec in EditControls.all {
            #expect(initial[spec.key] == spec.defaultSetting, "\(spec.key)")
        }
        #expect(EditDefaults.controlKeys == EditControls.all.map(\.key))
    }

    @Test func rangesAndDefaultsAgreeWithTheEngineSchema() throws {
        let engine = try engineSettings()
        for (panel, key, equal) in engineMapping {
            let spec = try #require(EditControls.byKey[panel])
            let setting = try #require(engine[key], "engine schema has no \(key)")
            let minimum = try #require(setting.minimum), maximum = try #require(setting.maximum)
            if equal {
                #expect(spec.range == minimum...maximum, "\(panel) vs \(key)")
            } else {
                #expect(minimum <= spec.range.lowerBound && spec.range.upperBound <= maximum,
                        "\(panel) outside \(key)")
            }
        }
        // hdrRange's ceiling follows the format; no format may exceed the engine.
        let headroom = try #require(engine["headroom_max"]?.maximum)
        for encoding in ["sdr-jpeg", "sdr-tiff", "adaptive", "pq", "hlg", "ultrahdr", "avif-pq", "avif-hlg"] {
            let range = EditDefaults.initial(encoding: encoding, sourceDomain: nil, unadjusted: nil)
            #expect((range["hdrRange"]?.numberValue ?? .infinity) <= headroom)
        }
        let recovery = try #require(engine["highlight_recovery"])
        let spec = try #require(EditControls.byKey["highlightRecovery"])
        #expect(spec.kind == .segmented(try #require(recovery.choices)))
        #expect(spec.defaultSetting == recovery.default)
        #expect(EditControls.byKey["quality"]?.defaultSetting == engine["quality"]?.default)
    }

    /// The panel-v1 adapter fills an omitted control with the same default.
    @Test func adapterDefaultsMatchTheTable() throws {
        let settings = try Engine.normalize(["encoding": .string("adaptive")]).settings
        for (panel, key, _) in engineMapping where panel != "modelStrength" {
            #expect(settings[key] == EditControls.byKey[panel]?.defaultSetting, "\(panel) → \(key)")
        }
        #expect(settings["highlight_recovery"] == EditControls.byKey["highlightRecovery"]?.defaultSetting)

        let model = try Engine.normalize(["encoding": .string("adaptive"), "_model_mode": .bool(true),
                                          "_model_id": .string("research-cnn-v1")]).command
        for (panel, flag) in aiPostFlags {
            #expect(model[flag] == EditControls.byKey[panel]?.defaultSetting, "\(panel) → \(flag)")
        }
    }

    /// Every table bound is accepted by the adapter; one step below the lower
    /// bound is rejected wherever the engine's limit is the same.
    @Test func adapterAcceptsTheTableBounds() throws {
        func normalize(_ key: String, _ value: Double, model: Bool) throws {
            var options: [String: JSONValue] = ["encoding": .string("pq"), key: .number(value)]
            if model { options["_model_mode"] = .bool(true); options["_model_id"] = .string("research-cnn-v1") }
            _ = try Engine.normalize(options)
        }
        for spec in EditControls.all where spec.kind == .range && spec.key != "modelStrength" {
            let model = aiPostFlags[spec.key] != nil
            try normalize(spec.key, spec.range.lowerBound, model: model)
            try normalize(spec.key, spec.range.upperBound, model: model)
        }
        for key in aiPostFlags.keys {
            let spec = try #require(EditControls.byKey[key])
            #expect(throws: (any Error).self, "\(key) below its range") {
                try normalize(key, spec.range.lowerBound - spec.step, model: true)
            }
        }
        for (panel, _, equal) in engineMapping where equal {
            let spec = try #require(EditControls.byKey[panel])
            #expect(throws: (any Error).self, "\(panel) below its range") {
                try normalize(panel, spec.range.lowerBound - spec.step, model: false)
            }
            #expect(throws: (any Error).self, "\(panel) above its range") {
                try normalize(panel, spec.range.upperBound + spec.step, model: false)
            }
        }
    }
}
