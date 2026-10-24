import CoreImage
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct LookPipelineTests {
    private func rawCopy() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("look-pipeline-\(UUID()).ARW")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW"), to: url)
        return url
    }

    @Test func zeroColourRAWStockKeepsItsSceneAndAppleBaseline() async throws {
        let url = try rawCopy()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        var recipe = Recipe(inputDomain: .rawEDR, values: [Recipe.filmID: .string("portra400"),
            "look.filmExposure": .number(0), "hdr.range": .number(4)])
        func render(_ recipe: Recipe) async throws -> RenderPlanes {
            let options = try SourceOptions(recipe: recipe,
                resolution: .preview(maximumSize: PixelSize(width: 128, height: 128)))
            let source = try await engine.load(url, options: options)
            return try await engine.render(source, recipe: recipe)
        }
        func hdr(_ planes: RenderPlanes) -> [Float] {
            let p = RenderEngine.readPixels(planes)
            let offset: Float
            if case let .pairedLog2(value, _) = planes.encoding { offset = value } else { offset = 0 }
            return (0..<(p.baseRGBA.count/4)).flatMap { i in (0..<3).map { c in
                (p.baseRGBA[i*4+c]+offset)*exp2(p.gain[i*p.gainChannelCount+(p.gainChannelCount == 1 ? 0 : c)])-offset
            } }
        }
        let noPhysics = try await render(recipe), s0 = RenderEngine.readPixels(noPhysics), h0 = hdr(noPhysics)
        recipe.setValue(.number(100), for: "effect.grain"); recipe.setValue(.number(100), for: "effect.halation")
        let physics = try await render(recipe), s1 = RenderEngine.readPixels(physics), h1 = hdr(physics)
        for strength in [0.0, 1, 100] {
            recipe.setValue(.number(strength), for: "look.filmStrength")
            #expect(try SourceOptions(recipe: recipe).sceneLinear)
            #expect(recipe.needsLookBaseline == (strength < 100))
            let actualPlanes = try await render(recipe), actual = RenderEngine.readPixels(actualPlanes), actualHDR = hdr(actualPlanes)
            var neutral = recipe
            for id in Adjustments.effectIDs { neutral.setValue(.number(0), for: id) }
            let colourPlanes = try await render(neutral), colour = RenderEngine.readPixels(colourPlanes), colourHDR = hdr(colourPlanes)
            var checked = 0, worst: Float = 0
            for i in 0..<(s0.baseRGBA.count/4) {
                let expected = (0..<3).map { c in colour.baseRGBA[i*4+c]+s1.baseRGBA[i*4+c]-s0.baseRGBA[i*4+c] }
                guard expected.allSatisfy({ $0 > 0.01 && $0 < 0.95 }) else { continue }
                for c in 0..<3 {
                    let expectedHDR = colourHDR[i*3+c]+h1[i*3+c]-h0[i*3+c]
                    guard expectedHDR > 0.01 else { continue }
                    checked += 1
                    worst = max(worst, abs(actual.baseRGBA[i*4+c]-expected[c]), abs(actualHDR[i*3+c]-expectedHDR))
                }
            }
            #expect(checked > 10 && worst < 1e-4, "RAW stock strength \(strength): \(worst)")
        }
    }

    @Test func independentEffectsWorkWithAFullPartialAndDisabledRAWLogLook() async throws {
        let url = try rawCopy()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        let lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        var recipe = Recipe(inputDomain: .rawEDR, look: LUTReference(contentHash: lut.contentHash, name: "Log"), values: [
            "look.input": .string("slog3-sgamut3cine"), "look.output": .string("rec709"), "hdr.range": .number(4)])
        for strength in [0.0, 40, 100] {
            recipe.setValue(.number(strength), for: "look.strength")
            recipe.setValue(.number(0), for: "effect.grain"); recipe.setValue(.number(0), for: "effect.halation")
            let options = try SourceOptions(recipe: recipe,
                resolution: .preview(maximumSize: PixelSize(width: 128, height: 128)))
            let source = try await engine.load(url, options: options)
            let plain = RenderEngine.readPixels(try await engine.render(source, recipe: recipe, lut: lut))
            recipe.setValue(.number(100), for: "effect.grain"); recipe.setValue(.number(100), for: "effect.halation")
            let actual = RenderEngine.readPixels(try await engine.render(source, recipe: recipe, lut: lut))
            #expect(zip(plain.baseRGBA, actual.baseRGBA).contains { abs($0-$1) > 1e-6 })
            #expect(actual.gainChannelCount == 3 && actual.gain.allSatisfy(\.isFinite))
        }
    }

    /// Check the user-visible crossfade against independently rendered endpoints,
    /// including zero, instead of comparing two copies of the same LUT formula.
    @Test(arguments: [false, true], [false, true])
    func partialRAWLookBlendsRenderedEndpoints(isFilm: Bool, hdrEnabled: Bool) async throws {
        let url = try rawCopy()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        let lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        var full = Recipe(inputDomain: .rawEDR)
        full.setValue(.bool(hdrEnabled), for: "hdr.enabled")
        full.setValue(.number(4), for: "hdr.range")
        let strength: String
        if isFilm {
            full.setValue(.string("portra400"), for: Recipe.filmID)
            full.setValue(.number(0), for: "effect.grain")
            full.setValue(.number(0), for: "effect.halation")
            full.setValue(.number(0), for: "look.filmExposure")
            strength = "look.filmStrength"
        } else {
            full.look = LUTReference(contentHash: lut.contentHash, name: "Log conversion")
            full.setValue(.string("slog3-sgamut3cine"), for: "look.input")
            full.setValue(.string("rec709"), for: "look.output")
            strength = "look.strength"
        }
        let resolution = SourceResolution.preview(maximumSize: PixelSize(width: 96, height: 96))
        func pixels(_ recipe: Recipe) async throws -> PlanePixels {
            let source = try await engine.load(url, options: SourceOptions(recipe: recipe, resolution: resolution))
            return RenderEngine.readPixels(try await engine.render(source, recipe: recipe, lut: isFilm ? nil : lut))
        }
        var zero = full
        zero.setValue(.number(0), for: strength)
        let original = try await pixels(zero), styled = try await pixels(full)
        for weight in [0.01, 0.4, 0.99] {
            var partial = full
            partial.setValue(.number(weight*100), for: strength)
            let actual = try await pixels(partial)
            let worst = actual.baseRGBA.indices.reduce(Float(0)) { error, i in
                max(error, abs(actual.baseRGBA[i] - (original.baseRGBA[i] + (styled.baseRGBA[i]-original.baseRGBA[i])*Float(weight))))
            }
            #expect(worst < 1e-5, "partial \(weight), film \(isFilm), error \(worst)")
            if hdrEnabled {
                func hdr(_ p: PlanePixels, _ i: Int, _ c: Int) -> Float {
                    p.baseRGBA[i*4+c]*exp2(p.gain[i*p.gainChannelCount+(p.gainChannelCount == 1 ? 0 : c)])
                }
                for i in 0..<(actual.baseRGBA.count/4) { for c in 0..<3 {
                    let expected = hdr(original,i,c)+(hdr(styled,i,c)-hdr(original,i,c))*Float(weight)
                    #expect(abs(hdr(actual,i,c)-expected) < 1e-4)
                } }
                partial.setValue(.bool(false), for: "hdr.enabled")
                let sdr = try await pixels(partial)
                #expect(zip(sdr.baseRGBA, actual.baseRGBA).allSatisfy { abs($0-$1) < 1e-6 }, "HDR controls must not move the SDR base")
            } else {
                #expect(actual.gain.allSatisfy { $0 == 0 })
            }
        }
        // Removing the style and setting its strength to zero share the endpoint.
        var none = zero
        none.look = nil; none.setValue(nil, for: Recipe.filmID)
        let without = try await pixels(none)
        #expect(zip(without.baseRGBA, original.baseRGBA).allSatisfy { abs($0-$1) < 1e-6 })
    }

    /// The companion Apple development must use the same global sampling window
    /// as the scene source, including a lazy export tile rather than a whole frame.
    @Test func partialRAWLookTilesMatchWholeSource() async throws {
        let url = try rawCopy()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        let lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        let recipe = Recipe(inputDomain: .rawEDR, look: LUTReference(contentHash: lut.contentHash, name: "Log"), values: [
            "look.input": .string("slog3-sgamut3cine"), "look.output": .string("rec709"),
            "look.strength": .number(40), "hdr.range": .number(4)])
        let source = try await engine.load(url, options: SourceOptions(recipe: recipe))
        let region = CGRect(x: 800, y: 600, width: 64, height: 32)
        let whole = RenderEngine.readPixels(try await engine.render(source, recipe: recipe, lut: lut, region: region))
        let lazy = try await engine.openExportSource(url, options: SourceOptions(recipe: recipe))
        let tile = try await engine.materializeExportRegion(lazy, outputSize: source.size, region: region)
        let tiled = RenderEngine.readPixels(try await engine.render(tile, recipe: recipe, lut: lut, region: region))
        let error = zip(whole.baseRGBA, tiled.baseRGBA).reduce(Float(0)) { max($0, abs($1.0-$1.1)) }
        let gainError = zip(whole.gain, tiled.gain).reduce(Float(0)) { max($0, abs($1.0-$1.1)/4) }
        #expect(error <= 1/1023 && gainError <= 1/1023)
    }

    @Test func logRAWPreservesSignedWideGamutSamples() async throws {
        let url = try rawCopy()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        let source = try await engine.load(url, options: SourceOptions(resolution: .preview(maximumSize: PixelSize(width: 320, height: 320)), sceneLinear: true))
        let pixels = RenderEngine.readTexture(source.texture)
        #expect(pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element < -1e-5 })
    }

    @Test func directRenderCannotChainTwoDisplayLooks() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)), domain: .rawEDR)
        var edit = RenderAdjustments()
        edit.film.stock = .portra400
        edit.look.lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        edit.look.input = .sLog3; edit.look.output = .rec709
        do {
            _ = try await engine.render(source, adjustments: edit)
            Issue.record("Two alternative looks were chained")
        } catch RenderError.invalidAdjustment {}
    }
}
