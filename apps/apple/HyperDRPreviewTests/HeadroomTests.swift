import XCTest
import HyperDREngine
@testable import HyperDR

@MainActor final class HeadroomTests: XCTestCase {
    func testWeightMatchesActualEngineMetadataAtItsTargetHeadroom() async throws {
        let engine = try await Engine()
        let bundle = previewFixtureBundle()
        let url = try XCTUnwrap(bundle.url(forResource: "photo", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "photo", withExtension: "jpg"))
        let session = try engine.openPreview(source: url)
        defer { session.close() }
        for stops in [0.0, 0.5, 1.0, 2.0, 4.0] {
            let frame = try await session.renderFrame(EngineRequest(settings: ["preview_max_edge":.number(64), "headroom":.number(stops), "headroom_max":.number(4)]))
            let m = frame.metadata
            XCTAssertEqual(Double(GainWeight.value(headroom: exp2(m.headroomStops), metadata: m)),
                           try XCTUnwrap(m.gainWeight), accuracy: 1e-6)
        }
    }
    func testSDRDegenerateAndReversedHeadrooms() {
        XCTAssertEqual(GainWeight.value(headroom: 1, base: 0, alternate: 4), 0)
        XCTAssertEqual(GainWeight.value(headroom: 8, base: 2, alternate: 2 + 1e-10), 0)
        XCTAssertEqual(GainWeight.value(headroom: 8, base: 2, alternate: 2 - 1e-10), 0)
        XCTAssertEqual(GainWeight.value(headroom: 2, base: 2, alternate: 0), 0.5)
        XCTAssertEqual(GainWeight.value(headroom: 4, base: 0, alternate: 4), 0.5)
        XCTAssertEqual(GainWeight.value(headroom: .nan, base: 0, alternate: 4), 0)
    }
    func testRebuildThresholdAccumulatesAgainstRenderedWeightAndHonorsEndpoints() {
        XCTAssertFalse(GainWeight.needsRebuild(from: 0.5, to: 0.504))
        XCTAssertTrue(GainWeight.needsRebuild(from: 0.5, to: 0.506))
        XCTAssertTrue(GainWeight.needsRebuild(from: 0.004, to: 0))
        XCTAssertTrue(GainWeight.needsRebuild(from: 0.996, to: 1))
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
