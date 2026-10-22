import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A bounded, oriented embedded thumbnail for temporary display only. Never a
/// RenderSource: it must not enter adjustments, model inference or export.
public enum EmbeddedPreview {
    public struct Image: @unchecked Sendable {
        public let image: CGImage
        /// Oriented native dimensions; use this aspect ratio when fitting the placeholder.
        public let pixelSize: PixelSize
        public init(image: CGImage, pixelSize: PixelSize) { self.image = image; self.pixelSize = pixelSize }
    }

    public static func load(_ url: URL, maximumDimension: Int = 1024) async -> CGImage? {
        await read(url, maximumDimension: maximumDimension)?.image
    }

    public static func read(_ url: URL, maximumDimension: Int = 1024) async -> Image? {
        guard maximumDimension > 0 else { return nil }
        let task = Task.detached(priority: .userInitiated) { () -> Image? in
            guard !Task.isCancelled, FileManager.default.isReadableFile(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            guard let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
                  type.conforms(to: .rawImage) || type.conforms(to: .heic) || type.conforms(to: .heif) else { return nil }
            if !type.conforms(to: .rawImage) {
                // Some raster readers synthesize thumbnails even with IfAbsent=false.
                // Require an actual HEIF thumbnail item before asking ImageIO to read it.
                let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
                let contents = properties?[kCGImagePropertyFileContentsDictionary] as? [CFString: Any]
                let images = contents?[kCGImagePropertyImages] as? [[CFString: Any]]
                guard let thumbnails = images?.first?[kCGImagePropertyThumbnailImages] as? [Any],
                      !thumbnails.isEmpty else { return nil }
            }
            // Do not manufacture a thumbnail by developing a full RAW/raster.
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maximumDimension, 2048),
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR
            ] as CFDictionary)
            guard let image, !Task.isCancelled,
                  image.width <= min(maximumDimension, 2048), image.height <= min(maximumDimension, 2048),
                  let bitmap = CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // Force only these bounded SDR pixels off the UI thread; do not
            // hand SwiftUI a lazy provider that may decode when first drawn.
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let decoded = bitmap.makeImage(), !Task.isCancelled else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
            let rotated = (properties?[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            return Image(image: decoded, pixelSize: PixelSize(width: rotated ? height : width, height: rotated ? width : height))
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
