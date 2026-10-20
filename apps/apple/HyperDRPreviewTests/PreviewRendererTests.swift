import Foundation
import Metal
import QuartzCore
import XCTest
@testable import HyperDR

/// The renderer's presentation retries; the pixels are `CanvasCompositionTests`'.
@MainActor final class PreviewRendererTests: XCTestCase {
    private func ramp(_ renderer: PreviewRenderer) throws -> CanvasComposition {
        CanvasComposition(edited: try PreviewRenderer.syntheticRamp(device: renderer.device, width: 16, height: 16))
    }

    /// No drawable (a layer without a device hands out none) presents nothing
    /// and is retried: the next call, with a working layer, draws.
    func testNilDrawableIsRetriedOnTheNextDraw() async throws {
        let renderer = try makePreviewRenderer()
        let content = try ramp(renderer)
        let transform = CanvasTransform(imageSize: CGSize(width: 16, height: 16),
                                        viewport: CGSize(width: 16, height: 16))
        let broken = CAMetalLayer()
        broken.drawableSize = CGSize(width: 16, height: 16)
        XCTAssertFalse(try renderer.draw(in: broken, composition: content, transform: transform))
        XCTAssertTrue(renderer.needsRetry)

        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .rgba16Float
        layer.drawableSize = CGSize(width: 16, height: 16)
        XCTAssertTrue(try renderer.draw(in: layer, composition: content, transform: transform))
        XCTAssertFalse(renderer.needsRetry)
        XCTAssertNotNil(renderer.readyFrameIdentity)
        // The in-flight gate (A2b-1) holds further presents until it completes.
        await eventually("the presentation to complete") { !renderer.isBusy }

        XCTAssertFalse(renderer.clear(in: broken))
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertNil(renderer.readyFrameIdentity, "clear lets go of the pairs even when it cannot present")
        XCTAssertTrue(renderer.clear(in: layer))
        XCTAssertFalse(renderer.needsRetry)
    }

    /// A miss followed by a layer with nothing to present (zero size) must not
    /// leave `needsRetry` set, or the view retries every tick.
    func testNothingToPresentClearsTheRetryFlag() throws {
        let renderer = try makePreviewRenderer()
        let content = try ramp(renderer)
        let transform = CanvasTransform(imageSize: CGSize(width: 16, height: 16),
                                        viewport: CGSize(width: 16, height: 16))
        let broken = CAMetalLayer()
        broken.drawableSize = CGSize(width: 16, height: 16)
        let empty = CAMetalLayer()

        XCTAssertFalse(try renderer.draw(in: broken, composition: content, transform: transform))
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertTrue(try renderer.draw(in: empty, composition: content, transform: transform))
        XCTAssertFalse(renderer.needsRetry, "zero-size layer")

        XCTAssertFalse(try renderer.draw(in: broken, composition: content, transform: transform))
        XCTAssertFalse(renderer.clear(in: broken))
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertFalse(renderer.clear(in: empty))
        XCTAssertTrue(renderer.needsRetry, "zero-size clear must be retried at a drawable size")
    }
}
