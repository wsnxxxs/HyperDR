import CoreGraphics
import Foundation
import Testing
@testable import HyperDRDesign

@Test func theRulerHasTheSevenMarksAtTheirTruePositions() {
    let positions = ScopeScale.ticks.map(\.position)
    let expected = [0, 0.35, 0.7, 0.775, 0.85, 0.925, 1.0]
    #expect(positions.count == expected.count)
    for (position, want) in zip(positions, expected) { #expect(abs(position - want) < 1e-12) }
    #expect(positions == positions.sorted())
    #expect(ScopeScale.ticks.map(\.label) == ["0", nil, "SDR 100%", nil, "+2", nil, "+4 EV"])
    #expect(ScopeScale.ticks.map(\.isMajor) == [true, false, true, false, true, false, true])
}

@Test func labelsAnchorAtTheEndsAndCentreInBetween() {
    #expect(ScopeScale.ticks.first?.anchor == .leading)
    #expect(ScopeScale.ticks.last?.anchor == .trailing)
    #expect(ScopeScale.ticks[2].anchor == .center)
}

@Test func theStopsAndEncodedPositionsAgreeWithTheLinearOne() {
    #expect(ScopeScale.position(stops: 0) == 0.7)
    #expect(abs(ScopeScale.position(stops: 2) - ScopeScale.position(4.0)) < 1e-12)
    #expect(abs(ScopeScale.position(stops: 1) - ScopeScale.position(2.0)) < 1e-12)
    #expect(ScopeScale.position(stops: 9) == 1)
    #expect(ScopeScale.position(stops: -2) == 0.7)
    #expect(ScopeScale.position(stops: .nan) == 0.7)
    #expect(ScopeScale.position(sdrEncoded: 0.5) == 0.35)
    #expect(ScopeScale.position(sdrEncoded: 2) == 0.7)
    // Monotonic across the whole ruler.
    var last = -1.0
    for step in 0...400 {
        let position = ScopeScale.position(Double(step) / 40)
        #expect(position >= last)
        last = position
    }
}

@Test func curvesAreSquareRootsOfTheShareOfTheCommonPeak() {
    #expect(ScopeMath.peak([[1, 5, 2], [3, 9]]) == 9)
    #expect(ScopeMath.peak([]) == 0)
    #expect(ScopeMath.curve([0, 25, 100], peak: 100) == [0, 0.5, 1])
    #expect(ScopeMath.curve([4, 4], peak: 0) == [0, 0])
    // The top of a curve keeps its headroom.
    #expect(ScopeMath.y(for: 1, height: 132) == ScopeMath.curveHeadroom)
    #expect(ScopeMath.y(for: 0, height: 132) == 132)
}

@Test func theLimitLineSitsWhereTheRulerPutsItsStops() {
    // On a 302 pt plot: 2.5 stops is 0.7 + 0.3 × 2.5 / 4 of the width.
    #expect(abs(ScopeScale.position(stops: 2.5) * 302 - 0.8875 * 302) < 1e-9)
    #expect(ScopeMath.ceilingValue(stops: 2.5) == "2.5")
    #expect(ScopeMath.ceilingValue(stops: 0) == nil)
}

@Test func waveformCellsFadeWithTheirShareOfTheColumn() {
    #expect(ScopeMath.waveformOpacity(count: 10, columnMax: 10) == 1)
    #expect(ScopeMath.waveformOpacity(count: 5, columnMax: 10) == 0.5)
    #expect(ScopeMath.waveformOpacity(count: 1, columnMax: 10) == nil)
    #expect(ScopeMath.waveformOpacity(count: 0, columnMax: 10) == nil)
    #expect(ScopeMath.waveformOpacity(count: 3, columnMax: 0) == nil)
}

@Test func theWaveformMaskIsAsLargeAsTheGridAndRowZeroIsAtTheBottom() throws {
    var counts = [UInt32](repeating: 0, count: 3 * 4)
    counts[0 * 3 + 1] = 8   // row 0 (black), column 1
    counts[3 * 3 + 2] = 8   // row 3 (brightest), column 2
    let mask = try #require(ScopeMath.waveformMask(WaveformCounts(columns: 3, rows: 4, counts: counts)))
    #expect(mask.width == 3 && mask.height == 4)
    let data = try #require(mask.dataProvider?.data as Data?)
    func alpha(x: Int, y: Int) -> UInt8 { data[(y * mask.bytesPerRow) + x * 4 + 3] }
    #expect(alpha(x: 1, y: 3) == 255)   // black is the bottom image row
    #expect(alpha(x: 2, y: 0) == 255)
    #expect(alpha(x: 0, y: 0) == 0)
    #expect(ScopeMath.waveformMask(WaveformCounts(columns: 3, rows: 4, counts: [1, 2])) == nil)
}
