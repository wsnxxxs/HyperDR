import CoreGraphics
import HyperDRRecipe
import Testing
@testable import HyperDRDesign

private let identity = [0.0, 0, 1, 1]

@Test func aTapAddsAPointInOrderAndTheCurveStaysValid() throws {
    let first = try #require(ToneCurvePoints.inserted(identity, at: CGPoint(x: 0.5, y: 0.7)))
    #expect(first.coordinates == [0, 0, 0.5, 0.7, 1, 1])
    #expect(first.index == 1)
    let second = try #require(ToneCurvePoints.inserted(first.coordinates, at: CGPoint(x: 0.25, y: 0.1)))
    #expect(second.coordinates == [0, 0, 0.25, 0.1, 0.5, 0.7, 1, 1])
    #expect(second.index == 1)
    _ = try ToneCurve(second.coordinates)
}

@Test func aPointTooCloseToAnotherIsNotAdded() {
    #expect(ToneCurvePoints.inserted([0, 0, 0.5, 0.5, 1, 1], at: CGPoint(x: 0.51, y: 0.9)) == nil)
    #expect(ToneCurvePoints.inserted(identity, at: CGPoint(x: 0.005, y: 0.9)) == nil, "against the end point")
}

@Test func theCurveHoldsAtMostSixteenPoints() throws {
    var coordinates = identity
    for i in 1...14 {
        coordinates = try #require(ToneCurvePoints.inserted(coordinates, at: CGPoint(x: Double(i) / 15, y: 0.5))).coordinates
    }
    #expect(coordinates.count == 32)
    #expect(ToneCurvePoints.inserted(coordinates, at: CGPoint(x: 0.5 / 15, y: 0.5)) == nil)
    _ = try ToneCurve(coordinates)
}

@Test func aDraggedPointStaysBetweenItsNeighboursAndInsideTheRange() throws {
    let curve = [0.0, 0, 0.3, 0.3, 0.6, 0.6, 1, 1]
    let past = ToneCurvePoints.moved(curve, index: 1, to: CGPoint(x: 0.9, y: 1.4))
    #expect(past[2] == 0.6 - ToneCurvePoints.gap)
    #expect(past[3] == 1)
    let before = ToneCurvePoints.moved(curve, index: 2, to: CGPoint(x: -1, y: -1))
    #expect(before[4] == 0.3 + ToneCurvePoints.gap)
    #expect(before[5] == 0)
    _ = try ToneCurve(past)
    _ = try ToneCurve(before)
}

@Test func theEndPointsDoNotMoveOrGo() {
    let curve = [0.0, 0, 0.5, 0.5, 1, 1]
    #expect(ToneCurvePoints.moved(curve, index: 0, to: CGPoint(x: 0.2, y: 0.2)) == curve)
    #expect(ToneCurvePoints.moved(curve, index: 2, to: CGPoint(x: 0.9, y: 0.2)) == curve)
    #expect(ToneCurvePoints.removed(curve, index: 0) == curve)
    #expect(ToneCurvePoints.removed(curve, index: 2) == curve)
    #expect(ToneCurvePoints.removed(curve, index: 1) == identity)
}

@Test func theCurveIsWrittenAsOneValueAndTheStraightLineIsNotStored() {
    let panel = AdjustmentPanel(context: AdjustmentContext())
    var recipe = Recipe(inputDomain: .rawEDR)
    panel.set("tone.curve", curve: [0, 0, 0.5, 0.7, 1, 1], in: &recipe)
    #expect(recipe.conditionValue("tone.curve") == .array([0, 0, 0.5, 0.7, 1, 1].map(ParameterValue.number)))
    #expect(panel.group(group: .light, in: recipe)?.controls.first { $0.id == "tone.curve" }?.isDefault == false)
    panel.set("tone.curve", curve: [0, 0, 1, 1], in: &recipe)
    #expect(panel.group(group: .light, in: recipe)?.controls.first { $0.id == "tone.curve" }?.isDefault == true)
    // Not a curve: ignored.
    panel.set("tone.curve", curve: [0, 0, 0.5, 0.5], in: &recipe)
    #expect(panel.group(group: .light, in: recipe)?.controls.first { $0.id == "tone.curve" }?.isDefault == true)
    // Points on the diagonal are the user's: kept.
    panel.set("tone.curve", curve: [0, 0, 0.5, 0.5, 1, 1], in: &recipe)
    #expect(panel.group(group: .light, in: recipe)?.controls.first { $0.id == "tone.curve" }?.isDefault == false)
    panel.reset("tone.curve", in: &recipe)
    #expect(panel.group(group: .light, in: recipe)?.controls.first { $0.id == "tone.curve" }?.isDefault == true)
}

@Test func whitesAndTheCurveHaveTheirOwnIcons() {
    #expect(AdjustmentSymbols.control(Adjustments.declaration("tone.whites")!) == "circle")
    #expect(AdjustmentSymbols.control(Adjustments.declaration("tone.curve")!)
            != AdjustmentSymbols.group(.light))
}

@Test func accessibilityCanAddPointsWithoutTheCurveChangingUntilTheyAreMoved() throws {
    let first = try #require(ToneCurvePoints.insertedInWidestGap(identity))
    #expect(first.index == 1)
    #expect(first.coordinates == [0, 0, 0.5, 0.5, 1, 1])
    // The next goes in the widest gap, on the curve.
    let bent = [0.0, 0, 0.2, 0.4, 1, 1]
    let next = try #require(ToneCurvePoints.insertedInWidestGap(bent))
    #expect(next.index == 2)
    #expect(next.coordinates[4] == 0.6)
    #expect(abs(next.coordinates[5] - ToneCurvePoints.curve(bent).value(at: 0.6)) < 1e-12)
    _ = try ToneCurve(next.coordinates)
    // Full: nothing to add.
    var full = identity
    for i in 1...14 { full = try #require(ToneCurvePoints.inserted(full, at: CGPoint(x: Double(i) / 15, y: 0.5))).coordinates }
    #expect(ToneCurvePoints.insertedInWidestGap(full) == nil)
}
