import CoreImage
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct RAWPreviewRasterTests {
    @Test func bitmapDraftPreservesPortraitOrientationAndCellBoundaries() async throws {
        // Non-zero origin, odd portrait sizes and >256 rows exercise the cell
        // stitching and the one top-down flip used by the preview contract.
        let extent = CGRect(x: 13, y: 29, width: 513, height: 1027)
        let image = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 13, y: 29),
            "inputPoint1": CIVector(x: 526, y: 1056),
            "inputColor0": CIColor(red: 0.2, green: 0.3, blue: 0.4),
            "inputColor1": CIColor(red: 0.8, green: 0.7, blue: 0.6)
        ])!.outputImage!.cropped(to: extent)
        let engine = try RenderEngine()
        let size = PixelSize(width: 257, height: 515)
        let pixels = try await engine.draftPixels(image, size: size)
        #expect(pixels.count == size.width * size.height * 4)
        #expect(stride(from: 0, to: pixels.count, by: 4).allSatisfy { pixels[$0].isFinite && pixels[$0] > 0.01 })
        // Area integration accumulates float rounding at odd grid ratios.
        #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { abs(pixels[$0] - 1) < 0.0005 })
        #expect(pixels[0] > pixels[(size.height - 1) * size.width * 4])
    }

    @Test func reducedDNGRemainsEditableAndComplete() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        try FileManager.default.copyItem(at: fixture, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        var options = SourceOptions(resolution: .preview(maximumSize: PixelSize(width: 513, height: 513)))
        options.rawDecoderVersion = "8.dng"
        options.draftRAWPreview = true
        let source = try await engine.load(url, options: options)
        #expect(source.isDraftRAWPreview && source.rawSettings?.decoderVersion == "8.dng")
        #expect(source.texture.width <= 513 && source.texture.height <= 513)
        let pixels = RenderEngine.readTexture(source.texture)
        #expect(pixels.allSatisfy { $0.isFinite })
        #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { abs(pixels[$0] - 1) < 0.0005 })
        let recipe = Recipe(inputDomain: .rawEDR, values: ["tone.exposure": .number(1)], rawDecoderVersion: "8.dng")
        let edited = try await engine.render(source, recipe: recipe)
        #expect(edited.base.width == source.size.width && edited.base.height == source.size.height)
    }
}

extension RenderEngine {
    fileprivate func draftPixels(_ image: CIImage, size: PixelSize) throws -> [Float] {
        Self.readTexture(try rasterizeDraftRAWPreview(image, size: size, space: Self.workingColorSpace))
    }
}
