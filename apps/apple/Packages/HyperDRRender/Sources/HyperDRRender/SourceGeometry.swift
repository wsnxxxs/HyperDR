import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import HyperDRRecipe

/// The crop pane's geometry where the source is opened (`Geometry`): every
/// image the source holds is transformed alike and cropped to the output, so
/// analysis, AI, the film meter, previews, detail regions and export all see
/// the cropped photo as the photo. Lazy Core Image work: only the rows a
/// render asks for are resampled.
extension OpenedSource {
    func applying(_ geometry: Geometry) throws -> OpenedSource {
        guard !geometry.isIdentity else { return self }
        let full = nativeSize ?? raw?.nativeSize
            ?? PixelSize(width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()))
        let output = geometry.outputSize(of: GeometrySize(width: Double(full.width), height: Double(full.height)))
        let photo = GeometrySize(width: Double(full.width), height: Double(full.height))
        let base = try Self.transform(image, geometry, nativePhoto: photo)
        let transformedHDR = hdr === image ? base : try Self.transform(hdr, geometry, photo: image.extent, nativePhoto: photo)
        let transformedGain = try gain.map { gain in
            AuthoredGainMap(standard: gain.standard, auxiliaryInfo: gain.auxiliaryInfo,
                            image: try Self.transform(gain.image, geometry, photo: image.extent, nativePhoto: photo),
                            channelCount: gain.channelCount, baseColorSpace: gain.baseColorSpace,
                            alternateColorSpace: gain.alternateColorSpace,
                            auxiliaryColorSpace: gain.auxiliaryColorSpace, tags: gain.tags)
        }
        var result = OpenedSource(domain: domain, image: base, hdr: transformedHDR, baseSpace: baseSpace,
                                  gain: transformedGain,
                                  raw: raw?.withGeometry(nativeSize: PixelSize(width: output.width, height: output.height),
                                                         developedExtent: base.extent.size),
                                  nativeSize: nativeSize.map { _ in PixelSize(width: output.width, height: output.height) },
                                  rawPreviewSize: rawPreviewSize, draftRAWPreview: draftRAWPreview)
        result.modelCapture = modelCapture
        result.uncroppedSize = full
        return result
    }

    /// `image` through `geometry`, cropped to the output with its origin at
    /// zero. `photo` is the extent of the image the geometry is measured on
    /// (the base): a smaller gain map is scaled onto it, transformed, and
    /// scaled back to its own resolution.
    /// `nativePhoto` fixes the crop's pixel grid before a decoded preview is
    /// resized. Auxiliary planes still use `photo` as their reference extent.
    static func transform(_ image: CIImage, _ geometry: Geometry, photo: CGRect? = nil,
                          nativePhoto: GeometrySize? = nil) throws -> CIImage {
        let extent = image.extent
        let reference = photo ?? extent
        guard extent.width > 0, extent.height > 0, reference.width > 0, reference.height > 0 else {
            throw RenderError.invalidSize
        }
        // Onto the base's pixel grid, so straightening turns the same picture.
        let toBase = CGAffineTransform(translationX: reference.minX, y: reference.minY)
            .scaledBy(x: reference.width / extent.width, y: reference.height / extent.height)
            .translatedBy(x: -extent.minX, y: -extent.minY)
        let size = nativePhoto ?? GeometrySize(width: reference.width, height: reference.height)
        let nativeOutput = geometry.outputSize(of: size)
        let sx = reference.width / size.width, sy = reference.height / size.height
        let turned = geometry.quarterTurns % 2 != 0
        let output = (width: max(1, Int((Double(nativeOutput.width) * (turned ? sy : sx)).rounded())),
                      height: max(1, Int((Double(nativeOutput.height) * (turned ? sx : sy)).rounded())))
        // Decoded CI pixels -> native top-left coordinates -> canonical output
        // -> this resolution's CI pixels. Never re-snap a preview's translation.
        let fromCI = Homography(m: [1 / sx, 0, -reference.minX / sx,
                                   0, -1 / sy, reference.maxY / sy, 0, 0, 1])
        let toCI = Homography(m: [Double(output.width) / Double(nativeOutput.width), 0, 0,
                                 0, -Double(output.height) / Double(nativeOutput.height), Double(output.height), 0, 0, 1])
        let map = toCI * geometry.photoToOutput(for: size) * fromCI
        let onBase = image.transformed(by: toBase).clampedToExtent()
        let transformed: CIImage
        if map.isAffine {
            let m = map.m
            transformed = onBase.transformed(by: CGAffineTransform(a: m[0] / m[8], b: m[3] / m[8], c: m[1] / m[8],
                                                                   d: m[4] / m[8], tx: m[2] / m[8], ty: m[5] / m[8]))
        } else {
            let filter = CIFilter.perspectiveTransformWithExtent()
            filter.inputImage = onBase
            filter.extent = reference
            func corner(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                let point = map.apply(GeometryPoint(x: Double(x), y: Double(y)))
                return CGPoint(x: point.x, y: point.y)
            }
            filter.topLeft = corner(reference.minX, reference.maxY)
            filter.topRight = corner(reference.maxX, reference.maxY)
            filter.bottomRight = corner(reference.maxX, reference.minY)
            filter.bottomLeft = corner(reference.minX, reference.minY)
            guard let image = filter.outputImage else { throw RenderError.cannotDecodeSource }
            transformed = image
        }
        let cropped = transformed.cropped(to: CGRect(x: 0, y: 0, width: output.width, height: output.height))
        guard photo != nil, extent.size != reference.size else { return cropped }
        // Back to the image's own resolution.
        let auxiliaryX = extent.width / reference.width, auxiliaryY = extent.height / reference.height
        let own = CGRect(x: 0, y: 0, width: max(1, (Double(output.width) * auxiliaryX).rounded()),
                         height: max(1, (Double(output.height) * auxiliaryY).rounded()))
        return cropped.transformed(by: CGAffineTransform(scaleX: own.width / Double(output.width),
                                                         y: own.height / Double(output.height))).cropped(to: own)
    }
}

extension RAWDevelopment {
    /// The development as the geometry leaves it: its native size and
    /// developed extent are the output's.
    func withGeometry(nativeSize: PixelSize, developedExtent: CGSize) -> Self {
        RAWDevelopment(boost: boost, boostShadow: boostShadow, baselineExposure: baselineExposure,
                       localToneMap: localToneMap, extendedDynamicRange: extendedDynamicRange,
                       lensCorrectionSupported: lensCorrectionSupported, lensCorrectionApplied: lensCorrectionApplied,
                       decoderVersion: decoderVersion, temperature: temperature, tint: tint,
                       luminanceNR: luminanceNR, colorNR: colorNR, sharpness: sharpness,
                       supportsLuminanceNR: supportsLuminanceNR, supportsColorNR: supportsColorNR,
                       supportsSharpness: supportsSharpness, nativeSize: nativeSize,
                       developedExtent: developedExtent, scaleFactor: scaleFactor, isDraft: isDraft,
                       sourceValues: sourceValues)
    }
}

extension Geometry {
    /// The output of a photo of `size` pixels: the size the editor shows, the
    /// export plans for, and `SourceOptions.geometry` opens the source at.
    public func outputSize(of size: PixelSize) -> PixelSize {
        let output = outputSize(of: GeometrySize(width: Double(size.width), height: Double(size.height)))
        return PixelSize(width: output.width, height: output.height)
    }
}
