import XCTest
@testable import HyperDR

@MainActor final class HeadroomTests: XCTestCase {
    func testSDRDegenerateAndReversedHeadrooms() {
        XCTAssertEqual(DisplayWeight.value(headroom: 1, base: 0, alternate: 4), 0)
        XCTAssertEqual(DisplayWeight.value(headroom: 8, base: 2, alternate: 2 + 1e-10), 0)
        XCTAssertEqual(DisplayWeight.value(headroom: 8, base: 2, alternate: 2 - 1e-10), 0)
        XCTAssertEqual(DisplayWeight.value(headroom: 2, base: 2, alternate: 0), -0.5)
        XCTAssertEqual(DisplayWeight.value(headroom: 1, base: 2, alternate: 0), -1)
        XCTAssertEqual(DisplayWeight.value(headroom: 4, base: 2, alternate: 0), 0)
        XCTAssertEqual(DisplayWeight.value(headroom: 4, base: 0, alternate: 4), 0.5)
        XCTAssertEqual(DisplayWeight.value(headroom: .nan, base: 0, alternate: 4), 0)
    }
    func testRebuildThresholdAccumulatesAgainstRenderedWeightAndHonorsEndpoints() {
        XCTAssertFalse(DisplayWeight.needsRebuild(from: 0.5, to: 0.504))
        XCTAssertTrue(DisplayWeight.needsRebuild(from: 0.5, to: 0.506))
        XCTAssertTrue(DisplayWeight.needsRebuild(from: 0.004, to: 0))
        XCTAssertTrue(DisplayWeight.needsRebuild(from: 0.996, to: 1))
        XCTAssertTrue(DisplayWeight.needsRebuild(from: -0.996, to: -1))
    }
    func testLatestScreenSampleAndPolicyAreIndependentOfModelPublication() {
        let monitor = HeadroomMonitor()
        XCTAssertNil(monitor.snapshot.screen)
        XCTAssertTrue(monitor.update(HeadroomSnapshot(screen:"first",current:2,potential:8)))
        XCTAssertTrue(monitor.update(HeadroomSnapshot(screen:"second",current:3,potential:6)))
        XCTAssertEqual(HeadroomPolicy.current.target(monitor.snapshot), 3)
        XCTAssertEqual(HeadroomPolicy.potential.target(monitor.snapshot), 6)
        XCTAssertEqual(HeadroomPolicy.declaredCurrent.target(monitor.snapshot), 3)
        XCTAssertFalse(monitor.update(monitor.snapshot))
        XCTAssertTrue(monitor.sample(nil)); XCTAssertEqual(monitor.snapshot.current, 1)
    }
}
