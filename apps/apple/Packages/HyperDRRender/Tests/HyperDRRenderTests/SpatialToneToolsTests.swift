import Foundation
import CoreImage
import Testing
import HyperDRRecipe
@testable import HyperDRRender

struct SpatialToneToolsTests {
    @Test func dehazeAndClarityMatchTheReferenceAndKeepRegionsStable() async throws {
        let size = PixelSize(width: 64,height: 48)
        var rgb: [DoubleReference.RGB] = (0..<(size.width*size.height)).map { i in
            let x = i%size.width,y = i/size.width
            let value = 0.24+0.3*Double(x)/63+0.035*sin(Double(x+y)*0.9)
            return .init(repeating: value)
        }
        rgb[rgb.count-1] = .init(repeating: 4)
        let rgba = rgb.flatMap { [Float($0.x),Float($0.y),Float($0.z),Float(1)] }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) },bytesPerRow: size.width*16,
            size: CGSize(width: size.width,height: size.height),format: .RGBAf,colorSpace: RenderEngine.workingColorSpace)
        let engine = try RenderEngine(), source = try await engine.source(image: image,domain: .hdr)
        let dark = DoubleReference.RGB(repeating: 0.3)
        #expect(DoubleReference.dehaze(dark,air: .init(repeating: 0.8),transmission: 0.6,amount: 0) == dark)
        #expect(DoubleReference.dehaze(dark,air: .init(repeating: 0.8),transmission: 0.6,amount: 1).x < dark.x)
        #expect(DoubleReference.clarity(dark,lowFrequency: log2(0.25+1e-4),amount: 0) == dark)
        #expect(DoubleReference.clarity(dark,lowFrequency: log2(0.25+1e-4),amount: 1).x > dark.x)
        for (haze,clarity): (Float,Float) in [(0.6,0),(-0.6,0),(0,0.8),(0,-0.8),(0.6,0.8)] {
            var edit = RenderAdjustments(); edit.hdr.range = 4; edit.hdr.coverage = 0
            edit.tone.dehaze = haze; edit.tone.clarity = clarity
            let map = DoubleReference.toneSpatialAnalysis(rgb,base: rgb,size: size,tone: edit.tone,color: edit.color,sdr: false)
            let pixels = RenderEngine.readPixels(try await engine.render(source,adjustments: edit))
            if haze != 0 && clarity != 0 {
                let measured = try await engine.analysis(source,adjustments: edit)
                let expected = DoubleReference.spatialAnalysis(rgb,size: size,settings: edit,sdr: false)
                #expect(abs(Double(measured.peaks.x)-expected.peaks.x) < 0.0001)
            }
            for i in [21,80,1030,2053,3000,3071] {
                let expected = DoubleReference.prepare(rgb[i],settings: edit,sdr: false,spatial: map.samples[i],air: map.air)
                let actual = Double(pixels.baseRGBA[4*i])*exp2(Double(pixels.gain[i*pixels.gainChannelCount]))
                #expect(abs(actual-expected.base.x*exp2(expected.gain)) < 0.00005)
            }
            let region = CGRect(x: 16,y: 12,width: 16,height: 12)
            let detail = RenderEngine.readPixels(try await engine.render(source,adjustments: edit,region: region))
            for y in 0..<12 { for x in 0..<16 {
                #expect(abs(detail.baseRGBA[(y*16+x)*4]-pixels.baseRGBA[((y+12)*64+x+16)*4]) < 0.000001)
            }}
        }
    }
}
