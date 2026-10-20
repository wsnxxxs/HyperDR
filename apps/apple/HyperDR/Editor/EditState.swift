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
    var quality = Double(CustomExportFormat().quality)
    /// The photo's long edge in the export; nil keeps the original size.
    var longEdge: Int?

    var workflow: Workflow { Workflow(encoding: encoding) }

    /// The gamut written, as `ExportPlanner` resolves it: an SDR format's
    /// choice (`auto` is P3 for TIFF and sRGB otherwise); Display P3 for a
    /// gain-map format; Rec. 2020 for a BT.2100 one, which defines its own
    /// primaries. Only SDR formats offer a choice.
    var gamut: ExportColorGamut {
        if workflow == .colorOnly {
            if outputGamut == "auto" { return encoding == "sdr-tiff" ? .p3 : .srgb }
            return ExportColorGamut(rawValue: outputGamut) ?? .srgb
        }
        return ExportEncoding(rawValue: encoding)?.isBT2100 == true ? .rec2020 : .p3
    }

    /// The panel's settings for a format Kit wrote (a version's, to restore).
    init(_ format: CustomExportFormat) {
        encoding = format.encoding.rawValue
        quality = Double(format.quality)
        longEdge = format.longEdge
        if workflow == .colorOnly { outputGamut = format.gamut == .p3 ? "p3" : "srgb" }
    }
    init() {}

    /// What Kit plans from.
    var customFormat: CustomExportFormat {
        CustomExportFormat(encoding: ExportEncoding(rawValue: encoding) ?? .adaptive, gamut: gamut,
                           quality: Int(quality.rounded()), longEdge: longEdge)
    }
}

/// A one-shot message the view shows in place (not an alert).
nonisolated enum EditorNotice: Equatable {
    case clipboardImageUnsupported
}

nonisolated extension JSONValue {
    var editorString: String? { if case .string(let s) = self { return s }; return nil }
}
