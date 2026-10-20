import Foundation
import CoreImage
import Metal
import Testing
import simd
@testable import HyperDRRender

private func displayImage(_ rgb: SIMD3<Float>, space: CGColorSpace) -> CIImage {
    displayImage([rgb],space:space)
}
private func displayImage(_ rgb: [SIMD3<Float>], space: CGColorSpace) -> CIImage {
    let pixels = rgb.map { SIMD4($0,1) }
    return CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:16*rgb.count,
                   size:CGSize(width:rgb.count,height:1),format:.RGBAf,colorSpace:space)
}
private extension RenderEngine {
    func displayTestTexture(_ image: CIImage, space: CGColorSpace) throws -> RenderedTexture {
        RenderedTexture(texture:try rasterize(image,space:space),colorSpace:space)
    }
    func displayTestRGB(_ image: CIImage, space: CGColorSpace) throws -> SIMD3<Float> {
        displayRGB(try rasterize(image,space:space))
    }
}
private func displayRGB(_ texture: any MTLTexture) -> SIMD3<Float> {
    let p = RenderEngine.readTexture(texture)
    return SIMD3(p[0],p[1],p[2])
}
private func reconstructDisplay(_ pair: DisplayGainPair, weight: Float) -> SIMD3<Float> {
    let base = displayRGB(pair.base), pixels = RenderEngine.readTexture(pair.gain)
    let gain = pair.gainChannelCount == 1 ? SIMD3(repeating:pixels[0]) : SIMD3(pixels[0],pixels[1],pixels[2])
    let scale = SIMD3(exp2(weight*gain.x),exp2(weight*gain.y),exp2(weight*gain.z))
    return pair.gainToP3*((pair.p3ToGain*base+pair.baseOffset)*scale-pair.alternateOffset)
}

@Suite(.serialized) struct DisplayPairTests {
    @Test func generatedPairUsesIdentityFastPath() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image:displayImage(SIMD3(4,2,1),space:RenderEngine.workingColorSpace),domain:.hdr)
        let original = try await engine.render(source)
        let pair = try await engine.displayPair(original,source:source)
        #expect(pair.base === original.base && pair.gain === original.gain)
        #expect(pair.isSimpleGain && pair.gainChannelCount == 1)
        #expect(pair.baseHeadroom == 0 && abs(pair.alternateHeadroom-2) < 0.00001)
        #expect(simd_length(reconstructDisplay(pair,weight:1)-SIMD3(4,2,1)) < 0.00001)
    }

    @Test func nativeISOAndLegacyNormalizeWithoutChangingExportPair() async throws {
        let engine = try RenderEngine()
        let space = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let b = SIMD3<Float>(0.3,0.4,0.5), g = SIMD3<Float>(1,2,0.5)
        let oB = SIMD3<Float>(1/64,1/32,1/128), oA = SIMD3<Float>(0.02,0.01,0.03)
        let fullHDR = (b+oB)*SIMD3(exp2(g.x),exp2(g.y),exp2(g.z))-oA
        let baseImage = displayImage([b,b],space:space)
        let hdrImage = displayImage([fullHDR,b+oB-oA],space:space).settingContentHeadroom(4)
        let baseTexture = try await engine.displayTestTexture(baseImage,space:space)
        // gamma = 2: stored codes are (g/4)^2, decoded by the square root.
        let gainImage = displayImage([(g/4)*(g/4),.zero],space:RenderEngine.workingColorSpace)
        let gainSource = try await engine.source(image:gainImage,domain:.sdr)
        var tags = ["HDRToneMap:BaseColorIsWorkingColor":"True","HDRToneMap:BaseHeadroom":"0","HDRToneMap:AlternateHeadroom":"4"]
        for c in 0..<3 {
            let prefix = "HDRToneMap:ChannelMetadata[\(c)]."
            for (key,value) in [("GainMapMin",Float(0)),("GainMapMax",4),("Gamma",2),("BaseOffset",oB[c]),("AlternateOffset",oA[c])] {
                tags[prefix+key] = String(value)
            }
        }
        func source(_ standard: AuthoredGainMap.Standard) -> RenderSource {
            let metadata = AuthoredGainMap(standard:standard,auxiliaryInfo:tags as NSDictionary,image:gainImage,
                channelCount:3,baseColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,alternateColorSpace:nil,
                auxiliaryColorSpace:nil,tags:standard == .iso ? tags : [:])
            return RenderSource(id:UUID(),renderID:UUID(),origin:nil,domain:.dual,size:PixelSize(width:2,height:1),nativeSize:PixelSize(width:2,height:1),
                authoredGainMap:metadata,hdrImage:hdrImage,authoredBaseImage:baseImage,rawSettings:nil,
                texture:baseTexture.texture,baseSpace:space,gainTexture:gainSource.texture)
        }
        let isoSource = source(.iso), export = try await engine.render(isoSource)
        let rawGain = RenderEngine.readTexture(export.gain)
        let normalized = try await engine.displayPair(export,source:isoSource)
        #expect(!normalized.isSimpleGain && normalized.gainChannelCount == 3)
        #expect(normalized.baseOffset == oB && normalized.alternateOffset == oA)
        #expect(normalized.baseHeadroom == 0 && normalized.alternateHeadroom == 4)
        #expect(simd_length(displayRGB(normalized.gain)-g) < 0.00001)
        // Independent whole-color ICC conversion checks the matrices at a mixed
        // ISO weight, as well as both endpoints. No CPU grade formula is reused.
        for weight: Float in [0,0.5,1] {
            let scale = SIMD3(exp2(weight*g.x),exp2(weight*g.y),exp2(weight*g.z))
            let native = (b+oB)*scale-oA
            let expected = try await engine.displayTestRGB(displayImage(native,space:space),space:RenderEngine.workingColorSpace)
            #expect(simd_length(reconstructDisplay(normalized,weight:weight)-expected) < 0.0001)
        }
        // Resampling encoded gamma codes would give g/sqrt(2), not g/2.
        let reduced = try await engine.render(isoSource,recipe:.init(inputDomain:.dual),size:PixelSize(width:1,height:1))
        let reducedDisplay = try await engine.displayPair(reduced,source:isoSource)
        #expect(simd_length(displayRGB(reducedDisplay.gain)-g/2) < 0.00001)
        let repeated = try await engine.displayPair(export,source:isoSource)
        #expect(RenderEngine.readTexture(repeated.gain) == RenderEngine.readTexture(normalized.gain))
        #expect(RenderEngine.readTexture(export.gain) == rawGain && export.gain === gainSource.texture)
        if case .authored = export.encoding {} else { Issue.record("Display changed the export encoding") }
        let legacySource = source(.apple), legacyExport = try await engine.render(legacySource)
        let legacy = try await engine.displayPair(legacyExport,source:legacySource)
        let expectedHDR = try await engine.displayTestRGB(hdrImage,space:RenderEngine.workingColorSpace)
        let expectedBase = try await engine.displayTestRGB(baseImage,space:RenderEngine.workingColorSpace)
        #expect(simd_length(reconstructDisplay(legacy,weight:0)-expectedBase) < 0.0001)
        #expect(simd_length(reconstructDisplay(legacy,weight:1)-expectedHDR) < 0.0001)
        #expect(legacy.gainChannelCount == 3 && legacy.baseOffset == legacy.alternateOffset)
        #expect(legacy.baseHeadroom == 0 && legacy.alternateHeadroom == 2)
        var hdrEdit = RenderAdjustments(); hdrEdit.hdr.strength = 0.5
        let editedLegacy = try await engine.render(legacySource,adjustments:hdrEdit)
        let editedDisplay = try await engine.displayPair(editedLegacy,source:legacySource)
        #expect(editedDisplay.gain === editedLegacy.gain && editedDisplay.alternateHeadroom == 2)
    }
}
