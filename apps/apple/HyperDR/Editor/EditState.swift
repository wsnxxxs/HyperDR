import Foundation
import HyperDREngine
import HyperDRKit
import Observation

/// The export panel's two layouts, derived from the output encoding: the
/// colour-only one for SDR JPEG, and the HDR one. The lossless files belong to
/// the HDR layout whether or not their HDR output is on, so turning it off does
/// not move the panel under the pointer; whether the file is SDR is
/// `ExportChoices.writesHDR`.
nonisolated enum Workflow: Equatable, Sendable {
    case colorOnly, hdr

    init(encoding: String) { self = encoding == "sdr-jpeg" ? .colorOnly : .hdr }
}

/// The lossless group's two cards. Each stands for an SDR and an HDR encoding
/// (and, for TIFF, two HDR depths); the panel's HDR output switch and depth
/// menu pick among them.
nonisolated enum LosslessFamily: String, CaseIterable, Sendable {
    case tiff, dng

    /// The card's id, which is also its `enc.<id>.label` / `.hint` key.
    var cardID: String { "lossless-\(rawValue)" }

    init?(cardID: String) {
        guard let family = Self.allCases.first(where: { $0.cardID == cardID }) else { return nil }
        self = family
    }

    init?(encoding: String) {
        switch ExportEncoding(rawValue: encoding) {
        case .sdrTIFF?, .hdrTIFF16?, .hdrTIFF32?: self = .tiff
        case .sdrDNG?, .hdrDNG?: self = .dng
        default: return nil
        }
    }

    func encoding(hdr: Bool, tiffDepth: Int) -> ExportEncoding {
        let sdr: ExportEncoding = self == .tiff ? .sdrTIFF : .sdrDNG
        return hdr ? sdr.hdrCounterpart(tiffDepth: tiffDepth) : sdr
    }
}

/// The export panel's custom-format page: not edits, so no undo step
/// (p7-2b §3.1). The adjustments are the recipe's.
nonisolated struct ExportChoices: Equatable, Sendable {
    var encoding = "adaptive"
    /// For a format that offers a choice (`ExportEncoding.gamutChoices`):
    /// `auto`, `srgb`, `p3` or `rec2020`.
    var outputGamut = "auto"
    var quality = Double(CustomExportFormat().quality)
    /// The photo's long edge in the export; nil keeps the original size.
    var longEdge: Int?
    /// The HDR TIFF's depth, 16 or 32 bits per channel, kept while the card
    /// writes SDR so turning HDR output back on finds it again.
    var tiffDepth = 16

    var workflow: Workflow { Workflow(encoding: encoding) }

    /// Whether the file carries anything above SDR white: every format but the
    /// SDR JPEG, TIFF and DNG.
    var writesHDR: Bool { !(ExportEncoding(rawValue: encoding)?.isSDR ?? false) }

    /// The gamut written, as `ExportPlanner` resolves it: the choice of a
    /// format that offers one (`auto` is sRGB for JPEG and Display P3 for the
    /// lossless files); Display P3 for a gain-map format; Rec. 2020 for a
    /// BT.2100 one, which defines its own primaries.
    var gamut: ExportColorGamut {
        guard let format = ExportEncoding(rawValue: encoding) else { return .p3 }
        let choices = format.gamutChoices
        guard !choices.isEmpty else { return format.isBT2100 ? .rec2020 : .p3 }
        if let chosen = ExportColorGamut(rawValue: outputGamut), choices.contains(chosen) { return chosen }
        return format == .sdrJPEG ? .srgb : .p3
    }

    /// The panel's settings for a format Kit wrote (a version's, to restore).
    init(_ format: CustomExportFormat) {
        encoding = format.encoding.rawValue
        quality = Double(format.quality)
        longEdge = format.longEdge
        if !format.encoding.gamutChoices.isEmpty { outputGamut = format.gamut.rawValue }
        if format.encoding == .hdrTIFF32 { tiffDepth = 32 }
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
