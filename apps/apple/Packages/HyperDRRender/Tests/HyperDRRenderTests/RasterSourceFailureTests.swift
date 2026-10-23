import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HyperDRRender

/// Source-opening failures are checked before any Metal engine is created.
struct RasterSourceFailureTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raster-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test(arguments: [false, true], [false, true])
    func missingJPEGDimensionsAreDecodeFailures(preview: Bool, deferred: Bool) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("corrupt.jpg")
        try Data([0xff, 0xd8, 0xff, 0xe0] + [UInt8](repeating: 0, count: 64)).write(to: file)
        // ImageIO recognises the container, but cannot read its dimensions.
        let input = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetType(input).map { $0 as String } == UTType.jpeg.identifier)
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any]
        #expect(properties?[kCGImagePropertyPixelWidth as String] == nil)
        #expect(properties?[kCGImagePropertyPixelHeight as String] == nil)
        let options = SourceOptions(kind: .imageIO, resolution: preview
            ? .preview(maximumSize: PixelSize(width: 128, height: 96)) : .full)
        do {
            _ = try RenderEngine.open(file, options: options, deferred: deferred)
            Issue.record("A JPEG without decodable dimensions was accepted")
        } catch RenderError.cannotDecodeSource { }
    }

    @Test(arguments: [PixelSize(width: 0, height: 12), PixelSize(width: 16, height: -1)])
    func invalidPreviewBoundsRemainCallerErrors(bound: PixelSize) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("valid.jpg")
        let context = try #require(CGContext(data: nil, width: 16, height: 12,
            bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let writer = try #require(CGImageDestinationCreateWithURL(file as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(writer))
        let healthy = try RenderEngine.open(file, options: SourceOptions(kind: .imageIO))
        #expect(healthy.nativeSize == PixelSize(width: 16, height: 12))
        do {
            _ = try RenderEngine.open(file, options: SourceOptions(kind: .imageIO,
                resolution: .preview(maximumSize: bound)))
            Issue.record("An invalid caller preview bound was accepted")
        } catch RenderError.invalidSize { }
    }
}
