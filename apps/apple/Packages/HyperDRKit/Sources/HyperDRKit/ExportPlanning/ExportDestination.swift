import Foundation

/// The three destinations of the export panel (p7-adjustments §4.2).
public enum ExportDestination: String, Sendable, Hashable, Codable, CaseIterable {
    case photos
    case web
    case social

    /// `dest.<id>` / `.hint` in `Localizable.xcstrings`.
    public var labelKey: String { "dest.\(rawValue)" }
    public var hintKey: String { "dest.\(rawValue).hint" }

    public var profile: DestinationProfile {
        switch self {
        case .photos: .photos
        case .web: .web
        case .social: .social
        }
    }
}

/// Where the file goes once it is written; the panel's main button follows it.
public enum DestinationHandling: String, Sendable, Hashable, Codable {
    /// Back into the photo library, by replacing the original or as a new photo.
    case photoLibrary
    /// A file the user places: the Mac save panel, iOS "Save to Files".
    case file
    /// The system share sheet, which hands the file to another app.
    case share
}

/// One column of p7-adjustments §4.2. The panel's read-only "Will write" row
/// and the destination cards read this table, so neither can drift from it.
public struct DestinationProfile: Sendable, Hashable {
    public static let currentVersion = 1
    public var version: Int { Self.currentVersion }
    public let destination: ExportDestination
    /// Written when the photo has HDR (the HDR group is on).
    public let encoding: ExportEncoding
    /// Written when the HDR group is off: the SDR version only.
    public let sdrEncoding: ExportEncoding
    /// The most stops this destination carries: brighter highlights are brought
    /// down to it at export time; the edit keeps its own range.
    public let ceilingStops: Double
    public let gamut: ExportColorGamut
    public let sdrGamut: ExportColorGamut
    /// Longest side in pixels; nil keeps the original size. Never upscales.
    public let longEdge: Int?
    public let quality: Int
    /// The photos destination keeps everything, including where the photo was
    /// taken; the two publishing destinations drop the location.
    public let keepLocation: Bool
    public let handling: DestinationHandling

    /// p7-adjustments §4.2. Values marked 🔬 there are this table's constants
    /// until writer-lab and the device measurements settle them; a test pins
    /// the ones the design shows.
    public static let photos = DestinationProfile(
        destination: .photos,
        encoding: .adaptive, sdrEncoding: .adaptive,
        ceilingStops: 3, // 🔬 "Photos" display above 3 stops
        gamut: .p3, sdrGamut: .p3,
        longEdge: nil,
        quality: 90, // the HEVC quality P3a-2 settles 🔬
        keepLocation: true,
        handling: .photoLibrary)

    public static let web = DestinationProfile(
        destination: .web,
        encoding: .isoGainMapJPEG, sdrEncoding: .sdrJPEG,
        ceilingStops: 3, // 🔬 8-bit gain at 3 stops
        gamut: .p3, sdrGamut: .p3, // embedded ICC 🔬
        longEdge: 2560, // twice a typical text column
        quality: 90,
        keepLocation: false,
        handling: .file)

    public static let social = DestinationProfile(
        destination: .social,
        encoding: .isoGainMapJPEG, sdrEncoding: .sdrJPEG,
        ceilingStops: 2, // 🔬 platforms compress HDR further
        gamut: .p3, sdrGamut: .srgb, // 🔬 the platform may treat P3 as sRGB
        longEdge: 2160, // 🔬 1728 × 2160 for 4:5
        quality: 92,
        keepLocation: false,
        handling: .share)
}

/// An oriented pixel size, in the direction the file is written.
public struct ExportPixelSize: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    /// A stored size is re-validated: a decoded zero would divide by zero in
    /// `fitted`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try container.decode(Int.self, forKey: .width),
                  height: try container.decode(Int.self, forKey: .height))
    }

    public var longEdge: Int { max(width, height) }
    public var pixels: Int { width * height }

    /// The size written under a long-edge limit: never upscales, keeps the
    /// aspect ratio, and lands exactly on the limit when one is given.
    public func fitted(longEdge limit: Int?) -> ExportPixelSize {
        guard let limit, limit > 0, longEdge > limit else { return self }
        let scale = Double(limit) / Double(longEdge)
        let short = max(1, Int((Double(min(width, height)) * scale).rounded()))
        return width >= height
            ? ExportPixelSize(width: limit, height: short)
            : ExportPixelSize(width: short, height: limit)
    }
}

/// A composited frame's canvas. A frame is laid out around a photo size, and
/// every mat is rounded to an even count, so the canvas cannot be scaled from
/// the photo's own: the caller lays it out for the photo's written size
/// (`ExportPlanner.photoSize(for:photo:)`) and the plan writes that canvas as
/// it is.
public struct ExportFrameFacts: Sendable, Hashable {
    /// The frame's canvas, laid out for the photo already limited to the
    /// destination's long edge; nil when the photo is written unframed, in which
    /// case the canvas is the photo's own written size.
    public let canvas: ExportPixelSize?

    public init(canvas: ExportPixelSize? = nil) {
        self.canvas = canvas
    }

    public var isFramed: Bool { canvas != nil }
}
