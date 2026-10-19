import CoreGraphics
import Foundation
import Testing
@testable import HyperDRDesign

@Test func theDividerStaysWithinFivePercentOfTheEdges() {
    let frame = CGRect(x: 100, y: 0, width: 400, height: 300)
    #expect(SplitGeometry.ratio(forX: 300, in: frame) == 0.5)
    #expect(SplitGeometry.ratio(forX: 0, in: frame) == 0.05)
    #expect(SplitGeometry.ratio(forX: 900, in: frame) == 0.95)
    #expect(SplitGeometry.dividerX(ratio: 0.25, in: frame) == 200)
    #expect(SplitGeometry.ratio(forX: 5, in: .zero) == 0.5)
}

@Test func aLabelFadesWhenTheDividerComesWithin72PointsOfItsEdge() {
    let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
    #expect(SplitGeometry.labelOpacity(.original, dividerX: 71, visible: visible) == 0)
    #expect(SplitGeometry.labelOpacity(.original, dividerX: 72, visible: visible) == 1)
    #expect(SplitGeometry.labelOpacity(.edited, dividerX: 329, visible: visible) == 0)
    #expect(SplitGeometry.labelOpacity(.edited, dividerX: 328, visible: visible) == 1)
    #expect(SplitGeometry.labelOpacity(.edited, dividerX: 71, visible: visible) == 1)
}

@Test func theOverlayColoursAreTheDesignedOnes() {
    #expect(CanvasOverlayStyle.highlightSRGB == 0xEF4444)
    #expect(CanvasOverlayStyle.shadowSRGB == 0x3B82F6)
    #expect(CanvasOverlayStyle.maskSRGB == 0xC026D3)
    #expect(CanvasOverlayStyle.zebraOpacity == 0.92)
    #expect(CanvasOverlayStyle.maskOpacity == 0.47)
    #expect(CanvasOverlayStyle.stripePeriodPoints == 8 && CanvasOverlayStyle.stripeWidthPoints == 3)
    #expect(CanvasOverlayStyle.stripeAngleDegrees == 45)
}
