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

    private func planes(_ device: any MTLDevice, base: Float, stops: Float, width: Int = 16, height: Int = 8) throws -> FramePlanes {
        let base = [Float](repeating: base, count: width*height*3)
        let gain = [Float](repeating: 0, count: width*height)
        return FramePlanes(base: try XCTUnwrap(device.makeBuffer(bytes: base, length: base.count*4)),
            baseRowBytes: width*12, gain: try XCTUnwrap(device.makeBuffer(bytes: gain, length: gain.count*4)),
            gainRowBytes: width*4, gainChannels: 1, width: width, height: height,
            gainWidth: width, gainHeight: height, gainMin: stops, gainMax: stops)
    }

    /// Uses exactly the production pass-1 and pass-2 encoding. Expected
    /// outputs are independent scalar formulae for every target pixel.
    private func pixels(base: Float, stops: Float, flags: UInt32, weight: Float = 1,
                        range: Float = 2, scale: Float = 1) throws -> [Float] {
        let renderer = try makePreviewRenderer()
        let compositor = try CanvasCompositor(device: renderer.device, queue: renderer.queue, library: renderer.library)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let image = try compositor.makeTestTexture(planes(renderer.device, base: base, stops: stops), command: command)
        let out = try target(renderer.device)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = out
        descriptor.colorAttachments[0].loadAction = .clear; descriptor.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: descriptor))
        var params = CompositionParams(rect: SIMD4(-1,-1,1,1))
        params.flags = flags; params.weight = weight; params.hdrRange = range; params.backingScale = scale
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
        let compositor = try CanvasCompositor(device: renderer.device, queue: renderer.queue, library: renderer.library)
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
        let compositor = try CanvasCompositor(device:renderer.device,queue:renderer.queue,library:renderer.library)
        let geometry = CanvasTransform(imageSize:size,viewport:size)
        let out = try target(renderer.device,width:w,height:h)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let content = CanvasComposition(original:original,edited:edited,originalDetail:originalTile,
            editedDetail:editedTile,mode:.compare,splitRatio:0.5,headroom:16)
        try compositor.encode(content,transform:geometry,target:out,command:command)
        let image = try read(out,after:command)
        for (tile,isOriginal) in [(originalTile,true),(editedTile,false)] {
            let local = try CanvasCompositor(device:renderer.device,queue:renderer.queue,library:renderer.library)
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
        let compositor = try CanvasCompositor(device:renderer.device,queue:renderer.queue,library:renderer.library)
        let out = try target(renderer.device,width:64,height:48)
        let transform = CanvasTransform(imageSize:CGSize(width:64,height:48),viewport:CGSize(width:64,height:48))
        for sdr in [false,true] { for overlay in [false,true] {
            var content = CanvasComposition(original:whole,edited:whole,mode:.compare,headroom:2,
                overlays:CanvasOverlays(highlights:overlay,shadows:overlay,mask:overlay,hdrRange:0.5),previewsAsSDR:sdr)
            var command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(content,transform:transform,target:out,command:command)
            let expected = try read(out,after:command)
            content.originalDetail = tile; content.editedDetail = tile
            command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(content,transform:transform,target:out,command:command)
            let actual = try read(out,after:command)
            for i in actual.indices { XCTAssertEqual(actual[i],expected[i],accuracy:0.002,"pixel channel \(i)") }
        } }
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
        let content = CanvasComposition(original:whole,edited:whole,originalDetail:tile,editedDetail:tile,
            mode:.compare,headroom:4,overlays:CanvasOverlays(highlights:true,shadows:true,mask:true,hdrRange:1))
        view.compositionProvider = { content }
        let loop = try XCTUnwrap(view.renderLoop)
        view.tick()
        await eventually(timeout:.seconds(3)) { renderer.inFlight == 1 }
        for _ in 0..<200 { view.setNeedsRedraw(); view.tick() }
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
