import Foundation
import HyperDREngine
import HyperDRKit
import Observation
import HyperDRRecipe

/// Colour-only (SDR output) or HDR, derived from the output encoding.
nonisolated enum Workflow: Equatable, Sendable {
    case colorOnly, hdr

    init(encoding: String) { self = encoding == "sdr-jpeg" || encoding == "sdr-tiff" ? .colorOnly : .hdr }
}

/// What the export itself is asked for: the format and its options, which are
/// not edits, so they have no undo step (p7-2b §3.1). The adjustments are the
/// recipe's.
///
/// Transitional until the P7-3b switch: the old export still takes an
/// `EditOptions` request, built by `exportRequest(recipe:lut:)` below. The
/// switch deletes that function and `init(exportedOptions:)`.
nonisolated struct ExportChoices: Equatable, Sendable {
    var encoding = "adaptive"
    /// `auto`, `srgb` or `p3`.
    var outputGamut = "auto"
    var clampSrgb = false
    var quality = EditControls.all.first { $0.key == "quality" }?.defaultValue ?? 90

    var workflow: Workflow { Workflow(encoding: encoding) }
}

// MARK: - Until P7-3b: the old export's request

extension ExportChoices {
    /// The request the old export renders: the schema's defaults for the
    /// encoding, the export's own choices, and the two recipe values the old
    /// engine path can honour, lens correction and the look's LUT (`lut` is
    /// its library id). The other adjustments are not exported until P7-3b.
    nonisolated func exportRequest(recipe: Recipe, lut: (id: String, name: String)?) -> EditOptions {
        var values = EditDefaults.initial(encoding: encoding).values
        values["outputGamut"] = .string(outputGamut)
        values["clampSrgb"] = .bool(clampSrgb)
        values["quality"] = .number(quality)
        values["lensCorrection"] = .bool(recipe.conditionValue("develop.lensCorrection")?.boolValue ?? true)
        values["lutId"] = .string(lut?.id ?? "")
        values["lutName"] = .string(lut?.name ?? "")
        if lut != nil, recipe.conditionValue("look.enabled")?.boolValue == false { values["lutStrength"] = .number(0) }
        return EditOptions(values)
    }

    /// The export choices of a request the history recorded.
    nonisolated init(exportedOptions options: EditOptions) {
        if case .string(let id)? = options["encoding"] { encoding = id }
        if case .string(let id)? = options["outputGamut"] { outputGamut = id }
        if case .bool(let on)? = options["clampSrgb"] { clampSrgb = on }
        if case .number(let value)? = options["quality"] { quality = value }
    }
}

/// A one-shot message the view shows in place (not an alert).
nonisolated enum EditorNotice: Equatable {
    case rangeClamped(maxStops: Double)
    case clipboardImageUnsupported
}

nonisolated extension JSONValue {
    var editorString: String? { if case .string(let s) = self { return s }; return nil }
}
