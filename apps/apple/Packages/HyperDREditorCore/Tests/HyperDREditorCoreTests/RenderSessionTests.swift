import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HyperDREditorCore

/// The real adapter on HyperDRRender, with a small generated photo.
@Suite struct RenderSessionTests {
    private static func tinyPNG(width: Int = 96, height: Int = 64) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tiny.png")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func opensRendersARegionAndRefusesStaleRequests() async throws {
        let session = try RenderSession()
        let url = try Self.tinyPNG()
        let source = try await session.open(url, previewSize: PixelSize(width: 48, height: 48))
        #expect(source.domain == .sdr)
        #expect(source.pixelSize == PixelSize(width: 96, height: 64))

        var recipe = Recipe(inputDomain: .sdr)
        recipe.setValue(.number(0.5), for: "tone.exposure")
        let preview = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: recipe,
                                                                  size: PixelSize(width: 48, height: 32)))
        #expect(preview.display.outputSize == PixelSize(width: 48, height: 32))
        #expect(preview.planes.base.width == 48)

        // A region needs the full-size source and returns only the ROI.
        let detail = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: recipe,
            size: source.pixelSize, region: CGRect(x: 16, y: 8, width: 32, height: 24)))
        #expect(detail.planes.base.width == 32 && detail.planes.base.height == 24)
        #expect(detail.planes.outputSize == source.pixelSize)

        // AI renders without the model, marked pending.
        var ai = recipe
        ai.setHDRSource(.ai)
        let pending = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: ai,
                                                                  size: PixelSize(width: 48, height: 32)))
        #expect(pending.modelGainPending)

        let thumbnail = try await session.sdrThumbnail(preview, maximumSize: PixelSize(width: 24, height: 24))
        #expect(thumbnail.width == 24)

        await #expect(throws: EditorRenderingError.staleSource) {
            try await session.render(EditorRenderRequest(sourceID: UUID(), recipe: recipe, size: PixelSize(width: 48, height: 32)))
        }
    }
}
