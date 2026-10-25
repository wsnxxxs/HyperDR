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

// MARK: - HDR segment (adjust-tools §2.1)

@Test func aTapPastWhiteAddsAPointInTheHDRSegment() throws {
    let added = try #require(ToneCurvePoints.inserted(identity, at: CGPoint(x: 2.5, y: 3.4), maxValue: 4))
    #expect(added.coordinates == [0, 0, 1, 1, 2.5, 3.4])
    #expect(added.index == 2)
    // Above white and not below it, and not past the plot's end.
    let low = try #require(ToneCurvePoints.inserted(identity, at: CGPoint(x: 2, y: 0.2), maxValue: 4))
    #expect(low.coordinates[5] == 1)
    let far = try #require(ToneCurvePoints.inserted(identity, at: CGPoint(x: 9, y: 9), maxValue: 4))
    #expect(far.coordinates.suffix(2) == [4, 4])
    // Next to the fixed white there is no room.
    #expect(ToneCurvePoints.inserted(identity, at: CGPoint(x: 1.03, y: 1.2), maxValue: 4) == nil)
}

@Test func anHDRPointStaysAboveWhiteAndBetweenItsNeighbours() {
    let curve = [0.0, 0, 1, 1, 2, 2.4, 3, 3]
    let up = ToneCurvePoints.moved(curve, index: 2, to: CGPoint(x: 3.5, y: 9), maxValue: 4)
    #expect(up[4] == 3 - ToneCurvePoints.hdrGap)
    #expect(up[5] == 4)
    let down = ToneCurvePoints.moved(curve, index: 2, to: CGPoint(x: 0, y: 0), maxValue: 4)
    #expect(down[4] == 1 + ToneCurvePoints.hdrGap)
    #expect(down[5] == 1, "an HDR point does not go below white")
    // The last point has no right neighbour: the plot's end is its limit.
    let last = ToneCurvePoints.moved(curve, index: 3, to: CGPoint(x: 9, y: 1.5), maxValue: 3.5)
    #expect(last[6] == 3.5)
}

@Test func theFixedWhiteStaysWhenTheCurveGoesOnPastIt() {
    let curve = [0.0, 0, 0.5, 0.6, 1, 1, 2, 2.5]
    #expect(ToneCurvePoints.moved(curve, index: 2, to: CGPoint(x: 0.9, y: 0.2), maxValue: 4) == curve)
    #expect(ToneCurvePoints.removed(curve, index: 2) == curve)
    #expect(ToneCurvePoints.removed(curve, index: 3) == [0, 0, 0.5, 0.6, 1, 1])
    #expect(ToneCurvePoints.removed(curve, index: 1) == [0, 0, 1, 1, 2, 2.5])
}

@Test func theHDRSegmentIsIdentityWithoutPointsAndCarriesOnFromTheLastOne() {
    #expect(CurveInterpolation(identity).value(at: 2.7) == 2.7)
    let lifted = CurveInterpolation([0, 0, 1, 1, 2, 2.6])
    #expect(abs(lifted.value(at: 2) - 2.6) < 1e-12)
    #expect(abs(lifted.value(at: 3.5) - 4.1) < 1e-12, "slope 1 past the last point")
    #expect(lifted.value(at: 1.5) > 1.5, "the segment between white and the point is lifted")
    // The SDR part matches the renderer's table.
    let sdr = [0.0, 0, 0.3, 0.45, 1, 1]
    for x in stride(from: 0.0, through: 1.0, by: 0.05) {
        #expect(abs(CurveInterpolation(sdr).value(at: x) - ToneCurvePoints.curve(sdr).value(at: x)) < 1e-12)
    }
}

@Test func theHDRStripKeepsTheIdentityAStraightDiagonal() {
    let layout = ToneCurvePlotLayout(rect: CGRect(x: 10, y: 10, width: 300, height: 300), stops: 3)
    #expect(layout.maxValue == 4)
    for v in [0.0, 0.5, 1, 1.7, 3, 4] {
        let p = layout.view(CGPoint(x: v, y: v))
        #expect(abs((p.x - 10) - (310 - p.y)) < 1e-9)
    }
    let corner = layout.view(CGPoint(x: 4, y: 4))
    #expect(abs(corner.x - 310) < 1e-9 && abs(corner.y - 10) < 1e-9)
    let back = layout.unit(layout.view(CGPoint(x: 2.2, y: 1.4)))
    #expect(abs(back.x - 2.2) < 1e-9 && abs(back.y - 1.4) < 1e-9)
    // Without an HDR segment the plot is the old 0…1 square.
    let sdr = ToneCurvePlotLayout(rect: CGRect(x: 0, y: 0, width: 200, height: 200), stops: 0)
    #expect(sdr.view(CGPoint(x: 0.5, y: 0.25)) == CGPoint(x: 100, y: 150))
    #expect(sdr.hdrRect == nil)
}

@Test func accessibilityCanAddAnHDRPointInTheGapAfterTheLastOne() throws {
    let added = try #require(ToneCurvePoints.insertedInWidestGap(identity, maxValue: 3))
    // The widest gap is white to the plot's end: 1…3, middle 2, on the identity.
    #expect(added.coordinates == [0, 0, 1, 1, 2, 2])
}

// MARK: - Parametric curve

@Test func theParametricPreviewIsTheIdentityWithNoAmountsAndKeepsBlackAndWhite() {
    let neutral = ParametricCurvePreview.neutral
    #expect(neutral.isIdentity)
    for x in stride(from: 0.0, through: 1.0, by: 0.1) { #expect(neutral.value(at: x) == x) }
    let bent = ParametricCurvePreview(amounts: [100, -100, 100, -100], splits: [25, 50, 75])
    #expect(bent.value(at: 0) == 0)
    #expect(bent.value(at: 1) == 1)
    let samples = bent.samples(count: 100)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "never turns back")
}

@Test func aZoneAmountMovesItsOwnZone() {
    // Shadows up lifts the lowest quarter and leaves the top alone.
    let lifted = ParametricCurvePreview(amounts: [100, 0, 0, 0], splits: [25, 50, 75])
    #expect(lifted.value(at: 0.125) > 0.125)
    #expect(lifted.value(at: 0.6) == 0.6)
    let pressed = ParametricCurvePreview(amounts: [0, 0, 0, -100], splits: [25, 50, 75])
    #expect(pressed.value(at: 0.875) < 0.875)
    #expect(pressed.value(at: 0.1) == 0.1)
}

@Test func theZoneBoundariesKeepTheirOrderAndAGap() {
    let splits = [25.0, 50, 75]
    #expect(ParametricCurvePreview.moved(splits, index: 0, to: 60) == [45, 50, 75])
    #expect(ParametricCurvePreview.moved(splits, index: 1, to: 10) == [25, 30, 75])
    #expect(ParametricCurvePreview.moved(splits, index: 2, to: 120) == [25, 50, 95])
    #expect(ParametricCurvePreview.moved(splits, index: 0, to: -5) == [5, 50, 75])
}
