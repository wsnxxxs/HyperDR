import Foundation
import CoreImage
import HyperDRRecipe
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct ProgressiveRAWTests {
    @Test func sharedNativeCellsPreserveBothIndependentAreaGrids() async throws {
        // Odd sizes cross horizontal and vertical canonical-cell boundaries,
        // including pixels whose footprints are shared by several cells.
        let width = 4101, height = 517
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                bytes[p] = UInt8(x % 251)
                bytes[p + 1] = UInt8(y % 251)
                bytes[p + 2] = UInt8((x * 17 + y * 31) % 256)
            }
        }
        let space = RenderEngine.workingColorSpace
        let image = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: space)
            .transformed(by: CGAffineTransform(translationX: 13, y: 21))
        let sizes = [PixelSize(width: 641, height: 81), PixelSize(width: 127, height: 16)]
        let engine = try RenderEngine()
        let errors = try await engine.sharedGridErrors(image, sizes: sizes)
        #expect(errors.allSatisfy { $0 <= 0.000001 })
    }

    @Test func anInstalledPreviewNeverAnswersAFullSizeLoad() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ARW")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW"), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let producer = try RenderEngine(), consumer = try RenderEngine()
        var options = SourceOptions(resolution: .preview(maximumSize: .init(width: 512, height: 512)))
        options.rawDecoderVersion = await producer.preferredRAWDecoder(url)
        let preview = try await producer.load(url, options: options, preparingAnalysis: true)
        let analysis = try await producer.previewAnalysis(preview)
        try await consumer.installRefinedPreview(preview, analysis: analysis, resolution: options.resolution)
        let cached = try await consumer.load(url, options: options)
        #expect(cached.size == preview.size && cached.renderID == preview.renderID)
        options.resolution = .full
        let full = try await consumer.load(url, options: options)
        #expect(full.size == full.nativeSize && full.size != preview.size)
        #expect(full.rawSettings?.scaleFactor == 1)
    }

    @Test func draftIsEditableButExportKeepsNativeAnalysis() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        try FileManager.default.copyItem(at: fixture, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        var options = SourceOptions(resolution: .preview(maximumSize: PixelSize(width: 256, height: 256)))
        options.draftRAWPreview = true
        options.rawDecoderVersion = await engine.preferredRAWDecoder(url)
        let draft = try await engine.load(url, options: options, preparingAnalysis: true)
        #expect(draft.isDraftRAWPreview)
        var recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: options.rawDecoderVersion)
        recipe.setValue(.number(1), for: "tone.exposure")
        let edited = try await engine.render(draft, recipe: recipe, size: draft.size)
        #expect(edited.base.width == draft.size.width && edited.base.height == draft.size.height)
        await #expect { try await engine.previewAnalysis(draft) } throws: { error in
            if case RenderError.invalidAdjustment = error { return true }
            return false
        }

        // Even a caller passing preview options cannot send draft analysis into export.
        let export = try await engine.openExportSource(url, options: options)
        #expect(!export.analysisSource.isDraftRAWPreview)
        #expect(export.rawSettings?.scaleFactor == 1)
        #expect(export.rawSettings?.decoderVersion == draft.rawSettings?.decoderVersion)
    }
}

extension RenderEngine {
    fileprivate func sharedGridErrors(_ image: CIImage, sizes: [PixelSize]) throws -> [Float] {
        let shared = try rasterizeRAWPreviews(image, sizes: sizes, space: Self.workingColorSpace)
        return try zip(sizes, shared).map { size, result in
            let reference = try rasterizeRAWPreview(image, size: size, space: Self.workingColorSpace)
            let expected = Self.readTexture(reference), actual = Self.readTexture(result)
            return zip(expected, actual).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        }
    }
}
