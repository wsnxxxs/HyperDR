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

    /// Weighted box integration in linear light, followed by the sRGB transfer.
    /// Reads only the immutable base plane; gain, viewing mode and EDR are irrelevant.
    public static func sdrImage(from frame: PreviewFrame, maxPixelSize: Int) throws -> CGImage {
        let base = frame.base
        guard maxPixelSize > 0, base.channels == 3,
              frame.metadata.colorSpace == "linear-display-p3" else { throw invalid() }
        let scale = min(1, Double(maxPixelSize) / Double(max(base.width, base.height)))
        let width = max(1, Int((Double(base.width) * scale).rounded()))
        let height = max(1, Int((Double(base.height) * scale).rounded()))
        let dx = Double(base.width) / Double(width), dy = Double(base.height) / Double(height)
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        try base.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self), stride = base.rowBytes / MemoryLayout<Float>.size
            for y in 0..<height {
                try Task.checkCancellation()
                let top = Double(y) * dy, bottom = Double(y + 1) * dy
                for x in 0..<width {
                    let left = Double(x) * dx, right = Double(x + 1) * dx
                    var sums = (0.0, 0.0, 0.0)
                    for sy in Int(top.rounded(.down))..<min(base.height, Int(bottom.rounded(.up))) {
                        let wy = min(bottom, Double(sy + 1)) - max(top, Double(sy))
                        for sx in Int(left.rounded(.down))..<min(base.width, Int(right.rounded(.up))) {
                            let weight = wy * (min(right, Double(sx + 1)) - max(left, Double(sx)))
                            let p = sy * stride + sx * 3
                            let r = samples[p], g = samples[p + 1], b = samples[p + 2]
                            guard r.isFinite, g.isFinite, b.isFinite else { throw invalid() }
                            sums.0 += Double(min(1, max(0, r))) * weight
                            sums.1 += Double(min(1, max(0, g))) * weight
                            sums.2 += Double(min(1, max(0, b))) * weight
                        }
                    }
                    let p = (y * width + x) * 3
                    bytes[p] = encode(sums.0 / (dx * dy))
                    bytes[p + 1] = encode(sums.1 / (dx * dy))
                    bytes[p + 2] = encode(sums.2 / (dx * dy))
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: width * 3, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw invalid() }
        return image
    }

    private static func encode(_ linear: Double) -> UInt8 {
        let value = min(1, max(0, linear))
        let encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, (encoded * 255).rounded())))
    }
    private static func invalid() -> HyperDRError {
        HyperDRError(code: "invalid_options", message: "Invalid export thumbnail")
    }
}
