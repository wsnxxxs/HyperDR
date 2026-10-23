import Foundation
import CoreImage
import ImageIO
import Metal
import HyperDRRecipe

public enum RenderError: Error, Sendable {
    case metalUnavailable, allocationFailed, invalidSize, invalidRegion
    case cannotOpenSource, cannotDecodeSource, missingGainMap, unsupportedGainColorSpace
    case sourceChanged
    case unsupportedRAWDecoder(String)
    case gpu(String)
    case invalidAdjustment, invalidLUT(String), aiNotAvailable, duplicateHDRSplit
}

/// All textures and readback arrays use top-to-bottom rows, after source orientation.
public struct PixelSize: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct ISOGainChannel: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let gamma: Double
    public let baseOffset: Double
    public let alternateOffset: Double
}

/// Native auxiliary information is retained without rounding or reinterpreting ISO/Apple tags.
/// ISO metadata includes each channel's min/max/gamma and offsets, both headrooms,
/// and BaseColorIsWorkingColor. The full dictionary also retains the original pixel bytes.
public struct AuthoredGainMap: @unchecked Sendable {
    public enum Standard: String, Sendable { case iso, apple }
    public let standard: Standard
    public let auxiliaryInfo: NSDictionary
    public let image: CIImage
    public let channelCount: Int
    public let baseColorSpace: CGColorSpace
    public let alternateColorSpace: CGColorSpace?
    public let auxiliaryColorSpace: CGColorSpace?
    // Reverse ISO sources are normalized to an SDR base at the Render boundary.
    // Only the effective properties below change. tags, auxiliaryInfo and image
    // remain the original file metadata and encoded gain, without rewriting them.
    var hasCanonicalSDRBase = false
    /// ISO gain is applied in linear light in the gamut selected by the metadata.
    /// Legacy Apple maps may not expose that gamut separately; the native dictionary
    /// is authoritative and system HDR reconstruction handles that case.
    public var gainWorkingColorSpace: CGColorSpace? {
        if usesBaseColorSpace == true { return CGColorSpaceCreateExtendedLinearized(baseColorSpace) }
        return (alternateColorSpace ?? auxiliaryColorSpace).flatMap(CGColorSpaceCreateExtendedLinearized)
    }
    public var isoChannels: [ISOGainChannel]? {
        guard let channels = nativeISOChannels else { return nil }
        guard hasCanonicalSDRBase else { return channels }
        return channels.map {
            ISOGainChannel(minimum: $0.minimum, maximum: $0.maximum, gamma: $0.gamma,
                           baseOffset: $0.alternateOffset, alternateOffset: $0.alternateOffset)
        }
    }
    var nativeISOChannels: [ISOGainChannel]? {
        guard standard == .iso else { return nil }
        var result: [ISOGainChannel] = []
        for index in 0..<3 {
            let prefix = "HDRToneMap:ChannelMetadata[\(index)]."
            func value(_ name: String) -> Double? { tags[prefix + name].flatMap(Double.init) }
            guard let minimum = value("GainMapMin"), let maximum = value("GainMapMax"),
                  let gamma = value("Gamma"), let baseOffset = value("BaseOffset"),
                  let alternateOffset = value("AlternateOffset") else {
                return index == 1 && result.count == 1 ? result : nil
            }
            result.append(ISOGainChannel(minimum: minimum, maximum: maximum, gamma: gamma,
                                         baseOffset: baseOffset, alternateOffset: alternateOffset))
        }
        return result
    }
    public let tags: [String: String]

    /// ISO headrooms are in log2 stops. Native tags remain available for exact round trips.
    public var baseHeadroom: Double? {
        tags[hasCanonicalSDRBase ? "HDRToneMap:AlternateHeadroom" : "HDRToneMap:BaseHeadroom"].flatMap(Double.init)
    }
    public var alternateHeadroom: Double? {
        tags[hasCanonicalSDRBase ? "HDRToneMap:BaseHeadroom" : "HDRToneMap:AlternateHeadroom"].flatMap(Double.init)
    }
    var needsSDRBaseNormalization: Bool {
        guard !hasCanonicalSDRBase, standard == .iso,
              let baseHeadroom, let alternateHeadroom else { return false }
        return baseHeadroom > alternateHeadroom
    }
    public var usesBaseColorSpace: Bool? {
        tags["HDRToneMap:BaseColorIsWorkingColor"].map { $0 == "True" }
    }
}

/// An imported pair carries native ISO/Apple encoding and metadata verbatim. Newly
/// generated gains are single-channel log2 stops in linear P3 with zero offsets.
public enum GainEncoding: Sendable {
    case log2
    /// Independently edited SDR/HDR endpoints in linear P3. Equal offsets keep
    /// black channels representable and zero gain exactly neutral.
    case pairedLog2(offset: Float, headroom: Float)
    case authored(AuthoredGainMap)
    case isoLog2(ISOLogGainMetadata)
}

/// Edited author pairs carry decoded log2 gains, retaining the author's offsets
/// and gain working gamut. `source` keeps the complete original auxiliary metadata.
public struct ISOLogGainMetadata: @unchecked Sendable {
    public let source: AuthoredGainMap
    public let workingColorSpace: CGColorSpace
    public let baseOffset: SIMD3<Float>
    public let alternateOffset: SIMD3<Float>
}

public enum PairProvenance: String, Sendable {
    case identity, authored, editedAuthored, split, resplit
}

/// RGB base is RGBA32Float (alpha remains alpha). Gain is R32Float or RGBA32Float;
/// only RGB are gain channels in the latter. Gain never occupies the base's alpha.
/// For authored pairs, baseColorSpace is the native *linear* base space. For our
/// generated pairs it is extendedLinearDisplayP3. Apply ISO gain in its working
/// gamut before converting the reconstructed HDR to linear P3.
public struct RenderPlanes: @unchecked Sendable {
    public let base: any MTLTexture
    public let gain: any MTLTexture
    public let gainChannelCount: Int
    public let encoding: GainEncoding
    public let baseColorSpace: CGColorSpace
    public let provenance: PairProvenance
    public let region: CGRect
    /// Full output canvas for normalized gain sampling when `region` is an ROI.
    public let outputSize: PixelSize
    public let aiPending: Bool

    public init(base: any MTLTexture, gain: any MTLTexture, gainChannelCount: Int = 1,
                encoding: GainEncoding = .log2, baseColorSpace: CGColorSpace,
                provenance: PairProvenance, region: CGRect, outputSize: PixelSize? = nil, aiPending: Bool = false) {
        self.base = base
        self.gain = gain
        self.gainChannelCount = gainChannelCount
        self.encoding = encoding
        self.baseColorSpace = baseColorSpace
        self.provenance = provenance
        self.region = region
        self.outputSize = outputSize ?? PixelSize(width:base.width,height:base.height)
        self.aiPending = aiPending
    }
}

/// File revision bound to the materialized pixels and any later analysis decode.
struct SourceRevision: Hashable {
    let size: Int?
    let modified: Date?
    init(url: URL) throws {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        size = values.fileSize
        modified = values.contentModificationDate
    }
    func validate(_ url: URL) throws {
        guard try Self(url:url) == self else { throw RenderError.sourceChanged }
    }
}

/// Immutable source assets. Full, latest-preview and fixed-analysis variants are
/// retained for one asset/development family. Clients account for other retained sources.
public struct RenderSource: @unchecked Sendable {
    /// Stable across engines and preview/full: path + file revision + normalized
    /// development parameters, including whether the log look developed scene-linear.
    /// Decoded-only sources receive a fresh identity.
    public let id: UUID
    /// The photo's AI identity: the same development with Apple's boost left on.
    /// Log look does not change it, so one prediction serves both developments.
    public var modelSourceID: UUID {
        guard let origin else { return id }
        return sourceIdentity(url:origin.url,revision:origin.revision,options:origin.options,sceneLinear:false)
    }
    /// A decoded variant has its own GPU cache identity; source/model identity is shared.
    let renderID: UUID
    /// Reopen at the fixed analysis scale, including when shared with another engine.
    let origin: (url: URL, options: SourceOptions, revision: SourceRevision)?
    public let domain: InputDomain
    public let size: PixelSize
    /// Full size after the geometry (`SourceOptions.geometry`).
    public let nativeSize: PixelSize
    public let authoredGainMap: AuthoredGainMap?
    /// System HDR reconstruction, oriented, in CI coordinates (bottom-left).
    public let hdrImage: CIImage
    /// Author's base image, before working-space conversion, when a pair exists.
    public let authoredBaseImage: CIImage?
    public let rawSettings: RAWDevelopment?
    let texture: any MTLTexture
    let baseSpace: CGColorSpace
    let gainTexture: (any MTLTexture)?
    /// Internal ROI assets retain global source coordinates while owning only a tile.
    var samplingRegion = CGRect(x:0,y:0,width:1,height:1)
    var gainSamplingRegion = CGRect(x:0,y:0,width:1,height:1)
    /// The full size before a geometry, when one is applied.
    var geometryUncroppedSize: PixelSize? = nil
    /// Full size before the geometry: the photo as the file holds it, oriented.
    public var uncroppedSize: PixelSize { geometryUncroppedSize ?? nativeSize }
}

extension RenderSource {
    /// RAW stays native through CIRAWFilter; only the final area-downsample size
    /// changes with a preview bound. Reuse pixels when a different bound rounds
    /// to the exact same raster (e.g. first square bound vs fitted canvas).
    public func reusesRAWPreview(options: SourceOptions) -> Bool {
        guard domain == .rawEDR, let origin, let rawSettings,
              samplingRegion == CGRect(x: 0, y: 0, width: 1, height: 1),
              case .preview(let bound) = options.resolution,
              bound.width > 0, bound.height > 0 else { return false }
        var development = options
        development.resolution = origin.options.resolution
        guard development == origin.options else { return false }
        let native = rawSettings.nativeSize, developed = rawSettings.developedExtent
        let scale = min(1, Double(bound.width) / Double(native.width), Double(bound.height) / Double(native.height))
        let expected = PixelSize(width: max(1, Int((Double(developed.width) * scale).rounded())),
                                 height: max(1, Int((Double(developed.height) * scale).rounded())))
        return expected == size
    }
}

public struct RAWDevelopment: Sendable {
    public let boost: Float
    public let boostShadow: Float
    public let baselineExposure: Float
    public let localToneMap: Float
    public let extendedDynamicRange: Float
    public let lensCorrectionSupported: Bool
    public let lensCorrectionApplied: Bool
    public let decoderVersion: String
    public let temperature: Float
    public let tint: Float
    public let luminanceNR: Float
    public let colorNR: Float
    public let sharpness: Float
    public let supportsLuminanceNR: Bool
    public let supportsColorNR: Bool
    public let supportsSharpness: Bool
    /// Oriented native dimensions, independent of preview development scale.
    public let nativeSize: PixelSize
    /// Native output extent after orientation/cropping, before preview downsampling.
    public let developedExtent: CGSize
    /// Output scale relative to native pixels, after bounded RAW development.
    public private(set) var scaleFactor: Float
    func atPreviewScale(_ scale: Float) -> Self {
        var copy = self
        copy.scaleFactor = scale
        return copy
    }
    public let isDraft: Bool
    /// Camera white balance / Apple detail defaults, in Recipe units (K, tint,
    /// 0...100 percent). Captured before applying any RAW overrides.
    public let sourceValues: [String:Double]
    public var capabilities: Set<String> {
        var values: Set<String> = []
        for (supported,name) in [(supportsLuminanceNR,"CIRAWFilter.isLuminanceNoiseReductionSupported"),
            (supportsColorNR,"CIRAWFilter.isColorNoiseReductionSupported"),
            (supportsSharpness,"CIRAWFilter.isSharpnessSupported"),
            (lensCorrectionSupported,"CIRAWFilter.isLensCorrectionSupported")] {
            if supported { values.insert(name) }
        }
        return values
    }
}

/// Preview develops only the pixels needed by the canvas, retaining Apple detail
/// quality. Full development is the default for export; both modes keep G2 semantics.
public enum SourceResolution: Hashable, Sendable {
    case full
    case preview(maximumSize: PixelSize)

    /// A shared canvas tier for RAW and ImageIO sources. Never upscales the source.
    public static func preview(canvasSize: PixelSize, nativeSize: PixelSize) throws -> SourceResolution {
        guard canvasSize.width > 0, canvasSize.height > 0, nativeSize.width > 0, nativeSize.height > 0 else {
            throw RenderError.invalidSize
        }
        let edge = [1280, 2048, 2560, 3840].first { $0 >= max(canvasSize.width, canvasSize.height) } ?? 3840
        let scale = min(1, Double(edge)/Double(max(nativeSize.width,nativeSize.height)))
        return .preview(maximumSize: PixelSize(width: max(1,Int((Double(nativeSize.width)*scale).rounded())),
                                               height: max(1,Int((Double(nativeSize.height)*scale).rounded()))))
    }
}

/// Retained for callers of the original RAW preview API; the policy now covers all sources.
public typealias RAWResolution = SourceResolution

/// RAW graph setup can load a system model; developing begins at pixel materialization.
public enum SourceLoadPhase: Sendable { case loadingDecoder, developing, preparingAnalysis }

public struct SourceOptions: Hashable, Sendable {
    public static let parameters = Adjustments.all.filter { $0.cost == .redevelop }
    public enum Kind: String, Sendable { case automatic, imageIO, raw }
    /// Nil leaves CIRAWFilter on its legacy system default. Recorded versions must be supported.
    public var rawDecoderVersion: String? = nil
    public var kind: Kind
    public var lensCorrection: Bool
    public var raw = RAWAdjustments()
    public var resolution: SourceResolution
    /// Develop RAW without Apple's tone curve. Set when a log look is in effect,
    /// so the curve sees scene-linear reflectance. Part of the cache key: preview
    /// and export reopen the source when it changes.
    public var sceneLinear: Bool
    /// The crop pane's geometry, applied where the source opens; part of the
    /// cache key, so preview and export reopen when it changes.
    public var geometry: Geometry = .identity
    public var rawResolution: RAWResolution {
        get { resolution }
        set { resolution = newValue }
    }
    public init(kind: Kind = .automatic, lensCorrection: Bool? = nil, raw: RAWAdjustments = RAWAdjustments(), rawResolution: RAWResolution? = nil, resolution: SourceResolution = .full, sceneLinear: Bool = false) {
        self.kind = kind
        self.lensCorrection = lensCorrection ?? RenderParameter.defaultBool("develop.lensCorrection")
        self.raw = raw
        self.resolution = rawResolution ?? resolution
        self.sceneLinear = sceneLinear
    }
}

public struct RenderedTexture: @unchecked Sendable {
    public let texture: any MTLTexture
    public let colorSpace: CGColorSpace
}

public struct PlanePixels: Sendable {
    public let size: PixelSize
    public let baseRGBA: [Float]
    public let gainSize: PixelSize
    /// Tightly packed, one or three float channels per pixel; encoding matches RenderPlanes.
    public let gain: [Float]
    public let gainChannelCount: Int
}
