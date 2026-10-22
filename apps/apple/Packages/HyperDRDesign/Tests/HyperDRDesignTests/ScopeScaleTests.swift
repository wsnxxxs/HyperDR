import XCTest
@testable import HyperDRDesign

final class ScopeScaleTests: XCTestCase {
    func testAnchors() {
        for (value, position) in [(0.0,0.0),(1,0.7),(2,0.775),(4,0.85),(8,0.925),(16,1)] {
            XCTAssertEqual(ScopeScale.position(value),position,accuracy:1e-12)
        }
        XCTAssertEqual(ScopeScale.position(.nan),0)
        XCTAssertEqual(ScopeScale.position(-1),0)
        XCTAssertEqual(ScopeScale.position(32),1)
    }

    func testOverlaySpecificationAndWhiteConversion() {
        XCTAssertEqual(CanvasOverlayStyle.maskSRGB,0xC026D3)
        XCTAssertEqual(CanvasOverlayStyle.maskOpacity,0.47)
        XCTAssertEqual(CanvasOverlayStyle.stripePeriodPoints,8)
        XCTAssertEqual(CanvasOverlayStyle.stripeWidthPoints,3)
        let white = CanvasOverlayStyle.linearDisplayP3(0xFFFFFF)
        XCTAssertEqual(white.x,1,accuracy:0.0002)
        XCTAssertEqual(white.y,1,accuracy:0.0002)
        XCTAssertEqual(white.z,1,accuracy:0.0003)
    }
}
