import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small JPEG made in the temporary directory, for tests that only need
/// "some photo" for the engine to open. Tests must not read files out of the
/// repository for that: the checkout sits under ~/Desktop, where `open` can
/// block for tens of seconds on a busy machine (a 733-sample profile of a
/// 36 s test sat in the engine reading the sample for its hash).
///
/// Each photo has a private directory of its own (a fresh UUID, never shared
/// between tests or processes) and is meant to be removed by its user, on every
/// path out:
///
///     let photo = try TinyPhoto(); defer { photo.remove() }
struct TinyPhoto {
    let url: URL
    private var directory: URL { url.deletingLastPathComponent() }

    /// Where every photo's directory lives, and what its name starts with.
    static let namePrefix = "hyperdr-tiny-photo-"

    /// The directories of this kind that are in the temporary folder now.
    static func leftovers() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix(namePrefix) })
    }

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.namePrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("input.jpg")
        let width = 96, height = 64
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                                             blue: 0.5 + 0.4 * CGFloat((x / 8 + y / 8) % 2), alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Removes the photo and its directory; harmless to call twice.
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
