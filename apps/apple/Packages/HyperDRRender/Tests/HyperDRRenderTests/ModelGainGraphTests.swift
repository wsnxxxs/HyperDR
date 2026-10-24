import Foundation
import CoreImage
import CoreML
import Metal
import Testing
import HyperDRRecipe
@testable import HyperDRRender

private func aiImage(_ pixels: [SIMD3<Float>]) -> CIImage {
    let values = pixels.map { SIMD4($0,1) }
    return CIImage(bitmapData:values.withUnsafeBytes { Data($0) },bytesPerRow:values.count*16,
        size:CGSize(width:values.count,height:1),format:.RGBAf,colorSpace:RenderEngine.workingColorSpace)
}
private func aiPrediction(_ source: RenderSource, _ values: [Float], device: any MTLDevice) throws -> ModelGainPrediction {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r32Float,width:values.count,height:1,mipmapped:false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let texture = try #require(device.makeTexture(descriptor:descriptor))
    values.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,values.count,1),mipmapLevel:0,
        withBytes:$0.baseAddress!,bytesPerRow:values.count*4) }
    return ModelGainPrediction(sourceID:source.id,modelID:"test/analysis-768",gain:texture)
}
@Suite(.serialized) struct ModelGainGraphTests {
    @Test func pendingGuidedGainAndHDRGates() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try RenderEngine(device:device)
        let input: [SIMD3<Float>] = [SIMD3(repeating:0.05),SIMD3(repeating:0.5),SIMD3(repeating:0.9)]
        let source = try await engine.source(image:aiImage(input),domain:.sdr)
        var edit = RenderAdjustments(); edit.hdr.source = .ai; edit.hdr.range = 4
        let pending = try await engine.render(source,adjustments:edit)
        #expect(pending.aiPending && RenderEngine.readPixels(pending).gain == [0,0,0])
        edit.hdr.modelGain = try aiPrediction(source,[0.2,1,2],device:device)
        let ready = try await engine.render(source,adjustments:edit)
        #expect(!ready.aiPending)
        let expected = DoubleReference.modelGain([0.2,1,2],guide:input.map { DoubleReference.luma(SIMD3<Double>($0)) },size:source.size)
        let result = RenderEngine.readPixels(ready)
        for i in expected.indices { #expect(abs(Double(result.gain[i])-expected[i]) < 0.00001) }
        edit.hdr.expansionStart = 0.7
        let gated = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        let reference = DoubleReference.modelGain([0.2,1,2],guide:input.map { DoubleReference.luma(SIMD3<Double>($0)) },size:source.size,expansionStart:0.7)
        for i in reference.indices { #expect(abs(Double(gated.gain[i])-reference[i]) < 0.00001) }
        #expect(gated.gain[0] == 0 && gated.baseRGBA == result.baseRGBA)
        edit.hdr.strength = 2; edit.hdr.range = 1; edit.hdr.expansionStart = nil
        let limited = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(limited.baseRGBA == result.baseRGBA)
        // The asymptotic shoulder can round to the ceiling (or one float32
        // ULP above it) on another GPU. Check its independent numeric result.
        let expectedPeak = DoubleReference.softShoulder(
            Double(result.baseRGBA[8])*exp2(Double(result.gain[2])*2), range: 1, active: true)
        #expect(abs(Double(limited.baseRGBA[8]*exp2(limited.gain[2]))-expectedPeak) < 1e-6)
        edit.hdr.enabled = false
        let off = try await engine.render(source,adjustments:edit)
        #expect(!off.aiPending && RenderEngine.readPixels(off).gain == [0,0,0])
    }

    @Test(.needsModel) func rawUsesUneditedBaseAndCapturedMaximum() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try RenderEngine(device:device)
        let source = try await engine.source(image:aiImage([SIMD3(4,2,1)]),domain:.rawEDR)
        let base = try await engine.sdrBase(source)
        let baseSource = try await engine.source(image:base,domain:.sdr)
        let pixels = RenderEngine.readPixels(try await engine.render(baseSource))
        #expect(zip(pixels.baseRGBA, [Float(1),0.5,0.25,1]).allSatisfy { abs($0-$1) < 1e-6 })
        var edit = RenderAdjustments(); edit.hdr.source = .capturedAI; edit.hdr.range = 4
        edit.hdr.modelGain = try aiPrediction(source,[1],device:device)
        let low = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(abs(low.gain[0]-2) < 0.00001)
        edit.hdr.modelGain = try aiPrediction(source,[3],device:device)
        // An immutable prediction's identity includes model version/analysis scale.
        edit.hdr.modelGain = ModelGainPrediction(sourceID:source.id,modelID:"test-v2",gain:edit.hdr.modelGain!.gain)
        let high = RenderEngine.readPixels(try await engine.render(source,adjustments:edit))
        #expect(abs(high.gain[0]-3) < 0.00001 && high.baseRGBA == low.baseRGBA)
        let provider = try CoreMLModelGainProvider(computeUnits:.cpuOnly,device:device,analysisLongSide:64)
        let predicted = try await engine.predictModelGain(source,provider:provider)
        let cached = try await engine.predictModelGain(source,provider:provider)
        #expect(predicted.sourceID == source.id && predicted.modelID == provider.modelID && predicted.gain === cached.gain)
        let alternative = try CoreMLModelGainProvider(computeUnits:.cpuOnly,device:device,analysisLongSide:32)
        let otherModel = try await engine.predictModelGain(source,provider:alternative)
        let retained = try await engine.predictModelGain(source,provider:provider)
        #expect(otherModel.modelID != predicted.modelID && retained.gain === predicted.gain)
        #expect(await engine.modelPredictionCache.count == 2)
        do { _ = try CoreMLModelGainProvider(device:nil); Issue.record("Missing device accepted") }
        catch ModelGainError.deviceUnavailable {}
        let sdrPrediction = try await engine.predictModelGain(baseSource,provider:provider)
        #expect(sdrPrediction.sourceID == baseSource.id)
        let hdr = try await engine.source(image:aiImage([SIMD3(4,2,1)]),domain:.hdr)
        do { _ = try await engine.sdrBase(hdr); Issue.record("HDR accepted AI base inference") }
        catch RenderError.invalidAdjustment {}
        do { _ = try await engine.render(hdr,adjustments:edit); Issue.record("HDR accepted AI source") }
        catch RenderError.invalidAdjustment {}
    }
}
