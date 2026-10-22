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
    struct Scatter: Decodable { let width, height: Int; let pixelMicrons: Double; let scattered: [[Double]] }
    let grain: [String: Grain]
    let halation: [String: Halation]
    let scatter: Scatter
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

    /// Film sees the scene before the split, so HDR highlights enter its shoulder. Per pixel:
    /// no halation (a strip this small has none to speak of, but its map's sampling has a
    /// width) and no scatter (none at this size).
    @Test func gpuMatchesTheDoubleReference() async throws {
        let engine = try RenderEngine()
        let values = try reference().inputs.map { SIMD3($0[0], $0[1], $0[2]) }
        let sdrValues = values.filter { $0.max() <= 1 }
        let sdr = try await engine.source(image: bitmap(sdrValues), domain: .sdr)
        let hdr = try await engine.source(image: bitmap(values), domain: .hdr)
        for id in FilmStockID.allCases {
            for strength in [Float(1), 0.4] {
                var edit = RenderAdjustments()
                edit.film.stock = id; edit.film.strength = strength; edit.film.grain = 0; edit.film.exposure = 0.5; edit.film.halation = 0
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
            let components = film.halationComponents(longEdge: case_.size)
            let low = (case_.size - case_.square) / 2, high = low + case_.square
            func inside(_ i: Int) -> Double { (low..<high).contains(i) ? 1 : 0 }
            // The square is separable: each Gaussian covers it by the product of its axes.
            func axis(_ i: Int, _ taps: (radius: Int, taps: [SIMD3<Double>])) -> SIMD3<Double> {
                (-taps.radius...taps.radius).reduce(.zero) { $0 + taps.taps[$1 + taps.radius] * inside(i + $1) }
            }
            var worst = SIMD3<Double>.zero
            for (i, expected) in case_.logExposure.enumerated() {
                let x = case_.start + i
                var cover = SIMD3<Double>.zero
                for component in components {
                    cover += axis(x, FilmStock.taps(component, truncate: FilmStock.halationTruncate, weighted: true))
                        * axis(case_.row, FilmStock.taps(component, truncate: FilmStock.halationTruncate))
                }
                let raw = background + (square - background) * inside(x) * inside(case_.row)
                let glow = background + (square - background) * cover
                let actual = (raw + strength * glow) / (1 + strength)
                for c in 0..<3 { worst[c] = max(worst[c], abs(actual[c] - pow(10, expected[c]))) }
            }
            let peak = square
            for c in 0..<3 { #expect(worst[c] / peak[c] < 1e-3, "\(name) channel \(c): \(worst[c] / peak[c]) of the peak") }
        }
    }

    /// spektrafilm's in-emulsion scatter: a Gaussian core and an exponential tail.
    @Test func scatterMatchesSpektrafilm() throws {
        let fixture = try reference().scatter, film = try FilmStock.named(.portra400)
        let width = fixture.width, height = fixture.height
        var raw = [SIMD3<Double>](repeating: SIMD3(repeating: 0.02), count: width * height)
        for y in 4..<12 { for x in 6..<16 { raw[y * width + x] = SIMD3(40, 30, 20) } }
        raw[18 * width + 24] = SIMD3(200, 150, 90)
        for y in 0..<height { for x in 32..<width { raw[y * width + x] += SIMD3(repeating: Double(x - 32) * 0.375) } }
        let longEdge = Int((film.pitch(longEdge: 1) / fixture.pixelMicrons).rounded())
        let scattered = film.scatter(raw, width: width, height: height, longEdge: longEdge)
        var worst = 0.0
        for (i, expected) in fixture.scattered.enumerated() { for c in 0..<3 {
            worst = max(worst, abs(scattered[i][c] - expected[c]) / max(expected[c], 1e-3))
        } }
        #expect(worst < 1e-5, "\(worst) relative to spektrafilm")
        #expect(scattered[18 * width + 25].x > 1, "the point's tail spreads beyond it")
        // Energy is kept: the field's total barely changes (reflected edges).
        let total = raw.reduce(.zero, +), after = scattered.reduce(.zero, +)
        for c in 0..<3 { #expect(abs(after[c] / total[c] - 1) < 1e-3) }
    }

    /// Scatter on the GPU, at the render's resolution: the reference's blur of the film
    /// exposure, and a region (with its halo) agrees with the whole render.
    @Test func gpuScatterMatchesTheDoubleReference() async throws {
        let engine = try RenderEngine()
        let width = 900, height = 40
        var values = [SIMD3<Double>](repeating: SIMD3(0.05, 0.06, 0.04), count: width * height)
        for y in 0..<height { for x in 0..<width where (x / 3 + y / 3) % 2 == 0 { values[y * width + x] = SIMD3(0.4, 0.3, 0.2) } }
        for y in 14..<22 { for x in 440..<452 { values[y * width + x] = SIMD3(30, 26, 20) } }
        let rgba = values.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
        let source = try await engine.source(image: image, domain: .hdr)
        var edit = RenderAdjustments()
        edit.hdr.enabled = false
        edit.film.stock = .portra400; edit.film.grain = 0; edit.film.exposure = 0; edit.film.halation = 0
        // A 2700-pixel render of the 900-pixel field (the source is sampled at a third).
        let size = PixelSize(width: 2700, height: 120)
        #expect(edit.film.sourceHalo(size: size) > 3)
        let region = CGRect(x: 1250, y: 30, width: 160, height: 60)
        let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, size: size, region: region))
        let film = try FilmStock.named(.portra400)
        // The reference samples the source as the render does: bilinear, at pixel centres.
        func sample(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let u = (Double(x) + 0.5) / 3 - 0.5, v = (Double(y) + 0.5) / 3 - 0.5
            let x0 = Int(u.rounded(.down)), y0 = Int(v.rounded(.down)), fx = u - Double(x0), fy = v - Double(y0)
            func at(_ x: Int, _ y: Int) -> SIMD3<Double> { values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)] }
            return (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
        }
        let halo = edit.film.sourceHalo(size: size)
        let around = region.insetBy(dx: CGFloat(-halo), dy: CGFloat(-halo)).intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let aw = Int(around.width), ah = Int(around.height)
        var raw = [SIMD3<Double>]()
        for y in 0..<ah { for x in 0..<aw { raw.append(film.filmRaw(sample(Int(around.minX) + x, Int(around.minY) + y))) } }
        let scattered = film.scatter(raw, width: aw, height: ah, longEdge: size.width)
        var worst = 0, unscattered = 0
        for y in 0..<Int(region.height) { for x in 0..<Int(region.width) {
            let i = (y + Int(region.minY - around.minY)) * aw + x + Int(region.minX - around.minX)
            let expected = DoubleReference.fitP3(film.fromRaw(scattered[i])), plain = DoubleReference.fitP3(film.fromRaw(raw[i]))
            for c in 0..<3 {
                let actual = code(Double(pixels.baseRGBA[(y * Int(region.width) + x) * 4 + c]))
                worst = max(worst, abs(actual - code(expected[c]))); unscattered = max(unscattered, abs(actual - code(plain[c])))
            }
        } }
        #expect(worst <= 1, "\(worst) codes from the double reference")
        #expect(unscattered > 8, "scatter softens the highlight's edge: \(unscattered) codes")
        let whole = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, size: size))
        var seam: Float = 0
        for y in 0..<Int(region.height) { for x in 0..<Int(region.width) { for c in 0..<3 {
            seam = max(seam, abs(whole.baseRGBA[((y + 30) * size.width + x + 1250) * 4 + c] - pixels.baseRGBA[(y * Int(region.width) + x) * 4 + c]))
        } } }
        #expect(seam == 0, "a region matches the whole render: \(seam)")
    }

    /// Halation on the GPU: with one analysis cell per pixel, the map is the reference's
    /// convolution (narrowed for its sampling) sampled by a cubic B-spline, and the glow
    /// reddens the dark field next to a highlight.
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
        let raw = values.map { film.filmRaw($0) }
        let map = FilmStock.blur(raw, width: width, height: height, components: film.halationMapComponents(cells: width),
                                 truncate: FilmStock.halationTruncate)
        let scattered = film.scatter(raw, width: width, height: height, longEdge: width)
        #expect(edit.film.sourceHalo(size: PixelSize(width: width, height: height)) > 0)
        // At texel centres the B-spline weighs 1/6, 2/3, 1/6, clamped at the edges.
        let spline = [1.0 / 6, 2.0 / 3, 1.0 / 6]
        var worst = 0
        for y in 0..<height { for x in 320..<400 {
            var glow = SIMD3<Double>.zero
            for dy in -1...1 { for dx in -1...1 {
                glow += spline[dy + 1] * spline[dx + 1] * map[min(max(y + dy, 0), height - 1) * width + min(max(x + dx, 0), width - 1)]
            } }
            let exposed = (scattered[y * width + x] + strength * glow) / (1 + strength)
            let expected = DoubleReference.fitP3(film.fromRaw(exposed))
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

    /// At full size the halation map (768 cells, eight pixels each here) and its B-spline
    /// give the stock's halation of the scattered exposure, computed at full resolution:
    /// within a few per cent of the glow, for a lamp on a cell's edge and on its centre.
    @Test(arguments: [2994, 2998]) func fullSizeHalationFollowsTheStock(x0: Int) async throws {
        let engine = try RenderEngine()
        let width = 6000, height = 400, lamp = 12, y0 = 194, row = 200
        let dark = SIMD3<Double>(repeating: 0.03), bright = SIMD3<Double>(repeating: 40)
        var rgba = [SIMD4<Float>](repeating: SIMD4(0.03, 0.03, 0.03, 1), count: width * height)
        for y in y0..<(y0 + lamp) { for x in x0..<(x0 + lamp) { rgba[y * width + x] = SIMD4(40, 40, 40, 1) } }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
        let source = try await engine.source(image: image, domain: .hdr)
        var edit = RenderAdjustments()
        edit.hdr.enabled = false
        edit.film.stock = .vision3500T; edit.film.grain = 0; edit.film.exposure = 0; edit.film.antihalation = false
        let region = CGRect(x: 2800, y: row, width: 400, height: 1)
        let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, region: region))
        let film = try FilmStock.named(.vision3500T), strength = film.halationStrength(edit.film)
        let low = film.filmRaw(dark), high = film.filmRaw(bright)
        typealias Taps = (radius: Int, taps: [SIMD3<Double>])
        func convolve(_ a: Taps, _ b: Taps) -> Taps {
            var taps = [SIMD3<Double>](repeating: .zero, count: 2 * (a.radius + b.radius) + 1)
            for i in a.taps.indices { for j in b.taps.indices { taps[i + j] += a.taps[i] * b.taps[j] } }
            return (a.radius + b.radius, taps)
        }
        // The lamp is a square: each separable Gaussian covers it by the product of its axes.
        func axis(_ i: Int, _ start: Int, _ taps: Taps) -> SIMD3<Double> {
            (-taps.radius...taps.radius).reduce(.zero) { $0 + ((start..<(start + lamp)).contains(i + $1) ? taps.taps[$1 + taps.radius] : .zero) }
        }
        let scatter = film.scatterComponents(longEdge: width), halation = film.halationComponents(longEdge: width)
        var worst = 0, peak = 0
        for x in Int(region.minX)..<Int(region.maxX) {
            var scattered = SIMD3<Double>.zero, glow = SIMD3<Double>.zero
            for s in scatter {
                let sh = FilmStock.taps(s, truncate: FilmStock.scatterTruncate, weighted: true), sv = FilmStock.taps(s, truncate: FilmStock.scatterTruncate)
                scattered += axis(x, x0, sh) * axis(row, y0, sv)
                for h in halation {
                    let hh = FilmStock.taps(h, truncate: FilmStock.halationTruncate, weighted: true), hv = FilmStock.taps(h, truncate: FilmStock.halationTruncate)
                    glow += axis(x, x0, convolve(hh, sh)) * axis(row, y0, convolve(hv, sv))
                }
            }
            let exposed = (low + (high - low) * scattered + strength * (low + (high - low) * glow)) / (1 + strength)
            let expected = DoubleReference.fitP3(film.fromRaw(exposed)), plain = DoubleReference.fitP3(film.fromRaw(low + (high - low) * scattered))
            for c in 0..<3 {
                let actual = code(Double(pixels.baseRGBA[(x - Int(region.minX)) * 4 + c]))
                worst = max(worst, abs(actual - code(expected[c]))); peak = max(peak, code(expected[c]) - code(plain[c]))
            }
        }
        #expect(peak > 400, "the glow is visible: \(peak) codes")
        #expect(Double(worst) < 0.03 * Double(peak), "\(worst) codes from the full-resolution halation, glow \(peak)")
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
