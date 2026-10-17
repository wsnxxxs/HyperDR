import CoreGraphics
import XCTest
@testable import HyperDR

@MainActor final class CanvasTransformTests: XCTestCase {
    private func transform(imageW: CGFloat = 6000, imageH: CGFloat = 4000,
                           viewW: CGFloat = 900, viewH: CGFloat = 600,
                           scale: CGFloat = 2) -> CanvasTransform {
        CanvasTransform(imageSize: CGSize(width: imageW, height: imageH),
                        viewport: CGSize(width: viewW, height: viewH),
                        backingScale: scale)
    }

    /// Web `fittedSize`: the photo fits inside the viewer with no gutter.
    func testFitCentresThePhoto() {
        let fit = transform()
        let frame = fit.imageFrame
        XCTAssertEqual(fit.fittedSize.width, 900, accuracy: 1e-6)
        XCTAssertEqual(fit.fittedSize.height, 600, accuracy: 1e-6)
        XCTAssertEqual(frame.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(frame.minY, 0, accuracy: 1e-6)
    }

    func testFitUsesTheTighterAxis() {
        // A tall photo: height limits the fit, and the photo is centred.
        let fit = transform(imageW: 1000, imageH: 2000)
        XCTAssertEqual(fit.fittedSize.height, 600, accuracy: 1e-6)
        XCTAssertEqual(fit.fittedSize.width, 300, accuracy: 1e-6)
        XCTAssertEqual(fit.imageFrame.minX, 300, accuracy: 1e-6)
    }

    /// `zoomAtPointer`: the detail under the pointer stays under the pointer.
    func testZoomKeepsThePointerAnchorFixed() {
        var fit = transform()
        let anchor = CGPoint(x: 700, y: 450)
        fit = fit.zoomed(to: 2, anchorInView: anchor)
        let frame = fit.imageFrame
        // Distance from the photo's centre to the anchor, measured in fitted
        // units, is preserved: (700-450) is 250 right and 150 below centre.
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual((anchor.x - centre.x) / fit.zoom, 250, accuracy: 1e-6)
        XCTAssertEqual((anchor.y - centre.y) / fit.zoom, 150, accuracy: 1e-6)
        XCTAssertEqual(fit.zoom, 2, accuracy: 1e-9)
    }

    func testZoomIsClampedToTheWebRange() {
        var fit = transform()
        fit = fit.zoomed(to: 9, anchorInView: CGPoint(x: 450, y: 300))
        XCTAssertEqual(fit.zoom, 4, accuracy: 1e-9)
        fit = fit.zoomed(to: 0.2, anchorInView: CGPoint(x: 450, y: 300))
        XCTAssertEqual(fit.zoom, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.pan, .zero)
    }

    /// `clampedPan`: at most `size * (zoom - 1) / 2` from the centre.
    func testPanIsClampedToTheZoomedOverflow() {
        var deep = transform()
        deep = deep.zoomed(to: 4, anchorInView: CGPoint(x: 450, y: 300))
        let limit = deep.panLimit
        XCTAssertEqual(limit.width, 900 * 3 / 2, accuracy: 1e-6)
        XCTAssertEqual(limit.height, 600 * 3 / 2, accuracy: 1e-6)
        let pushed = deep.panned(by: CGSize(width: 10_000, height: -10_000))
        XCTAssertEqual(pushed.pan.x, limit.width, accuracy: 1e-6)
        XCTAssertEqual(pushed.pan.y, -limit.height, accuracy: 1e-6)
        XCTAssertEqual(pushed.imageFrame.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(pushed.imageFrame.maxY, 600, accuracy: 1e-6)
    }

    /// `wheelZoomLevel`: a trackpad pinch (ctrl-wheel) zooms faster, and a
    /// sub-threshold delta is ignored so the canvas does not jitter.
    func testWheelZoomMatchesTheWebCurve() {
        let plain = try? XCTUnwrap(CanvasTransform.wheelZoom(fromZoom: 1, deltaY: -100, ctrl: false))
        XCTAssertEqual(plain ?? 0, exp(0.15), accuracy: 1e-6)
        let pinch = try? XCTUnwrap(CanvasTransform.wheelZoom(fromZoom: 1, deltaY: -100, ctrl: true))
        XCTAssertEqual(pinch ?? 0, exp(1.0), accuracy: 1e-6)
        XCTAssertNil(CanvasTransform.wheelZoom(fromZoom: 1, deltaY: -0.01, ctrl: false))
        XCTAssertEqual(CanvasTransform.wheelZoom(fromZoom: 3.9, deltaY: -100, ctrl: true) ?? 0,
                       4, accuracy: 1e-9)
    }

    /// The photo rect is published in the same coordinates the overlays use,
    /// and the display pass snaps it to whole device pixels.
    func testNormalisedDisplayRectIsSnappedToDevicePixels() {
        var fit = transform()
        fit = fit.zoomed(to: 2, anchorInView: CGPoint(x: 450, y: 300))
        let frame = fit.imageFrame
        let rect = PreviewRenderer.normalisedRect(fit, drawableSize: CGSize(width: 1800, height: 1200))
        let scale: CGFloat = 1800 / 900
        func pixelX(_ value: Float) -> CGFloat { (CGFloat(value) + 1) / 2 * 1800 }
        // NDC y grows upwards while the view's origin is top-left.
        func pixelY(_ value: Float) -> CGFloat { (1 - CGFloat(value)) / 2 * 1200 }
        XCTAssertEqual(pixelX(rect.x), (frame.minX * scale).rounded(), accuracy: 1e-4)
        XCTAssertEqual(pixelX(rect.z), (frame.maxX * scale).rounded(), accuracy: 1e-4)
        XCTAssertEqual(pixelY(rect.y), (frame.maxY * scale).rounded(), accuracy: 1e-4)
        XCTAssertEqual(pixelY(rect.w), (frame.minY * scale).rounded(), accuracy: 1e-4)
    }

    /// At 100% one source pixel covers exactly one backing pixel.
    func testActualPixelsMapOneSourcePixelPerBackingPixel() {
        var fit = transform()
        let zoom = 6000 / (fit.fittedSize.width * fit.backingScale)
        fit = fit.zoomed(to: zoom, anchorInView: CGPoint(x: 450, y: 300))
        let rect = PreviewRenderer.normalisedRect(fit, drawableSize: CGSize(width: 1800, height: 1200))
        let deviceWidth = (Double(rect.z) - Double(rect.x)) / 2 * 1800
        XCTAssertEqual(deviceWidth, 6000, accuracy: 1)
    }
}
