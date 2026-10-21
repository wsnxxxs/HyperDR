import HyperDRKit
import SwiftUI

/// The export sheet's format tiles: a container and the encodings it carries.
/// The eight encodings fold into four tiles, so the choice reads as "which
/// file" first; the encoding row then picks how a tile writes HDR.
enum ExportFamily: CaseIterable, Hashable {
    case jpeg, heic, avif, tiff

    /// In the order the encoding menu lists them; the first is the default.
    var encodings: [ExportEncoding] {
        switch self {
        case .jpeg: [.isoGainMapJPEG, .sdrJPEG]
        case .heic: [.adaptive, .pq, .hlg]
        case .avif: [.avifPq, .avifHlg]
        case .tiff: [.sdrTIFF]
        }
    }

    init(_ encoding: ExportEncoding) {
        switch encoding {
        case .isoGainMapJPEG, .sdrJPEG: self = .jpeg
        case .adaptive, .pq, .hlg: self = .heic
        case .avifPq, .avifHlg: self = .avif
        case .sdrTIFF: self = .tiff
        }
    }

    /// The container's own name, the same in every language.
    var name: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        }
    }

    /// What the container is good for, one or two words under the name.
    var caption: LocalizedStringKey {
        switch self {
        case .jpeg: "ios.export.family.jpeg"
        case .heic: "ios.export.family.heic"
        case .avif: "ios.export.family.avif"
        case .tiff: "ios.export.family.tiff"
        }
    }
}

extension ExportEncoding {
    /// The encoding within its container: "Gain map HDR", "PQ", "SDR".
    var variantName: Text {
        switch self {
        case .isoGainMapJPEG: Text("ios.export.variant.gainMap")
        case .adaptive: Text(LocalizedStringKey(labelKey))
        case .pq, .avifPq: Text(verbatim: "PQ")
        case .hlg, .avifHlg: Text(verbatim: "HLG")
        case .sdrJPEG, .sdrTIFF: Text("ios.export.variant.sdr")
        }
    }
}
