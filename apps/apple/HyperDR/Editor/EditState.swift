import Foundation
import HyperDREngine
import HyperDRKit
import Observation

/// Colour-only (SDR output) or HDR, derived from the output encoding.
nonisolated enum Workflow: Equatable, Sendable {
    case colorOnly, hdr

    init(encoding: String) { self = encoding == "sdr-jpeg" || encoding == "sdr-tiff" ? .colorOnly : .hdr }
}

/// The export panel's custom-format page: not edits, so no undo step
/// (p7-2b §3.1). The adjustments are the recipe's.
nonisolated struct ExportChoices: Equatable, Sendable {
    var encoding = "adaptive"
    /// For an SDR format: `auto`, `srgb` or `p3`.
    var outputGamut = "auto"
    /// For an HDR format: limit the colours to sRGB instead of keeping Display P3.
    var clampSrgb = false
    var quality = EditControls.all.first { $0.key == "quality" }?.defaultValue ?? 90

    var workflow: Workflow { Workflow(encoding: encoding) }

    /// The gamut written: an SDR format's choice (`auto` is P3 for TIFF and
    /// sRGB otherwise), or Display P3 for an HDR one unless limited to sRGB.
    /// BT.2100 formats define their own primaries, which the plan applies.
    var gamut: ExportColorGamut {
        if workflow == .colorOnly {
            if outputGamut == "auto" { return encoding == "sdr-tiff" ? .p3 : .srgb }
            return ExportColorGamut(rawValue: outputGamut) ?? .srgb
        }
        return clampSrgb ? .srgb : .p3
    }

    /// The panel's settings for a format Kit wrote (a version's, to restore).
    init(_ format: CustomExportFormat) {
        encoding = format.encoding.rawValue
        quality = Double(format.quality)
        if workflow == .colorOnly { outputGamut = format.gamut == .p3 ? "p3" : "srgb" }
        else { clampSrgb = format.gamut == .srgb }
    }
    init() {}

    /// What Kit plans from.
    var customFormat: CustomExportFormat {
        CustomExportFormat(encoding: ExportEncoding(rawValue: encoding) ?? .adaptive, gamut: gamut,
                           quality: Int(quality.rounded()))
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
