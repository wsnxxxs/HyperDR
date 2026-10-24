import CoreGraphics
import HyperDRRecipe
import XCTest
import simd
@testable import HyperDR

/// The crop box's hit areas and the glide that fits the crop after a drag
/// (`CropDrag.at`, `CropLayout.moving`).
@MainActor final class CropInteractionTests: XCTestCase {
    private let box = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testCornersAndEdgesTakePrecedenceNearTheBox() {
        let reach: CGFloat = 24
        XCTAssertEqual(CropDrag.at(CGPoint(x: 90, y: 92), box: box, reach: reach), .resize(x: -1, y: -1))
        XCTAssertEqual(CropDrag.at(CGPoint(x: 515, y: 410), box: box, reach: reach), .resize(x: 1, y: 1))
        XCTAssertEqual(CropDrag.at(CGPoint(x: 300, y: 80), box: box, reach: reach), .resize(x: 0, y: -1))
        XCTAssertEqual(CropDrag.at(CGPoint(x: 300, y: 250), box: box, reach: reach), .move)
        XCTAssertNil(CropDrag.at(CGPoint(x: 300, y: 60), box: box, reach: reach))
    }

    /// Outside, an edge reaches a full 2 × 24 pt band (beyond a 44 pt target).
    func testTheEdgeBandIsAtLeastATouchTargetWide() {
        let reach: CGFloat = 24
        XCTAssertEqual(CropDrag.at(CGPoint(x: 300, y: 100 - 23), box: box, reach: reach), .resize(x: 0, y: -1))
        XCTAssertEqual(CropDrag.at(CGPoint(x: 300, y: 100 + 23), box: box, reach: reach), .resize(x: 0, y: -1))
    }

    /// A small box keeps a middle to move it by.
    func testASmallBoxStillMoves() {
        let small = CGRect(x: 100, y: 100, width: 60, height: 60)
        XCTAssertEqual(CropDrag.at(CGPoint(x: 130, y: 130), box: small, reach: 24), .move)
        XCTAssertEqual(CropDrag.at(CGPoint(x: 95, y: 130), box: small, reach: 24), .resize(x: -1, y: 0))
    }

    func testTheGlideEndsOnTheFittedPlacement() {
        let photo = GeometrySize(width: 6000, height: 4000)
        var geometry = Geometry.identity
        let start = CropLayout(photo: photo, geometry: geometry, viewport: CGSize(width: 800, height: 600), margin: 28)
        geometry.crop = CropRect(centre: GeometryPoint(x: 1000, y: 500), size: GeometrySize(width: 2000, height: 1500),
                                 frame: photo)
        let held = start.with(geometry), target = held.fitted
        XCTAssertFalse(held.settles(at: target))
        XCTAssertEqual(held.moving(towards: target, 0), held)
        XCTAssertTrue(held.moving(towards: target, 1).settles(at: target))
        // Half way the zoom is the geometric mean, so it reads evenly.
        XCTAssertEqual(held.moving(towards: target, 0.5).scale, (held.scale * target.scale).squareRoot(), accuracy: 1e-9)
        // The fitted crop sits in the middle of the canvas.
        XCTAssertEqual(target.cropRect.midX, 400, accuracy: 1e-6)
        XCTAssertEqual(target.cropRect.midY, 300, accuracy: 1e-6)
    }
    func testLockedCornersShrinkOnEitherAxisAndDiagonally() {
        let start = GeometryRect(centre: GeometryPoint(x: 0, y: 0), size: GeometrySize(width: 100, height: 100))
        let quad = GeometryRect(centre: start.centre, size: GeometrySize(width: 400, height: 400)).corners
        for x in [-1, 1] {
            for y in [-1, 1] {
                for delta in [GeometryPoint(x: Double(-20 * x), y: 0),
                              GeometryPoint(x: 0, y: Double(-20 * y)),
                              GeometryPoint(x: Double(-20 * x), y: Double(-20 * y))] {
                    let result = CropDrag.resize(x: x, y: y).apply(delta, to: start, ratio: 1, quad: quad, minimum: 10)
                    XCTAssertEqual(result.width, 80, accuracy: 1e-9)
                    XCTAssertEqual(result.height, 80, accuracy: 1e-9)
                    XCTAssertEqual(result.centre.x - Double(x) * result.width / 2, -Double(x) * 50, accuracy: 1e-9)
                    XCTAssertEqual(result.centre.y - Double(y) * result.height / 2, -Double(y) * 50, accuracy: 1e-9)
                }
            }
        }
    }

    func testDisplayUsesTheSameOddPixelWindowAsRasterization() {
        let photo = GeometrySize(width: 95, height: 63)
        for turns in 0..<4 {
            let geometry = Geometry(quarterTurns: turns, flipped: turns % 2 == 0,
                                    crop: CropRect(centreX: 0.071, centreY: -0.043, width: 0.53, height: 0.61))
            let output = geometry.outputSize(of: photo)
            let layout = CropLayout(photo: photo, geometry: geometry,
                                    viewport: CGSize(width: output.width, height: output.height), margin: 0)
            let display = layout.display(clipsToCrop: true, dimsOutsideCrop: false)
            let expected = geometry.photoToOutput(for: photo).inverse.apply(GeometryPoint(x: 0.5, y: 0.5))
            let uv = display.photoFromCanvas * SIMD3<Float>(0.5 / Float(output.width), 0.5 / Float(output.height), 1)
            XCTAssertEqual(Double(uv.x / uv.z), expected.x / photo.width, accuracy: 1e-6)
            XCTAssertEqual(Double(uv.y / uv.z), expected.y / photo.height, accuracy: 1e-6)
        }
    }

    func testThinCropsCanShrinkWithoutInflatingTheirShortEdge() {
        for size in [GeometrySize(width: 4000, height: 200), GeometrySize(width: 200, height: 4000),
                     GeometrySize(width: 400, height: 100)] {
            let start = GeometryRect(centre: GeometryPoint(x: 0, y: 0), size: size)
            let delta = GeometryPoint(x: -size.width * 0.1, y: -size.height * 0.1)
            for ratio in [Double?.none, size.width / size.height] {
                let result = CropDrag.resize(x: 1, y: 1).resolve(delta, to: start, ratio: ratio,
                                                               quad: start.corners, minimum: 240)
                XCTAssertEqual(result.rect.width, size.width * 0.9, accuracy: 1e-9)
                XCTAssertEqual(result.rect.height, size.height * 0.9, accuracy: 1e-9)
                XCTAssertEqual(result.rect.minX, start.minX, accuracy: 1e-9)
                XCTAssertEqual(result.rect.minY, start.minY, accuracy: 1e-9)
                XCTAssertFalse(result.stopped)
                XCTAssertTrue(result.rect.corners.allSatisfy { Geometry.contains(start.corners, $0) })
            }
        }
    }

    func testMinimumLongEdgeKeepsTheLockedRatioAndNeverInflatesASmallStart() {
        for size in [GeometrySize(width: 4000, height: 200), GeometrySize(width: 200, height: 4000),
                     GeometrySize(width: 100, height: 5)] {
            let start = GeometryRect(centre: GeometryPoint(x: 0, y: 0), size: size)
            let result = CropDrag.resize(x: 1, y: 1).apply(GeometryPoint(x: -10000, y: -10000), to: start,
                ratio: size.width / size.height, quad: start.corners, minimum: 240)
            XCTAssertEqual(max(result.width, result.height), min(240, max(size.width, size.height)), accuracy: 1e-9)
            XCTAssertEqual(result.width / result.height, size.width / size.height, accuracy: 1e-9)
            XCTAssertEqual(result.minX, start.minX, accuracy: 1e-9)
            XCTAssertEqual(result.minY, start.minY, accuracy: 1e-9)
        }
    }

    /// Entering the pane, the cropped frame still shown lands on its crop:
    /// the crop's corners on the canvas are the corners of that frame.
    func testACroppedFrameIsDrawnOnItsCropInThePane() {
        let photo = GeometrySize(width: 6000, height: 4000)
        let geometry = Geometry(angle: 7, quarterTurns: 1, aspect: .free,
                                crop: CropRect(centreX: 0.04, centreY: -0.03, width: 0.5, height: 0.4))
        let layout = CropLayout(photo: photo, geometry: geometry, viewport: CGSize(width: 800, height: 600), margin: 28)
        let display = layout.display(clipsToCrop: false, dimsOutsideCrop: true, rendered: geometry)
        let box = layout.cropRect
        func output(_ point: CGPoint) -> CGPoint {
            let q = display.photoFromCanvas * SIMD3<Float>(Float(point.x / 800), Float(point.y / 600), 1)
            return CGPoint(x: Double(q.x / q.z), y: Double(q.y / q.z))
        }
        for (point, expected) in [(CGPoint(x: box.minX, y: box.minY), CGPoint(x: 0, y: 0)),
                                  (CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: 1, y: 1)),
                                  (CGPoint(x: box.midX, y: box.midY), CGPoint(x: 0.5, y: 0.5))] {
            let at = output(point)
            XCTAssertEqual(at.x, expected.x, accuracy: 1e-4)
            XCTAssertEqual(at.y, expected.y, accuracy: 1e-4)
        }
        // With the whole photo rendered, the default is unchanged.
        XCTAssertEqual(layout.display(clipsToCrop: false, dimsOutsideCrop: true),
                       layout.display(clipsToCrop: false, dimsOutsideCrop: true, rendered: .identity))
    }

    /// The canvas draws the edit alone while it draws through the geometry:
    /// in the pane, and after it until the cropped frame replaces the whole photo.
    func testTheGeometryTransitionCoversLeavingThePane() {
        let cropped = Geometry(crop: CropRect(centreX: 0, centreY: 0, width: 0.5, height: 0.5))
        XCTAssertTrue(CropLayout.drawsThroughGeometry(shown: .identity, recipe: .identity, cropping: true))
        XCTAssertTrue(CropLayout.drawsThroughGeometry(shown: cropped, recipe: cropped, cropping: true))
        // Left, the whole photo still shown: drawn through the crop.
        XCTAssertTrue(CropLayout.drawsThroughGeometry(shown: .identity, recipe: cropped, cropping: false))
        // The cropped frame has arrived, or there is no crop: the comparison applies.
        XCTAssertFalse(CropLayout.drawsThroughGeometry(shown: cropped, recipe: cropped, cropping: false))
        XCTAssertFalse(CropLayout.drawsThroughGeometry(shown: .identity, recipe: .identity, cropping: false))
    }
}
