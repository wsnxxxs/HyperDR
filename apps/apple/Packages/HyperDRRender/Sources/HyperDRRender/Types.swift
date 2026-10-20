import Foundation
import CoreImage
import ImageIO
import Metal
import HyperDRRecipe

public enum RenderError: Error, Sendable {
    case metalUnavailable, allocationFailed, invalidSize, invalidRegion
    case cannotOpenSource, cannotDecodeSource, missingGainMap, unsupportedGainColorSpace
    case gpu(String)
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
    /// ISO gain is applied in linear light in the gamut selected by the metadata.
    /// Legacy Apple maps may not expose that gamut separately; the native dictionary
    /// is authoritative and system HDR reconstruction handles that case.
    public var gainWorkingColorSpace: CGColorSpace? {
        if usesBaseColorSpace == true { return CGColorSpaceCreateExtendedLinearized(baseColorSpace) }
        return (alternateColorSpace ?? auxiliaryColorSpace).flatMap(CGColorSpaceCreateExtendedLinearized)
    }
    public var isoChannels: [ISOGainChannel]? {
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
    public var baseHeadroom: Double? { tags["HDRToneMap:BaseHeadroom"].flatMap(Double.init) }
    public var alternateHeadroom: Double? { tags["HDRToneMap:AlternateHeadroom"].flatMap(Double.init) }
    public var usesBaseColorSpace: Bool? {
        tags["HDRToneMap:BaseColorIsWorkingColor"].map { $0 == "True" }
    }
}

/// An imported pair carries native ISO/Apple encoding and metadata verbatim. Newly
/// generated gains are single-channel log2 stops in linear P3 with zero offsets.
public enum GainEncoding: Sendable {
    case log2
    case authored(AuthoredGainMap)
}

public enum PairProvenance: String, Sendable {
    case identity, authored, split, resplit
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

    public init(base: any MTLTexture, gain: any MTLTexture, gainChannelCount: Int = 1,
                encoding: GainEncoding = .log2, baseColorSpace: CGColorSpace,
                provenance: PairProvenance, region: CGRect) {
        self.base = base
        self.gain = gain
        self.gainChannelCount = gainChannelCount
        self.encoding = encoding
        self.baseColorSpace = baseColorSpace
        self.provenance = provenance
        self.region = region
    }
}

/// Immutable source assets. The renderer retains one decoded source at a time;
/// clients may keep additional sources and must account for their texture memory.
public struct RenderSource: @unchecked Sendable {
    public let id: UUID
    public let domain: InputDomain
    public let size: PixelSize
    public let authoredGainMap: AuthoredGainMap?
    /// System HDR reconstruction, oriented, in CI coordinates (bottom-left).
    public let hdrImage: CIImage
    /// Author's base image, before working-space conversion, when a pair exists.
    public let authoredBaseImage: CIImage?
    public let rawSettings: RAWDevelopment?
    let texture: any MTLTexture
    let baseSpace: CGColorSpace
    let gainTexture: (any MTLTexture)?
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
}

public struct SourceOptions: Hashable, Sendable {
    public static let parameters = [ParameterDeclaration(id: "raw.lensCorrection", kind: .boolean,
        range: 0...1, defaultValue: 1, domains: [.rawEDR])]
    public enum Kind: String, Sendable { case automatic, imageIO, raw }
    public var kind: Kind
    public var lensCorrection: Bool
    public init(kind: Kind = .automatic, lensCorrection: Bool = true) {
        self.kind = kind
        self.lensCorrection = lensCorrection
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
