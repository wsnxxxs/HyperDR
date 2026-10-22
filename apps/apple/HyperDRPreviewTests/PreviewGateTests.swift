import Foundation
import Metal
import QuartzCore
import XCTest
@testable import HyperDR

/// A2b-1: at most one presenting command buffer in flight. Headless: an
/// offscreen `CAMetalLayer` and an injected drawable source, no window.
@MainActor final class PreviewGateTests: XCTestCase {
    private let side = 16

    private func makeLayer(_ renderer: PreviewRenderer) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: side, height: side)
        return layer
    }

    private var transform: CanvasTransform {
        CanvasTransform(imageSize: CGSize(width: side, height: side),
                        viewport: CGSize(width: side, height: side))
    }

    /// A pair whose every pixel shows `base · 2^stops` on an 8× screen.
    private func uniform(_ renderer: PreviewRenderer, base: Float, stops: Float) throws -> CanvasComposition {
        let count = 4 * 4
        let pair = try makeDisplayPair(renderer.device, base: [Float](repeating: base, count: count * 3), width: 4, height: 4,
                                       gain: [Float](repeating: stops, count: count), alternateHeadroom: Double(max(stops, 1)))
        return CanvasComposition(edited: pair, headroom: 8)
    }

    /// The red channel at the drawable's centre, after the GPU finished.
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

    /// While the previous presentation is in flight, `draw` does not call
    /// `nextDrawable` and asks for a retry; once it completes, the next draw
    /// presents the frame prepared in the meantime.
    func testDrawWaitsForThePreviousPresentation() async throws {
        let renderer = try makePreviewRenderer()
        let probe = DrawableProbe()
        probe.install(on: renderer)
        let layer = makeLayer(renderer)

        var content = try uniform(renderer, base: 0.5, stops: 0)
        XCTAssertTrue(try renderer.draw(in: layer, composition: content, transform: transform))
        XCTAssertEqual(probe.requests, 1)
        XCTAssertEqual(renderer.inFlight, 1)
        XCTAssertTrue(renderer.isBusy)

        // A newer frame arrives while the GPU is behind.
        content = try uniform(renderer, base: 1, stops: 3)
        XCTAssertFalse(try renderer.draw(in: layer, composition: content, transform: transform))
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertFalse(try renderer.draw(in: layer, composition: content, transform: transform))
        XCTAssertEqual(probe.requests, 1, "a closed gate never asks for a drawable")
        XCTAssertEqual(renderer.inFlight, 1)

        await eventually("the presentation to complete") { !renderer.isBusy }
        XCTAssertTrue(try renderer.draw(in: layer, composition: content, transform: transform))
        XCTAssertFalse(renderer.needsRetry)
        XCTAssertEqual(probe.requests, 2)
        let drawable = try XCTUnwrap(probe.last)
        await eventually("the second presentation to complete") { !renderer.isBusy }
        XCTAssertEqual(try centreRed(renderer, drawable), 8, accuracy: 0.01,
                       "the retry shows the latest frame")
    }

    /// `clear` obeys the same gate and still lets go of the frame at once.
    func testClearWaitsForThePreviousPresentation() async throws {
        let renderer = try makePreviewRenderer()
        let probe = DrawableProbe()
        probe.install(on: renderer)
        let layer = makeLayer(renderer)
        let content = try uniform(renderer, base: 0.5, stops: 0)
        XCTAssertTrue(try renderer.draw(in: layer, composition: content, transform: transform))

        XCTAssertFalse(renderer.clear(in: layer))
        XCTAssertNil(renderer.readyFrameIdentity, "the frame is released even when gated")
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertEqual(probe.requests, 1)

        await eventually("the presentation to complete") { !renderer.isBusy }
        XCTAssertTrue(renderer.clear(in: layer))
        XCTAssertFalse(renderer.needsRetry)
        XCTAssertEqual(probe.requests, 2)
    }

    /// A nil drawable commits nothing, so it never closes the gate: the next
    /// tick asks again straight away.
    func testNilDrawableDoesNotCountAsInFlight() throws {
        let renderer = try makePreviewRenderer()
        let probe = DrawableProbe()
        probe.install(on: renderer)
        let layer = makeLayer(renderer)
        let content = try uniform(renderer, base: 0.5, stops: 0)

        probe.handsOutNone = true
        XCTAssertFalse(try renderer.draw(in: layer, composition: content, transform: transform))
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertEqual(renderer.inFlight, 0)
        XCTAssertFalse(renderer.isBusy)

        probe.handsOutNone = false
        XCTAssertTrue(try renderer.draw(in: layer, composition: content, transform: transform))
        XCTAssertFalse(renderer.needsRetry)
        XCTAssertEqual(probe.requests, 2)
        XCTAssertEqual(renderer.inFlight, 1)
    }

}
