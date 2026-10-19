import Foundation
import Metal
import QuartzCore
import Synchronization
import XCTest
@testable import HyperDR

/// A2b-2 (batch3 §14.6 step 2): the render loop draws off the main thread.
/// Headless throughout: views are never put in a window, and drawables come
/// from a separate offscreen layer through `DrawableProbe`.
@MainActor final class PreviewRenderLoopTests: XCTestCase {
    private let side: CGFloat = 16

    private func offscreenLayer(_ renderer: PreviewRenderer) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: side, height: side)
        return layer
    }

    /// A canvas showing the synthetic ramp, its renderer and its probe.
    private func canvas(standIn: Bool = true) throws
        -> (EDRCanvasView, PreviewRenderer, DrawableProbe, CAMetalLayer) {
        let renderer = try makePreviewRenderer()
        let layer = offscreenLayer(renderer)
        let probe = DrawableProbe(standIn: standIn ? layer : nil)
        probe.install(on: renderer)
        let view = EDRCanvasView(renderer: renderer)
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
        view.layout()
        view.showsSyntheticRamp = true
        return (view, renderer, probe, layer)
    }

    private func loop(_ view: EDRCanvasView) throws -> PreviewRenderLoop {
        try XCTUnwrap(view.renderLoop)
    }

    /// Red channel at the drawable's centre.
    private func centreRed(_ renderer: PreviewRenderer, _ drawable: any CAMetalDrawable) throws -> Float {
        let texture = drawable.texture
        let buffer = try XCTUnwrap(renderer.device.makeBuffer(length: 8, options: .storageModeShared))
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: texture.width / 2, y: texture.height / 2, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: 8,
                  destinationBytesPerImage: 8)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return Float(buffer.contents().load(as: Float16.self))
    }

    /// Judgement 1 and 3: drawables are only requested off the main thread;
    /// a tick that arrives while a draw is in flight is coalesced, and the
    /// newest snapshot is what ends up on screen.
    func testDrawsOffTheMainThreadAndShowsTheNewestSnapshot() async throws {
        let (view, renderer, probe, _) = try canvas()
        let loop = try loop(view)
        view.tick()
        await eventually("first presentation") { loop.state.presentations >= 1 && loop.state.idle }
        let hdr = try centreRed(renderer, try XCTUnwrap(probe.last))

        view.showsOriginal = true
        view.tick()
        view.transform.zoom = 1.5
        view.tick()
        view.transform.zoom = 1
        view.tick()
        await eventually("newest snapshot drawn") {
            loop.state.lastPresented == view.handedOverGeneration && loop.state.idle
        }
        let original = try centreRed(renderer, try XCTUnwrap(probe.last))
        XCTAssertGreaterThan(hdr, 1, "the ramp's middle reaches into HDR")
        XCTAssertEqual(original, hdr, accuracy: 0.01, "the original retains the source's own HDR")
        XCTAssertEqual(probe.mainThreadRequests, 0)
        XCTAssertGreaterThan(probe.requests, 0)
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved, 1)
        XCTAssertFalse(loop.state.presentedOutOfOrder)
    }

    /// A nil drawable keeps the snapshot: the loop retries it by itself a
    /// display frame later, with no new tick from the main thread. Pass 1 runs
    /// only once a drawable is in hand (A2b-1 review P3-2).
    func testNilDrawableIsRetriedWithoutANewTick() async throws {
        let (view, renderer, probe, _) = try canvas()
        let loop = try loop(view)
        probe.handsOutNone = true
        view.tick()
        await eventually("several misses") { probe.requests >= 3 }
        XCTAssertEqual(loop.state.presentations, 0)
        XCTAssertEqual(renderer.pass1Runs, 0, "no pass 1 without a drawable")
        probe.handsOutNone = false
        await eventually("drawn after the misses") {
            loop.state.lastPresented == view.handedOverGeneration && loop.state.idle
        }
        XCTAssertEqual(renderer.pass1Runs, 1)
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved, 1)
    }

    /// Judgement 5: closing the photo clears once and lets go of the frame.
    func testClosingThePhotoReleasesTheFrame() async throws {
        let (view, _, probe, _) = try canvas()
        let loop = try loop(view)
        view.tick()
        await eventually("ramp drawn") { loop.state.presentations >= 1 && loop.state.idle }
        XCTAssertNotNil(loop.readyFrameIdentity)
        view.showsSyntheticRamp = false
        view.tick()
        await eventually("cleared") { loop.state.presentations >= 2 && loop.state.idle }
        XCTAssertNil(loop.readyFrameIdentity)
        let requests = probe.requests
        view.setNeedsRedraw()
        view.tick()
        await eventually("idle again") { loop.state.lastPresented == view.handedOverGeneration && loop.state.idle }
        XCTAssertEqual(probe.requests, requests, "an empty canvas is cleared once, not every tick")
    }

    /// Judgement 5: stopping returns at once on the main thread, and the loop
    /// exits within 1.1 s even while it is waiting for a drawable.
    func testStopWhileWaitingForADrawable() async throws {
        let (view, _, probe, _) = try canvas()
        let loop = try loop(view)
        probe.block = 1
        view.tick()
        await eventually("waiting in nextDrawable") { probe.isBlocking }
        let start = ContinuousClock.now
        loop.stop()
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1))
        XCTAssertTrue(loop.waitUntilStopped(timeout: 1.1))
    }

    /// Judgement 6: one canvas stuck waiting for drawables does not hold up
    /// another.
    func testCanvasesAreIndependent() async throws {
        let (stuck, _, stuckProbe, _) = try canvas()
        let (free, _, _, _) = try canvas()
        stuckProbe.block = 1
        stuck.tick()
        await eventually("first canvas waiting") { stuckProbe.isBlocking }
        free.tick()
        let freeLoop = try loop(free)
        await eventually(timeout: .milliseconds(500), "second canvas presents") {
            freeLoop.state.presentations >= 1
        }
        XCTAssertTrue(stuckProbe.isBlocking, "the first canvas was still waiting")
        try loop(stuck).stop()
    }

    // MARK: - Judgement 2: progress while the renderer is backpressured

    /// Exercise a fixed number of updates while a test-controlled gate remains
    /// closed. A main-queue marker must run before relief, independently of the
    /// render executor. Latencies are diagnostic measurements, not assertions
    /// about how promptly the OS schedules a timer on a busy test machine.
    private func driveWhileBlocked(_ view: EDRCanvasView, scenario: String,
                                   isBlocked: () -> Bool) async {
        XCTAssertTrue(isBlocked(), "\(scenario): pressure must be established first")
        var durations: [Duration] = []
        for step in 0..<240 {
            let start = ContinuousClock.now
            view.transform.zoom = step.isMultiple(of: 2) ? 1 : 1.5
            view.setNeedsRedraw()
            view.tick()
            durations.append(ContinuousClock.now - start)
        }
        var mainQueueServiced = false
        DispatchQueue.main.async { MainActor.assumeIsolated { mainQueueServiced = true } }
        await eventually(timeout: .seconds(10), "main queue progresses before pressure relief") { mainQueueServiced }
        XCTAssertTrue(isBlocked(), "\(scenario): updates and main-queue work completed without relief")
        let ordered = durations.sorted()
        print("A2b-2 \(scenario): 240 updates while blocked; tick p99=\(ordered[237]) max=\(ordered[239])")
        XCTAssertLessThanOrEqual(ordered[237], .milliseconds(1), "\(scenario): canvas tick p99")
        XCTAssertLessThanOrEqual(ordered[239], .milliseconds(4), "\(scenario): canvas tick max")
    }

    /// A drawable source stays suspended until the test opens its gate, then
    /// returns nil once. No elapsed-time assumption about nextDrawable's timeout.
    func testPressureDrawableSourceBlocks() async throws {
        let (view, renderer, probe, _) = try canvas()
        let loop = try loop(view)
        let gate = DrawablePressureGate()
        let source = renderer.drawableSource
        let requests = Mutex(0)
        renderer.drawableSource = { layer in
            let first = requests.withLock { count in count += 1; return count == 1 }
            if first { gate.waitForRelease(); return nil }
            return source(layer)
        }
        defer { gate.release() }
        view.tick()
        await eventually(timeout: .seconds(10), "drawable source entered gate") { gate.isWaiting }
        await driveWhileBlocked(view, scenario: "drawable source blocked / nil", isBlocked: { gate.isWaiting })
        XCTAssertEqual(requests.withLock { $0 }, 1, "coalesced updates must not request more drawables")
        XCTAssertEqual(loop.state.presentations, 0)
        XCTAssertEqual(renderer.pass1Runs, 0, "no pass 1 while waiting for a drawable")
        gate.release()
        await eventually(timeout: .seconds(10), "newest snapshot after relief without another tick") {
            loop.state.lastPresented == view.handedOverGeneration && loop.state.idle
        }
        XCTAssertFalse(gate.didTimeOut)
        XCTAssertEqual(gate.mainThreadRequests + probe.mainThreadRequests, 0)
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved, 1)
        XCTAssertFalse(loop.state.presentedOutOfOrder)
    }

    /// The shared event is signalled by the test only after pending updates and
    /// a main-queue marker complete; no 250 ms timer or presentation-rate budget.
    func testPressureGPUBacklog() async throws {
        let (view, renderer, probe, _) = try canvas()
        let loop = try loop(view)
        let event = try XCTUnwrap(renderer.device.makeSharedEvent())
        let commands = Mutex(0)
        renderer.presentingCommandHook = { command in
            commands.withLock { $0 += 1 }
            command.encodeWaitForEvent(event, value: 1)
        }
        defer { event.signaledValue = 1 }
        view.tick()
        await eventually(timeout: .seconds(10), "GPU command parked on shared event") {
            commands.withLock { $0 } == 1 && renderer.inFlight == 1
        }
        await driveWhileBlocked(view, scenario: "GPU command awaiting event", isBlocked: {
            event.signaledValue == 0 && renderer.inFlight == 1
        })
        XCTAssertEqual(commands.withLock { $0 }, 1, "pending snapshots must not submit a second command")
        XCTAssertEqual(renderer.busyRefusals, 0, "the loop waits for completion rather than polling")
        renderer.presentingCommandHook = nil
        event.signaledValue = 1
        await eventually(timeout: .seconds(10), "newest snapshot after GPU relief") {
            loop.state.lastPresented == view.handedOverGeneration && loop.state.idle
        }
        XCTAssertEqual(probe.mainThreadRequests, 0)
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved, 1)
        XCTAssertFalse(loop.state.presentedOutOfOrder)
    }

    /// Hold the real offscreen layer's complete pool off the main thread. The
    /// source gate explicitly models compositor ownership until release rather
    /// than relying on CAMetalLayer's undocumented overflow-after-timeout policy.
    func testPressureDrawablesHeld() async throws {
        let (view, renderer, probe, layer) = try canvas()
        let loop = try loop(view)
        let gate = DrawablePressureGate(layer: layer)
        defer { gate.release() }
        let held = await Task.detached { gate.holdDrawables() }.value
        XCTAssertEqual(held, layer.maximumDrawableCount)
        let source = renderer.drawableSource
        renderer.drawableSource = { layer in gate.waitForRelease(); return source(layer) }
        view.tick()
        await eventually(timeout: .seconds(10), "renderer waiting for held pool") { gate.isWaiting }
        await driveWhileBlocked(view, scenario: "all drawables held", isBlocked: { gate.isWaiting })
        XCTAssertEqual(loop.state.presentations, 0)
        XCTAssertEqual(renderer.pass1Runs, 0)
        gate.release()
        await eventually(timeout: .seconds(10), "newest snapshot after returning held drawables") {
            loop.state.lastPresented == view.handedOverGeneration && loop.state.idle
        }
        XCTAssertFalse(gate.didTimeOut)
        XCTAssertEqual(gate.mainThreadRequests + probe.mainThreadRequests, 0)
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved, 1)
        XCTAssertFalse(loop.state.presentedOutOfOrder)
    }

}

extension PreviewRenderLoopTests {
    func testReleasingTheViewStopsTheThreadAndFreesTheFrame() async throws {
        var (view, _, _, _) = try canvas()
        let executor = try loop(view)
        view.tick()
        await eventually(timeout: .seconds(2), "drawn") { executor.state.presentations >= 1 && executor.state.idle }
        XCTAssertNotNil(executor.readyFrameIdentity)
        weak let oldView = view
        view = EDRCanvasView(renderer: try makePreviewRenderer())
        await eventually(timeout: .seconds(2), "view released and executor stopped") {
            oldView == nil && executor.state.hasStopped
        }
        XCTAssertNil(executor.readyFrameIdentity)
    }

    func testResizeReachesTheLayerBetweenDrawsAndPreservesAppKitScale() async throws {
        let (view, _, _, _) = try canvas()
        let executor = try loop(view)
        view.layer?.contentsScale = 2 // stand-in for AppKit's backing update
        view.tick()
        await eventually(timeout: .seconds(2), "drawn") { executor.state.presentations >= 1 && executor.state.idle }
        view.frame = CGRect(x: 0, y: 0, width: 32, height: 24)
        view.layout()
        view.tick()
        await eventually(timeout: .seconds(2), "resized draw") {
            executor.state.lastPresented == view.handedOverGeneration && executor.state.idle
        }
        XCTAssertEqual((view.layer as? CAMetalLayer)?.drawableSize, CGSize(width: 32, height: 24))
        XCTAssertEqual(view.layer?.contentsScale, 2)
    }

    func testNilDrawableRetryIsPaced() async throws {
        let (view, _, probe, _) = try canvas()
        probe.handsOutNone = true
        view.tick()
        await eventually(timeout: .seconds(2), "retry started") { probe.requests >= 2 }
        let start = ContinuousClock.now
        let count = probe.requests
        try await Task.sleep(for: .milliseconds(200))
        let duration = (ContinuousClock.now - start).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        // Account for scheduler delays instead of assuming the sleep lasted
        // exactly 200 ms. At 8 ms intervals, the ceiling is 125 calls/s.
        XCTAssertLessThanOrEqual(probe.requests - count, Int(ceil(elapsed / 0.008)) + 2)
        view.renderLoop?.stop()
    }

    func testClosingAtZeroSizeClearsWhenTheCanvasGetsItsSizeBack() async throws {
        let (view, _, probe, _) = try canvas()
        let executor = try loop(view)
        view.tick()
        await eventually(timeout: .seconds(2), "drawn") { executor.state.presentations >= 1 && executor.state.idle }
        let requests = probe.requests
        view.frame = .zero
        view.layout()
        view.showsSyntheticRamp = false
        view.tick()
        await eventually(timeout: .seconds(2), "zero-size close") {
            executor.state.lastPresented == view.handedOverGeneration && executor.state.idle
        }
        XCTAssertNil(executor.readyFrameIdentity)
        XCTAssertEqual(probe.requests, requests)
        view.frame = CGRect(x: 0, y: 0, width: 32, height: 24)
        view.layout()
        view.tick()
        await eventually(timeout: .seconds(2), "nonzero-size clear") {
            executor.state.lastPresented == view.handedOverGeneration && executor.state.idle
        }
        XCTAssertEqual(probe.requests, requests + 1, "the previous photo must be cleared after resize")
    }

    func testPreparationFailureIsReportedOnceWithoutRetryAndNewInputCanRecover() async throws {
        let renderer = try makePreviewRenderer()
        let layer = offscreenLayer(renderer)
        let probe = DrawableProbe(standIn: layer)
        probe.install(on: renderer)
        var errors: [String] = []
        let view = EDRCanvasView(renderer: renderer, onError: { errors.append($0) })
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
        view.layout()
        view.showsSyntheticRamp = true
        renderer.preparationHook = { throw PreviewError.unavailable("Injected preparation failure") }
        let executor = try loop(view)
        view.tick()
        await eventually(timeout: .seconds(2), "reported error") { errors.count == 1 && executor.state.idle }
        let requests = probe.requests
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(probe.requests, requests)
        XCTAssertEqual(errors.count, 1)
        renderer.preparationHook = nil
        view.setNeedsRedraw()
        view.tick()
        await eventually(timeout: .seconds(2), "recovered on new input") {
            executor.state.lastPresented == view.handedOverGeneration && executor.state.idle
        }
        XCTAssertNotNil(executor.readyFrameIdentity)
    }
}

extension PreviewRenderLoopTests {
    func testRendererHooksCanChangeWhileTheExecutorIsDrawing() async throws {
        let (view, renderer, probe, _) = try canvas()
        let executor = try loop(view)
        probe.block = 0.001
        for _ in 0..<200 {
            probe.install(on: renderer)
            renderer.presentingCommandHook = { $0.label = "Concurrent hook probe" }
            renderer.preparationHook = {}
            view.setNeedsRedraw()
            view.tick()
            await Task.yield()
            renderer.presentingCommandHook = nil
            renderer.preparationHook = nil
        }
        await eventually(timeout: .seconds(3), "latest snapshot after hook changes") {
            executor.state.lastPresented == view.handedOverGeneration && executor.state.idle
        }
        XCTAssertEqual(probe.mainThreadRequests, 0)
    }
}

/// Only the render executor waits on this condition; the test/main actor opens
/// it. The deadline is a cleanup backstop, never a scheduling/performance oracle.
nonisolated private final class DrawablePressureGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let layer: CAMetalLayer?
    private var held: [any CAMetalDrawable] = []
    private var released = false
    private var waiting = false
    private var timedOut = false
    private var mainRequests = 0

    init(layer: CAMetalLayer? = nil) { self.layer = layer }
    var isWaiting: Bool { condition.withLock { waiting } }
    var didTimeOut: Bool { condition.withLock { timedOut } }
    var mainThreadRequests: Int { condition.withLock { mainRequests } }

    func holdDrawables() -> Int {
        guard let layer else { return 0 }
        let drawables = autoreleasepool {
            (0..<layer.maximumDrawableCount).compactMap { _ in layer.nextDrawable() }
        }
        return condition.withLock { held = drawables; return held.count }
    }

    func waitForRelease() {
        condition.lock()
        defer { condition.unlock() }
        if Thread.isMainThread { mainRequests += 1 }
        waiting = true
        let deadline = Date().addingTimeInterval(30)
        while !released {
            if !condition.wait(until: deadline) { timedOut = true; break }
        }
        waiting = false
    }

    func release() {
        condition.lock()
        held.removeAll()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor extension PreviewRenderLoopTests {
    /// Absolute timing belongs to an explicitly quiet, unsanitized run. Keep
    /// the original budgets rather than weakening them for concurrent CI load.
    func testQuietPressureRetainsOriginalMainQueueBudgets() async throws {
        guard ProcessInfo.processInfo.environment["HYPERDR_QUIET_PRESSURE"] == "1" else {
            throw XCTSkip("Set HYPERDR_QUIET_PRESSURE=1 on a quiet machine for the original 36 ms budget")
        }
        for scenario in 0..<3 {
            let (view,renderer,probe,layer)=try canvas()
            let executor=try loop(view)
            var held:[any CAMetalDrawable]=[]
            let event=try XCTUnwrap(renderer.device.makeSharedEvent())
            if scenario==0 { probe.block=1;probe.handsOutNone=true }
            if scenario==1 {
                let next=Mutex<UInt64>(0)
                renderer.presentingCommandHook={ command in
                    let value=next.withLock { $0 += 1;return $0 }
                    command.encodeWaitForEvent(event,value:value)
                    DispatchQueue.global().asyncAfter(deadline:.now()+0.25) { event.signaledValue=value }
                }
            }
            if scenario==2 {
                for _ in 0..<layer.maximumDrawableCount {
                    if let drawable=layer.nextDrawable() { held.append(drawable) }
                }
                XCTAssertEqual(held.count,layer.maximumDrawableCount)
            }
            checkQuiet(await quietDrive(view,seconds:5),["quiet source","quiet GPU","quiet held pool"][scenario])
            held.removeAll();probe.block=0;probe.handsOutNone=false
            renderer.presentingCommandHook=nil
            executor.stop()
            await eventually(timeout:.seconds(10),"quiet executor cleanup") { executor.state.hasStopped }
            XCTAssertEqual(probe.mainThreadRequests,0)
            XCTAssertLessThanOrEqual(renderer.maxInFlightObserved,1)
        }
    }
    private struct QuietPressure {
        var tickDurations: [Duration] = []
        var probeGaps: [Duration] = []
        var maxProbeGap: Duration { probeGaps.max() ?? .zero }
        var p99ProbeGap: Duration { Self.p99(probeGaps) }
        var p99: Duration { Self.p99(tickDurations) }
        static func p99(_ values: [Duration]) -> Duration {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return .zero }
            return sorted[Swift.max(0, Int((Double(sorted.count) * 0.99).rounded(.up)) - 1)]
        }
        var max: Duration { tickDurations.max() ?? .zero }
    }

    /// 120 Hz of transform changes and ticks for `seconds`, with a main-queue
    /// probe firing every 4 ms; records each tick's time in canvas code and
    /// the longest gap between probe firings.
    private func quietDrive(_ view: EDRCanvasView, seconds: Double) async -> QuietPressure {
        var result = QuietPressure()
        var firings: [ContinuousClock.Instant] = []
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .nanoseconds(0))
        timer.setEventHandler { MainActor.assumeIsolated { firings.append(.now) } }
        timer.resume()
        let clock = ContinuousClock()
        let end = clock.now + .milliseconds(Int(seconds * 1000))
        var step = 0
        while clock.now < end {
            step += 1
            let start = clock.now
            view.transform.zoom = step.isMultiple(of: 2) ? 1 : 1.5
            view.setNeedsRedraw()
            view.tick()
            result.tickDurations.append(clock.now - start)
            try? await Task.sleep(for: .microseconds(8333))
        }
        timer.cancel()
        result.probeGaps = zip(firings, firings.dropFirst()).map { $1 - $0 }
        return result
    }

    private func checkQuiet(_ pressure: QuietPressure, _ scenario: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        print("A2b-2 \(scenario): ticks=\(pressure.tickDurations.count) p99=\(pressure.p99) "
            + "max=\(pressure.max) probeP99Gap=\(pressure.p99ProbeGap) probeMaxGap=\(pressure.maxProbeGap)")
        XCTAssertGreaterThan(pressure.tickDurations.count, 100, scenario, file: file, line: line)
        XCTAssertLessThanOrEqual(pressure.p99, .milliseconds(1), "\(scenario) p99", file: file, line: line)
        XCTAssertLessThanOrEqual(pressure.max, .milliseconds(4), "\(scenario) max", file: file, line: line)
        // A 4 ms timer, so a 16 ms delay is a 20 ms gap. The canvas code
        // itself is bounded above; the main queue also serves XCTest and
        // shares a busy machine, so one outlier is allowed up to two 120 Hz
        // frames (seen once in 12 runs: 20.5 ms while ticks peaked at 0.5 ms).
        XCTAssertLessThanOrEqual(pressure.p99ProbeGap, .milliseconds(20), "\(scenario) probe p99",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(pressure.maxProbeGap, .milliseconds(36), "\(scenario) probe max",
                                 file: file, line: line)
    }

}
