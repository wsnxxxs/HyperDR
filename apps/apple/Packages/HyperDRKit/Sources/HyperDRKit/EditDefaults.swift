import Foundation
import HyperDREngine

/// Port of the Web editor's default/reference settings and preview tier rules.
/// The frozen fixture in `HyperDRKitTests` is the source of truth for parity.
public enum EditDefaults {
    private struct Encoding {
        let id: String
        let maxRange: Double
    }

    private static let encodings: [Encoding] = [
        Encoding(id: "sdr-jpeg", maxRange: 4),
        Encoding(id: "sdr-tiff", maxRange: 4),
        Encoding(id: "adaptive", maxRange: 3),
        Encoding(id: "pq", maxRange: 4),
        Encoding(id: "hlg", maxRange: 2.3),
        Encoding(id: "ultrahdr", maxRange: 4),
        Encoding(id: "avif-pq", maxRange: 4),
        Encoding(id: "avif-hlg", maxRange: 2.3),
    ]

    private static let controlDefaults: [String: JSONValue] = [
        "lutStrength": .number(1),
        "brightness": .number(0.6),
        "hdrStrength": .number(0.4),
        "hdrRange": .number(2.5),
        "modelStrength": .number(1),
        "aiBrightness": .number(0),
        "aiContrast": .number(1),
        "aiShadows": .number(0),
        "aiHighlights": .number(0),
        "aiHdrRange": .number(-1),
        "aiExpansionStart": .number(-1),
        "expansionStart": .number(0.25),
        "areaCoverage": .number(1),
        "highlightRecovery": .string("blend"),
        "contrast": .number(1),
        "vibrance": .number(0),
        "quality": .number(90),
    ]

    static let controlKeys = [
        "lutStrength", "brightness", "hdrStrength", "hdrRange", "modelStrength",
        "aiBrightness", "aiContrast", "aiShadows", "aiHighlights", "aiHdrRange",
        "aiExpansionStart", "expansionStart", "areaCoverage", "highlightRecovery",
        "contrast", "vibrance", "quality",
    ]

    private static let workflowOverrides = [
        "colorGamut", "outputGamut", "clampSrgb", "rawProfile", "rawLook", "lensCorrection",
    ]

    private static func encoding(_ id: String) -> Encoding {
        encodings.first { $0.id == id } ?? encodings.first { $0.id == "adaptive" }!
    }

    private static func isSdrEncoding(_ id: String) -> Bool {
        id == "sdr-jpeg" || id == "sdr-tiff"
    }

    private static func isHDRSource(_ domain: String?) -> Bool {
        domain == "display-referred-hdr" || domain == "dual-rendition"
    }

    private static func defaults(encoding id: String) -> [String: JSONValue] {
        var values: [String: JSONValue] = [
            "encoding": .string(id),
            "hevcPreset": .string("slow"),
            "colorGamut": .string("srgb"),
            "outputGamut": .string("auto"),
            "clampSrgb": .bool(false),
            "rawProfile": .string(""),
            "rawProfileName": .string(""),
            "rawLook": .string(""),
            "rawLookName": .string(""),
            "lensCorrection": .bool(true),
            "lensProfileName": .string(""),
            "lutId": .string(""),
            "lutName": .string(""),
            "lutInput": .string("srgb"),
            "lutOutput": .string("srgb"),
            "modelId": .string("research-cnn-v1"),
        ]
        values.merge(controlDefaults) { _, new in new }
        return values
    }

    private static func applySourceIdentity(_ values: inout [String: JSONValue],
                                            encoding: Encoding,
                                            unadjusted: [String: Double]?) {
        guard let unadjusted else { return }
        for (key, value) in unadjusted { values[key] = .number(value) }
        let range = unadjusted["hdrRange"] ?? values["hdrRange"]?.numberValue ?? encoding.maxRange
        values["hdrRange"] = .number(min(range, encoding.maxRange))
        values["contrast"] = .number(1)
        values["vibrance"] = .number(0)
    }

    /// Defaults for a newly opened photo. HDR/dual sources keep their own
    /// rendering when the engine supplied `unadjusted` control values.
    public static func initial(encoding id: String, sourceDomain: String?,
                               unadjusted: [String: Double]?) -> EditOptions {
        let active = encoding(id)
        var values = defaults(encoding: active.id)
        if isSdrEncoding(active.id) { values["brightness"] = .number(0) }
        values["hdrRange"] = .number(min(2.5, active.maxRange))
        values["aiHdrRange"] = .number(min(-1, active.maxRange))
        if isHDRSource(sourceDomain) {
            applySourceIdentity(&values, encoding: active, unadjusted: unadjusted)
        }
        return EditOptions(values)
    }

    private static func neutralSettings(encoding id: String) -> [String: JSONValue] {
        var values = defaults(encoding: encoding(id).id)
        values["brightness"] = .number(0)
        values["hdrStrength"] = .number(0)
        values["hdrRange"] = .number(0)
        values["contrast"] = .number(1)
        values["vibrance"] = .number(0)
        values["areaCoverage"] = .number(0)
        values["lutStrength"] = .number(0)
        return values
    }

    /// The neutral comparison frame. Output/colour choices and the corrective
    /// lens toggle follow the current workflow, matching photo.js's reference
    /// request; creative LUT and adjustment values are neutral.
    public static func reference(encoding id: String, workflow: EditOptions) -> EditOptions {
        let active = encoding(id)
        var values = neutralSettings(encoding: active.id)
        values["hdrStrength"] = .number(1)
        values["hdrRange"] = .number(active.maxRange)
        for key in workflowOverrides {
            if let value = workflow[key] { values[key] = value }
        }
        return EditOptions(values)
    }

    /// Only the controls, for replacing a new photo's image adjustments while
    /// leaving output/colour/model workflow choices alone.
    public static func imageAdjustments(_ options: EditOptions) -> EditOptions {
        EditOptions(options.values.filter { controlKeys.contains($0.key) })
    }

    /// Port of `quantizedPreviewTier`: 960/1280/2048, clamped by the server
    /// ceiling, the stage box and the screen scale (capped at 2).
    public static func previewEdge(ceiling: Int, boxWidth: Double, boxHeight: Double,
                                   scale: Double) -> Int {
        let tiers = [960, 1280, 2048]
        let allowed = tiers.filter { $0 <= ceiling }
        let list = allowed.isEmpty ? [ceiling] : allowed
        let dpr = min(scale == 0 ? 1 : scale, 2)
        let want = max(boxWidth, boxHeight, 640) * dpr
        for tier in list where Double(tier) >= want { return tier }
        return list[list.count - 1]
    }
}
