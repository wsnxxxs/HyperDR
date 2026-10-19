import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../../..", isDirectory: true).standardized

private struct WebReference: Decodable {
    struct Encoding: Decodable { let id: String; let maxRange: Double }
    struct InitialCase: Decodable {
        let encoding: String
        let sourceDomain: String?
        let unadjusted: [String: Double]?
        let settings: [String: JSONValue]
    }
    struct ReferenceCase: Decodable {
        let encoding: String
        let workflow: [String: JSONValue]
        let settings: [String: JSONValue]
    }
    struct PreviewCase: Decodable {
        let ceiling: Int
        let width, height, scale: Double
        let edge: Int
    }
    let schema: Int
    let encodings: [Encoding]
    let imageAdjustmentKeys: [String]
    let domains: [String]
    let unadjusted: [String: Double]
    let initial: [InitialCase]
    let reference: [ReferenceCase]
    let previewEdge: [PreviewCase]
}

private func loadReference() throws -> WebReference {
    let url = repository.appendingPathComponent(
        "apps/apple/Packages/HyperDRKit/Tests/HyperDRKitTests/Fixtures/web-reference.json")
    return try JSONDecoder().decode(WebReference.self, from: Data(contentsOf: url))
}

/// Settings the Web wrote with fixed values and Kit leaves to the panel-v1
/// adapter (batch4 §2.1); `EditControlsTests` shows omitting them changes no
/// request byte.
private let adapterSupplied: Set<String> = ["contrast", "vibrance"]

/// D1 deliberately differs from the frozen Web defaults (removed with the Web
/// front end): neutral brightness for every format, the schema's HDR strength
/// and area coverage, automatic headroom, and no values of an HDR source's own.
private func d1Defaults(_ settings: [String: JSONValue]) -> [String: JSONValue] {
    var settings = settings
    settings["brightness"] = .number(SchemaDefaults.number("exposure_bias"))
    settings["hdrStrength"] = .number(SchemaDefaults.number("gain_strength"))
    settings["areaCoverage"] = .number(SchemaDefaults.number("area_coverage"))
    settings["lutStrength"] = .number(SchemaDefaults.number("lut_strength"))
    settings["hdrRange"] = .number(-1)
    return settings
}

private func withoutAdapterSupplied(_ settings: [String: JSONValue]) -> [String: JSONValue] {
    // R2 intentionally removes the Web reference's external RAW vocabulary.
    let removed: Set<String> = ["highlightRecovery", "rawProfile", "rawProfileName", "rawLook", "rawLookName", "lensProfileName"]
    return settings.filter { !adapterSupplied.contains($0.key) && !removed.contains($0.key) }
}

/// The fixture stays frozen with the Web's encoding names; E4r renamed
/// `ultrahdr` to `iso-gainmap-jpeg` (the engine accepts the old name only
/// until P2c), so the comparison translates it.
private func renamed(_ encoding: String) -> String {
    encoding == "ultrahdr" ? "iso-gainmap-jpeg" : encoding
}

private func renamed(_ settings: [String: JSONValue]) -> [String: JSONValue] {
    var settings = settings
    if case .string(let encoding)? = settings["encoding"] { settings["encoding"] = .string(renamed(encoding)) }
    return settings
}

@Suite struct EditDefaultsTests {
    @Test func matchesFrozenWebInitialReference() throws {
        let reference = try loadReference()
        #expect(reference.schema == 1)
        #expect(reference.encodings.count == 8)
        for encoding in reference.encodings {
            #expect(EditDefaults.maxRange(for: renamed(encoding.id)) == encoding.maxRange, "\(encoding.id)")
        }
        #expect(reference.domains.count == 5)
        #expect(reference.initial.count == 80)
        for entry in reference.initial {
            let actual = EditDefaults.initial(encoding: renamed(entry.encoding))
            #expect(actual.values == d1Defaults(withoutAdapterSupplied(renamed(entry.settings))),
                "initial mismatch: \(entry.encoding) \(entry.sourceDomain ?? "nil")")
        }
    }

    @Test func matchesFrozenReferenceAndPreviewTiers() throws {
        let reference = try loadReference()
        for entry in reference.reference {
            let workflow = EditOptions(entry.workflow)
            let actual = EditDefaults.reference(encoding: renamed(entry.encoding), workflow: workflow)
            #expect(actual.values == withoutAdapterSupplied(renamed(entry.settings)), "reference mismatch: \(entry.encoding)")
        }
        #expect(reference.reference.count == 8)
        for entry in reference.previewEdge {
            #expect(EditDefaults.previewEdge(ceiling: entry.ceiling,
                boxWidth: entry.width, boxHeight: entry.height, scale: entry.scale) == entry.edge)
        }
        #expect(reference.previewEdge.count == 12)
    }

    @Test func imageAdjustmentsKeepOnlyControls() throws {
        let reference = try loadReference()
        let workflow = EditOptions(try #require(reference.reference.first).workflow)
        let adjustments = EditDefaults.imageAdjustments(workflow)
        #expect(adjustments.values.keys.sorted() ==
                reference.imageAdjustmentKeys.filter { !adapterSupplied.contains($0) && $0 != "highlightRecovery" }.sorted())
        #expect(adjustments["encoding"] == nil)
        #expect(adjustments["colorGamut"] == nil)
        #expect(adjustments["hdrStrength"] == reference.reference.first?.workflow["hdrStrength"])
    }

    /// One set of defaults: nothing about the source changes them, and they are the schema's.
    @Test func defaultsAreTheSchemasForEverySource() throws {
        let schema = try Engine.schema()
        let initial = EditDefaults.initial(encoding: "adaptive")
        for (panel, key) in [("brightness", "exposure_bias"), ("hdrStrength", "gain_strength"),
                             ("expansionStart", "expansion_start"), ("areaCoverage", "area_coverage"),
                             ("lutStrength", "lut_strength"), ("quality", "quality")] {
            let setting = try #require(schema.settings.first { $0.key == key })
            #expect(initial[panel] == setting.default, "\(panel) vs \(key)")
        }
        // Automatic headroom is the schema's default: `headroom` "auto", capped at `headroom_max`.
        #expect(schema.settings.first { $0.key == "headroom" }?.default == .string("auto"))
        #expect(initial["hdrRange"] == .number(-1))
        for encoding in ["sdr-jpeg", "pq", "hlg"] {
            #expect(EditDefaults.initial(encoding: encoding)["brightness"] == .number(0), "\(encoding)")
            #expect(EditDefaults.initial(encoding: encoding)["hdrRange"] == .number(-1), "\(encoding)")
        }
    }

    @Test func editOptionsEncodeAsAFlatObject() throws {
        let options = EditOptions(["encoding": .string("adaptive"), "contrast": .number(1.123456)])
        let data = try JSONEncoder().encode(options)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["values"] == nil)
        #expect(object["encoding"] as? String == "adaptive")
        #expect(try JSONDecoder().decode(EditOptions.self, from: data) == options)
    }
}
