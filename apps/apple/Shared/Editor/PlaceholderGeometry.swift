import CoreGraphics
import Foundation
import HyperDRRecipe

/// The opening thumbnail laid out as the first frame will be: turned,
/// mirrored, straightened and cropped by the recipe being restored, so the
/// frame that replaces it does not jump. Perspective is left out (the
/// thumbnail is a stand-in, softened and dimmed); the crop is exact.
nonisolated enum PlaceholderGeometry {
    /// `image` is the whole oriented photo (its proportions may differ a little
    /// from `photo`, the photo's size in pixels); the result is the part
    /// `geometry` keeps, with that part's size in photo pixels.
    static func apply(_ geometry: Geometry, to image: CGImage, photo: CGSize) -> (image: CGImage, size: CGSize)? {
        guard !geometry.isIdentity, photo.width > 0, photo.height > 0, image.width > 0, image.height > 0 else { return nil }
        let size = GeometrySize(width: Double(photo.width), height: Double(photo.height))
        let crop = geometry.rasterCropRect(for: size)
        let scaleX = Double(image.width) / Double(photo.width)
        let scaleY = Double(image.height) / Double(photo.height)
        let scale = (scaleX + scaleY) / 2
        let width = max(1, Int((crop.width * scale).rounded()))
        let height = max(1, Int((crop.height * scale).rounded()))
        // Photo pixels to output pixels, the affine part of the map.
        let m = geometry.photoToOutput(for: size).m
        let toOutput = CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Work with y down, like the maps do.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(CGAffineTransform(scaleX: scale, y: scale))
        context.concatenate(toOutput)
        context.concatenate(CGAffineTransform(scaleX: 1 / scaleX, y: 1 / scaleY))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = context.makeImage() else { return nil }
        let output = geometry.outputSize(of: size)
        return (cropped, CGSize(width: output.width, height: output.height))
    }
}
