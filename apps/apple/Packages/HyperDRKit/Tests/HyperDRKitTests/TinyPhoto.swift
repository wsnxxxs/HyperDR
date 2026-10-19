import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small JPEG made in the temporary directory, for tests that only need
/// "some photo" for the engine to open. Tests must not read files out of the
/// repository for that: the checkout sits under ~/Desktop, where `open` can
/// block for tens of seconds on a busy machine (a 733-sample profile of a
/// 36 s test sat in the engine reading the sample for its hash).
enum TinyPhoto {
    /// Written once per process; the same file is handed out afterwards.
    static let url: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-tiny-photo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("input.jpg")
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
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "could not write the tiny test photo")
        return url
    }()
}
