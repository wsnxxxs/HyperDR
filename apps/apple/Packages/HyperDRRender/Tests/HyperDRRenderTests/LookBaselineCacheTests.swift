import Foundation
import HyperDRRecipe
import Metal
import Testing
@testable import HyperDRRender

private extension RenderEngine {
    /// The cached baselines' identities: rendered source, analysis source.
    var baselineIdentities: (rendered: ObjectIdentifier?, analysed: ObjectIdentifier?) {
        (lookBaselineCache.map { ObjectIdentifier($0.texture) }, analysisLookBaselineCache.map { ObjectIdentifier($0.texture) })
    }
}

/// A partial film strength needs the Apple endpoint on both the fixed analysis
/// grid and the rendered source. Moving the strength must reuse both, not
/// develop the RAW twice per step, and give what a fresh engine renders.
@Suite(.serialized) struct LookBaselineCacheTests {
    private func fixture() throws -> (directory: URL, file: URL) {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-cache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("input.dng")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng"), to: file)
        return (directory, file)
    }

    @Test func strengthStepsReuseBothBaselines() async throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        func recipe(_ strength: Double) -> Recipe {
            Recipe(inputDomain: .rawEDR, values: ["look.film": .string("portra400"), "look.filmStrength": .number(strength)])
        }
        let options = try SourceOptions(recipe: recipe(40), resolution: .preview(maximumSize: PixelSize(width: 640, height: 640)))
        let engine = try RenderEngine()
        let source = try await engine.load(file, options: options, preparingAnalysis: true)
        _ = try await engine.render(source, recipe: recipe(40))
        let cached = await engine.baselineIdentities
        let rendered = try #require(cached.rendered), analysed = try #require(cached.analysed)
        #expect(rendered != analysed)
        for strength in [41.0, 75] {
            let planes = try await engine.render(source, recipe: recipe(strength))
            let reused = await engine.baselineIdentities
            #expect(reused.rendered == rendered, "\(strength)%: rendered baseline")
            #expect(reused.analysed == analysed, "\(strength)%: analysis baseline")
            let fresh = try RenderEngine()
            let reopened = try await fresh.load(file, options: options, preparingAnalysis: true)
            let expected = RenderEngine.readPixels(try await fresh.render(reopened, recipe: recipe(strength)))
            let actual = RenderEngine.readPixels(planes)
            #expect(actual.baseRGBA == expected.baseRGBA, "\(strength)%: base")
            #expect(actual.gain == expected.gain, "\(strength)%: gain")
        }
    }
}
