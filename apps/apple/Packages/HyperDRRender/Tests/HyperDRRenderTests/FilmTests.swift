import Foundation
import CoreImage
import Testing
import HyperDRRecipe
@testable import HyperDRRender

private struct FilmReference: Decodable {
    struct Grain: Decodable { let size: Int; let densityMean, densityRMS: [[Double]] }
    struct Halation: Decodable {
        let size, square, row, start: Int
        let level, background: Double
        let removed: Bool
        let logExposure: [[Double]]
    }
    let inputs: [[Double]]
    let outputs: [String: [[Double]]]
    let grain: [String: Grain]
    let halation: [String: Halation]
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

    /// The halation kernel against spektrafilm's film exposure across a bright square. Its
    /// recursive blur approximates the Gaussian's far tail to about 1e-3 of the peak.
    @Test func halationMatchesSpektrafilm() throws {
        let fixture = try reference()
        #expect(fixture.halation.count == 2)
        for (name, case_) in fixture.halation {
            let id = try #require(FilmStockID(rawValue: name)), film = try FilmStock.named(id)
            var settings = FilmAdjustments(); settings.stock = id; settings.antihalation = !case_.removed
            let strength = film.halationStrength(settings)
            let background = film.filmRaw(SIMD3(repeating: case_.background)), square = film.filmRaw(SIMD3(repeating: case_.level))
            let kernel = film.halationKernel(longEdge: case_.size), r = kernel.radius, side = 2 * r + 1
            let low = (case_.size - case_.square) / 2, high = low + case_.square
            func inside(_ i: Int) -> Double { (low..<high).contains(i) ? 1 : 0 }
            var worst = SIMD3<Double>.zero
            for (i, expected) in case_.logExposure.enumerated() {
                let x = case_.start + i
                var cover = 0.0
                for dy in -r...r { for dx in -r...r {
                    cover += Double(kernel.weights[(dy + r) * side + dx + r]) * inside(x + dx) * inside(case_.row + dy)
                } }
                let raw = background + (square - background) * inside(x) * inside(case_.row)
                let glow = background + (square - background) * cover
                let actual = (raw + strength * glow) / (1 + strength)
                for c in 0..<3 { worst[c] = max(worst[c], abs(actual[c] - pow(10, expected[c]))) }
            }
            let peak = square
            for c in 0..<3 { #expect(worst[c] / peak[c] < 1e-3, "\(name) channel \(c): \(worst[c] / peak[c]) of the peak") }
        }
    }

    /// Halation on the GPU: with one analysis cell per pixel, the map equals the reference's
    /// convolution, and the glow reddens the dark field next to a highlight.
    @Test func gpuHalationMatchesTheDoubleReference() async throws {
        let engine = try RenderEngine()
        let width = 720, height = 24, dark = SIMD3<Double>(repeating: 0.05), bright = SIMD3<Double>(repeating: 40)
        var values = [SIMD3<Double>](repeating: dark, count: width * height)
        for y in 4..<20 { for x in 352..<368 { values[y * width + x] = bright } }
        let rgba = values.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
        let source = try await engine.source(image: image, domain: .hdr)
        var edit = RenderAdjustments()
        edit.film.stock = .vision3500T; edit.film.grain = 0; edit.film.exposure = 0; edit.film.antihalation = false
        let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        let film = try FilmStock.named(.vision3500T), strength = film.halationStrength(edit.film)
        let kernel = film.halationKernel(longEdge: width), r = kernel.radius, side = 2 * r + 1
        let raw = values.map { film.filmRaw($0) }
        func mirror(_ i: Int, _ n: Int) -> Int { min(max(i < 0 ? -i : i >= n ? 2 * (n - 1) - i : i, 0), n - 1) }
        var worst = 0
        for y in 0..<height { for x in 320..<400 {
            var glow = SIMD3<Double>.zero
            for dy in -r...r { for dx in -r...r {
                glow += Double(kernel.weights[(dy + r) * side + dx + r]) * raw[mirror(y + dy, height) * width + mirror(x + dx, width)]
            } }
            let v = values[y * width + x]
            let expected = DoubleReference.fitP3(film.apply(v, halation: (glow, strength)))
            for c in 0..<3 { worst = max(worst, abs(code(Double(pixels.baseRGBA[(y * width + x) * 4 + c])) - code(expected[c]))) }
        } }
        #expect(worst <= 1, "\(worst) codes from the double reference")
        edit.film.halation = 0
        let none = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        let near = (12 * width + 348) * 4
        #expect(pixels.baseRGBA[near] > none.baseRGBA[near] + 0.01, "a red glow beside the highlight")
        #expect(pixels.baseRGBA[near] - none.baseRGBA[near] > pixels.baseRGBA[near + 2] - none.baseRGBA[near + 2])
        edit.film.halation = 1; edit.film.antihalation = true
        let layered = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        #expect(layered.baseRGBA[near] < pixels.baseRGBA[near], "the antihalation layer holds the glow back")
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
        #expect(edit.film.halation == 1 && edit.film.antihalation)
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
