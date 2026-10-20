import Foundation
import CoreImage
import ImageIO
import Metal
import Testing
import HyperDRRecipe
@testable import HyperDRRender

private final class ExportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bands: [ExportStripe] = []
    private var header: ExportRenderReport?
    func prepare(_ value: ExportRenderReport) { lock.withLock { header = value } }
    func consume(_ value: ExportStripe) { lock.withLock { #expect(header != nil); bands.append(value) } }
    var stripes: [ExportStripe] { lock.withLock { bands } }
    var rgb: [Float] { stripes.flatMap(\.baseRGB) }
    var gain: [Float] { stripes.flatMap(\.gain) }
}
private func exportImage(_ pixels: [SIMD4<Float>], width: Int) -> CIImage {
    CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:width*16,
        size:CGSize(width:width,height:pixels.count/width),format:.RGBAf,colorSpace:RenderEngine.workingColorSpace)
}
private let isoCapabilities = ExportPairCapabilities(supportsThreeChannelGain:true)
private func closeExport(_ a: [Float], _ b: [Float], tolerance: Float = 0.00003) {
    #expect(a.count == b.count)
    for (x,y) in zip(a,b) { #expect(abs(x-y) < tolerance) }
}
private func collect(_ engine: RenderEngine, _ source: RenderSource, recipe: Recipe, request: ExportRenderRequest,
                     rows: Int = 1) async throws -> (ExportRenderReport,ExportCollector) {
    let collector = ExportCollector()
    let report = try await engine.renderExportStripes(source,recipe:recipe,request:request,rows:rows,
        prepare:{ collector.prepare($0) },consume:{ collector.consume($0) })
    return (report,collector)
}

@Suite(.serialized) struct ExportRenderingTests {
    @Test func identityCeilingSDRAndAIContract() async throws {
        let engine = try RenderEngine()
        let size = PixelSize(width:2,height:2)
        let pixels: [SIMD4<Float>] = [SIMD4(4,2,1,1),SIMD4(1,1,1,1),SIMD4(2,1,0.5,1),SIMD4(0.2,0.3,0.4,1)]
        let source = try await engine.source(image:exportImage(pixels,width:2),domain:.hdr)
        let recipe = Recipe(inputDomain:.hdr)
        let (header,plain) = try await collect(engine,source,recipe:recipe,
            request:ExportRenderRequest(photoSize:size,capabilities:isoCapabilities))
        let expected = RenderEngine.readPixels(try await engine.render(source,recipe:recipe))
        closeExport(plain.rgb,(0..<4).flatMap { Array(expected.baseRGBA[$0*4..<$0*4+3]) })
        closeExport(plain.gain,expected.gain)
        #expect(header.gain?.channelCount == 1 && header.resplitReasons.isEmpty)
        let (ceilingReport,limited) = try await collect(engine,source,recipe:recipe,
            request:ExportRenderRequest(photoSize:size,ceilingStops:1,capabilities:isoCapabilities))
        #expect(!header.ceilingApplied && header.rangeBeforeCeiling == header.rangeAfterCeiling)
        #expect(ceilingReport.ceilingApplied && ceilingReport.rangeBeforeCeiling > 1 && ceilingReport.rangeAfterCeiling == 1)
        #expect(ceilingReport.resplitReasons.isEmpty && ceilingReport.sourceProvenance == ceilingReport.provenance)
        closeExport(limited.rgb,plain.rgb) // independent H1 property
        #expect(limited.gain[0] < 1 && limited.gain[0] > 0.9)
        let (_,sdr) = try await collect(engine,source,recipe:recipe,
            request:ExportRenderRequest(photoSize:size,gamut:.sRGB,includesGain:false,capabilities:isoCapabilities))
        closeExport(sdr.rgb,plain.rgb) // ABI base remains P3, no duplicate gamut conversion
        #expect(sdr.gain.isEmpty)
        let sample = try await engine.source(image:exportImage([SIMD4(0.5,0.5,0.5,1)],width:1),domain:.sdr)
        let ai = Recipe(inputDomain:.sdr,hdrSource:.ai)
        let sink = ExportCollector()
        do {
            _ = try await engine.renderExportStripes(sample,recipe:ai,
                request:ExportRenderRequest(photoSize:sample.size,capabilities:isoCapabilities),
                prepare:{ sink.prepare($0) },consume:{ sink.consume($0) })
            Issue.record("AI export accepted missing prediction")
        } catch RenderError.aiNotAvailable {}
        #expect(sink.stripes.isEmpty)
        let (_,again) = try await collect(engine,source,recipe:recipe,
            request:ExportRenderRequest(photoSize:size,capabilities:isoCapabilities),rows:2)
        closeExport(again.rgb,plain.rgb); closeExport(again.gain,plain.gain)
    }

    @Test func authoredOffsetsCapabilitiesAndFrameReference() async throws {
        let engine = try RenderEngine()
        let b = SIMD3<Float>(0.4,0.3,0.2), gains = SIMD3<Float>(1,2,0.5)
        let ob = SIMD3<Float>(repeating:1/64), oa = SIMD3<Float>(repeating:1/32)
        let h = (b+ob)*SIMD3(exp2(gains.x),exp2(gains.y),exp2(gains.z))-oa
        let base = try await engine.source(image:exportImage([SIMD4(b,1)],width:1),domain:.sdr)
        let map = try await engine.source(image:exportImage([SIMD4(gains/4,1)],width:1),domain:.sdr)
        var tags = ["HDRToneMap:BaseColorIsWorkingColor":"True","HDRToneMap:BaseHeadroom":"0","HDRToneMap:AlternateHeadroom":"3"]
        for c in 0..<3 {
            let prefix = "HDRToneMap:ChannelMetadata[\(c)]."
            for (key,value) in [("GainMapMin",Float(0)),("GainMapMax",4),("Gamma",1),("BaseOffset",ob[c]),("AlternateOffset",oa[c])] {
                tags[prefix+key] = String(value)
            }
        }
        let meta = AuthoredGainMap(standard:.iso,auxiliaryInfo:tags as NSDictionary,
            image:exportImage([SIMD4(gains/4,1)],width:1),channelCount:3,
            baseColorSpace:CGColorSpace(name:CGColorSpace.displayP3)!,alternateColorSpace:nil,auxiliaryColorSpace:nil,tags:tags)
        let source = RenderSource(id:UUID(),renderID:UUID(),origin:nil,domain:.dual,size:base.size,nativeSize:base.size,
            authoredGainMap:meta,hdrImage:exportImage([SIMD4(h,1)],width:1),authoredBaseImage:exportImage([SIMD4(b,1)],width:1),
            rawSettings:nil,texture:base.texture,baseSpace:RenderEngine.workingColorSpace,gainTexture:map.texture)
        let recipe = Recipe(inputDomain:.dual)
        let (author,preserved) = try await collect(engine,source,recipe:recipe,
            request:ExportRenderRequest(photoSize:base.size,capabilities:isoCapabilities))
        #expect(author.provenance == .authored && author.resplitReasons.isEmpty)
        #expect(author.gain?.baseOffset == ob && author.gain?.alternateOffset == oa)
        closeExport(preserved.rgb,[b.x,b.y,b.z]); closeExport(preserved.gain,[gains.x,gains.y,gains.z])
        let (converted,split) = try await collect(engine,source,recipe:recipe,
            request:ExportRenderRequest(photoSize:base.size,capabilities:ExportPairCapabilities(supportsThreeChannelGain:false)))
        #expect(converted.resplitReasons == [.writerCarriesOneChannel])
        #expect(converted.sourceProvenance == .authored && converted.provenance == .resplit)
        let reference = DoubleReference.exportSplit(SIMD3(Double(h.x),Double(h.y),Double(h.z)))
        closeExport(split.rgb,[Float(reference.base.x),Float(reference.base.y),Float(reference.base.z)])
        closeExport(split.gain,[Float(reference.gain)])
        let linear709 = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let nativeBase = CIImage(bitmapData:[SIMD4(b,1)].withUnsafeBytes { Data($0) },bytesPerRow:16,
            size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:linear709)
        let nativeHDR = CIImage(bitmapData:[SIMD4(h,1)].withUnsafeBytes { Data($0) },bytesPerRow:16,
            size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:linear709)
        let nativeMeta = AuthoredGainMap(standard:.iso,auxiliaryInfo:tags as NSDictionary,image:meta.image,
            channelCount:3,baseColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,
            alternateColorSpace:nil,auxiliaryColorSpace:nil,tags:tags)
        let native = RenderSource(id:UUID(),renderID:UUID(),origin:nil,domain:.dual,size:base.size,nativeSize:base.size,
            authoredGainMap:nativeMeta,hdrImage:nativeHDR,authoredBaseImage:nativeBase,rawSettings:nil,
            texture:base.texture,baseSpace:linear709,gainTexture:map.texture)
        let (icc,iccOutput) = try await collect(engine,native,recipe:recipe,
            request:ExportRenderRequest(photoSize:base.size,capabilities:isoCapabilities))
        #expect(icc.resplitReasons == [.unsupportedGainWorkingGamut])
        let iccReference = DoubleReference.exportSplit(DoubleReference.matrix(
            SIMD3(Double(h.x),Double(h.y),Double(h.z)),DoubleReference.from709))
        closeExport(iccOutput.rgb,[Float(iccReference.base.x),Float(iccReference.base.y),Float(iccReference.base.z)])
        closeExport(iccOutput.gain,[Float(iccReference.gain)])
        let png = try captionPNG()
        let frame = FrameSnapshot(canvasSize:PixelSize(width:6,height:7),photo:ExportRect(x:2,y:2,width:1,height:1),
            paper:SIMD3(0.8,0.7,0.6),shadow:FrameShadow(opacity:0.3,sigma:0.8,offset:SIMD2(0,1)),
            caption:FrameCaption(png:png,rect:ExportRect(x:0,y:5,width:6,height:2)))
        let (framed,output) = try await collect(engine,source,recipe:recipe,
            request:ExportRenderRequest(photoSize:base.size,capabilities:isoCapabilities,frame:frame),rows:2)
        #expect(framed.presentationFrame && framed.framePhoto == frame.photo)
        #expect(framed.resplitReasons == [.frameRequiresNeutralPair] && framed.gain?.channelCount == 1)
        for y in 0..<7 { for x in 0..<6 {
            let i = y*6+x
            if x==2 && y==2 { closeExport(Array(output.rgb[i*3..<i*3+3]),split.rgb); continue }
            #expect(output.gain[i] == 0) // independent SDR-frame property
            let expected = DoubleReference.framePixel(x:x,y:y,frame:frame,
                captionRGB:SIMD3(repeating:1),captionAlpha:y>=5 ? 128.0/255 : 0)
            closeExport(Array(output.rgb[i*3..<i*3+3]),[Float(expected.x),Float(expected.y),Float(expected.z)])
        } }
    }

    @Test func alphaMatteAndThrowingConsumer() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image:exportImage([SIMD4(0.2,0.1,0.05,0.5)],width:1),domain:.sdr)
        let (_,result) = try await collect(engine,source,recipe:Recipe(inputDomain:.sdr,values:["hdr.enabled":.bool(false)]),
            request:ExportRenderRequest(photoSize:source.size,includesGain:false,capabilities:isoCapabilities))
        closeExport(result.rgb,[0.2,0.1,0.05]) // existing black-matte alpha rule
        enum Stopped: Error { case consume }
        do {
            _ = try await engine.renderExportStripes(source,recipe:Recipe(inputDomain:.sdr),
                request:ExportRenderRequest(photoSize:source.size,capabilities:isoCapabilities),
                prepare:{ _ in },consume:{ _ in throw Stopped.consume })
            Issue.record("Consumer error swallowed")
        } catch Stopped.consume {}
    }

    private func captionPNG() throws -> Data {
        let bytes = Data((0..<12).flatMap { _ in [UInt8(255),255,255,128] })
        let image = CGImage(width:6,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:24,
            space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
            provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
