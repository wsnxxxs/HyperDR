import CoreImage
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRRender

private func hdrLookImage(_ values: [SIMD3<Float>], width: Int, height: Int) -> CIImage {
    let rgba = values.map { SIMD4($0, 1) }
    return CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width*16,
        size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
}
private func lookHDR(_ p: PlanePixels, _ i: Int, offset: Float = 0) -> SIMD3<Float> {
    SIMD3((0..<3).map { c in (p.baseRGBA[4*i+c]+offset)*exp2(p.gain[i*p.gainChannelCount+(p.gainChannelCount == 1 ? 0 : c)])-offset })
}

@Suite(.serialized) struct LookHDRTests {
    @Test func boundedLUTProtectsActualHighlightsAndKeepsItsSDRLook() async throws {
        let engine = try RenderEngine()
        let levels: [Float] = [0.05, 0.2, 0.55, 0.8, 1, 1.01, 2, 4, 8]
        let source = try await engine.source(image: hdrLookImage(levels.map { SIMD3(repeating: $0) },
            width: levels.count, height: 1), domain: .hdr)
        var edit = RenderAdjustments()
        edit.look.lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n0.6 0.6 0.6\n")
        edit.look.input = .displayP3; edit.look.output = .displayP3
        for strength: Float in [0.25, 0.75, 1] {
            edit.look.strength = strength; edit.hdr.enabled = true
            let on = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            edit.hdr.enabled = false
            let off = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            #expect(on.baseRGBA == off.baseRGBA)
            #expect(off.gain.allSatisfy { $0 == 0 })
            for i in levels.indices where levels[i] >= 1 {
                #expect(abs(lookHDR(on,i).max()-levels[i]) < 0.00002)
            }
            #expect(on.baseRGBA[4] < levels[1], "the look still changes midtone brightness")
        }
    }

    @Test(arguments: FilmStockID.allCases)
    func everyStockPreservesCapturedHighlightPeak(stock: FilmStockID) async throws {
        let engine = try RenderEngine()
        let levels: [Float] = [0.18, 1.25, 2, 4, 8]
        let source = try await engine.source(image: hdrLookImage(levels.map { SIMD3(repeating: $0) },
            width: levels.count, height: 1), domain: .hdr)
        var edit = RenderAdjustments()
        edit.film.stock = stock; edit.film.exposure = 0; edit.effects.grain = 0; edit.effects.halation = 0
        let p = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        for i in 1..<levels.count {
            #expect(abs(lookHDR(p,i).max()-levels[i]) < 0.00005, "\(stock) highlight \(levels[i])")
        }
    }

    @Test func stockGrainKeepsTheCapturedCeiling() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: hdrLookImage([SIMD3(repeating: 4)],width: 1,height: 1),domain: .hdr)
        var edit = RenderAdjustments()
        edit.film.stock = .portra400; edit.film.exposure = 0; edit.effects.grain = 1
        edit.effects.halation = 0; edit.hdr.range = 2
        let frame = try await engine.render(source,adjustments: edit,size: PixelSize(width: 4000,height: 4000),
            region: CGRect(x: 1950,y: 1950,width: 100,height: 100))
        let pixels = RenderEngine.readPixels(frame)
        let offset: Float
        if case let .pairedLog2(value, _) = frame.encoding { offset = value } else { offset = 0 }
        let peak = (0..<10000).map { lookHDR(pixels,$0,offset: offset).max() }.max()!
        #expect(peak <= 4.00001 && peak > 3.9)
    }

    @Test func logToSDRHasHDRAndNoHiddenSpatialGlow() async throws {
        try await checkLocality(ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_FUJI_LUT_DIR"] != nil))
    func officialFujiLUTsKeepHDRAndZeroHalationIsLocal() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HYPERDR_FUJI_LUT_DIR"]!)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "cube" }
        #expect(files.count >= 12)
        for file in files { try await checkLocality(ColorLUT(contentsOf: file)) }
    }

    private func checkLocality(_ lut: ColorLUT) async throws {
        let engine = try RenderEngine(), w = 48, h = 32
        let dark = [SIMD3<Float>](repeating: SIMD3(repeating: 0.02), count: w*h)
        var lamp = dark
        for y in 12..<20 { for x in 20..<28 { lamp[y*w+x] = SIMD3(repeating: 4) } }
        let a = try await engine.source(image: hdrLookImage(dark,width: w,height: h), domain: .rawEDR)
        let b = try await engine.source(image: hdrLookImage(lamp,width: w,height: h), domain: .rawEDR)
        var edit = RenderAdjustments()
        edit.look.lut = lut; edit.look.input = .flog2cFGamutC; edit.look.output = .rec709
        edit.look.exposure = 1.32; edit.effects.halation = 0
        for grain: Float in [0, 1] {
            edit.effects.grain = grain
            let plain = RenderEngine.readPixels(try await engine.render(a,adjustments: edit))
            let frame = try await engine.render(b,adjustments: edit)
            let bright = RenderEngine.readPixels(frame)
            let offset: Float
            if case let .pairedLog2(value, _) = frame.encoding { offset = value } else { offset = 0 }
            #expect(lookHDR(bright,16*w+24,offset: offset).max() > 3.8, "\(lut.title): bounded LUT erased HDR")
            for y in 0..<h { for x in 0..<w where !(12..<20).contains(y) || !(20..<28).contains(x) {
                let i = y*w+x
                for c in 0..<3 {
                    #expect(abs(bright.baseRGBA[4*i+c]-plain.baseRGBA[4*i+c]) < 1e-6)
                    #expect(abs(lookHDR(bright,i,offset: offset)[c]-lookHDR(plain,i,offset: offset)[c]) < 1e-6,
                            "\(lut.title): a point LUT or grain created a halo outside the light")
                }
            } }
        }
    }
}
