import CoreImage
import Foundation
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct FilmPrecisionTests {
    private typealias RGB = SIMD3<Double>

    private func image(_ values: [RGB], width: Int, height: Int) -> CIImage {
        let pixels = values.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
        return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
    }

    private func code(_ value: Double) -> Int {
        let x = min(1, max(0, value))
        let encoded = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        return Int((encoded * 1023).rounded())
    }

    /// Independent double evaluation of only this pixel's complete scatter support.
    /// Reflecting at an image edge is retained when the support reaches that edge.
    private func reference(_ values: [RGB], width: Int, height: Int, x: Int, y: Int,
                           film: FilmStock, edit: RenderAdjustments, sdr: Bool) -> RGB {
        let halo = edit.film.sourceHalo(size: PixelSize(width: width, height: height))
        let left = max(0, x - halo), top = max(0, y - halo)
        let right = min(width, x + halo + 1), bottom = min(height, y + halo + 1)
        var raw: [RGB] = []
        for sy in top..<bottom { for sx in left..<right {
            var rgb = DoubleReference.point(values[sy * width + sx], operation: .exposure,
                                             value: Double(edit.tone.exposure), sdr: sdr)
            rgb = DoubleReference.point(rgb, operation: .highlights, value: Double(edit.tone.highlights))
            raw.append(film.filmRaw(rgb * exp2(Double(edit.film.exposure ?? 0))))
        } }
        let scattered = film.scatter(raw, width: right - left, height: bottom - top, longEdge: max(width, height))
        var reference = DoubleReference.point(values[y * width + x], operation: .exposure,
                                              value: Double(edit.tone.exposure), sdr: sdr)
        reference = DoubleReference.point(reference, operation: .highlights, value: Double(edit.tone.highlights))
        return film.renderFromRaw(scattered[(y - top) * (right - left) + x - left], reference: reference)
    }

    /// These ordinary SDR colours exposed a 2–4 code error in the half-float
    /// scatter passes, even though film exposure never came near half's ceiling.
    @Test(arguments: FilmStockID.allCases)
    func scatterPreservesSDRShadowCodes(stock: FilmStockID) async throws {
        let width = 4096, height = 16
        var state: UInt64 = 0x1177ffcc
        func random() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(UInt32(truncatingIfNeeded: state) >> 8) * 0x1p-24
        }
        var values: [RGB] = []
        for _ in 0..<(width * height) {
            let scale = exp2(random() * 12 - 12)
            values.append(RGB(Double(scale * random()), Double(scale * random()), Double(scale * random())))
        }
        let site: (x: Int, y: Int)
        switch stock {
        case .portra400: site = (2790, 3)
        case .gold200: site = (1023, 1)
        case .velvia100: site = (1719, 3)
        case .kodachrome64: site = (6, 0)
        case .vision3500T: site = (1554, 8)
        // The worst pixel of the whole field for each stock added once scatter ran in float32.
        case .portra160: site = (1391, 1)
        case .portra800: site = (1727, 0)
        case .portra800Push1: site = (2655, 0)
        case .portra800Push2: site = (2763, 0)
        case .ektar100: site = (478, 1)
        case .ultramax400: site = (1591, 0)
        case .pro400h: site = (596, 0)
        case .c200: site = (284, 1)
        case .xtra400: site = (1394, 0)
        case .provia100f: site = (2080, 0)
        case .ektachrome100: site = (1520, 1)
        case .vision350D: site = (1419, 0)
        case .vision3250D: site = (1757, 0)
        case .vision3200T: site = (3621, 2)
        case .verita200d: site = (2230, 0)
        }
        let engine = try RenderEngine()
        let source = try await engine.source(image: image(values, width: width, height: height), domain: .sdr)
        var edit = RenderAdjustments()
        edit.hdr.enabled = false
        edit.film.stock = stock; edit.film.exposure = 0; edit.effects.grain = 0; edit.effects.halation = 0
        let region = CGRect(x: site.x - 1, y: max(0, site.y - 1), width: 3, height: 3)
        let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, region: region))
        let film = try FilmStock.named(stock)
        var worst = 0
        for y in 0..<3 { for x in 0..<3 {
            let expected = reference(values, width: width, height: height,
                x: Int(region.minX) + x, y: Int(region.minY) + y, film: film, edit: edit, sdr: true)
            for c in 0..<3 {
                let actual = Double(pixels.baseRGBA[(y * 3 + x) * 4 + c])
                #expect(actual.isFinite)
                worst = max(worst, abs(code(actual) - code(expected[c])))
            }
        } }
        #expect(worst <= 1, "\(stock.rawValue) scatter differs by \(worst) SDR codes")
        #expect(pixels.gain.allSatisfy { $0 == 0 })
    }

    /// A valid 10000-nit highlight and the declared exposure controls produce
    /// linear film exposure above 65504. Clipping it before scatter shifted the
    /// surrounding print by 65 codes, even with HDR output switched off.
    @Test func scatterRetainsBrightHDRExposure() async throws {
        let width = 3000, height = 3
        var values = [RGB](repeating: RGB(repeating: Double(Float(0.01))), count: width * height)
        for y in 0..<height { values[y * width + 1500] = RGB(repeating: Double(Float(49.26))) }
        let engine = try RenderEngine()
        let source = try await engine.source(image: image(values, width: width, height: height), domain: .hdr)
        var edit = RenderAdjustments()
        edit.hdr.enabled = false; edit.tone.exposure = 4; edit.tone.highlights = 1
        edit.film.stock = .portra400; edit.film.exposure = 3; edit.effects.grain = 0; edit.effects.halation = 0
        let region = CGRect(x: 1490, y: 0, width: 21, height: height)
        let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, region: region))
        let film = try FilmStock.named(.portra400)
        var worst = 0
        for y in 0..<height { for x in 0..<21 {
            let expected = reference(values, width: width, height: height,
                x: x + 1490, y: y, film: film, edit: edit, sdr: false)
            for c in 0..<3 {
                let actual = Double(pixels.baseRGBA[(y * 21 + x) * 4 + c])
                #expect(actual.isFinite)
                worst = max(worst, abs(code(actual) - code(expected[c])))
            }
        } }
        #expect(worst <= 1, "bright HDR scatter differs by \(worst) SDR codes")
        #expect(pixels.gain.allSatisfy { $0 == 0 })
    }
}
