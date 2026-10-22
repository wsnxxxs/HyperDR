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

    func testZoomIsClampedToActualPixelRange() {
        var fit = transform()
        fit = fit.zoomed(to: 99, anchorInView: CGPoint(x: 450, y: 300))
        XCTAssertEqual(fit.zoom, 4 * 6000 / 1800, accuracy: 1e-9)
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
        let plain = try? XCTUnwrap(transform().wheelZoom(fromZoom: 1, deltaY: -100, ctrl: false))
        XCTAssertEqual(plain ?? 0, exp(0.15), accuracy: 1e-6)
        let pinch = try? XCTUnwrap(transform().wheelZoom(fromZoom: 1, deltaY: -100, ctrl: true))
        XCTAssertEqual(pinch ?? 0, exp(1.0), accuracy: 1e-6)
        XCTAssertNil(transform().wheelZoom(fromZoom: 1, deltaY: -0.01, ctrl: false))
        XCTAssertEqual(transform().wheelZoom(fromZoom: 13, deltaY: -100, ctrl: true) ?? 0,
                       4 * 6000 / 1800, accuracy: 1e-9)
    }

    /// The photo rect is published in the same coordinates the overlays use,
    /// and the display pass snaps it to whole device pixels.
    func testNormalisedDisplayRectIsSnappedToDevicePixels() {
        var fit = transform()
        fit = fit.zoomed(to: 2, anchorInView: CGPoint(x: 450, y: 300))
        let frame = fit.imageFrame
        let rect = EDRDisplayPass.normalisedRect(fit, drawableSize: CGSize(width: 1800, height: 1200))
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
        let rect = EDRDisplayPass.normalisedRect(fit, drawableSize: CGSize(width: 1800, height: 1200))
        let deviceWidth = (Double(rect.z) - Double(rect.x)) / 2 * 1800
        XCTAssertEqual(deviceWidth, 6000, accuracy: 1)
    }
}

extension CanvasTransformTests {
    func testLargePhotoCanReachActualPixelsAndFourHundredPercent() {
        let canvas = CanvasModel()
        canvas.setViewport(CGSize(width: 800, height: 600), backingScale: 2)
        canvas.setImageSize(PixelSize(width: 9504, height: 6336))
        XCTAssertEqual(canvas.zoomReadout, .fit)
        XCTAssertEqual(canvas.zoomPercent, 17)
        canvas.zoomToActualPixels()
        XCTAssertEqual(canvas.transform.zoom, 5.94, accuracy: 1e-9)
        XCTAssertEqual(canvas.zoomReadout, .percent(100))
        for _ in 0..<20 { canvas.zoomIn() }
        XCTAssertEqual(canvas.zoomReadout, .percent(400))
        XCTAssertFalse(canvas.canZoomIn)
        XCTAssertEqual(canvas.transform.maxZoom, 23.76, accuracy: 1e-9)
        canvas.zoomOut()
        XCTAssertEqual(canvas.zoomReadout, .percent(300))
        canvas.zoomOut()
        XCTAssertEqual(canvas.zoomReadout, .percent(200))
        canvas.fitToWindow()
        canvas.zoomIn()
        XCTAssertEqual(canvas.zoomReadout, .percent(25))
        canvas.zoomOut()
        XCTAssertEqual(canvas.zoomReadout, .fit)
    }

    func testStopsIncludeFitAndFractionsWithoutDuplicateSteps() {
        let fit = transform(imageW: 16000, imageH: 12000, viewW: 1000, viewH: 750)
        XCTAssertEqual(fit.zoomStops, [1, 2, 8 / 3, 4, 16 / 3, 8, 16, 24, 32])
        XCTAssertEqual(fit.zoomStops.filter { $0 == 1 }.count, 1)
        let tiny = transform(imageW: 100, imageH: 100, viewW: 1000, viewH: 1000)
        XCTAssertEqual(tiny.maxZoom, 4)
        XCTAssertEqual(tiny.zoomStops, [1, 4])
    }

    func testWheelAndPinchClampAtDynamicLimitAndResizeCorrectsPan() {
        let fit = transform(imageW: 9504, viewW: 800)
        XCTAssertEqual(fit.wheelZoom(fromZoom: 20, deltaY: -100000, ctrl: true), fit.maxZoom)
        XCTAssertEqual(fit.zoomed(to: 10000, anchorInView: .zero).zoom, fit.maxZoom)
        let canvas = CanvasModel()
        canvas.setViewport(CGSize(width: 800, height: 600), backingScale: 1)
        canvas.setImageSize(PixelSize(width: 6000, height: 4000))
        for _ in 0..<30 { canvas.zoomIn() }
        var moved = canvas.transform.panned(by: CGSize(width: 50000, height: 50000))
        canvas.apply(moved)
        canvas.setViewport(CGSize(width: 1200, height: 900), backingScale: 2)
        moved = canvas.transform
        XCTAssertEqual(canvas.zoomPercent, 400)
        XCTAssertEqual(moved.zoom, moved.maxZoom)
        XCTAssertEqual(moved.pan, moved.clampedPan(moved.pan))
    }
}
