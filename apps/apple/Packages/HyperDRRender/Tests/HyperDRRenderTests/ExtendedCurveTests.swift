import Foundation
import CoreImage
import Testing
import HyperDRRecipe
@testable import HyperDRRender

struct ExtendedCurveTests {
    @Test func endpointCurvesFitSDRExtrapolateAndSampleAtTheirOwnInputs() async throws {
        let engine = try RenderEngine()
        func source(_ rgb: SIMD3<Float>) async throws -> RenderSource {
            let rgba = [rgb.x,rgb.y,rgb.z,Float(1)]
            let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) },bytesPerRow: 16,
                size: CGSize(width: 1,height: 1),format: .RGBAf,colorSpace: RenderEngine.workingColorSpace)
            return try await engine.source(image: image,domain: .hdr)
        }
        let red = try await source(.init(0.8,0.1,0.1))
        var edit = RenderAdjustments(); edit.hdr.range = 4; edit.hdr.coverage = 0
        edit.tone.curveSDR = try ToneCurve([0,0,0.5,0.8,1,1])
        let pixels = RenderEngine.readPixels(try await engine.render(red,adjustments: edit))
        for c in 0..<3 {
            #expect(pixels.baseRGBA[c] <= 1)
            let hdr = Double(pixels.baseRGBA[c])*exp2(Double(pixels.gain[c]))
            #expect(abs(hdr-(c == 0 ? 0.8 : 0.1)) < 0.00001)
        }
        let gray = try await source(.init(repeating: 2))
        edit = RenderAdjustments(); edit.hdr.range = 4; edit.hdr.coverage = 0; edit.tone.exposure = 4
        edit.tone.curveHDR = try ToneCurve([0,0,1,1,3,2])
        #expect(edit.tone.curveHDR.value(at: 6) == 5)
        let result = RenderEngine.readPixels(try await engine.render(gray,adjustments: edit))
        let prepared = DoubleReference.prepare(.init(repeating: 2),settings: edit,sdr: false)
        let expected = DoubleReference.hdrOutput(prepared,settings: edit.hdr,range: 4,shoulder: true,
            allowRolloff: true,tone: edit.tone)
        #expect(abs(Double(result.baseRGBA[0])*exp2(Double(result.gain[0]))-expected.base.x*exp2(expected.gains.x)) < 0.0001)
        var recipe = Recipe(inputDomain: .hdr)
        recipe.setValue(try ToneCurve([0,0,1,1,2,3]).parameterValue,for: "tone.curve")
        let beforeBoth = try await engine.pickCurve(gray,recipe: recipe,parameterID: "tone.curve",point: .init(x: 0.5,y: 0.5))
        let beforeHDR = try await engine.pickCurve(gray,recipe: recipe,parameterID: "tone.curveHDR",point: .init(x: 0.5,y: 0.5))
        #expect(abs(beforeBoth.coordinate-2) < 0.00001)
        #expect(abs(beforeHDR.coordinate-3) < 0.00001)
        recipe = Recipe(inputDomain: .hdr); recipe.setValue(.number(100),for: "hdr.sdrRolloff")
        let beforeSDR = try await engine.pickCurve(gray,recipe: recipe,parameterID: "tone.curveSDR",point: .init(x: 0.5,y: 0.5))
        #expect(abs(beforeSDR.coordinate-1) < 1e-12)
    }

    @Test func HDRAndEndpointCurvesMatchTheirReference() async throws {
        let engine = try RenderEngine()
        let values: [Float] = [0.03,0.18,0.5,0.8,1,2,4]
        let rgba = values.flatMap { [$0,$0,$0,Float(1)] }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: values.count*16,
            size: CGSize(width: values.count, height: 1), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
        let source = try await engine.source(image: image, domain: .hdr)
        let curve = try ToneCurve([0,0, 0.5,0.7, 1,1, 3,2])
        #expect(curve.value(at: 1) == 1 && curve.value(at: 3) == 2)
        for mode in 0..<4 {
            var edit = RenderAdjustments(); edit.hdr.range = 4; edit.hdr.coverage = 0
            if mode == 0 { edit.tone.curve = curve }
            if mode == 1 { edit.tone.curveSDR = try ToneCurve([0,0, 0.5,0.35, 1,1]) }
            if mode == 2 { edit.tone.curveHDR = curve }
            if mode == 3 {
                edit.tone.curveRed = try ToneCurve([0,0, 0.5,0.7, 1,1]); edit.tone.parametricLights = 0.5
            }
            let pixels = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            for (i,value) in values.enumerated() {
                let prepared = DoubleReference.prepare(.init(repeating: Double(value)), settings: edit, sdr: false)
                let expected = DoubleReference.hdrOutput(prepared, settings: edit.hdr, range: 4, shoulder: false,
                    allowRolloff: true, tone: edit.tone)
                for c in 0..<3 {
                    let base = Double(pixels.baseRGBA[4*i+c])
                    let gain = Double(pixels.gain[i*pixels.gainChannelCount+(pixels.gainChannelCount == 1 ? 0 : c)])
                    #expect(abs(base-expected.base[c]) < 0.00005)
                    #expect(abs(base*exp2(gain)-expected.base[c]*exp2(expected.gains[c])) < 0.0001)
                }
            }
        }
        let recipe = Recipe(inputDomain: .hdr)
        let sample = try await engine.pickCurve(source,recipe: recipe,parameterID: "tone.curveRed",point: .init(x: 0.2,y: 0.5))
        #expect(abs(sample.coordinate-DoubleReference.curveCoordinate(0.18)) < 0.0001)
        var tone = ToneAdjustments(); tone.curveHDR = try ToneCurve([0,0, 0.5,0.1, 1,1])
        let dark = DoubleReference.RGB(repeating: 0.18)
        #expect(DoubleReference.endpointCurves(base: dark, hdr: dark, tone: tone).hdr == dark)
    }
}
