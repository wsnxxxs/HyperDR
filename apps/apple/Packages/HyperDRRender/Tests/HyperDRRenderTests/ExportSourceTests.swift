import Foundation
import CoreImage
import ImageIO
import Metal
import Testing
import Darwin
import HyperDRRecipe
@testable import HyperDRRender

private final class StreamPixels: @unchecked Sendable {
    private let lock = NSLock()
    private var rgbStorage: [Float] = [], gainStorage: [Float] = []
    func consume(_ stripe: ExportStripe) {
        lock.withLock { rgbStorage.append(contentsOf:stripe.baseRGB); gainStorage.append(contentsOf:stripe.gain) }
    }
    var rgb: [Float] { lock.withLock { rgbStorage } }
    var gain: [Float] { lock.withLock { gainStorage } }
}
private let streamCaps = ExportPairCapabilities(supportsThreeChannelGain:true)
private func compareBands(_ a: [Float], _ b: [Float], scale: Float = 1, label: String = "") {
    #expect(a.count == b.count)
    let error = zip(a,b).reduce(Float(0)) { max($0,abs($1.0-$1.1)*scale) }
    if !label.isEmpty { print("STREAM_DIFF \(label) max=\(error)") }
    #expect(error <= 1.0/1023)
}
private func licensedRAW() -> URL {
    var root = URL(fileURLWithPath:#filePath)
    for _ in 0..<7 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
}

@Suite(.serialized) struct ExportSourceTests {
    @Test func orientedRasterAndAuthoredPairMatchWhole() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let width = 73, height = 49
        let bytes = Data((0..<width*height).flatMap { i in [UInt8((i*37)%256),UInt8((i*11)%256),UInt8((i*7)%256),255] })
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
            provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let url = folder.appendingPathComponent("oriented.tiff")
        let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.tiff" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation:6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let engine = try RenderEngine()
        let full = try await engine.load(url)
        let lazy = try await engine.openExportSource(url)
        #expect(lazy.id == full.id && lazy.nativeSize == PixelSize(width:height,height:width))
        let tile = try await engine.materializeExportRegion(lazy,outputSize:lazy.nativeSize,
                                                           region:CGRect(x:0,y:17,width:height,height:11))
        #expect(tile.texture.height <= 15 && tile.texture.height < full.texture.height)
        let recipe = Recipe(inputDomain:full.domain,values:["tone.exposure":.number(0.7),"tone.shadows":.number(25)])
        let request = ExportRenderRequest(photoSize:PixelSize(width:37,height:55),capabilities:streamCaps)
        let a = StreamPixels(), b = StreamPixels()
        _ = try await engine.renderExportStripes(full,recipe:recipe,request:request,rows:11,prepare:{ _ in },consume:{ a.consume($0) })
        _ = try await engine.renderExportStripes(lazy,recipe:recipe,request:request,rows:11,prepare:{ _ in },consume:{ b.consume($0) })
        compareBands(a.rgb,b.rgb,label:"raster_base"); compareBands(a.gain,b.gain,scale:0.25,label:"raster_gain")
        // A real system-written gain-map fixture exercises cropped native gain decoding.
        let heic = folder.appendingPathComponent("pair.heic")
        let base = CIImage(cgImage:image)
        let hdr = base.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:4,y:0,z:0,w:0),
            "inputGVector":CIVector(x:0,y:4,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:4,w:0)])
            .settingContentHeadroom(4)
        try CIContext().writeHEIFRepresentation(of:base,to:heic,format:.RGBA8,
            colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!,options:[.hdrImage:hdr])
        let author = try await engine.load(heic)
        let lazyAuthor = try await engine.openExportSource(heic)
        #expect(author.domain == .dual && lazyAuthor.domain == .dual)
        let authorRequest = ExportRenderRequest(photoSize:PixelSize(width:61,height:43),capabilities:streamCaps)
        let c = StreamPixels(), d = StreamPixels()
        _ = try await engine.renderExportStripes(author,recipe:Recipe(inputDomain:.dual),request:authorRequest,
            rows:9,prepare:{ _ in },consume:{ c.consume($0) })
        _ = try await engine.renderExportStripes(lazyAuthor,recipe:Recipe(inputDomain:.dual),request:authorRequest,
            rows:9,prepare:{ _ in },consume:{ d.consume($0) })
        compareBands(c.rgb,d.rgb,label:"ISO_base"); compareBands(c.gain,d.gain,scale:0.25,label:"ISO_gain")
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1234)],ofItemAtPath:url.path)
        await engine.clearCaches()
        do {
            _ = try await engine.materializeExportRegion(lazy,outputSize:lazy.nativeSize,
                region:CGRect(x:0,y:0,width:height,height:11))
            Issue.record("Lazy source accepted a different file revision")
        } catch RenderError.sourceChanged {}
    }

    @Test func rawRegionsMatchWholeDevelopment() async throws {
        let engine = try RenderEngine()
        let url = licensedRAW()
        #expect(FileManager.default.fileExists(atPath:url.path))
        let full = try await engine.load(url)
        let lazy = try await engine.openExportSource(url)
        #expect(lazy.id == full.id && max(lazy.analysisSource.size.width,lazy.analysisSource.size.height) <= 1024)
        let rect = CGRect(x:21,y:333,width:257,height:67)
        let tile = try await engine.materializeExportRegion(lazy,outputSize:full.size,region:rect)
        #expect(tile.texture.width == 261 && tile.texture.height == 71)
        let recipe = Recipe(inputDomain:.rawEDR,values:["tone.exposure":.number(0.25),"tone.contrast":.number(30)])
        let a = RenderEngine.readPixels(try await engine.render(full,recipe:recipe,size:full.size,region:rect))
        let b = RenderEngine.readPixels(try await engine.render(tile,recipe:recipe,size:full.size,region:rect))
        compareBands(a.baseRGBA,b.baseRGBA,label:"RAW_ROI_base"); compareBands(a.gain,b.gain,scale:0.25,label:"RAW_ROI_gain")
        let request = ExportRenderRequest(photoSize:PixelSize(width:641,height:428),capabilities:streamCaps)
        let one = StreamPixels(), bands = StreamPixels()
        _ = try await engine.renderExportStripes(full,recipe:recipe,request:request,rows:128,prepare:{ _ in },consume:{ one.consume($0) })
        _ = try await engine.renderExportStripes(lazy,recipe:recipe,request:request,rows:128,prepare:{ _ in },consume:{ bands.consume($0) })
        compareBands(one.rgb,bands.rgb,label:"RAW_export_base"); compareBands(one.gain,bands.gain,scale:0.25,label:"RAW_export_gain")
    }

    /// Explicit fresh-process measurement; excluded from the ordinary test suite.
    @Test(.enabled(if:ProcessInfo.processInfo.environment["HYPERDR_EXPORT_MEMORY_PROBE"] != nil))
    func rawMemoryProbe() async throws {
        let mode = ProcessInfo.processInfo.environment["HYPERDR_EXPORT_MEMORY_PROBE"]!
        let engine = try RenderEngine()
        let recorder = FootprintRecorder()
        recorder.sample("baseline")
        let start = ContinuousClock.now
        if mode == "stream" {
            let source = try await engine.openExportSource(licensedRAW())
            recorder.sample("opened")
            _ = try await engine.renderExportStripes(source,recipe:Recipe(inputDomain:.rawEDR),
                request:ExportRenderRequest(photoSize:source.nativeSize,capabilities:streamCaps),rows:256,
                prepare:{ _ in recorder.sample("prepared") },consume:{ _ in recorder.sample("band") })
        } else {
            let source = try await engine.load(licensedRAW())
            recorder.sample("opened")
            _ = try await engine.renderExportStripes(source,recipe:Recipe(inputDomain:.rawEDR),
                request:ExportRenderRequest(photoSize:source.nativeSize,capabilities:streamCaps),rows:256,
                prepare:{ _ in recorder.sample("prepared") },consume:{ _ in recorder.sample("band") })
        }
        recorder.sample("complete")
        await engine.clearCaches()
        recorder.sample("cleared")
        print("RAW_MEMORY mode=\(mode) elapsed=\(start.duration(to:.now)) sampled_peak_bytes=\(recorder.peak)")
    }
}

private final class FootprintRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: UInt64 = 0
    var peak: UInt64 { lock.withLock { highest } }
    func sample(_ stage: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { p in
            p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        lock.withLock { highest = max(highest,info.phys_footprint) }
        print("RAW_MEMORY stage=\(stage) footprint_bytes=\(info.phys_footprint) lifetime_peak_bytes=\(info.ledger_phys_footprint_peak)")
    }
}
