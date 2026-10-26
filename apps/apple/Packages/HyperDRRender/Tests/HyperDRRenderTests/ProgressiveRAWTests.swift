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
        let export = try await engine.openExportSource(url, options: options, reusingAnalysis: true)
        #expect(!export.analysisSource.isDraftRAWPreview)
        #expect(export.rawSettings?.scaleFactor == 1)
        #expect(export.rawSettings?.decoderVersion == draft.rawSettings?.decoderVersion)
    }

    @Test func detailsReuseOnlyTheMatchingNativeAnalysisWithoutChangingPixels() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ARW")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW"), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        let options = SourceOptions(resolution: .preview(maximumSize: PixelSize(width: 512, height: 512)))
        let preview = try await engine.load(url, options: options, preparingAnalysis: true)
        let analysis = try await engine.previewAnalysis(preview)
        let reused = try await engine.openExportSource(url, options: options, reusingAnalysis: true)
        #expect(reused.analysisSource.renderID == analysis.renderID)
        let referenceEngine = try RenderEngine()
        let reference = try await referenceEngine.openExportSource(url, options: options)
        let region = CGRect(x: 1013, y: 501, width: 257, height: 129)
        let recipe = Recipe(inputDomain: .rawEDR, values: ["tone.exposure": .number(0.5), "tone.contrast": .number(30)])
        func pixels(_ renderer: RenderEngine, _ source: ExportSource) async throws -> PlanePixels {
            let tile = try await renderer.materializeExportRegion(source, outputSize: source.nativeSize, region: region)
            return RenderEngine.readPixels(try await renderer.render(tile, recipe: recipe, size: source.nativeSize, region: region))
        }
        let actual = try await pixels(engine, reused), expected = try await pixels(referenceEngine, reference)
        let baseError = zip(actual.baseRGBA, expected.baseRGBA).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        let gainError = zip(actual.gain, expected.gain).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(baseError <= 0.00001 && gainError <= 0.00001)

        var changed = recipe
        changed.setValue(.number(70), for: "develop.sharpness")
        let different = try await engine.openExportSource(url, options: SourceOptions(recipe: changed), reusingAnalysis: true)
        #expect(different.analysisSource.id != analysis.id)
        #expect(different.analysisSource.renderID != analysis.renderID)
    }

    @Test func retainedLookPreviewsMatchIndependentRendersAndReleaseOnYield() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ARW")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW"), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        let size = PixelSize(width: 512, height: 512)
        let original = Recipe(inputDomain: .rawEDR)
        let displayOptions = try SourceOptions(recipe: original, resolution: .preview(maximumSize: size))
        let display = try await engine.load(url, options: displayOptions, preparingAnalysis: true, retainingPreview: true)
        var film = original
        film.setValue(.string("portra400"), for: Recipe.filmID)
        film.setValue(.number(60), for: "look.filmStrength")
        film.setValue(.number(100), for: "effect.grain")
        film.setValue(.number(100), for: "effect.halation")
        let sceneOptions = try SourceOptions(recipe: film, resolution: .preview(maximumSize: size))
        let scene = try await engine.load(url, options: sceneOptions, preparingAnalysis: true, retainingPreview: true)
        // The baseline is the already-developed Apple texture, with no copy or resampling.
        #expect(try await engine.baselineUsesDisplay(scene, display: display, edit: RenderAdjustments(recipe: film)))
        // A neutral thumbnail must not evict a live partial-strength baseline.
        _ = try await engine.render(scene, recipe: original, size: PixelSize(width: 96, height: 64))
        #expect(try await engine.baselineUsesDisplay(scene, display: display, edit: RenderAdjustments(recipe: film)))

        let referenceEngine = try RenderEngine()
        let reference = try await referenceEngine.load(url, options: sceneOptions, preparingAnalysis: true)
        let lut = try ColorLUT(cube: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        var log = original
        log.look = LUTReference(contentHash: lut.contentHash, name: "Test")
        log.setValue(.string("slog3-sgamut3cine"), for: "look.input")
        log.setValue(.string("srgb"), for: "look.output")
        log.setValue(.number(60), for: "look.strength")
        for recipe in [film, log] {
            let actual = RenderEngine.readPixels(try await engine.render(scene, recipe: recipe, lut: recipe.look == nil ? nil : lut))
            let expected = RenderEngine.readPixels(try await referenceEngine.render(reference, recipe: recipe, lut: recipe.look == nil ? nil : lut))
            #expect(actual.baseRGBA.count == expected.baseRGBA.count && actual.gain.count == expected.gain.count)
            let baseError = zip(actual.baseRGBA, expected.baseRGBA).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            let gainError = zip(actual.gain, expected.gain).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            #expect(baseError <= 0.00001 && gainError <= 0.00001)
        }
        let again = try await engine.load(url, options: displayOptions, preparingAnalysis: true, retainingPreview: true)
        #expect(again.renderID == display.renderID)
        let sceneAgain = try await engine.load(url, options: sceneOptions, preparingAnalysis: true, retainingPreview: true)
        #expect(sceneAgain.renderID == scene.renderID)
        await engine.clearCaches()
        #expect(await engine.retainedPreviewAnalysis(id: display.id) == nil)
        #expect(await engine.retainedPreviewAnalysis(id: scene.id) == nil)
        var changed = film
        changed.setValue(.number(70), for: "develop.sharpness")
        let changedOptions = try SourceOptions(recipe: changed, resolution: .preview(maximumSize: size))
        let updated = try await engine.load(url, options: changedOptions, preparingAnalysis: true, retainingPreview: true)
        #expect(updated.modelSourceID != scene.modelSourceID)
        #expect(await engine.retainedPreviewAnalysis(id: scene.id) == nil)
    }
}

extension RenderEngine {
    fileprivate func baselineUsesDisplay(_ source: RenderSource, display: RenderSource, edit: RenderAdjustments) throws -> Bool {
        try lookBaseline(source, edit: edit) === display.texture
    }

    fileprivate func sharedGridErrors(_ image: CIImage, sizes: [PixelSize]) throws -> [Float] {
        let shared = try rasterizeRAWPreviews(image, sizes: sizes, space: Self.workingColorSpace)
        return try zip(sizes, shared).map { size, result in
            let reference = try rasterizeRAWPreview(image, size: size, space: Self.workingColorSpace)
            let expected = Self.readTexture(reference), actual = Self.readTexture(result)
            return zip(expected, actual).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        }
    }
}
