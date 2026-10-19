import CoreGraphics
import Foundation
import HyperDREngine
import ImageIO
import Metal
import QuartzCore
import Synchronization
import XCTest
@testable import HyperDR

/// S12's 120 Hz input / main-thread time-per-change measurement, headless.
/// This measures model/snapshot handoff and GPU time, not SwiftUI layout or
/// CADisplayLink hitches (those require the later visible-window A3 run).
@MainActor final class CompositionPerformanceTests: XCTestCase {
    func test120HzHandoffWithZebrasAndBackgroundScopes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scope-perf-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at:url) }
        let context = try XCTUnwrap(CGContext(data:nil,width:2048,height:1365,bitsPerComponent:8,
            bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),
            colors:[CGColor(gray:0,alpha:1),CGColor(gray:1,alpha:1)] as CFArray,locations:[0,1]))
        context.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:2048,y:0),options:[])
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let engine = try await Engine(), session = try engine.openPreview(source:url)
        defer { session.close() }
        var request = try Engine.normalize(["encoding":.string("iso-gainmap-jpeg"),"hdrRange":.number(3),"brightness":.number(0.6)])
        request.setSetting("preview_max_edge",.number(2048))
        let frame = try await session.renderFrame(request)
        XCTAssertEqual(frame.base.width,2048)
        let services = FakeEditorServices(openDelay:.zero,previewDelay:.milliseconds(1))
        services.preview = LiveEditorServices.preview(frame)
        services.autoCompletesRefreshes = false
        let model = EditorModel(services:services)
        model.open([url])
        // Readiness is outside S12's timing sample. TSan instruments millions
        // of scope pixel reads (over 3 seconds); retain the 4 ms input budget.
        await eventually(timeout:.seconds(10)) { model.document?.phase == .ready && model.scopes.current != nil }
        model.beginAdjusting("brightness")
        let renderer = try makePreviewRenderer()
        let layer = CAMetalLayer(); layer.device = renderer.device; layer.pixelFormat = .rgba16Float
        layer.drawableSize = CGSize(width:1000,height:667)
        let probe = DrawableProbe(standIn:layer); probe.install(on:renderer)
        let gpu = Mutex<[Double]>([])
        renderer.presentingCommandHook = { command in
            command.addCompletedHandler { command in
                gpu.withLock { $0.append((command.gpuEndTime-command.gpuStartTime)*1000) }
            }
        }
        let view = EDRCanvasView(renderer:renderer)
        view.frame = CGRect(x:0,y:0,width:1000,height:667); view.layout()
        view.transform = CanvasTransform(imageSize:CGSize(width:2048,height:1365),viewport:view.bounds.size)
        var content = CanvasComposition(original:frame,edited:frame,mode:.compare,headroom:8)
        view.compositionProvider = { content }
        let loop = try XCTUnwrap(view.renderLoop)
        // Warm pipelines and texture allocations before measuring changes.
        view.tick()
        await eventually(timeout:.seconds(3)) { loop.state.idle && loop.state.presentations > 0 }
        let input = ScopeInput(frame)
        for phase in 0..<3 {
            content.overlays.highlights = phase > 0; content.overlays.shadows = phase > 0
            let scope = phase == 2 ? Task.detached(priority:.utility) { () -> Duration in
                let start = ContinuousClock.now
                _ = ScopeAnalyzer.analyze(input,waveform:true)
                return ContinuousClock.now-start
            } : nil
            gpu.withLock { $0.removeAll() }
            var samples: [Double] = []
            let start = ContinuousClock.now
            for i in 0..<120 {
                let before = ContinuousClock.now
                model.adjust("brightness",to:0.6+Double(i%40)/100)
                content.overlays.hdrRange = Float(i%40)/10
                view.setNeedsRedraw(); view.tick()
                samples.append(milliseconds(ContinuousClock.now-before))
                try await Task.sleep(until:start + .seconds(Double(i+1)/120),clock:.continuous)
            }
            await eventually(timeout:.seconds(3)) { loop.state.idle && loop.state.lastPresented == view.handedOverGeneration }
            let gpuTimes = gpu.withLock { $0 }
            let sorted = samples.sorted(), gpuSorted = gpuTimes.sorted()
            let p99 = sorted[Int(Double(sorted.count-1)*0.99)]
            let gpuP99 = gpuSorted.isEmpty ? 0 : gpuSorted[Int(Double(gpuSorted.count-1)*0.99)]
            let scopeDuration = await scope?.value
            print("M2-R S12 phase=\(phase) input=120Hz n=\(samples.count) main mean=\(samples.reduce(0,+)/Double(samples.count))ms p99=\(p99)ms max=\(sorted.last!)ms GPU n=\(gpuSorted.count) p99=\(gpuP99)ms scope=\(String(describing:scopeDuration))")
            XCTAssertLessThan(p99,4,"S12 per-change main-thread budget")
        }
        model.endAdjusting("brightness")
        model.closeDocument()
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved,1)
        XCTAssertEqual(probe.mainThreadRequests,0)
        loop.stop()
        await eventually(timeout:.seconds(3)) { loop.state.hasStopped }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds)*1000+Double(value.attoseconds)/1e15
    }
}

extension CompositionPerformanceTests {
    /// Extra headroom work is measured on a background thread using the same
    /// source reconstruction, texture views, mip generation and display pipeline.
    func testHeadroomReconstructionCost() async throws {
        let renderer = try makePreviewRenderer()
        try await Task.detached {
            let compositor = try CanvasCompositor(device:renderer.device,queue:renderer.queue,library:renderer.library)
            let width=2048,height=2048,wholeHeight=1365
            let base=try XCTUnwrap(renderer.device.makeBuffer(length:width*height*12))
            let gain=try XCTUnwrap(renderer.device.makeBuffer(length:width*height*4))
            let b=base.contents().bindMemory(to:Float.self,capacity:width*height*3)
            let g=gain.contents().bindMemory(to:Float.self,capacity:width*height)
            for i in 0..<width*height {
                b[i*3]=0.1;b[i*3+1]=0.3;b[i*3+2]=0.5;g[i]=Float(i%127)/126
            }
            func planes(_ height:Int) -> FramePlanes {
                FramePlanes(base:base,baseRowBytes:width*12,gain:gain,gainRowBytes:width*4,
                    gainChannels:1,width:width,height:height,gainWidth:width,gainHeight:height,gainMin:-1,gainMax:4)
            }
            let setup=try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let whole=planes(wholeHeight),detail=planes(height)
            let first=try compositor.makeTestTexture(whole,mipmapped:true,command:setup)
            let second=try compositor.makeTestTexture(whole,mipmapped:true,command:setup)
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
            descriptor.textureType = .type2DArray;descriptor.arrayLength=6;descriptor.storageMode = .private;descriptor.usage=[.shaderRead,.shaderWrite]
            let atlas=try XCTUnwrap(renderer.device.makeTexture(descriptor:descriptor))
            try compositor.encode(detail,into:atlas,slice:0,command:setup)
            try compositor.encode(detail,into:atlas,slice:3,command:setup)
            setup.commit();await setup.completed();XCTAssertNil(setup.error)
            let outputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:1000,height:667,mipmapped:false)
            outputDescriptor.storageMode = .private;outputDescriptor.usage=[.renderTarget]
            let output=try XCTUnwrap(renderer.device.makeTexture(descriptor:outputDescriptor))
            var timings: [(String,Double,Double)] = []
            for scenario in 0..<3 {
                var cpu:[Double]=[],gpu:[Double]=[]
                for sample in 0..<26 {
                    let command=try XCTUnwrap(renderer.queue.makeCommandBuffer())
                    let start=ContinuousClock.now
                    if scenario>0 {
                        let weight:Float=sample.isMultiple(of:2) ? 0.45 : 0.65
                        try compositor.encode(whole,into:first,slice:0,weight:weight,weightedOnly:true,command:command)
                        if scenario==2 {
                            try compositor.encode(whole,into:second,slice:0,weight:weight,weightedOnly:true,command:command)
                            try compositor.encode(detail,into:atlas,slice:0,weight:weight,weightedOnly:true,command:command)
                            try compositor.encode(detail,into:atlas,slice:3,weight:weight,weightedOnly:true,command:command)
                        }
                    }
                    let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
                    pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
                    let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
                    compositor.draw(encoder,texture:first,params:CompositionParams(rect:SIMD4(-1,-1,1,1)))
                    encoder.endEncoding()
                    let encoded=ContinuousClock.now-start
                    command.commit();await command.completed();XCTAssertNil(command.error)
                    if sample>=2 {
                        let components=encoded.components
                        cpu.append(Double(components.seconds)*1000+Double(components.attoseconds)/1e15)
                        gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)
                    }
                }
                cpu.sort();gpu.sort()
                let name=["display-only","one-whole-headroom","two-whole-two-detail-headroom"][scenario]
                print("M2-R R4 \(name) n=24 CPU-encode p50=\(cpu[12])ms p95=\(cpu[22])ms GPU p50=\(gpu[12])ms p95=\(gpu[22])ms")
                timings.append((name,cpu[12],gpu[12]))
            }
            print("M2-R R4 device=\(renderer.device.name) cached-texture-bytes=\(first.allocatedSize+second.allocatedSize+atlas.allocatedSize) source=2048x1365 details=2048x2048; GPU median extra one=\(timings[1].2-timings[0].2)ms all=\(timings[2].2-timings[0].2)ms")
        }.value
    }
}
