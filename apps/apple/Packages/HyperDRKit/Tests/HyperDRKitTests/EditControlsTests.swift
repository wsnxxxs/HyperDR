import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

/// The engine schema's own limits, read from its exact JSON (the Swift
/// `SettingsSchema` keeps only key, kind, choices and default).
private struct EngineSetting: Decodable {
    let key: String
    let minimum, maximum: Double?
    let choices: [String]?
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
]
/// AI post-adjustments have no engine setting; the adapter writes them as
/// command flags and checks its own bounds.
private let aiPostFlags = [
    "aiBrightness": "--ai-brightness", "aiContrast": "--ai-contrast",
    "aiShadows": "--ai-shadows", "aiHighlights": "--ai-highlights",
    "aiHdrRange": "--ai-hdr-range", "aiExpansionStart": "--ai-expansion-start",
]
private let choiceMapping = [
    "encoding": "encoding", "colorGamut": "color_gamut", "outputGamut": "output_gamut",
    "hevcPreset": "hevc_preset", "lutInput": "lut_input", "lutOutput": "lut_output",
]
private let encodings = ["sdr-jpeg", "sdr-tiff", "adaptive", "pq", "hlg", "iso-gainmap-jpeg", "avif-pq", "avif-hlg"]

private let photo = PhotoSession(id: SessionID(rawValue: String(repeating: "c", count: 32)),
    sourceURL: URL(fileURLWithPath: "/tmp/defaults.jpg"), displayName: "defaults.jpg",
    byteCount: 1, sha256: "defaults-digest", format: .jpeg)

/// Resolves panel options the way every preview and export request is built.
private func resolved(_ values: [String: JSONValue]) throws -> EngineRequest {
    let resolver = OptionResolver(schema: try Engine.schema(),
        knownModels: ["research-cnn-v1": true], maxEdgeCeiling: 2048)
    return try resolver.resolveExport(EditOptions(values), session: photo)
}

private func bytes(_ request: EngineRequest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(request)
}

@Suite struct EditControlsTests {
    @Test func everySpecIsWellFormed() {
        for spec in EditControls.all {
            let key = spec.key
            #expect(spec.labelKey == "ctrl.\(key).label")
            #expect(spec.helpKey == "ctrl.\(key).help")
            #expect(spec.range.contains(spec.defaultValue), "\(key) default outside its range")
            #expect(spec.step > 0 && spec.step <= spec.range.upperBound - spec.range.lowerBound)
            #expect(!spec.allowsAuto || spec.range.lowerBound < 0, "\(key) auto needs a negative value")
            #expect(EditControls.byKey[key] == spec)
            #expect(EditChoices.byKey[key] == nil, "\(key) is both a control and a choice")
        }
        for spec in EditChoices.all {
            #expect(spec.options.map(\.labelKey) == spec.options.map { "choice.\(spec.key).\($0.id)" })
            #expect(Set(spec.options.map(\.id)).count == spec.options.count, "\(spec.key) repeats an id")
            #expect(spec.options.contains { $0.id == spec.defaultID }, "\(spec.key) default is no option")
            #expect(EditChoices.byKey[spec.key] == spec)
        }
    }

    /// Settings the adapter fills itself have no control (batch4 §2.1).
    @Test func adapterSuppliedSettingsAreNotControls() {
        for key in ["highlightRecovery", "contrast", "vibrance", "quality"] {
            #expect(EditControls.byKey[key] == nil && EditChoices.byKey[key] == nil, "\(key)")
            #expect(EditDefaults.initial(encoding: "pq", sourceDomain: nil, unadjusted: nil)[key] == nil)
        }
    }

    @Test func defaultsComeFromTheTables() {
        let initial = EditDefaults.initial(encoding: "pq", sourceDomain: nil, unadjusted: nil)
        for spec in EditControls.all {
            #expect(initial[spec.key] == .number(spec.defaultValue), "\(spec.key)")
        }
        for spec in EditChoices.all where spec.key != "encoding" {
            #expect(initial[spec.key] == .string(spec.defaultID), "\(spec.key)")
        }
        #expect(EditDefaults.controlKeys == EditControls.all.map(\.key))
    }

    @Test func rangesAndChoicesStayInsideTheEngineSchema() throws {
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
        #expect(Set(EditControls.all.map(\.key)) ==
                Set(engineMapping.map(\.panel)).union(aiPostFlags.keys), "a control has no engine mapping")
        #expect(Set(EditChoices.all.map(\.key)) == Set(choiceMapping.keys), "a choice has no engine mapping")
        for spec in EditChoices.all {
            let key = try #require(choiceMapping[spec.key])
            let choices = try #require(engine[key]?.choices, "engine schema has no \(key) choices")
            for option in spec.options {
                #expect(choices.contains(option.id), "\(spec.key).\(option.id) is not a \(key) value")
            }
        }
    }

    /// The per-format ceiling of hdrRange / aiHdrRange: inside the engine's
    /// headroom_max, accepted by the adapter, and the format's own limit for
    /// HLG, where the adapter rejects anything higher.
    @Test func everyFormatCeilingIsInsideTheEngine() throws {
        let headroom = try #require(try engineSettings()["headroom_max"]?.maximum)
        let staticCeiling = try #require(EditControls.byKey["hdrRange"]).range.upperBound
        #expect(Set(EditChoices.byKey["encoding"]?.options.map(\.id) ?? []) == Set(encodings))
        for encoding in encodings {
            let ceiling = EditDefaults.maxRange(for: encoding)
            #expect(ceiling > 0 && ceiling <= headroom, "\(encoding): \(ceiling) vs \(headroom)")
            #expect(ceiling <= staticCeiling)
            _ = try Engine.normalize(["encoding": .string(encoding), "hdrRange": .number(ceiling)])
            _ = try Engine.normalize(["encoding": .string(encoding), "_model_mode": .bool(true),
                                      "aiHdrRange": .number(ceiling)])
            let initial = EditDefaults.initial(encoding: encoding, sourceDomain: nil, unadjusted: nil)
            let initialRange = try #require(initial["hdrRange"]?.numberValue)
            #expect(initialRange <= ceiling, "\(encoding)")
        }
        for encoding in ["hlg", "avif-hlg"] {
            let above = EditDefaults.maxRange(for: encoding) + 0.1
            #expect(throws: (any Error).self) {
                _ = try Engine.normalize(["encoding": .string(encoding), "hdrRange": .number(above)])
            }
        }
        #expect(EditDefaults.maxRange(for: "unknown") == EditDefaults.maxRange(for: "adaptive"))
    }

    /// Writing a Kit default and leaving the key out give byte-identical
    /// requests, for every key `EditDefaults.initial` writes, per output
    /// format, manual and model mode. Binds the tables to the adapter.
    @Test func writingADefaultEqualsLeavingItOut() throws {
        // Two deliberate exceptions, both unchanged values (D1 unifies them):
        // - colorGamut / outputGamut: same settings, but an explicit choice is
        //   recorded in `command.*_explicit` and becomes a CLI flag.
        // - brightness under SDR output: Kit starts at 0, the adapter at 0.6.
        for encoding in encodings {
            for model in [false, true] {
                var minimal: [String: JSONValue] = ["encoding": .string(encoding)]
                if model { minimal["useModel"] = .bool(true) }
                let omitted = try resolved(minimal)
                let initial = EditDefaults.initial(encoding: encoding, sourceDomain: nil, unadjusted: nil)
                for (key, value) in initial.values where key != "encoding" {
                    let written = try resolved(minimal.merging([key: value]) { old, _ in old })
                    let label = "\(encoding) model=\(model) \(key)=\(value)"
                    switch key {
                    case "colorGamut", "outputGamut":
                        #expect(written.settings == omitted.settings, "\(label)")
                        var command = written.command
                        command[key == "colorGamut" ? "color_explicit" : "output_explicit"] = .bool(false)
                        #expect(command == omitted.command, "\(label)")
                    case "brightness" where !model && (encoding == "sdr-jpeg" || encoding == "sdr-tiff"):
                        #expect(written.settings["exposure_bias"] == .number(0))
                        #expect(omitted.settings["exposure_bias"] == .number(0.6))
                    default:
                        #expect(try bytes(written) == bytes(omitted), "\(label)")
                    }
                }
                // The settings left out on purpose are the adapter's values.
                for (key, value) in ["highlightRecovery": JSONValue.string("blend"), "contrast": .number(1),
                                     "vibrance": .number(0), "quality": .number(90)] {
                    let written = try resolved(minimal.merging([key: value]) { old, _ in old })
                    #expect(try bytes(written) == bytes(omitted), "\(encoding) model=\(model) \(key)")
                }
            }
        }
    }

    /// Every table bound is accepted by the adapter; one step outside is
    /// rejected wherever the engine's limit is the same.
    @Test func adapterAcceptsTheTableBounds() throws {
        func normalize(_ key: String, _ value: Double, model: Bool) throws {
            var options: [String: JSONValue] = ["encoding": .string("pq"), key: .number(value)]
            if model { options["_model_mode"] = .bool(true); options["_model_id"] = .string("research-cnn-v1") }
            _ = try Engine.normalize(options)
        }
        for spec in EditControls.all where spec.key != "modelStrength" {
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
        // modelStrength is checked by the resolver, which maps it to hdrStrength.
        let strength = try #require(EditControls.byKey["modelStrength"])
        for value in [strength.range.lowerBound, strength.range.upperBound] {
            #expect(try resolved(["useModel": .bool(true), "modelStrength": .number(value)])
                .settings["gain_strength"] == .number(value))
        }
        #expect(throws: (any Error).self) {
            _ = try resolved(["useModel": .bool(true), "modelStrength": .number(strength.range.upperBound + 0.05)])
        }
    }

    /// The AI post-adjustment defaults are the adapter's.
    @Test func aiPostDefaultsMatchTheAdapter() throws {
        let command = try Engine.normalize(["encoding": .string("adaptive"), "_model_mode": .bool(true),
                                            "_model_id": .string("research-cnn-v1")]).command
        for (panel, flag) in aiPostFlags {
            #expect(command[flag] == EditControls.byKey[panel].map { .number($0.defaultValue) }, "\(panel)")
        }
    }
}
