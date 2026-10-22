import Foundation
import CoreImage
import Metal
import Testing
import HyperDRRecipe
@testable import HyperDRRender

@Suite(.serialized) struct EditorRenderSupportTests {
    @Test func transientGroupsMasksAndAutomaticReadouts() async throws {
        let engine = try RenderEngine()
        let values: [SIMD4<Float>] = [SIMD4(0.05,0.05,0.05,1),SIMD4(0.5,0.5,0.5,1),SIMD4(0.9,0.9,0.9,1)]
        let image = CIImage(bitmapData:values.withUnsafeBytes { Data($0) },bytesPerRow:48,
            size:CGSize(width:3,height:1),format:.RGBAf,colorSpace:RenderEngine.workingColorSpace)
        let source = try await engine.source(image:image,domain:.sdr)
        let recipe = Recipe(inputDomain:.sdr,values:["tone.exposure":.number(1),"develop.tint":.number(35)])
        let before = recipe
        let bypass = RenderOptions(bypassedGroups:[.light,.hdr])
        let output = RenderEngine.readPixels(try await engine.render(source,recipe:recipe,options:bypass))
        #expect(output.baseRGBA == values.flatMap { [$0.x,$0.y,$0.z,$0.w] })
        #expect(output.gain == [0,0,0] && recipe == before)
        let mask = try await engine.effectMask(source,recipe:Recipe(inputDomain:.sdr),parameterID:"tone.highlights")
        let weights = RenderEngine.readTexture(mask.texture)
        #expect(mask.texture.pixelFormat == .r32Float && mask.outputSize == source.size)
        for (i,y) in [0.05,0.5,0.9].enumerated() {
            #expect(abs(Double(weights[i])-DoubleReference.smoothStep(0.4,1,y)) < 0.00001)
        }
        let disabledMask = try await engine.effectMask(source,recipe:recipe,parameterID:"tone.highlights",options:bypass)
        #expect(RenderEngine.readTexture(disabledMask.texture) == [0,0,0])
        let auto = try await engine.resolvedAutomatic(source,recipe:Recipe(inputDomain:.sdr))
        #expect(auto["hdr.expansionStart"] == 25)
        #expect((0.5...3).contains(try #require(auto["hdr.range"])))
        // Set parameters report nothing, unless the editor asks where Auto would be.
        let set = Recipe(inputDomain:.sdr,values:["hdr.range":.number(1),"hdr.expansionStart":.number(40)])
        #expect(try await engine.resolvedAutomatic(source,recipe:set).isEmpty)
        let marked = try await engine.resolvedAutomatic(source,recipe:set,includingSet:true)
        #expect(marked["hdr.range"] == auto["hdr.range"] && marked["hdr.expansionStart"] == 25)
        let hdr = try await engine.source(image:CIImage(color:CIColor(red:CGFloat(pow(2,3.72)),green:1,blue:1,
            colorSpace:RenderEngine.workingColorSpace)!).cropped(to:CGRect(x:0,y:0,width:1,height:1)),domain:.hdr)
        let report = try await engine.sourceReport(hdr)
        #expect(try #require(report.sourceValues["hdr.range"]) >= 3.72-0.00001)
        #expect(report.capabilities.contains("tone.exposure") && report.capabilities.contains("hdr.range"))
        #expect(!report.capabilities.contains("develop.tint") && !report.capabilities.contains("develop.sharpness"))
        let imported = try await engine.resolvedAutomatic(hdr,recipe:Recipe(inputDomain:.hdr))
        #expect(try #require(imported["hdr.range"]) >= 3.72-0.00001)
        let inactive = try await engine.effectMask(hdr,recipe:Recipe(inputDomain:.hdr),parameterID:"hdr.expansionStart")
        #expect(RenderEngine.readTexture(inactive.texture) == [0])
        let raw = Recipe(inputDomain:.rawEDR,values:["develop.tint":.number(100),"develop.sharpness":.number(90)])
        let normal = try SourceOptions(recipe:raw)
        let rawBypassed = try SourceOptions(recipe:raw,options:RenderOptions(bypassedGroups:[.color,.detail]))
        #expect(normal.raw.tint == 100 && normal.raw.sharpness == 0.9)
        #expect(rawBypassed.raw.tint == nil && rawBypassed.raw.sharpness == nil)
    }
}
