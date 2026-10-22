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
    @Test(arguments:[false,true])
    func downscaledSourceTilesIncludeIntegralRounding(hasGain: Bool) async throws {
        let engine = try RenderEngine()
        let native = PixelSize(width:9504,height:6336)
        let output = PixelSize(width:9479,height:6306)
        let image = CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6))
            .cropped(to:CGRect(x:0,y:0,width:native.width,height:native.height))
        let analysis = try await engine.source(image:image.cropped(to:CGRect(x:0,y:0,width:1,height:1)),domain:.sdr)
        // A constant CI graph exercises real ROI allocation without decoding a large fixture.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tile-bounds-\(UUID())")
        try Data([0]).write(to:url)
        defer { try? FileManager.default.removeItem(at:url) }
        let gain = hasGain ? AuthoredGainMap(standard:.iso,auxiliaryInfo:NSDictionary(),image:image,
            channelCount:1,baseColorSpace:RenderEngine.workingColorSpace,alternateColorSpace:nil,
            auxiliaryColorSpace:nil,tags:[:]) : nil
        let domain: InputDomain = hasGain ? .dual : .sdr
        let opened = OpenedSource(domain:domain,image:image,hdr:image,baseSpace:RenderEngine.workingColorSpace,
                                  gain:gain,raw:nil,nativeSize:native)
        let lazy = ExportSource(id:analysis.id,domain:domain,nativeSize:native,rawSettings:nil,
            analysisSource:analysis,opened:opened,url:url,revision:try SourceRevision(url:url))
        let tile = await engine.exportTileSize(lazy,request:ExportRenderRequest(photoSize:output,capabilities:streamCaps))
        let limit = PreparedExportRows.maximumSourceTileSize
        for y in stride(from:0,to:output.height,by:tile.height) {
            for x in stride(from:0,to:output.width,by:tile.width) {
                let region = CGRect(x:x,y:y,width:min(tile.width,output.width-x),height:min(tile.height,output.height-y))
                let source = try await engine.materializeExportRegion(lazy,outputSize:output,region:region)
                #expect(source.texture.width <= limit.width && source.texture.height <= limit.height)
                if hasGain {
                    let gain = try #require(source.gainTexture)
                    #expect(gain.width <= limit.width && gain.height <= limit.height)
                }
            }
        }
    }

    /// The film's scatter reads beyond a tile: a tile materialized with the halo renders
    /// exactly as the whole image does there, and one without it does not.
    @Test func filmTilesCarryTheScatterHalo() async throws {
        let engine = try RenderEngine()
        let size = PixelSize(width:3000,height:300)
        let image = CIFilter(name:"CICheckerboardGenerator",parameters:["inputCenter":CIVector(x:0,y:0),
            "inputColor0":CIColor(red:0.9,green:0.8,blue:0.7),"inputColor1":CIColor(red:0.05,green:0.06,blue:0.04),
            "inputWidth":5,"inputSharpness":1])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:size.width,height:size.height))
        let analysis = try await engine.source(image:image,domain:.sdr)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("film-halo-\(UUID())")
        try Data([0]).write(to:url)
        defer { try? FileManager.default.removeItem(at:url) }
        let opened = OpenedSource(domain:.sdr,image:image,hdr:image,baseSpace:RenderEngine.workingColorSpace,gain:nil,raw:nil,nativeSize:size)
        let lazy = ExportSource(id:analysis.id,domain:.sdr,nativeSize:size,rawSettings:nil,
            analysisSource:analysis,opened:opened,url:url,revision:try SourceRevision(url:url))
        var edit = RenderAdjustments()
        edit.film.stock = .portra400; edit.film.grain = 0; edit.film.exposure = 0; edit.film.halation = 0
        let halo = edit.film.sourceHalo(size:size)
        #expect(halo >= 6)
        let bounds = CGRect(x:0,y:0,width:size.width,height:size.height)
        let whole = RenderEngine.readPixels(try await engine.render(
            try await engine.materializeExportRegion(lazy,outputSize:size,region:bounds),adjustments:edit,size:size,region:bounds))
        func difference(_ region: CGRect, halo: Int) async throws -> Float {
            let tile = try await engine.materializeExportRegion(lazy,outputSize:size,region:region,halo:halo)
            let pixels = RenderEngine.readPixels(try await engine.render(tile,adjustments:edit,size:size,region:region))
            var worst: Float = 0
            for y in 0..<Int(region.height) { for x in 0..<Int(region.width) { for c in 0..<3 {
                worst = max(worst,abs(pixels.baseRGBA[(y*Int(region.width)+x)*4+c]
                    - whole.baseRGBA[((y+Int(region.minY))*size.width+x+Int(region.minX))*4+c]))
            } } }
            return worst
        }
        for region in [CGRect(x:1003,y:101,width:300,height:80),CGRect(x:0,y:0,width:200,height:50),CGRect(x:2900,y:250,width:100,height:50)] {
            #expect(try await difference(region,halo:halo) == 0,"\(region)")
        }
        #expect(try await difference(CGRect(x:1003,y:101,width:300,height:80),halo:0) > 0.01)
        // Export tiles leave room for the halo within the source tile limit.
        let tile = await engine.exportTileSize(lazy,request:ExportRenderRequest(photoSize:size,capabilities:streamCaps),halo:halo)
        #expect(tile.width + 2*halo + 6 <= PreparedExportRows.maximumSourceTileSize.width)
    }

    @Test func oversizedPanoramaRowsAndTextureLimit() async throws {
        let engine = try RenderEngine()
        let width = 20017, height = 19
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("panorama-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at:url) }
        let image = CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6)).cropped(to:CGRect(x:0,y:0,width:width,height:height))
        try CIContext().writeTIFFRepresentation(of:image,to:url,format:.RGBAh,colorSpace:RenderEngine.workingColorSpace)
        let lazy = try await engine.openExportSource(url)
        let recipe = Recipe(inputDomain:lazy.domain)
        let reader = try await engine.prepareExportRows(lazy,recipe:recipe,
            request:ExportRenderRequest(photoSize:lazy.nativeSize,capabilities:streamCaps))
        let rows = try reader.read(y:3,count:7)
        #expect(rows.rect.width == width && rows.baseRGB.count == width*7*3)
        let replay = try reader.read(y:3,count:7)
        #expect(rows.baseRGB == replay.baseRGB && rows.gain == replay.gain)
        let region = CGRect(x:123,y:3,width:17,height:7)
        let tile = try await engine.materializeExportRegion(lazy,outputSize:lazy.nativeSize,region:region)
        let expected = RenderEngine.readPixels(try await engine.render(tile,recipe:recipe,size:lazy.nativeSize,region:region))
        #expect(Array(rows.baseRGB[(123*3)..<(124*3)]) == Array(expected.baseRGBA.prefix(3)))
        let caption = CIImage(color:CIColor(red:1,green:1,blue:1,alpha:0.5))
            .cropped(to:CGRect(x:0,y:0,width:width+16,height:2))
        let png = try #require(CIContext().pngRepresentation(of:caption,format:.RGBA8,
            colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!))
        let frame = FrameSnapshot(canvasSize:PixelSize(width:width+16,height:height+6),
            photo:ExportRect(x:8,y:2,width:width,height:height),paper:SIMD3(repeating:0.8),
            caption:FrameCaption(png:png,rect:ExportRect(x:0,y:height+4,width:width+16,height:2)))
        let framed = try await engine.prepareExportRows(lazy,recipe:recipe,
            request:ExportRenderRequest(photoSize:lazy.nativeSize,capabilities:streamCaps,frame:frame))
        let band = try framed.read(y:height,count:6)
        #expect(band.gain[0] == 0 && band.gain[band.rect.width-1] == 0)
        // A caption wider than the Metal limit is cropped before rasterization.
        #expect(abs(band.baseRGB[5*band.rect.width*3]-0.9) < 0.003)
        #expect(band.baseRGB[(4095)*3] == band.baseRGB[(4096)*3])
        // Reject before calling Metal validation, which aborts rather than throws.
        do { _ = try await engine.load(url); Issue.record("Oversized full texture was accepted") }
        catch RenderError.invalidSize {}
    }

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
        let reader = try await engine.prepareExportRows(lazy,recipe:recipe,request:request)
        // An unrelated actor call cannot mutate the reader's frozen analysis.
        await engine.clearCaches()
        let replay = try await Task.detached {
            let tail = try reader.read(y:22,count:11)
            let head = try reader.read(y:0,count:11)
            let tailAgain = try reader.read(y:22,count:11)
            #expect(tail.baseRGB == tailAgain.baseRGB && tail.gain == tailAgain.gain)
            #expect(tail.baseRGB == Array(b.rgb[(22*37*3)..<(33*37*3)]))
            #expect(head.baseRGB == Array(b.rgb[0..<(11*37*3)]))
            return tail
        }.value
        #expect(replay.rect.y == 22)
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

    @Test(arguments:[false,true])
    func rawPreviewAreaFiltersHighFrequency(transpose: Bool) async throws {
        let engine = try RenderEngine()
        let width = transpose ? 16 : 9504, height = transpose ? 9504 : 16
        let values = (0..<width*height).map { Float((transpose ? $0/width : $0%width)%2) }
        let rgba: [Float] = values.flatMap { [$0,$0,$0,1] }
        let image = CIImage(bitmapData:rgba.withUnsafeBytes { Data($0) },bytesPerRow:width*16,
            size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:RenderEngine.workingColorSpace)
        for output in [PixelSize(width:transpose ? 1 : 1024,height:transpose ? 1024 : 1),PixelSize(width:1,height:1)] {
            let actual = try await engine.rawPreviewPixels(image,size:output)
            let sx = Double(width)/Double(output.width), sy = Double(height)/Double(output.height)
            var maximumError = 0.0
            for y in 0..<output.height {
                for x in 0..<output.width {
                    let left = Double(x)*sx, right = Double(x+1)*sx
                    let top = Double(y)*sy, bottom = Double(y+1)*sy
                    var sum = 0.0
                    for iy in Int(floor(top))..<min(height,Int(ceil(bottom))) {
                        let wy = min(bottom,Double(iy+1))-max(top,Double(iy))
                        for ix in Int(floor(left))..<min(width,Int(ceil(right))) {
                            let wx = min(right,Double(ix+1))-max(left,Double(ix))
                            sum += Double(values[iy*width+ix])*wx*wy
                        }
                    }
                    let expected = sum/(sx*sy)
                    for channel in 0..<3 {
                        maximumError = max(maximumError,abs(Double(actual[(y*output.width+x)*4+channel])-expected))
                    }
                }
            }
            print("RAW_AREA transpose=\(transpose) size=\(output.width)x\(output.height) max_error=\(maximumError)")
            #expect(maximumError < 0.00001)
        }
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

@Suite struct TIFFBitmapTests {
    @Test(arguments:[CIFormat.RGBA8, .RGBAh])
    func nativeBitmapPreservesOrientedPixels(format: CIFormat) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bitmap-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at:url) }
        let space = CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3)!
        let image = CIFilter(name:"CILinearGradient",parameters:[
            "inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:4113,y:13),
            "inputColor0":CIColor(red:0.1,green:0.3,blue:0.7,alpha:0.6),
            "inputColor1":CIColor(red:1.5,green:0.2,blue:0.1)])!.outputImage!
            .cropped(to:CGRect(x:0,y:0,width:4113,height:13))
        let bitmap = try #require(CIContext().createCGImage(image,from:image.extent,format:format,colorSpace:space))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,"public.tiff" as CFString,1,nil))
        CGImageDestinationAddImage(destination,bitmap,[kCGImagePropertyOrientation:6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let engine = try RenderEngine()
        let whole = try await engine.load(url)
        let lazy = try await engine.openExportSource(url)
        #expect(lazy.domain == whole.domain)
        #expect(lazy.nativeSize == PixelSize(width:13,height:4113))
        for y in [0,2047,4105] {
            let region = CGRect(x:0,y:y,width:13,height:8)
            let tile = try await engine.materializeExportRegion(lazy,outputSize:lazy.nativeSize,region:region)
            let recipe = Recipe(inputDomain:whole.domain)
            let a = RenderEngine.readPixels(try await engine.render(whole,recipe:recipe,size:whole.size,region:region))
            let b = RenderEngine.readPixels(try await engine.render(tile,recipe:recipe,size:whole.size,region:region))
            compareBands(a.baseRGBA,b.baseRGBA,label:"TIFF_bitmap")
            compareBands(a.gain,b.gain,scale:0.25,label:"TIFF_bitmap_gain")
        }
    }
}

private extension RenderEngine {
    func rawPreviewPixels(_ image: CIImage, size: PixelSize) throws -> [Float] {
        let texture = try rasterizeRAWPreview(image,size:size,space:Self.workingColorSpace)
        var pixels = [Float](repeating:0,count:size.width*size.height*4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!,bytesPerRow:size.width*16,
                from:MTLRegionMake2D(0,0,size.width,size.height),mipmapLevel:0)
        }
        return pixels
    }
}
