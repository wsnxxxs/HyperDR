import CoreGraphics
import HyperDRRecipe
import XCTest
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
}
