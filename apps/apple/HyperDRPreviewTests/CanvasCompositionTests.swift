import Foundation
import CoreGraphics
import ImageIO
import QuartzCore
import HyperDREngine
import HyperDRDesign
import HyperDRKit
import Metal
import XCTest
@testable import HyperDR

@MainActor final class CanvasCompositionTests: XCTestCase {
    private func target(_ device: any MTLDevice, width: Int = 16, height: Int = 8) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func read(_ texture: any MTLTexture, after command: any MTLCommandBuffer) throws -> [Float] {
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        var values = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        values.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0,0,texture.width,texture.height), mipmapLevel: 0)
        }
        return values.map(Float.init)
    }

    private func pair(_ device: any MTLDevice, base: Float, stops: Float, width: Int = 16, height: Int = 8) throws -> DisplayPair {
        try makeDisplayPair(device, base: [Float](repeating: base, count: width*height*3), width: width, height: height,
            gain: [Float](repeating: stops, count: width*height))
    }

    /// Uses exactly the production pass-1 and pass-2 encoding. Expected
    /// outputs are independent scalar formulae for every target pixel.
    private func pixels(base: Float, stops: Float, flags: UInt32, weight: Float = 1,
                        range: Float = 2, scale: Float = 1) throws -> [Float] {
        let renderer = try makePreviewRenderer()
        let compositor = try DisplayCompositor(device: renderer.device, library: renderer.library)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let image = try compositor.makeTestTexture(pair(renderer.device, base: base, stops: stops), weight: weight, command: command)
        let out = try target(renderer.device)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = out
        descriptor.colorAttachments[0].loadAction = .clear; descriptor.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: descriptor))
        var params = CompositionParams(rect: SIMD4(-1,-1,1,1))
        params.flags = flags; params.hdrRange = range; params.backingScale = scale
        compositor.draw(encoder, texture: image, params: params)
        encoder.endEncoding()
        return try read(out, after: command)
    }

    func testSDROverrideAndHeadroomWeightDoNotChangeFullGainStatistics() throws {
        for (flags, weight, expected) in [(UInt32(0),Float(1),Float(4)), (0,0.5,1), (1,1,0.25)] {
            let image = try pixels(base: 0.25, stops: 4, flags: flags, weight: weight)
            for p in 0..<128 {
                for c in 0..<3 { XCTAssertEqual(image[p*4+c], expected, accuracy: 0.003) }
                XCTAssertEqual(image[p*4+3], 1)
            }
        }
        // Zebras use the complete file gain even when the screen shows SDR.
        let sdr = try pixels(base: 0.25, stops: 4, flags: 3, weight: 0)
        for y in 0..<8 { for x in 0..<16 {
            let stripe = (Float(x+y+1) / sqrt(2)).truncatingRemainder(dividingBy:CanvasOverlayStyle.stripePeriodPoints) < CanvasOverlayStyle.stripeWidthPoints, i = (y*16+x)*4
            XCTAssertEqual(sdr[i], stripe ? 0.25*0.08+CanvasOverlayStyle.highlight.x*0.92 : 0.25, accuracy: 0.003)
            XCTAssertEqual(sdr[i+1], stripe ? 0.25*0.08+CanvasOverlayStyle.highlight.y*0.92 : 0.25, accuracy: 0.003)
        } }
    }

    func testHighlightToleranceShadowQuantizationAndScreenPointStripes() throws {
        for scale: Float in [1,2] {
            let hdr = try pixels(base: 1, stops: 2-0.009, flags: 2, scale: scale)
            let dark = try pixels(base: 0.0001, stops: 0, flags: 4, scale: scale)
            for y in 0..<8 { for x in 0..<16 {
                let stripe = (Float(x+y+1)/sqrt(2)).truncatingRemainder(dividingBy:CanvasOverlayStyle.stripePeriodPoints*scale) < CanvasOverlayStyle.stripeWidthPoints*scale
                let i = (y*16+x)*4
                let v = Float(Float16(exp2(Float(2-0.009))))
                XCTAssertEqual(hdr[i], stripe ? v*0.08+CanvasOverlayStyle.highlight.x*0.92 : v, accuracy: 0.005)
                XCTAssertEqual(dark[i+2], stripe ? 0.0001*0.08+CanvasOverlayStyle.shadow.z*0.92 : 0.0001, accuracy: 0.003)
            } }
        }
        let below = try pixels(base: 1, stops: 2-0.02, flags: 2)
        let notBlack = try pixels(base: 0.0002, stops: 0, flags: 4)
        for p in 0..<128 {
            XCTAssertEqual(below[p*4], exp2(2-0.02), accuracy: 0.004)
            XCTAssertEqual(notBlack[p*4+2], 0.0002, accuracy: 0.00001)
        }
    }

    func testMaskWeightIsMagentaAtFileGainRegardlessOfScreenWeight() throws {
        for weight: Float in [0,0.5,1] {
            let image = try pixels(base: 0.25, stops: 1, flags: 8, weight: weight, range: 2)
            let alpha: Float = 0.5 * CanvasOverlayStyle.maskOpacity
            let value: Float = 0.25 * exp2(weight)
            for p in 0..<128 {
                XCTAssertEqual(image[p*4], value*(1-alpha)+CanvasOverlayStyle.mask.x*alpha, accuracy: 0.003)
                XCTAssertEqual(image[p*4+1], value*(1-alpha)+CanvasOverlayStyle.mask.y*alpha, accuracy: 0.003)
                XCTAssertEqual(image[p*4+2], value*(1-alpha)+CanvasOverlayStyle.mask.z*alpha, accuracy: 0.003)
            }
        }
    }

    private func session() async throws -> PreviewSession {
        let engine = try await Engine()
        let bundle = previewFixtureBundle()
        let url = try XCTUnwrap(bundle.url(forResource: "photo", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "photo", withExtension: "jpg"))
        return try engine.openPreview(source: url)
    }

    private func frame(_ session: PreviewSession, exposure: Double, region: CGRect? = nil) async throws -> PreviewFrame {
        var request = EngineRequest(settings: ["preview_max_edge":.number(64), "exposure":.number(exposure),
            "headroom":.number(2)])
        if let region {
            try request.setCommand("region", .object(["left":.number(region.minX),"top":.number(region.minY),
                "width":.number(region.width),"height":.number(region.height),"center":.bool(false)]))
        }
        return try await session.renderFrame(request)
    }

    func testProductionSplitScissorsAndOriginalHidesOverlaysForEveryPixel() async throws {
        let session = try await session(); defer { session.close() }
        let original = try await frame(session, exposure: -1)
        let edited = try await frame(session, exposure: 1)
        let renderer = try makePreviewRenderer()
        let compositor = try CanvasCompositor(device: renderer.device, library: renderer.library)
        let w = edited.base.width, h = edited.base.height
        var geometry = CanvasTransform(imageSize: CGSize(width:w,height:h), viewport: CGSize(width:w,height:h))
        let out = try target(renderer.device,width:w,height:h)
        func render(_ content: CanvasComposition) throws -> [Float] {
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(content, transform: geometry, target: out, command: command)
            return try read(out,after:command)
        }
        for zoom: Double in [1,2] {
            geometry.zoom = zoom
            geometry.pan = geometry.clampedPan(CGPoint(x:7,y:3))
            let left = try render(CanvasComposition(original:original,edited:edited,mode:.original,headroom:16))
            let right = try render(CanvasComposition(original:original,edited:edited,headroom:16))
            for ratio in [0.05,0.5,0.95] {
                let split = try render(CanvasComposition(original:original,edited:edited,mode:.compare,splitRatio:ratio,headroom:16))
                let boundary = Int((geometry.imageFrame.minX+geometry.imageFrame.width*ratio).rounded())
                for y in 0..<h { for x in 0..<w { for c in 0..<4 {
                    let i = (y*w+x)*4+c
                    XCTAssertEqual(split[i], x < boundary ? left[i] : right[i], accuracy:0.001)
                } } }
            }
            let overlay = CanvasOverlays(highlights:true,shadows:true,mask:true,hdrRange:0)
            let hidden = try render(CanvasComposition(original:original,edited:edited,mode:.original,headroom:16,overlays:overlay))
            XCTAssertEqual(left,hidden)
            let covered = try render(CanvasComposition(original:original,edited:edited,headroom:16,overlays:overlay))
            let split = try render(CanvasComposition(original:original,edited:edited,mode:.compare,splitRatio:0.5,headroom:16,overlays:overlay))
            let boundary = Int((geometry.imageFrame.minX+geometry.imageFrame.width*0.5).rounded())
            for y in 0..<h { for x in 0..<w { for c in 0..<4 {
                let i = (y*w+x)*4+c
                XCTAssertEqual(split[i],x < boundary ? left[i] : covered[i],accuracy:0.001)
            } } }
        }
        XCTAssertEqual(compositor.rebuilds,2,"view/overlay changes only run pass 2")
    }

    func testDetailPlacementAndNoBrightnessSeamOnBothSides() async throws {
        let session = try await session(); defer { session.close() }
        let original = try await frame(session,exposure:0)
        let edited = try await frame(session,exposure:0.5)
        let crop = CGRect(x:4,y:4,width:16,height:12)
        let originalTile = try await frame(session,exposure:0,region:crop)
        let editedTile = try await frame(session,exposure:0.5,region:crop)
        XCTAssertEqual(CanvasCompositor.region(editedTile),crop)
        // Native full dimensions can exceed the whole preview. Position the
        // output in full-source coordinates, then compare the tile's pixels
        // to the same standalone frame at exactly 1:1.
        let size = CGSize(width:editedTile.metadata.fullWidth!,height:editedTile.metadata.fullHeight!)
        let w = Int(size.width), h = Int(size.height)
        let renderer = try makePreviewRenderer()
        let compositor = try CanvasCompositor(device: renderer.device, library:renderer.library)
        let geometry = CanvasTransform(imageSize:size,viewport:size)
        let out = try target(renderer.device,width:w,height:h)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let content = CanvasComposition(original:original,edited:edited,originalDetail:originalTile,
            editedDetail:editedTile,mode:.compare,splitRatio:0.5,headroom:16)
        try compositor.encode(content,transform:geometry,target:out,command:command)
        let image = try read(out,after:command)
        for (tile,isOriginal) in [(originalTile,true),(editedTile,false)] {
            let local = try CanvasCompositor(device: renderer.device, library:renderer.library)
            let tileOut = try target(renderer.device,width:tile.base.width,height:tile.base.height)
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try local.encode(CanvasComposition(original:tile,edited:tile,mode:.edited,headroom:16),
                transform:CanvasTransform(imageSize:crop.size,viewport:crop.size),target:tileOut,command:command)
            let expected = try read(tileOut,after:command)
            for y in 0..<12 { for x in 0..<16 {
                let globalX = x+4
                if (globalX < w/2) == isOriginal {
                    for c in 0..<3 { XCTAssertEqual(image[((y+4)*w+globalX)*4+c],expected[(y*16+x)*4+c],accuracy:0.004) }
                }
            } }
        }
    }
}


extension CanvasCompositionTests {
    func testUniformPhotoHasNoLocalLayerSeamWithOverlaysAndSDR() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seam-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at:url) }
        let context = try XCTUnwrap(CGContext(data:nil,width:64,height:48,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:0.5,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:48))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let engine = try await Engine(), session = try engine.openPreview(source:url)
        defer { session.close() }
        let whole = try await frame(session,exposure:0)
        let tile = try await frame(session,exposure:0,region:CGRect(x:16,y:12,width:32,height:24))
        let renderer = try makePreviewRenderer()
        let compositor = try CanvasCompositor(device: renderer.device, library:renderer.library)
        let out = try target(renderer.device,width:64,height:48)
        let transform = CanvasTransform(imageSize:CGSize(width:64,height:48),viewport:CGSize(width:64,height:48))
        for headroom in [1.0,1.3,2.0,4.0] { for sdr in [false,true] { for overlay in [false,true] {
            var content = CanvasComposition(original:whole,edited:whole,mode:.compare,headroom:headroom,
                overlays:CanvasOverlays(highlights:overlay,shadows:overlay,mask:overlay,hdrRange:0.5),previewsAsSDR:sdr)
            var command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(content,transform:transform,target:out,command:command)
            let expected = try read(out,after:command)
            content.originalDetail = tile; content.editedDetail = tile
            command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(content,transform:transform,target:out,command:command)
            let actual = try read(out,after:command)
            for i in actual.indices { XCTAssertEqual(actual[i],expected[i],accuracy:0.002,"pixel channel \(i)") }
        } } }
    }

    func testAllLayersShareOneInFlightPresentationAndNewestSnapshotWins() async throws {
        let session = try await session(); defer { session.close() }
        let whole = try await frame(session,exposure:0)
        let tile = try await frame(session,exposure:0,region:CGRect(x:4,y:4,width:16,height:12))
        let renderer = try makePreviewRenderer()
        let layer = CAMetalLayer(); layer.device = renderer.device; layer.pixelFormat = .rgba16Float
        layer.drawableSize = CGSize(width:64,height:48)
        let probe = DrawableProbe(standIn:layer); probe.install(on:renderer)
        let event = try XCTUnwrap(renderer.device.makeSharedEvent())
        renderer.presentingCommandHook = { $0.encodeWaitForEvent(event,value:1) }
        let view = EDRCanvasView(renderer:renderer)
        view.frame = CGRect(x:0,y:0,width:64,height:48); view.layout()
        view.transform = CanvasTransform(imageSize:CGSize(width:tile.metadata.fullWidth!,height:tile.metadata.fullHeight!),viewport:view.bounds.size)
        var content = CanvasComposition(original:whole,edited:whole,originalDetail:tile,editedDetail:tile,
            mode:.compare,headroom:4,overlays:CanvasOverlays(highlights:true,shadows:true,mask:true,hdrRange:1))
        view.compositionProvider = { content }
        let loop = try XCTUnwrap(view.renderLoop)
        view.tick()
        await eventually(timeout:.seconds(3)) { renderer.inFlight == 1 }
        for i in 0..<200 { content.headroom = exp2(Double(i%8)/2); view.setNeedsRedraw(); view.tick() }
        XCTAssertEqual(renderer.inFlight,1)
        XCTAssertEqual(renderer.maxInFlightObserved,1)
        event.signaledValue = 1
        renderer.presentingCommandHook = nil
        await eventually(timeout:.seconds(3)) { loop.state.idle && loop.state.lastPresented == view.handedOverGeneration }
        XCTAssertFalse(loop.state.presentedOutOfOrder)
        XCTAssertEqual(probe.mainThreadRequests,0)
        loop.stop()
        await eventually(timeout:.seconds(3)) { loop.state.hasStopped }
    }
}

extension CanvasCompositionTests {
    func testReviewerReconstructionRetainsGainWhenFullRenditionClipsToBlack() throws {
        let renderer = try makePreviewRenderer()
        let compositor = try DisplayCompositor(device:renderer.device,library:renderer.library)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let source = try makeDisplayPair(renderer.device,base:[0.1,0.1,0.1],width:1,height:1,gain:[0],
            coding:.isoCode(minimum:-1,maximum:2,gamma:1),alternateOffset:0.08)
        let image = try compositor.makeTestTexture(source,weight:0.5,command:command)
        let out = try target(renderer.device,width:1,height:1)
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture=out
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
        let params=CompositionParams(rect:SIMD4(-1,-1,1,1))
        compositor.draw(encoder,texture:image,params:params); encoder.endEncoding()
        let actual=try read(out,after:command)
        let expected=max(Float(0),Float(0.1)*exp2(-0.5)-0.08)
        XCTAssertEqual(expected,0)
        FileHandle.standardError.write(Data("clipped-gain GPU actual=\(actual) expected=\(expected)\n".utf8))
        XCTAssertTrue(abs(actual[0]-expected) < 0.0002,"clipped full HDR must not erase the ISO gain")
    }

    func testReviewerOriginalCacheTracksReferenceIdentity() async throws {
        let session=try await session(); defer { session.close() }
        let a=try await frame(session,exposure:-1), b=try await frame(session,exposure:1)
        let edit=try await frame(session,exposure:0)
        let renderer=try makePreviewRenderer()
        let compositor=try CanvasCompositor(device: renderer.device, library:renderer.library)
        let out=try target(renderer.device,width:edit.base.width,height:edit.base.height)
        let geometry=CanvasTransform(imageSize:CGSize(width:edit.base.width,height:edit.base.height),viewport:CGSize(width:out.width,height:out.height))
        func render(_ original:PreviewFrame) throws -> [Float] {
            let command=try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(CanvasComposition(original:original,edited:edit,mode:.original,headroom:16),transform:geometry,target:out,command:command)
            return try read(out,after:command)
        }
        let first=try render(a), second=try render(b)
        XCTAssertNotEqual(first,second)
        XCTAssertEqual(compositor.rebuilds,3)
        _ = try render(b)
        XCTAssertEqual(compositor.rebuilds,3)
        compositor.releaseFrames()
        _ = try render(b)
        XCTAssertEqual(compositor.rebuilds,5)
    }
}

extension CanvasCompositionTests {
    func testReviewerBothDetailLayersCrossTheDividerOnHighFrequencyPixels() async throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("checker-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at:url) }
        let context=try XCTUnwrap(CGContext(data:nil,width:64,height:48,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<48 { for x in 0..<64 {
            context.setFillColor(CGColor(gray:(x+y)%2 == 0 ? 0.15 : 0.75,alpha:1))
            context.fill(CGRect(x:x,y:y,width:1,height:1))
        } }
        let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let engine=try await Engine(), session=try engine.openPreview(source:url)
        defer { session.close() }
        let crop=CGRect(x:16,y:16,width:32,height:16)
        func make(_ exposure:Double,detail:Bool) async throws -> PreviewFrame {
            var r=EngineRequest(settings:["preview_max_edge":.number(detail ? 64 : 16),"exposure":.number(exposure),"headroom":.number(2)])
            if detail { try r.setCommand("region",.object(["left":.number(16),"top":.number(16),"width":.number(32),"height":.number(16)])) }
            return try await session.renderFrame(r)
        }
        let original=try await make(0,detail:false), edit=try await make(0.5,detail:false)
        let originalTile=try await make(0,detail:true), editedTile=try await make(0.5,detail:true)
        let renderer=try makePreviewRenderer()
        let compositor=try CanvasCompositor(device: renderer.device, library:renderer.library)
        let out=try target(renderer.device,width:64,height:48)
        func render(_ content:CanvasComposition,geometry:CanvasTransform,target:any MTLTexture) throws -> [Float] {
            let command=try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(content,transform:geometry,target:target,command:command)
            return try read(target,after:command)
        }
        let geometry=CanvasTransform(imageSize:CGSize(width:64,height:48),viewport:CGSize(width:64,height:48))
        var content=CanvasComposition(original:original,edited:edit,mode:.compare,headroom:16)
        let low=try render(content,geometry:geometry,target:out)
        content.originalDetail=originalTile; content.editedDetail=editedTile
        let high=try render(content,geometry:geometry,target:out)
        for (tile,left) in [(originalTile,true),(editedTile,false)] {
            let tileOut=try target(renderer.device,width:32,height:16)
            // Isolated crop metadata can be degenerate. The crop follows its
            // whole rendition's weight, as the production atlas does.
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let image = try compositor.display.makeTestTexture(compositor.upload(tile, command: command),
                weight: DisplayWeight.value(headroom: 16, metadata: (left ? original : edit).metadata), command: command)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = tileOut
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            compositor.display.draw(encoder, texture: image, params: CompositionParams(rect: SIMD4(-1,-1,1,1)))
            encoder.endEncoding()
            let expected = try read(tileOut, after: command)
            var changed=false
            for y in 0..<16 { for x in 0..<32 where (x+16 < 32) == left {
                let i=((y+16)*64+x+16)*4
                for c in 0..<3 { XCTAssertEqual(high[i+c],expected[(y*32+x)*4+c],accuracy:0.005) }
                changed = changed || abs(high[i]-low[i]) > 0.01
            } }
            XCTAssertTrue(changed,"the fixture must detect loss of either local side")
        }
    }
}

extension CanvasCompositionTests {
    func testReviewerOriginalActuallyHidesAnActiveOverlay() async throws {
        let session=try await session(); defer { session.close() }
        let frame=try await frame(session,exposure:3)
        let renderer=try makePreviewRenderer()
        let compositor=try CanvasCompositor(device: renderer.device, library:renderer.library)
        let out=try target(renderer.device,width:frame.base.width,height:frame.base.height)
        let geometry=CanvasTransform(imageSize:CGSize(width:out.width,height:out.height),viewport:CGSize(width:out.width,height:out.height))
        func render(_ mode:CanvasComposition.Mode,_ overlay:CanvasOverlays) throws -> [Float] {
            let command=try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(CanvasComposition(original:frame,edited:frame,mode:mode,headroom:16,overlays:overlay),transform:geometry,target:out,command:command)
            return try read(out,after:command)
        }
        let overlay=CanvasOverlays(highlights:true,shadows:true,mask:true,hdrRange:0)
        let plain=try render(.edited,CanvasOverlays())
        let covered=try render(.edited,overlay)
        XCTAssertNotEqual(plain,covered,"fixture must activate the overlay")
        let original=try render(.original,overlay)
        XCTAssertEqual(original,plain)
    }
}

extension CanvasCompositionTests {
    /// Negative gain and offsets can clip the full rendition while intermediate
    /// weights remain distinct. Check both a scalar ISO reference and the
    /// independent legacy float output, with RGB bases and compact bilinear gain.
    func testISOLogGainCacheMatchesReconstructionAcrossWeightsAndOffsets() throws {
        let renderer = try makePreviewRenderer()
        let compositor = try DisplayCompositor(device: renderer.device, library: renderer.library)
        let base: [Float] = [0,0.1,0.55, 0.02,0.1,0.9, 0.05,0.1,0.3, 0.1,0.2,1]
        let baseBuffer = try XCTUnwrap(renderer.device.makeBuffer(bytes: base, length: base.count*4))
        let gains: [Float] = [0,0.8]
        let gainBuffer = try XCTUnwrap(renderer.device.makeBuffer(bytes: gains, length: gains.count*4))
        let cases: [(Float,Float,Float,Float,Float)] = [
            (-1,2,1,0,0.08), // reviewer: full rendition clips, intermediate must stay black
            (-2,-2,1,0.08,0.08), // equal offsets: 0.1 * 0.5 gain => 0.01 at half weight
            (-3,1,1.7,0.15,0.02),
            (-0.5,3,0.7,0.015,0.025),
        ]
        for (minimum,maximum,gamma,baseOffset,alternateOffset) in cases {
            func source(_ weight: Float) -> FramePlanes {
                FramePlanes(base: baseBuffer, baseRowBytes: 4*12, gain: gainBuffer, gainRowBytes: 2*4,
                    gainChannels: 1, width: 4, height: 1, gainWidth: 2, gainHeight: 1,
                    gainMin: minimum, gainMax: maximum, gainGamma: gamma, gainWeight: weight,
                    baseOffset: baseOffset, alternateOffset: alternateOffset)
            }
            let pair = try makeDisplayPair(renderer.device, base: base, width: 4, height: 1, gain: gains,
                gainWidth: 2, gainHeight: 1, coding: .isoCode(minimum: minimum, maximum: maximum, gamma: gamma),
                baseOffset: baseOffset, alternateOffset: alternateOffset)
            for weight: Float in [0,0.25,0.5,0.65,1] {
                let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
                let texture = try compositor.makeTestTexture(pair, weight: weight, command: command)
                let out = try target(renderer.device,width:4,height:1)
                let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = out
                pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
                let params = CompositionParams(rect: SIMD4(-1,-1,1,1))
                compositor.draw(encoder,texture:texture,params:params); encoder.endEncoding()
                let actual = try read(out,after:command)
                let legacy = try renderer.reconstructFloat(planes: source(weight))
                for x in 0..<4 {
                    let location = min(1,max(0,(Float(x)+0.5)*0.5-0.5))
                    let code = gains[0]*(1-location)+gains[1]*location
                    let logGain = minimum+(maximum-minimum)*pow(code,1/gamma)
                    for c in 0..<3 {
                        let expected = max(0,(base[x*3+c]+baseOffset)*exp2(logGain*weight)-alternateOffset)
                        let tolerance = 0.002*max(1,abs(expected))
                        XCTAssertEqual(actual[x*4+c],expected,accuracy:tolerance,
                            "weight=\(weight), offsets=\(baseOffset)/\(alternateOffset), x=\(x), c=\(c)")
                        XCTAssertEqual(actual[x*4+c],legacy[x*4+c],accuracy:tolerance)
                    }
                }
            }
        }
    }

    /// Three-channel log2 gain follows the ISO formula per channel; a v1
    /// alternate rendition keeps both endpoints exact. The SDR override shows
    /// the base.
    func testRGBGainAndAlternateRenditionAndExplicitSDROverride() throws {
        let renderer = try makePreviewRenderer()
        let compositor = try DisplayCompositor(device:renderer.device,library:renderer.library)
        let base: [Float] = [0.1,0.2,0.5], hdr: [Float] = [0,0.8,4]
        let gain = (0..<3).map { log2((hdr[$0]+0.08)/(base[$0]+0.02)) }
        for alternate in [false,true] {
            let source = try makeDisplayPair(renderer.device,base:base,width:1,height:1,gain:alternate ? hdr : gain,
                gainChannels:3,coding:alternate ? .alternate : .log2,baseOffset:0.02,alternateOffset:0.08)
            for (weight,flags) in [(Float(0),UInt32(0)),(0.5,0),(1,0),(0.5,1)] {
                let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
                let texture = try compositor.makeTestTexture(source, weight: weight, command: command)
                let out = try target(renderer.device,width:1,height:1)
                let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = out
                pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
                var params = CompositionParams(rect:SIMD4(-1,-1,1,1))
                params.flags = flags
                compositor.draw(encoder,texture:texture,params:params); encoder.endEncoding()
                let actual = try read(out,after:command)
                for c in 0..<3 {
                    let expected: Float = flags == 1 || (alternate && weight == 0) ? base[c] : alternate && weight == 1 ? hdr[c]
                        : max(0,(base[c]+0.02)*pow((hdr[c]+0.08)/(base[c]+0.02),weight)-0.08)
                    XCTAssertEqual(actual[c],expected,accuracy:0.002,"alternate=\(alternate) weight=\(weight)")
                }
            }
        }
        XCTAssertEqual(compositor.rebuilds,8)
    }
}



extension CanvasCompositionTests {
    func testReviewerMinifiedISOGainRemainsContinuousAtFullHeadroom() throws {
        let renderer=try makePreviewRenderer()
        let compositor=try DisplayCompositor(device:renderer.device,library:renderer.library)
        let planes=try makeDisplayPair(renderer.device,base:[0.1,0.1,0.1, 0.1,0.1,0.1],width:2,height:1,gain:[0,1],
            coding:.isoCode(minimum:0,maximum:4,gamma:1))
        let setup=try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:2,height:1,mipmapped:true)
        descriptor.textureType = .type2DArray;descriptor.arrayLength=3;descriptor.storageMode = .private
        descriptor.usage = [.shaderRead,.shaderWrite]
        let cache=try XCTUnwrap(renderer.device.makeTexture(descriptor:descriptor))
        try compositor.encode(planes,into:cache,slice:0,weight:0,command:setup)
        XCTAssertEqual(cache.mipmapLevelCount,2)
        setup.commit();setup.waitUntilCompleted();XCTAssertNil(setup.error)
        var values:[Float]=[]
        for weight:Float in [0,0.5,0.999,1] {
            let command=try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(planes,into:cache,slice:0,weight:weight,weightedOnly:true,command:command)
            let out=try target(renderer.device,width:1,height:1)
            let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=out
            pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
            let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
            let params=CompositionParams(rect:SIMD4(-1,-1,1,1))
            compositor.draw(encoder,texture:cache,params:params);encoder.endEncoding()
            values.append(try read(out,after:command)[0])
        }
        FileHandle.standardError.write(Data("REVIEW minified weights=[0,.5,.999,1] actual=\(values), scalar=[.1,.25,\(0.05*(1+exp2(Float(4)*0.999))),.85]\n".utf8))
        XCTAssertEqual(values[0],0.1,accuracy:0.001)
        XCTAssertEqual(values[1],0.25,accuracy:0.001)
        XCTAssertEqual(values[3],0.85,accuracy:0.001)
        XCTAssertEqual(values[2],values[3],accuracy:0.01,"A .001 headroom weight change cannot jump across two reconstruction formulae")
    }
}

extension CanvasCompositionTests {
    func testLinearFilteringKeepsBothISOEndpointsContinuousWithOffsetsAndClipping() throws {
        let renderer = try makePreviewRenderer()
        let compositor = try DisplayCompositor(device:renderer.device,library:renderer.library)
        let base: [Float] = [0.1,0.02,0.6, 0.1,0.3,0.02], gains: [Float] = [0,1]
        let weights: [Float] = [0,0.001,0.5,0.999,1]
        for (minimum,maximum,baseOffset,alternateOffset): (Float,Float,Float,Float) in [(0,4,0,0),(-2,4,0,0.08),(-2,4,0.08,0.08),(-3,2,0.15,0.025)] {
            let planes = try makeDisplayPair(renderer.device,base:base,width:2,height:1,gain:gains,
                coding:.isoCode(minimum:minimum,maximum:maximum,gamma:1),
                baseOffset:baseOffset,alternateOffset:alternateOffset)
            // 1x1 uses production mipmaps. The centre of a 3x1 enlargement
            // linearly averages the same two texels without mip minification.
            for (width,mipmapped) in [(1,true),(3,false)] {
                var results: [[Float]] = []
                for weight in weights {
                    let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
                    let cache = try compositor.makeTestTexture(planes,weight:weight,mipmapped:mipmapped,command:command)
                    let out = try target(renderer.device,width:width,height:1)
                    let pass = MTLRenderPassDescriptor();pass.colorAttachments[0].texture=out
                    pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
                    let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
                    compositor.draw(encoder,texture:cache,params:CompositionParams(rect:SIMD4(-1,-1,1,1)))
                    encoder.endEncoding()
                    let actual = try read(out,after:command)
                    let centre = Array(actual[(width/2)*4..<(width/2)*4+3])
                    results.append(centre)
                    for c in 0..<3 {
                        let left = max(0,(base[c]+baseOffset)*exp2(minimum*weight)-alternateOffset)
                        let right = max(0,(base[3+c]+baseOffset)*exp2(maximum*weight)-alternateOffset)
                        XCTAssertEqual(centre[c],(left+right)/2,accuracy:0.002,
                            "weight=\(weight) offsets=\(baseOffset)/\(alternateOffset) mip=\(mipmapped)")
                    }
                }
                for c in 0..<3 {
                    // Bound the legitimate .001 source-weight change by the
                    // derivative of the scalar ISO formula plus half precision.
                    let slope = abs(base[c]+baseOffset)*abs(minimum)*max(1,exp2(minimum))
                        + abs(base[3+c]+baseOffset)*abs(maximum)*max(1,exp2(maximum))
                    let bound = slope*log(Float(2))*0.001/2 + 0.004
                    XCTAssertLessThanOrEqual(abs(results[0][c]-results[1][c]),bound)
                    XCTAssertLessThanOrEqual(abs(results[3][c]-results[4][c]),bound)
                }
            }
        }
    }

    func testHeadroomUpdatesAllLayersWithoutAllocatingOrRebuildingForDisplayChanges() async throws {
        let session = try await session();defer { session.close() }
        let whole = try await frame(session,exposure:0)
        let tile = try await frame(session,exposure:0,region:CGRect(x:4,y:4,width:16,height:12))
        let renderer = try makePreviewRenderer()
        let compositor = try CanvasCompositor(device: renderer.device, library:renderer.library)
        let out = try target(renderer.device,width:64,height:48)
        let fullWidth = try XCTUnwrap(tile.metadata.fullWidth), fullHeight = try XCTUnwrap(tile.metadata.fullHeight)
        let transform = CanvasTransform(imageSize:CGSize(width:fullWidth,height:fullHeight),viewport:CGSize(width:64,height:48))
        var content = CanvasComposition(original:whole,edited:whole,originalDetail:tile,editedDetail:tile,mode:.compare,headroom:1)
        func draw() throws {
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(content,transform:transform,target:out,command:command)
            _ = try read(out,after:command)
        }
        try draw()
        let initial = compositor.rebuilds, allocations = compositor.textureAllocations
        XCTAssertEqual(initial,4);XCTAssertEqual(allocations,3)
        content.splitRatio=0.4;content.overlays.highlights=true;content.previewsAsSDR=true
        try draw();XCTAssertEqual(compositor.rebuilds,initial)
        let alternate = whole.metadata.alternateHeadroom ?? whole.metadata.headroomStops
        content.headroom=exp2(alternate+1)
        try draw();XCTAssertEqual(compositor.rebuilds,initial+4,"both whole and both detail weights must update")
        XCTAssertEqual(compositor.textureAllocations,allocations,"headroom reuses all three texture allocations")
        content.headroom=exp2(alternate+2)
        try draw();XCTAssertEqual(compositor.rebuilds,initial+4,"identical clamped weight is a display-only update")
        content.headroom=1;content.previewsAsSDR=false
        try draw();XCTAssertEqual(compositor.rebuilds,initial+8)
        XCTAssertEqual(compositor.textureAllocations,allocations)
        let base = whole.metadata.baseHeadroom ?? 0
        let span = alternate - base
        for (weight, runs) in [(0.5,initial+12), (0.504,initial+12), (0.508,initial+16)] {
            content.headroom = exp2(base + span * weight)
            try draw()
            XCTAssertEqual(compositor.rebuilds, runs, "all four layers compare to last rendered weight")
        }
    }
}
