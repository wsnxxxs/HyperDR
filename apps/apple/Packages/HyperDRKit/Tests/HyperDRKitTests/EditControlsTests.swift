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
    ("quality", "quality", true),
    ("lutStrength", "lut_strength", true),
    ("brightness", "exposure_bias", true),
    ("hdrStrength", "gain_strength", false),
    ("hdrRange", "headroom_max", false),   // below 0 is automatic headroom
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

    /// D1: every mapped Kit default is the engine schema's own value.
    @Test func defaultsEqualTheSchemaDefaults() throws {
        let schema = try Engine.schema()
        func schemaDefault(_ key: String) throws -> JSONValue {
            let setting = try #require(schema.settings.first { $0.key == key })
            return try #require(setting.default, "\(key)")
        }
        for (panel, key, _) in engineMapping where panel != "hdrRange" {
            let spec = try #require(EditControls.byKey[panel])
            let expected = try schemaDefault(key)
            #expect(JSONValue.number(spec.defaultValue) == expected, "\(panel) vs \(key)")
        }
        for (panel, key) in choiceMapping {
            let spec = try #require(EditChoices.byKey[panel])
            let expected = try schemaDefault(key)
            #expect(JSONValue.string(spec.defaultID) == expected, "\(panel) vs \(key)")
        }
        #expect(try schemaDefault("headroom") == .string("auto"))
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
                // hdrRange's one state below the numeric range is automatic.
                #expect((spec.allowsAuto || minimum <= spec.range.lowerBound) && spec.range.upperBound <= maximum,
                        "\(panel) outside \(key)")
            }
        }
        // hdrRange: the schema's numeric range, with one state below it for automatic headroom.
        let headroom = try #require(engine["headroom_max"])
        let hdrRange = try #require(EditControls.byKey["hdrRange"])
        let headroomMaximum = try #require(headroom.maximum)
        #expect(hdrRange.allowsAuto && hdrRange.range == -1...headroomMaximum)
        #expect(hdrRange.defaultValue < 0, "the schema's headroom default is automatic")
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

    /// The AI post-adjustment defaults are the adapter's.
    @Test func aiPostDefaultsMatchTheAdapter() throws {
        let command = try Engine.normalize(["encoding": .string("adaptive"), "_model_mode": .bool(true),
                                            "_model_id": .string("research-cnn-v1")]).command
        for (panel, flag) in aiPostFlags {
            #expect(command[flag] == EditControls.byKey[panel].map { .number($0.defaultValue) }, "\(panel)")
        }
    }
}
