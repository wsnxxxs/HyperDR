import Foundation

/// One of the eight encodings the custom-format page keeps (M3 §3.2). The raw
/// value is the panel's encoding id, which is also the engine request's.
public enum ExportEncoding: String, Sendable, Hashable, Codable, CaseIterable {
    case adaptive
    case isoGainMapJPEG = "iso-gainmap-jpeg"
    case pq
    case hlg
    case avifPq = "avif-pq"
    case avifHlg = "avif-hlg"
    case sdrJPEG = "sdr-jpeg"
    case sdrTIFF = "sdr-tiff"

    /// `enc.<id>.label` / `.hint` in `Localizable.xcstrings`.
    public var labelKey: String { "enc.\(rawValue).label" }
    public var hintKey: String { "enc.\(rawValue).hint" }

    /// Formats whose output is an SDR base plus an ISO 21496-1 gain map.
    public var writesGainMap: Bool { self == .adaptive || self == .isoGainMapJPEG }

    /// SDR-only formats: what is written is the SDR version, with no gain map.
    public var isSDR: Bool { self == .sdrJPEG || self == .sdrTIFF }

    /// BT.2100 formats: Rec. 2020 primaries with the PQ or HLG transfer.
    public var isBT2100: Bool {
        switch self {
        case .pq, .hlg, .avifPq, .avifHlg: true
        case .adaptive, .isoGainMapJPEG, .sdrJPEG, .sdrTIFF: false
        }
    }

    /// The most stops of HDR this format carries (batch4 §2.2). A destination
    /// may narrow it further; the edit itself is never changed by a format.
    /// `EditDefaults.maxRange(for:)` answers the same question for the engine,
    /// and a test pins the two tables together.
    public var ceilingStops: Double {
        switch self {
        case .adaptive: 3
        case .isoGainMapJPEG, .pq, .avifPq, .sdrJPEG, .sdrTIFF: 4
        case .hlg, .avifHlg: 2.3
        }
    }
}

/// The output colour space. The raw values are the engine's `colorGamut` ids.
public enum ExportColorGamut: String, Sendable, Hashable, Codable, CaseIterable {
    case srgb
    case p3
    case rec2020

    /// `choice.colorGamut.<id>` in `Localizable.xcstrings`, the labels the
    /// inspector already uses ("sRGB", "Display P3", "Rec. 2020").
    public var labelKey: String { "choice.colorGamut.\(rawValue)" }
}

/// Who writes the file. The planning layer never calls a writer; it names one.
public enum ExportWriter: String, Sendable, Hashable, Codable {
    /// Our own container and codec code: the `hyperdr_package` C ABI entry
    /// (ISO gain-map JPEG and HEIC assembly, VideoToolbox, libavif for AVIF).
    case inHouse
    /// ImageIO: `CGImageDestination`, with a gain map we computed supplied as
    /// auxiliary data (writer-lab's B path).
    case imageIO
    /// libavif, used only for AVIF.
    case libavif

    /// Whether a photo's own three-channel gain map can be written as it is.
    /// Our writers carry one or three channels (ISO 21496-1); writer-lab only
    /// measured the one-channel ImageIO auxiliary-data path, so a three-channel
    /// authored pair is re-separated there until P7-3b measures otherwise.
    public var carriesThreeChannelGain: Bool { self == .inHouse }

    /// Whether this writer can encode a canvas piece by piece. gpu-pipeline §2
    /// gives `hyperdr_package` streamed, tiled writes; ImageIO cannot, and AVIF
    /// only ever splits into a grid of independent cells. The pre-P7 engine does
    /// not stream, so P7-3b may offer the strip degradation only for that entry.
    public var streamsInStrips: Bool { self == .inHouse }
}

/// Why the plan chose that writer, in the words of gpu-pipeline §11.x.
public enum ExportWriterReason: String, Sendable, Hashable, Codable {
    /// writer-lab: higher PSNR at equal file size (ISO gain-map JPEG).
    case qualityAtEqualSize
    /// writer-lab: ImageIO's quality edge is negligible or equal, and our peak
    /// is a fraction of it (10-bit HEIC pairs, PQ HEIC, HLG HEIC).
    case peakMemory
    /// libavif is the only AVIF encoder we have; ImageIO writes 8-bit SDR only.
    case onlyEncoder
    /// writer-lab did not compare this path (SDR JPEG / TIFF, and the 8-bit SDR
    /// HEIC that carries no gain map), so the writer that owns the format is used.
    case noComparison
    /// The preferred writer would not fit in memory; this one does.
    case memoryFallback
}

/// The custom-format page: what the eight encoding cards plus the gamut and
/// quality controls say. A destination carries these into the page when the
/// user chooses "Custom format…" (p7-adjustments §4.1).
public struct CustomExportFormat: Sendable, Hashable, Codable {
    public var encoding: ExportEncoding
    public var gamut: ExportColorGamut
    /// 0...100; TIFF ignores it.
    public var quality: Int

    public init(encoding: ExportEncoding, gamut: ExportColorGamut, quality: Int) {
        self.encoding = encoding
        self.gamut = gamut
        self.quality = quality
    }
}

/// The panel's two pages: a destination, or a hand-picked format.
public enum ExportChoice: Sendable, Hashable, Codable {
    case destination(ExportDestination)
    case custom(CustomExportFormat)

    public var destination: ExportDestination? {
        if case .destination(let destination) = self { return destination }
        return nil
    }

    public var customFormat: CustomExportFormat? {
        if case .custom(let format) = self { return format }
        return nil
    }
}
