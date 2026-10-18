import Foundation
import HyperDREngine

/// Default and reference settings for a photo, and the preview tier rule.
/// Values come from `EditControls` and `EditChoices`, which equal the
/// panel-v1 adapter's defaults; keys the adapter fills itself
/// (`highlightRecovery`, `contrast`, `vibrance`, `quality`) are omitted.
public enum EditDefaults {
    /// The highest `hdrRange` / `aiHdrRange` each output format accepts
    /// (batch4 §2.2). Unknown ids fall back to Adaptive, like `initial`.
    private static let maxRanges: [String: Double] = [
        "sdr-jpeg": 4, "sdr-tiff": 4, "adaptive": 3, "pq": 4,
        "hlg": 2.3, "iso-gainmap-jpeg": 4, "avif-pq": 4, "avif-hlg": 2.3,
    ]

    private struct Encoding {
        let id: String
        let maxRange: Double
    }

    public static func maxRange(for encoding: String) -> Double {
        self.encoding(encoding).maxRange
    }

    private static let controlDefaults: [String: JSONValue] =
        Dictionary(uniqueKeysWithValues: EditControls.all.map { ($0.key, .number($0.defaultValue)) })
    private static let choiceDefaults: [String: JSONValue] =
        Dictionary(uniqueKeysWithValues: EditChoices.all.map { ($0.key, .string($0.defaultID)) })

    static let controlKeys = EditControls.all.map(\.key)

    private static let workflowOverrides = [
        "colorGamut", "outputGamut", "clampSrgb", "rawProfile", "rawLook", "lensCorrection",
    ]

    private static func encoding(_ id: String) -> Encoding {
        if let range = maxRanges[id] { return Encoding(id: id, maxRange: range) }
        return Encoding(id: "adaptive", maxRange: maxRanges["adaptive"]!)
    }

    private static func isSdrEncoding(_ id: String) -> Bool {
        id == "sdr-jpeg" || id == "sdr-tiff"
    }

    private static func isHDRSource(_ domain: String?) -> Bool {
        domain == "display-referred-hdr" || domain == "dual-rendition"
    }

    private static func defaults(encoding id: String) -> [String: JSONValue] {
        // Settings without a ControlSpec or ChoiceSpec yet: switches (M3
        // gives them their own value objects) and resource selections.
        var values: [String: JSONValue] = [
            "clampSrgb": .bool(false),
            "rawProfile": .string(""),
            "rawProfileName": .string(""),
            "rawLook": .string(""),
            "rawLookName": .string(""),
            "lensCorrection": .bool(true),
            "lensProfileName": .string(""),
            "lutId": .string(""),
            "lutName": .string(""),
            "modelId": .string("research-cnn-v1"),
        ]
        values.merge(choiceDefaults) { _, new in new }
        values.merge(controlDefaults) { _, new in new }
        values["encoding"] = .string(id)
        return values
    }

    private static func applySourceIdentity(_ values: inout [String: JSONValue],
                                            encoding: Encoding,
                                            unadjusted: [String: Double]?) {
        guard let unadjusted else { return }
        for (key, value) in unadjusted { values[key] = .number(value) }
        let range = unadjusted["hdrRange"] ?? values["hdrRange"]?.numberValue ?? encoding.maxRange
        values["hdrRange"] = .number(min(range, encoding.maxRange))
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
