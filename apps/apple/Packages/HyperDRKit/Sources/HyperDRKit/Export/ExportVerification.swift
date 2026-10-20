import CoreImage
import Foundation
import HyperDREngine
import HyperDRRender
import ImageIO
import UniformTypeIdentifiers

public struct SystemExportVerification: Sendable, Codable, Equatable {
    public let width, height, bitDepth: Int
    public let orientation: Int
    public let auxiliaryGain: Bool
    public let hdrReadable: Bool
    public let verifiedHeadroomStops: [Double]
    public let profileName: String?
}

/// Called only after package's own reader has completed and released its decode.
/// System readback stays small; never retain two full-size decoded renditions.
enum ExportVerification {
    static func system(_ url: URL, plan: ExportPlan, gainMetadata: ExportGainMetadata? = nil) throws -> SystemExportVerification {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width == plan.size.width, height == plan.size.height,
                  (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] as CFDictionary) != nil else {
                throw RecipeExportError.verificationFailed("imageio_readback")
            }
            let depth = props[kCGImagePropertyDepth] as? Int ?? 0
            guard depth == plan.baseBitDepth else {
                throw RecipeExportError.verificationFailed("imageio_bit_depth")
            }
            let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
                ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
            let gain = CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true, .applyOrientationProperty: false])
            if plan.gainMap.writesGainMap && auxiliary == nil && gain == nil {
                throw RecipeExportError.verificationFailed("imageio_missing_gain")
            }
            if !plan.gainMap.writesGainMap && !plan.encoding.isBT2100 && auxiliary != nil {
                throw RecipeExportError.verificationFailed("unexpected_gain")
            }
            let hdr = plan.peakStops != nil
            var headrooms: [Double] = []
            if hdr {
                let images: [CIImage]
                if plan.gainMap.writesGainMap {
                    guard let gain,
                          let base = CIImage(contentsOf: url, options: [.expandToHDR: false, .applyOrientationProperty: false]) else {
                        throw RecipeExportError.verificationFailed("system_gain_application")
                    }
                    let maximum = Double(gainMetadata?.alternateHeadroom ?? Float(plan.peakStops ?? 0))
                    let minimum = Double(gainMetadata?.baseHeadroom ?? 0)
                    headrooms = [maximum, (minimum + maximum) / 2]
                    let scaled = gain.clampedToExtent().samplingLinear().transformed(by: .init(
                        scaleX: base.extent.width / gain.extent.width,
                        y: base.extent.height / gain.extent.height)).cropped(to: base.extent)
                    images = headrooms.map { base.applyingGainMap(scaled, headroom: Float(pow(2, $0))) }
                } else {
                    guard let image = CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: false]) else {
                        throw RecipeExportError.verificationFailed("system_hdr_readback")
                    }
                    images = [image]
                }
                let context = CIContext(options: [.cacheIntermediates: false])
                for image in images {
                    guard image.extent.width > 0, image.extent.height > 0 else {
                        throw RecipeExportError.verificationFailed("system_hdr_extent")
                    }
                    let scale = min(1, 64 / max(image.extent.width, image.extent.height))
                    let small = image.transformed(by: .init(scaleX: scale, y: scale))
                    let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
                    var samples = [Float](repeating: 0, count: w*h*4)
                    samples.withUnsafeMutableBytes { bytes in
                        context.render(small, toBitmap: bytes.baseAddress!, rowBytes: w*16,
                                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
                                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
                    }
                    guard samples.allSatisfy(\.isFinite) else {
                        throw RecipeExportError.verificationFailed("system_hdr_decode")
                    }
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            return .init(width: width, height: height, bitDepth: depth, orientation: 1,
                         auxiliaryGain: auxiliary != nil || (plan.gainMap.writesGainMap && gain != nil), hdrReadable: hdr,
                         verifiedHeadroomStops: headrooms, profileName: props[kCGImagePropertyProfileName] as? String)
        }
    }
}

/// The b-stage ordinary SDR HEIC exception. No auxiliary data is generated.
enum SDRHEICWriter {
    static func write(_ plane: PackagePlane, to url: URL, quality: Int) throws {
        try Task.checkCancellation()
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: plane.samples.baseAddress!),
                        count: plane.samples.count * 4, deallocator: .none)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let rgb = CGImage(width: plane.width, height: plane.height, bitsPerComponent: 32, bitsPerPixel: 96,
                                bytesPerRow: plane.width * 12, space: space,
                                bitmapInfo: [.floatComponents, .byteOrder32Little], provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RecipeExportError.verificationFailed("sdr_heic_pixels")
        }
        let image = CIImage(cgImage: rgb)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.displayP3)),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw RecipeExportError.verificationFailed("sdr_heic_writer")
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: Double(quality)/100,
                                                    kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RecipeExportError.verificationFailed("sdr_heic_finalize") }
        try Task.checkCancellation()
    }
}
