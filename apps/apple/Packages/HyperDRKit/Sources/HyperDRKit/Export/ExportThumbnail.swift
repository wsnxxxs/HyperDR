import CoreGraphics
import Foundation
import HyperDREngine
import ImageIO
import UniformTypeIdentifiers

/// A small SDR snapshot supplied at export admission, never decoded from output.
public struct ExportThumbnail: Sendable, Equatable {
    public static let maxPixelSize = 256
    public static let maxByteCount = 256 * 1024
    public let jpegData: Data

    public init(jpegData: Data) throws {
        guard jpegData.count >= 4, jpegData.count <= Self.maxByteCount,
              jpegData.prefix(2) == Data([0xff, 0xd8]), jpegData.suffix(2) == Data([0xff, 0xd9]),
              let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= Self.maxPixelSize,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
            throw Self.invalid()
        }
        self.jpegData = jpegData
    }

    public init(image: CGImage) throws {
        guard max(image.width, image.height) <= Self.maxPixelSize,
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Self.invalid() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else { throw Self.invalid() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Self.invalid()
        }
        CGImageDestinationAddImage(destination, normalized,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Self.invalid() }
        try self.init(jpegData: data as Data)
    }

    private static func invalid() -> HyperDRError {
        HyperDRError(code: "invalid_options", message: "Invalid export thumbnail")
    }
}
