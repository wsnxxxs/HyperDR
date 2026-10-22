import AppKit
import QuartzCore
import XCTest
@testable import HyperDR

@MainActor final class CanvasVisibilityTests: XCTestCase {
    func testHidingViewReleasesPreparedWithoutAnotherDisplayTick() async throws {
        let renderer = try makePreviewRenderer()
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 16, height: 16)
        let probe = DrawableProbe(standIn: layer)
        probe.install(on: renderer)
        let parent = NSView()
        let view = EDRCanvasView(renderer: renderer)
        parent.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        view.layout()
        view.showsSyntheticRamp = true
        let loop = try XCTUnwrap(view.renderLoop)
        for hideAncestor in [false, true] {
            view.setNeedsRedraw()
            view.tick()
            await eventually(timeout: .seconds(10)) { loop.state.idle && loop.readyFrameIdentity != nil }
            let requests = probe.requests
            if hideAncestor { parent.isHidden = true } else { view.isHidden = true }
            // No display callback: AppKit stops the link while hidden.
            await eventually(timeout: .seconds(10)) { loop.state.idle && loop.readyFrameIdentity == nil }
            XCTAssertEqual(probe.requests, requests)
            if hideAncestor { parent.isHidden = false } else { view.isHidden = false }
            XCTAssertTrue(view.needsRedraw)
            view.tick()
            await eventually(timeout: .seconds(10)) { loop.state.idle && loop.readyFrameIdentity != nil }
        }
    }
}
