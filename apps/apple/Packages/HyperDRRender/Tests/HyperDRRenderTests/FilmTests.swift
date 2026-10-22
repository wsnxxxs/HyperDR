import Foundation
import CoreImage
import Testing
import HyperDRRecipe
@testable import HyperDRRender

private struct FilmReference: Decodable {
    struct Grain: Decodable { let size: Int; let densityMean, densityRMS: [[Double]] }
    let inputs: [[Double]]
    let outputs: [String: [[Double]]]
    let grain: [String: Grain]
}

private func reference() throws -> FilmReference {
    let url = try #require(Bundle.module.url(forResource: "film-reference", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(FilmReference.self, from: Data(contentsOf: url))
}

private func bitmap(_ values: [SIMD3<Double>]) -> CIImage {
    precondition(!values.isEmpty)
    let rgba = values.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
    return CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: values.count * 16,
                   size: CGSize(width: values.count, height: 1), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
}

/// 10-bit sRGB code of a linear value.
private func code(_ value: Double) -> Int {
    let x = min(1, max(0, value)), encoded = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    return Int((encoded * 1023).rounded())
}

@Suite struct FilmTests {
    @Test func everyDeclaredStockIsBundled() throws {
        #expect(Adjustments.filmStocks == ["none"] + FilmStockID.allCases.map(\.rawValue))
        for id in FilmStockID.allCases {
            let stock = try FilmStock.named(id)
            #expect(stock.attribution.contains("spektrafilm") && stock.attribution.contains("CC BY-SA 4.0"))
        }
        #expect(try FilmStock.named(.velvia100).isReversal)
        #expect(try !FilmStock.named(.portra400).isReversal)
    }

    /// The double reference against spektrafilm's own per-pixel pipeline. The bundled
    /// chromaticity table is float16, worth at most a 10-bit code.
    @Test func doubleReferenceMatchesSpektrafilm() throws {
        let fixture = try reference()
        #expect(Set(fixture.outputs.keys) == Set(FilmStockID.allCases.map(\.rawValue)))
        for id in FilmStockID.allCases {
            let stock = try FilmStock.named(id), expected = try #require(fixture.outputs[id.rawValue])
            var worst = 0, linear = 0.0
            for (input, output) in zip(fixture.inputs, expected) {
                let actual = stock.apply(SIMD3(input[0], input[1], input[2]))
                for c in 0..<3 {
                    worst = max(worst, abs(code(actual[c]) - code(output[c])))
                    linear = max(linear, abs(actual[c] - output[c]))
                }
            }
            #expect(worst <= 1 && linear < 5e-4, "\(id.rawValue) differs from spektrafilm by \(worst) codes, \(linear)")
        }
    }

    @Test func midGreyStaysNearlyNeutralAndHighlightsRollOff() throws {
        for id in FilmStockID.allCases {
            let film = try FilmStock.named(id)
            let grey = film.apply(SIMD3(repeating: 0.184))
            // Kodachrome keeps a warm grey: its own character, within 0.02.
            #expect(grey.max() - grey.min() < 0.02, "\(id.rawValue) tints mid grey: \(grey)")
            #expect(abs(grey.x - 0.18) < 0.01)
            // The scanner sets paper white near display white; HDR input reaches the shoulder.
            var previous = 0.0
            for stops in stride(from: -6.0, through: 6, by: 0.5) {
                let y = DoubleReference.luma(film.apply(SIMD3(repeating: 0.184 * exp2(stops))))
                // Rising until it meets paper white, where the scanner's level holds it.
                #expect((y > previous || y > 0.9) && y <= 1, "\(id.rawValue) at \(stops) stops: \(y)")
                previous = y
            }
            #expect(previous > 0.85)
        }
    }

    /// Film sees the scene before the split, so HDR highlights enter its shoulder.
    @Test func gpuMatchesTheDoubleReference() async throws {
        let engine = try RenderEngine()
        let values = try reference().inputs.map { SIMD3($0[0], $0[1], $0[2]) }
        let sdrValues = values.filter { $0.max() <= 1 }
        let sdr = try await engine.source(image: bitmap(sdrValues), domain: .sdr)
        let hdr = try await engine.source(image: bitmap(values), domain: .hdr)
        for id in FilmStockID.allCases {
            for strength in [Float(1), 0.4] {
                var edit = RenderAdjustments()
                edit.film.stock = id; edit.film.strength = strength; edit.film.grain = 0; edit.film.exposure = 0.5
                for (source, inputs, isSDR) in [(sdr, sdrValues, true), (hdr, values, false)] {
                    edit.hdr.enabled = !isSDR
                    let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
                    var worst = 0, gain = 0.0
                    for (i, value) in inputs.enumerated() {
                        let expected = DoubleReference.prepare(value, settings: edit, sdr: isSDR)
                        for c in 0..<3 { worst = max(worst, abs(code(Double(pixels.baseRGBA[i * 4 + c])) - code(expected.base[c]))) }
                        if !isSDR { gain = max(gain, abs(Double(pixels.gain[i]) - expected.gain)) }
                    }
                    #expect(worst <= 1, "\(id.rawValue) at \(strength), sdr \(isSDR): \(worst) codes from the double reference")
                    #expect(gain < 1e-4)
                }
            }
        }
    }

    /// The variance table reproduces the RMS of spektrafilm's stochastic grain.
    @Test func grainMatchesSpektrafilmRMS() throws {
        let fixture = try reference()
        for id in FilmStockID.allCases {
            let film = try FilmStock.named(id), grain = try #require(fixture.grain[id.rawValue])
            for (mean, rms) in zip(grain.densityMean, grain.densityRMS) {
                let density = SIMD3(mean[0], mean[1], mean[2])
                var sum = SIMD3<Double>.zero, squares = SIMD3<Double>.zero
                let count = 128 * 128
                for y in 0..<128 { for x in 0..<128 {
                    let site = FilmGrainSite(x: x, y: y, longEdge: grain.size, amount: 1)
                    let d = film.addGrain(density, at: site) - density
                    sum += d; squares += d * d
                } }
                for c in 0..<3 {
                    let measured = (squares[c] / Double(count) - pow(sum[c] / Double(count), 2)).squareRoot()
                    #expect(abs(measured / rms[c] - 1) < 0.05, "\(id.rawValue) channel \(c): \(measured) against \(rms[c])")
                }
            }
        }
    }

    /// Grain is deterministic per output pixel: the GPU draws the reference's noise, and a
    /// region of the render agrees with the whole.
    @Test func gpuGrainMatchesTheDoubleReference() async throws {
        let engine = try RenderEngine()
        let grey = SIMD3<Double>(0.184, 0.184, 0.184)
        let source = try await engine.source(image: bitmap([grey, grey]), domain: .sdr)
        var edit = RenderAdjustments()
        edit.hdr.enabled = false
        edit.film.stock = .portra400; edit.film.grain = 2; edit.film.exposure = 0
        let size = PixelSize(width: 4000, height: 2)
        let region = CGRect(x: 100, y: 0, width: 64, height: 2)
        let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, size: size, region: region))
        var worst = 0, codes = Set<Int>()
        for y in 0..<2 { for x in 0..<64 {
            let site = FilmGrainSite(x: 100 + x, y: y, longEdge: 4000, amount: 2)
            let expected = DoubleReference.prepare(grey, settings: edit, sdr: true, grain: site).base
            let i = y * 64 + x
            for c in 0..<3 { worst = max(worst, abs(code(Double(pixels.baseRGBA[i * 4 + c])) - code(expected[c]))) }
            codes.insert(code(Double(pixels.baseRGBA[i * 4 + 1])))
        } }
        #expect(worst <= 1, "\(worst) codes from the double reference")
        #expect(codes.count > 3, "grain should be visible at 4000 pixels: \(codes.sorted())")
        let narrower = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, size: size,
            region: CGRect(x: 132, y: 0, width: 8, height: 1)))
        for x in 0..<8 { for c in 0..<3 { #expect(narrower.baseRGBA[x * 4 + c] == pixels.baseRGBA[(32 + x) * 4 + c]) } }
    }

    /// An SDR-to-SDR look: the gain of an HDR source is kept.
    @Test func filmKeepsTheGain() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: bitmap([SIMD3(2.4, 1.6, 0.8), SIMD3(0.3, 0.2, 0.1)]), domain: .hdr)
        let original = RenderEngine.readPixels(try await engine.render(source, adjustments: RenderAdjustments()))
        var edit = RenderAdjustments()
        edit.film.stock = .portra400
        let filmed = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        #expect(filmed.gain == original.gain)
        #expect(filmed.baseRGBA != original.baseRGBA)
        edit.film.strength = 0
        #expect(RenderEngine.readPixels(try await engine.render(source, adjustments: edit)).baseRGBA == original.baseRGBA)
    }

    @Test func recipeResolvesTheFilm() throws {
        var recipe = Recipe(inputDomain: .sdr)
        #expect(try RenderAdjustments(recipe: recipe).film.isIdentity)
        recipe.setValue(.string("vision3-500t"), for: "look.film")
        recipe.setValue(.number(60), for: "look.filmStrength")
        let edit = try RenderAdjustments(recipe: recipe)
        #expect(edit.film.stock == .vision3500T && edit.film.strength == 0.6 && edit.film.grain == 1)
        #expect(!edit.wholeImageIsIdentity)
        #expect(try RenderAdjustments(recipe: recipe, options: RenderOptions(bypassedGroups: [.look])).film.isIdentity)
        recipe.setValue(.string("kodachrome"), for: "look.film")
        #expect(throws: RenderError.self) { try RenderAdjustments(recipe: recipe) }
    }

    /// Auto exposure meters the original photo, centre-weighted, to 18.4 % grey; the
    /// light edits still act before the film.
    @Test func autoExposureMetersTheOriginal() async throws {
        let engine = try RenderEngine()
        let grey = SIMD3<Double>(repeating: 0.046)
        let source = try await engine.source(image: bitmap(Array(repeating: grey, count: 16)), domain: .sdr)
        let metered = try await engine.filmMeter(source)
        #expect(abs(metered - 2) < 0.01, "a flat 4.6 % grey is two stops under: \(metered)")
        var recipe = Recipe(inputDomain: .sdr)
        recipe.setValue(.bool(false), for: "hdr.enabled")
        recipe.setValue(.string("portra400"), for: "look.film")
        recipe.setValue(.number(0), for: "look.filmGrain")
        recipe.setValue(.number(0.5), for: "tone.exposure")
        #expect(try await engine.resolvedAutomatic(source, recipe: recipe)["look.filmExposure"] == Double(metered))
        let automatic = RenderEngine.readPixels(try await engine.render(source, recipe: recipe))
        recipe.setValue(.number(Double(metered)), for: "look.filmExposure")
        let manual = RenderEngine.readPixels(try await engine.render(source, recipe: recipe))
        #expect(automatic.baseRGBA == manual.baseRGBA)
        let expected = DoubleReference.prepare(grey, settings: try RenderAdjustments(recipe: recipe), sdr: true).base
        for c in 0..<3 { #expect(abs(code(Double(automatic.baseRGBA[c])) - code(expected[c])) <= 1) }
        // Half a stop over the meter's grey, through the film.
        #expect(abs(expected.y - (try FilmStock.named(.portra400).apply(SIMD3(repeating: 0.184 * exp2(0.5)))).y) < 0.002)
    }

    /// Film exposes the scene: RAW develops without Apple's tone curve while a film is applied.
    @Test func activeFilmDevelopsRAWSceneLinear() throws {
        var recipe = Recipe(inputDomain: .rawEDR)
        #expect(try !SourceOptions(recipe: recipe).sceneLinear)
        recipe.setValue(.string("portra400"), for: "look.film")
        #expect(try SourceOptions(recipe: recipe).sceneLinear)
        #expect(try !SourceOptions(recipe: recipe, options: RenderOptions(bypassedGroups: [.look])).sceneLinear)
        recipe.setValue(.number(0), for: "look.filmStrength")
        #expect(try !SourceOptions(recipe: recipe).sceneLinear)
    }
}
