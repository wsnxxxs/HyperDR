import CoreGraphics
import CoreVideo
import Foundation
import HyperDREngine
import HyperDRRender
import ImageIO
import UniformTypeIdentifiers

/// Parameters of our explicitly quantized auxiliary plane, in ISO log2 stops.
public struct ImageIOGainWriteReport: Sendable, Codable {
    public let channels, width, height: Int
    public let gainMin, gainMax, gamma: Float
    public let baseOffset, alternateOffset: SIMD3<Float>
    public let baseHeadroom, alternateHeadroom: Float
}

/// Manual ISO auxiliary data only: ImageIO never derives the base or gain.
enum ImageIOHEICWriter {
    static func write(base: PackagePlane, gain: PackagePlane, metadata: ExportGainMetadata,
                      to url: URL, quality: Int) throws -> ImageIOGainWriteReport {
        try Task.checkCancellation()
        guard metadata.baseHeadroom == 0 else {
            throw HyperDRError(code: "unsupported_format",
                message: "ImageIO HEIC8 requires an SDR base with zero base headroom")
        }
        return try autoreleasepool {
            guard base.width > 0, base.height > 0, base.channels == 3,
                  gain.width == base.width, gain.height == base.height,
                  [1, 3].contains(gain.channels), gain.channels == metadata.channelCount,
                  base.samples.count == base.width * base.height * 3,
                  gain.samples.count == gain.width * gain.height * gain.channels,
                  (0...100).contains(quality) else { throw RecipeExportError.invalidStripes }
            var low: Float = 0, high: Float = 0
            for (i, value) in gain.samples.enumerated() {
                if i % (gain.width * gain.channels) == 0 { try Task.checkCancellation() }
                guard value.isFinite else { throw RecipeExportError.invalidStripes }
                low = min(low, value); high = max(high, value)
            }
            // Gamma 1 gives a direct, documented log2 codebook; one set of
            // endpoints applies to all channels. Never clip signed author gain.
            let range = high - low
            var codes = Data(count: gain.samples.count)
            try codes.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for i in gain.samples.indices {
                    if i % (gain.width * gain.channels) == 0 { try Task.checkCancellation() }
                    let value = range > 0 ? (gain.samples[i] - low) / range : 0
                    bytes[i] = UInt8(min(255, max(0, Int((value * 255).rounded()))))
                }
            }
            var pixels = Data(count: base.width * base.height * 4)
            try pixels.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in 0..<base.height {
                    try Task.checkCancellation()
                    for x in 0..<base.width {
                        let i = y * base.width + x
                        for c in 0..<3 {
                            let v = base.samples[i*3+c]
                            guard v.isFinite else { throw RecipeExportError.invalidStripes }
                            let linear = min(1, max(0, v))
                            let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * powf(linear, 1/2.4) - 0.055
                            bytes[i*4+c] = UInt8(min(255, max(0, Int((encoded * 255).rounded()))))
                        }
                        bytes[i*4+3] = 255
                    }
                }
            }
            let report = ImageIOGainWriteReport(channels: gain.channels, width: gain.width, height: gain.height,
                gainMin: low, gainMax: high, gamma: 1, baseOffset: metadata.baseOffset,
                alternateOffset: metadata.alternateOffset, baseHeadroom: metadata.baseHeadroom,
                alternateHeadroom: metadata.alternateHeadroom)
            guard metadata.baseHeadroom.isFinite, metadata.alternateHeadroom.isFinite,
                  metadata.baseHeadroom >= 0, metadata.alternateHeadroom >= metadata.baseHeadroom,
                  (0..<gain.channels).allSatisfy({ metadata.baseOffset[$0].isFinite && metadata.alternateOffset[$0].isFinite }),
                  let space = CGColorSpace(name: CGColorSpace.displayP3),
                  let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: base.width, height: base.height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: base.width * 4, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let labeled = CGImageCreateCopyWithContentHeadroom(exp2f(metadata.baseHeadroom), image),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                throw RecipeExportError.verificationFailed("imageio_heic_pixels")
            }
            CGImageDestinationAddImage(destination, labeled, [kCGImageDestinationLossyCompressionQuality: Double(quality)/100,
                                                              kCGImagePropertyOrientation: 1] as CFDictionary)
            let auxiliary: [CFString: Any] = [
                kCGImageAuxiliaryDataInfoData: codes,
                kCGImageAuxiliaryDataInfoDataDescription: ["Width": gain.width, "Height": gain.height,
                    "BytesPerRow": gain.width * gain.channels,
                    "PixelFormat": gain.channels == 1 ? kCVPixelFormatType_OneComponent8 : kCVPixelFormatType_24RGB],
                kCGImageAuxiliaryDataInfoMetadata: try gainMetadata(report)]
            CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, auxiliary as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw RecipeExportError.verificationFailed("imageio_heic_finalize") }
            try Task.checkCancellation()
            return report
        }
    }

    private static func gainMetadata(_ gain: ImageIOGainWriteReport) throws -> CGImageMetadata {
        var channels = ""
        for c in 0..<gain.channels {
            let fields: [(String, Float)] = [("GainMapMin", gain.gainMin), ("GainMapMax", gain.gainMax),
                ("Gamma", gain.gamma), ("BaseOffset", gain.baseOffset[c]), ("AlternateOffset", gain.alternateOffset[c])]
            channels += "<rdf:li rdf:parseType=\"Resource\">" + fields.map {
                "<HDRToneMap:\($0.0)>\($0.1)</HDRToneMap:\($0.0)>"
            }.joined() + "</rdf:li>"
        }
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:HDRToneMap="http://ns.apple.com/HDRToneMap/1.0/">
        <HDRToneMap:Version>1</HDRToneMap:Version><HDRToneMap:BaseColorIsWorkingColor>True</HDRToneMap:BaseColorIsWorkingColor>
        <HDRToneMap:BaseHeadroom>\(gain.baseHeadroom)</HDRToneMap:BaseHeadroom>
        <HDRToneMap:AlternateHeadroom>\(gain.alternateHeadroom)</HDRToneMap:AlternateHeadroom>
        <HDRToneMap:ChannelMetadata><rdf:Seq>\(channels)</rdf:Seq></HDRToneMap:ChannelMetadata>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        guard let metadata = CGImageMetadataCreateFromXMPData(Data(xml.utf8) as CFData) else {
            throw RecipeExportError.verificationFailed("imageio_gain_metadata")
        }
        return metadata
    }

    /// Metadata check belongs to the second (system) reader, after native probe.
    static func verify(_ url: URL, expected: ImageIOGainWriteReport) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any],
              let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any],
              description["Width"] as? Int == expected.width, description["Height"] as? Int == expected.height,
              let metadata = info[kCGImageAuxiliaryDataInfoMetadata] else {
            throw RecipeExportError.verificationFailed("imageio_gain_metadata_readback")
        }
        let tags = metadata as! CGImageMetadata
        func field(_ path: String, _ value: Float) throws {
            guard let stored = CGImageMetadataCopyStringValueWithPath(tags, nil, path as CFString),
                  let number = Float(stored as String),
                  // ImageIO's XMP string view can round to six significant digits.
                  abs(number - value) <= max(0.00002, abs(value) * 0.000002) else {
                throw RecipeExportError.verificationFailed("imageio_gain_metadata_" + path)
            }
        }
        try field("HDRToneMap:BaseHeadroom", expected.baseHeadroom)
        try field("HDRToneMap:AlternateHeadroom", expected.alternateHeadroom)
        for c in 0..<expected.channels {
            let prefix = "HDRToneMap:ChannelMetadata[\(c)]."
            try field(prefix + "GainMapMin", expected.gainMin); try field(prefix + "GainMapMax", expected.gainMax)
            try field(prefix + "Gamma", expected.gamma); try field(prefix + "BaseOffset", expected.baseOffset[c])
            try field(prefix + "AlternateOffset", expected.alternateOffset[c])
        }
    }
}
