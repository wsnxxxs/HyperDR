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
        await eventually(timeout:.seconds(3)) { model.document?.phase == .ready && model.scopes.current != nil }
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
