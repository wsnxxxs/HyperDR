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
        XCTAssertLessThan(original, 1, "the newest snapshot shows the SDR original")
        XCTAssertGreaterThan(hdr, original * 2)
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

    // MARK: - Judgement 2: main-thread blocking under pressure

    private struct Pressure {
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
    private func drive(_ view: EDRCanvasView, seconds: Double) async -> Pressure {
        var result = Pressure()
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

    private func check(_ pressure: Pressure, _ scenario: String,
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

    /// Drawables exhausted: every request waits 1 s, alternating with nil.
    func testPressureDrawableSourceBlocks() async throws {
        let (view, renderer, probe, _) = try canvas()
        let loop = try loop(view)
        probe.block = 1
        probe.handsOutNone = true
        check(await drive(view, seconds: 5), "drawable source blocks 1 s / nil")
        XCTAssertEqual(probe.mainThreadRequests, 0)
        probe.block = 0
        probe.handsOutNone = false
        view.setNeedsRedraw()
        view.tick()
        await eventually(timeout: .milliseconds(1500), "newest snapshot after relief") {
            loop.state.lastPresented == view.handedOverGeneration
        }
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved, 1)
        XCTAssertFalse(loop.state.presentedOutOfOrder)
    }

    /// GPU backlog: every presenting command buffer waits 250 ms on the GPU
    /// for a shared event before it can complete.
    func testPressureGPUBacklog() async throws {
        let (view, renderer, probe, _) = try canvas()
        let loop = try loop(view)
        let event = try XCTUnwrap(renderer.device.makeSharedEvent())
        let next = Mutex<UInt64>(0)
        renderer.presentingCommandHook = { command in
            let value = next.withLock { $0 += 1; return $0 }
            command.encodeWaitForEvent(event, value: value)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { event.signaledValue = value }
        }
        check(await drive(view, seconds: 5), "GPU completes 250 ms late")
        XCTAssertEqual(renderer.busyRefusals, 0, "the loop waits for completion rather than polling")
        let presentations = loop.state.presentations
        XCTAssertGreaterThan(presentations, 5)
        XCTAssertLessThan(presentations, 30, "at most one draw per 250 ms in flight")
        renderer.presentingCommandHook = nil
        view.setNeedsRedraw()
        view.tick()
        await eventually(timeout: .milliseconds(800), "newest snapshot after relief") {
            loop.state.lastPresented == view.handedOverGeneration
        }
        XCTAssertEqual(probe.mainThreadRequests, 0)
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved, 1)
        XCTAssertFalse(loop.state.presentedOutOfOrder)
    }

    /// Drawables held: the test keeps every drawable of the layer for 5 s,
    /// so the loop's `nextDrawable` times out after 1 s again and again.
    func testPressureDrawablesHeld() async throws {
        let (view, renderer, probe, layer) = try canvas()
        let loop = try loop(view)
        view.tick()
        await eventually("first presentation") { loop.state.presentations >= 1 && loop.state.idle }
        var held: [any CAMetalDrawable] = []
        for _ in 0..<layer.maximumDrawableCount {
            if let drawable = layer.nextDrawable() { held.append(drawable) }
        }
        XCTAssertEqual(held.count, layer.maximumDrawableCount)
        let before = loop.state.presentations
        check(await drive(view, seconds: 5), "all drawables held")
        // After its 1 s timeout `nextDrawable` hands out an extra drawable
        // anyway (also seen in the A2b-1 review's pool probe), so drawing slows
        // down rather than stops.
        let during = loop.state.presentations - before
        print("A2b-2 all drawables held: \(during) presentations in 5 s")
        XCTAssertLessThanOrEqual(during, 15)
        held.removeAll()
        view.setNeedsRedraw()
        view.tick()
        await eventually(timeout: .milliseconds(1500), "newest snapshot after relief") {
            loop.state.lastPresented == view.handedOverGeneration
        }
        XCTAssertEqual(probe.mainThreadRequests, 0)
        XCTAssertLessThanOrEqual(renderer.maxInFlightObserved, 1)
        XCTAssertFalse(loop.state.presentedOutOfOrder)
    }
}
