import Foundation

/// One of the encodings the custom-format page keeps (M3 §3.2). The raw
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
    /// The lossless group: the SDR version as a 16-bit linear DNG, and the HDR
    /// version itself, linear with SDR white at 1.0, as a half or single float
    /// TIFF or a 16-bit linear DNG.
    case sdrDNG = "sdr-dng"
    case hdrTIFF16 = "hdr-tiff-16"
    case hdrTIFF32 = "hdr-tiff-32"
    case hdrDNG = "hdr-dng"

    /// `enc.<id>.label` / `.hint` in `Localizable.xcstrings`.
    public var labelKey: String { "enc.\(rawValue).label" }
    public var hintKey: String { "enc.\(rawValue).hint" }

    /// Formats whose output is an SDR base plus an ISO 21496-1 gain map.
    public var writesGainMap: Bool { self == .adaptive || self == .isoGainMapJPEG }

    /// SDR-only formats: what is written is the SDR version, with no gain map.
    public var isSDR: Bool { self == .sdrJPEG || self == .sdrTIFF || self == .sdrDNG }

    /// BT.2100 formats: Rec. 2020 primaries with the PQ or HLG transfer.
    public var isBT2100: Bool {
        switch self {
        case .pq, .hlg, .avifPq, .avifHlg: true
        default: false
        }
    }

    /// The HDR version written as linear samples, with no gain map or transfer curve.
    public var isLinearHDR: Bool { self == .hdrTIFF16 || self == .hdrTIFF32 || self == .hdrDNG }

    /// TIFF and DNG: no lossy coding, so no quality setting.
    public var isLossless: Bool { self == .sdrTIFF || self == .sdrDNG || isLinearHDR }

    public var isDNG: Bool { self == .sdrDNG || self == .hdrDNG }

    /// Whether the render hands this format a gain plane: to store, to
    /// reconstruct a BT.2100 rendition from, or to write the HDR version from.
    public var needsGainPlane: Bool { writesGainMap || isBT2100 || isLinearHDR }

    /// What a format becomes when the HDR group is off: the same file, SDR.
    /// The BT.2100 formats have no SDR form and are refused instead.
    public var sdrCounterpart: ExportEncoding {
        switch self {
        case .isoGainMapJPEG: .sdrJPEG
        case .hdrTIFF16, .hdrTIFF32: .sdrTIFF
        case .hdrDNG: .sdrDNG
        default: self
        }
    }

    /// The HDR form of a lossless file, at a TIFF depth of 16 or 32 bits (a
    /// DNG is always 16-bit integer).
    public func hdrCounterpart(tiffDepth: Int) -> ExportEncoding {
        switch self {
        case .sdrTIFF, .hdrTIFF16, .hdrTIFF32: tiffDepth == 32 ? .hdrTIFF32 : .hdrTIFF16
        case .sdrDNG, .hdrDNG: .hdrDNG
        default: self
        }
    }

    /// Bits per channel of a lossless file; nil for the coded formats.
    public var losslessBitDepth: Int? {
        switch self {
        case .sdrTIFF, .sdrDNG, .hdrTIFF16, .hdrDNG: 16
        case .hdrTIFF32: 32
        default: nil
        }
    }

    /// The colour spaces the page offers: the SDR formats sRGB or Display P3;
    /// the HDR TIFF and both DNGs Display P3 or Rec. 2020, since a linear file
    /// keeps whatever the wider space holds. The others fix their own.
    public var gamutChoices: [ExportColorGamut] {
        switch self {
        case .sdrJPEG, .sdrTIFF: [.srgb, .p3]
        case .sdrDNG, .hdrTIFF16, .hdrTIFF32, .hdrDNG: [.p3, .rec2020]
        default: []
        }
    }

    /// The most stops of HDR this format carries (batch4 §2.2). A destination
    /// may narrow it further; the edit itself is never changed by a format.
    /// A float TIFF holds any range; the 16-bit DNG gives each stop above
    /// white a bit of its shadow precision, so it stops at 6.
    public var ceilingStops: Double {
        switch self {
        case .adaptive: 3
        case .isoGainMapJPEG, .pq, .avifPq, .sdrJPEG, .sdrTIFF, .sdrDNG: 4
        case .hlg, .avifHlg: 2.3
        case .hdrTIFF16, .hdrTIFF32: 8
        case .hdrDNG: 6
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

    /// Native row-input writers. AVIF stages quantized rows on disk and encodes
    /// one small cell at a time; ImageIO's auxiliary API still needs whole planes.
    public func supportsRowInput(encoding: ExportEncoding) -> Bool {
        self == .inHouse || (self == .libavif && encoding.isAVIF)
    }

    /// Package/ImageIO capabilities for this exact output combination.
    public func capabilities(encoding: ExportEncoding, bitDepth: Int,
                             gainChannels: Int, workingGamut: String = "display-p3",
                             baseHeadroom: Double = 0) -> ExportWriterCapabilities {
        let depth = encoding == .adaptive ? [8, 10].contains(bitDepth)
            : encoding.losslessBitDepth.map { bitDepth == $0 }
            ?? (encoding.isBT2100 ? bitDepth == 10 : bitDepth == 8)
        let writerMatches = self == .inHouse || (self == .libavif && encoding.isAVIF)
            || (self == .imageIO && encoding == .adaptive && bitDepth == 8)
        let manualISO = self == .imageIO && encoding == .adaptive && bitDepth == 8
        let rgb = manualISO || (encoding != .adaptive && self != .imageIO)
        let supported = depth && writerMatches && workingGamut == "display-p3"
            && (gainChannels == 0 || encoding != .adaptive || baseHeadroom == 0)
            && [0, 1, 3].contains(gainChannels) && (gainChannels != 3 || rgb)
        return .init(supported: supported, supportsThreeChannelGain: rgb,
                     supportsSignedGain: manualISO || encoding != .adaptive,
                     requiresGainMaximumHeadroom: encoding == .adaptive && !manualISO)
    }

}

/// Why the plan chose that writer, in the words of gpu-pipeline §11.x.
public enum ExportWriterReason: String, Sendable, Hashable, Codable {
    /// writer-lab: higher PSNR at equal file size (ISO JPEG and 8-bit HEIC).
    case qualityAtEqualSize
    /// writer-lab: ImageIO's quality edge is negligible or equal, and our peak
    /// is a fraction of it (10-bit HEIC pairs, PQ HEIC, HLG HEIC).
    case peakMemory
    /// libavif is the only AVIF writer used by this export service.
    case onlyEncoder
    /// writer-lab did not compare this path (SDR JPEG, TIFF and DNG, and the
    /// 8-bit SDR HEIC that carries no gain map), so the writer that owns the
    /// format is used.
    case noComparison
    /// The preferred writer would not fit in memory; this one does.
    case memoryFallback
    /// The preferred writer cannot represent the supplied gain pair.
    case unsupportedCapability
    /// ImageIO has no verified E5 protection for the mat after lossy coding.
    case frameGainProtection
}

/// The custom-format page: what the encoding cards plus the gamut and
/// quality controls say. A destination carries these into the page when the
/// user chooses "Custom format…" (p7-adjustments §4.1).
public struct CustomExportFormat: Sendable, Hashable, Codable {
    public var encoding: ExportEncoding
    public var gamut: ExportColorGamut
    /// 0...100; TIFF and DNG ignore it.
    public var quality: Int

    /// nil keeps the original dimensions; a positive limit never upscales.
    public var longEdge: Int?

    public init(encoding: ExportEncoding = .adaptive, gamut: ExportColorGamut = .p3, quality: Int = 90, longEdge: Int? = nil) {
        self.encoding = encoding
        self.gamut = gamut
        self.quality = quality
        self.longEdge = longEdge
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

public struct ExportWriterCapabilities: Sendable, Hashable {
    public let supported: Bool
    public let supportsThreeChannelGain: Bool
    public let supportsSignedGain: Bool
    public let requiresGainMaximumHeadroom: Bool
}
