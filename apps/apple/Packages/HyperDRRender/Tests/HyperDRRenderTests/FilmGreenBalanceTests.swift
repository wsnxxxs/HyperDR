import CoreImage
import Foundation
import Testing
@testable import HyperDRRender

private typealias GreenRGB = SIMD3<Double>
private let kodakGreens: [GreenRGB] = [GreenRGB(0.08, 0.2, 0.05), GreenRGB(0.3, 0.35, 0.12)]
private let surroundingPalette: [GreenRGB] = [
    GreenRGB(0.12, 0.25, 0.55), GreenRGB(0.45, 0.3, 0.22), GreenRGB(0.25, 0.15, 0.1),
    GreenRGB(0.8, 0.65, 0.02), GreenRGB(0.8, 0.2, 0.015), GreenRGB(0.01, 0.03, 0.8),
    GreenRGB(0.7, 0.02, 0.6), GreenRGB(0.015, 0.6, 0.7), GreenRGB(repeating: 0.184)
]
private func greenHue(_ rgb: GreenRGB) -> Double {
    let lab = DoubleReference.oklab(rgb)
    return atan2(lab.z, lab.y)
}
private func greenShift(_ reference: GreenRGB, _ output: GreenRGB) -> Double {
    atan2(sin(greenHue(reference) - greenHue(output)), cos(greenHue(reference) - greenHue(output)))
}

@Suite(.serialized) struct FilmGreenBalanceTests {
    @Test(arguments: FilmStockID.allCases)
    func surroundingPaletteAndOtherPrintChainsKeepTheirCharacter(stock: FilmStockID) throws {
        let film = try FilmStock.named(stock)
        let inputs = film.greenBalance > 0 ? surroundingPalette : surroundingPalette + kodakGreens
        for stops in [-3.0, 0, 3] {
            for input in inputs.map({ $0 * exp2(stops) }) {
                let before = DoubleReference.fitP3(film.fromRaw(film.filmRaw(input)))
                #expect(film.apply(input) == before, "\(stock): an unrelated colour or print chain changed")
            }
        }
    }

    @Test func sharedPaperGreensImproveWhileKeepingWarmthAndTone() throws {
        let stocks = try FilmStockID.allCases.map { try FilmStock.named($0) }.filter { $0.greenBalance > 0 }
        #expect(stocks.count == 8)
        for film in stocks {
            for input in kodakGreens {
                let before = DoubleReference.fitP3(film.fromRaw(film.filmRaw(input))), after = film.apply(input)
                let oldShift = greenShift(input, before), newShift = greenShift(input, after)
                if oldShift > 6 * .pi / 180 {
                    #expect(newShift > 0.15 * oldShift && newShift < 0.5 * oldShift,
                            "\(film.id): retain some warmth, without keeping the excessive yellow shift")
                }
                #expect(abs(DoubleReference.luma(after) - DoubleReference.luma(before)) < 1e-8)
                #expect(after.min() >= 0 && after.max() <= 1)
            }
        }
    }

    @Test func greenMembershipHasNoVisibleBoundary() throws {
        let film = try FilmStock.named(.portra400)
        var previous = GreenRGB.zero
        for step in 0...400 {
            let input = GreenRGB(0.3, 0.28 + Double(step) * 0.0002, 0.1)
            let before = DoubleReference.fitP3(film.fromRaw(film.filmRaw(input)))
            let compensation = film.apply(input) - before
            if step > 0 {
                let jump = compensation - previous
                #expect(max(abs(jump.x), abs(jump.y), abs(jump.z)) < 0.001)
            }
            previous = compensation
        }
    }

    @Test func colouredPhysicalEffectsAreNotHueCorrected() throws {
        let film = try FilmStock.named(.portra400)
        let input = kodakGreens[0], raw = film.filmRaw(input)
        let glow = raw * GreenRGB(1.8, 1.1, 0.9), strength = GreenRGB(0.03, 0.01, 0.003)
        let plain = DoubleReference.fitP3(film.fromRaw(raw)), balanced = film.apply(input)
        for amount in [0.0, 1.0] {
            let site = FilmGrainSite(x: 13, y: 17, longEdge: 6000, amount: amount)
            let physical = DoubleReference.fitP3(film.fromRaw((raw + strength * glow) / (1 + strength), grain: site))
            let result = film.apply(input, grain: site, halation: (glow, strength))
            let error = (result - balanced) - (physical - plain)
            #expect(max(abs(error.x), abs(error.y), abs(error.z)) < 1e-10)
        }
    }

    @Test func gpuMatchesTheSamePaletteAndExposure() async throws {
        let values = kodakGreens + surroundingPalette
        let rgba = values.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: rgba.count * 16,
            size: CGSize(width: rgba.count, height: 1), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
        let engine = try RenderEngine(), source = try await engine.source(image: image, domain: .hdr)
        for stock in FilmStockID.allCases {
            var edit = RenderAdjustments()
            edit.hdr.enabled = false; edit.film.stock = stock; edit.film.exposure = 0
            edit.effects.grain = 0; edit.effects.halation = 0
            let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            let film = try FilmStock.named(stock)
            for (i, input) in values.enumerated() {
                let expected = film.apply(input)
                for c in 0..<3 { #expect(abs(Double(pixels.baseRGBA[4*i+c]) - expected[c]) < 0.00002, "\(stock) colour \(i)") }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_GREEN_REVIEW"] != nil))
    func fixedExposureColourEvidence() throws {
        struct Record: Encodable { let stock: String; let index: Int; let input, before, after: [Double] }
        func array(_ rgb: GreenRGB) -> [Double] { [rgb.x, rgb.y, rgb.z] }
        var records: [Record] = []
        for id in FilmStockID.allCases {
            let film = try FilmStock.named(id)
            for (i, input) in (kodakGreens + surroundingPalette).enumerated() {
                records.append(Record(stock: id.rawValue, index: i, input: array(input),
                    before: array(DoubleReference.fitP3(film.fromRaw(film.filmRaw(input)))), after: array(film.apply(input))))
            }
        }
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HYPERDR_GREEN_REVIEW"]!)
        try JSONEncoder().encode(records).write(to: url)
    }
}
