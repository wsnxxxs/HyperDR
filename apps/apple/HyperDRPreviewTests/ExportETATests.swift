import Foundation
import XCTest
@testable import HyperDR

@MainActor final class ExportETATests: XCTestCase {
    let kind = ExportTimingClass(isRAW:false,encoding:"adaptive",isAI:false,hasFrame:false,verifies:true)
    func testMedianPerPixelUsesSameClassThenFallsBackToAllHistory() throws {
        let matching = [ExportTimingSample(kind:kind,pixels:1e6,stages:[1,2,3,4]), .init(kind:kind,pixels:2e6,stages:[6,8,10,12])]
        var other = kind;other.isRAW=true
        let history = matching + [.init(kind:other,pixels:1e6,stages:[100,200,300,400])]
        let medians = try XCTUnwrap(ExportETA.durations(history:history,kind:kind,pixels:3e6))
        for (actual, expected) in zip(medians, [6.0,9,12,15]) { XCTAssertEqual(actual,expected,accuracy:1e-10) }
        var unknown=kind;unknown.hasFrame=true
        XCTAssertEqual(ExportETA.durations(history:history,kind:unknown,pixels:1e6),[3,4,5,6])
        XCTAssertNil(ExportETA.durations(history:[],kind:kind,pixels:1e6))
        XCTAssertNil(ExportETA.durations(history:[.init(kind:kind,pixels:0,stages:[1,2,3,4])],kind:kind,pixels:1e6))
    }
    @MainActor func testEstimateIsPureMonotonicAcrossStageChangesAndOverrun() throws {
        let state=ExportState();let start=Date(timeIntervalSince1970:100)
        state.startedAt=start;state.stageAt=start;state.durations=[10,30,20,5];state.phase = .running
        state.progress(stage:"developing",fraction:0,at:start)
        let a=try XCTUnwrap(state.estimate(at:start+8))
        XCTAssertEqual(a.fraction,8.0/65,accuracy:0.0001)
        let savedFloor=state.fractionFloor
        XCTAssertEqual(state.estimate(at:start+8),state.estimate(at:start+8));XCTAssertEqual(savedFloor,state.fractionFloor)
        state.progress(stage:"rendering",fraction:0.3,at:start+8)
        let b=try XCTUnwrap(state.estimate(at:start+8));XCTAssertGreaterThanOrEqual(b.fraction,a.fraction)
        let c=try XCTUnwrap(state.estimate(at:start+100));XCTAssertGreaterThan(c.fraction,b.fraction)
        state.progress(stage:"encoding",fraction:0.7,at:start+100)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(state.estimate(at:start+100)).fraction,c.fraction)
        state.progress(stage:"verifying",fraction:0.9,at:start+130)
        let overdue=try XCTUnwrap(state.estimate(at:start+140));XCTAssertTrue(overdue.isOverdue)
        XCTAssertEqual(overdue.fraction,0.99);XCTAssertEqual(overdue.remaining,.zero)
        state.phase = .saving
        XCTAssertNil(state.estimate(at:start+141)?.remaining);XCTAssertEqual(state.estimate(at:start+141)?.fraction,0.99)
        state.phase = .succeeded;XCTAssertEqual(state.estimate(at:start+142)?.fraction,1)
    }
    func testRemainingBucketsAreStableAndRoundUp() {
        func bucket(_ seconds:Double)->ExportEstimate.RemainingBucket? { ExportEstimate(fraction:0,remaining:.seconds(seconds),isOverdue:false).remainingBucket }
        XCTAssertEqual(bucket(4.99),.soon);XCTAssertEqual(bucket(5),.seconds(5));XCTAssertEqual(bucket(6),.seconds(10))
        XCTAssertEqual(bucket(59),.seconds(60));XCTAssertEqual(bucket(60),.minutes(1));XCTAssertEqual(bucket(61),.minutes(2))
    }
    @MainActor func testFirstExportHasNoEstimateOrInventedInitialDurations() {
        let state=ExportState();state.phase = .running;state.startedAt=Date(timeIntervalSince1970:0)
        XCTAssertNil(state.estimate(at:Date(timeIntervalSince1970:100)))
        state.progress(stage:"encoding",fraction:0.7,at:Date(timeIntervalSince1970:100))
        XCTAssertNil(state.estimate(at:Date(timeIntervalSince1970:200)))
    }
    func testPreferenceValidationIsPerFieldAndResetDoesNotTouchOtherStores() {
        let (d,name)=UserDefaults.ephemeral();defer { d.removePersistentDomain(forName:name) }
        d.set(["saveMode":"invalid","initialView":"original","histogramRGB":true,
            "output":["encoding":"bad","quality":"70","colorGamut":"p3","outputGamut":"auto","clampSrgb":"wrong"]],forKey:Preferences.key)
        let p=Preferences.load(from:d)
        XCTAssertEqual(p.saveMode,.ask);XCTAssertEqual(p.initialView,.original);XCTAssertTrue(p.histogramRGB)
        XCTAssertEqual(p.output,["colorGamut":"p3","outputGamut":"auto"])
        p.save(to:d);XCTAssertEqual(Preferences.load(from:d),p)
    }
}

@MainActor extension ExportETATests {
    func testRenderedRowsCorrectRemainingWithIdenticalHistoryAndElapsed() throws {
        let start = Date(timeIntervalSince1970: 100)
        func state(_ fraction: Double) -> ExportState {
            let value = ExportState(); value.startedAt = start; value.stageAt = start
            value.durations = [20,100,10,5]; value.phase = .running
            value.progress(stage: "rendering", fraction: 0, at: start)
            value.progress(stage: "rendering", fraction: fraction, at: start+10)
            return value
        }
        let low = state(0.1), high = state(0.9)
        XCTAssertEqual(try XCTUnwrap(low.estimate(at: start+10)?.remaining).seconds, 105, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(high.estimate(at: start+10)?.remaining).seconds, 25, accuracy: 1e-10)
        let floor = high.fractionFloor
        XCTAssertEqual(high.estimate(at: start+15), high.estimate(at: start+15))
        XCTAssertEqual(high.fractionFloor, floor, "Reading the pure estimator cannot mutate state")
        XCTAssertEqual(try XCTUnwrap(high.estimate(at: start+15)?.remaining).seconds, 20, accuracy: 1e-10)
        high.durations = nil
        XCTAssertNil(high.estimate(at: start+15), "Real progress cannot invent an ETA for the first export")
    }
    func testRowProgressRejectsInvalidAndRegressingEventsAndKeepsFloor() throws {
        let state = ExportState(), start = Date(timeIntervalSince1970: 0)
        state.startedAt = start; state.stageAt = start; state.durations = [20,100,10,5]; state.phase = .running
        state.progress(stage: "rendering", fraction: 0.9, at: start+10)
        let good = try XCTUnwrap(state.estimate(at: start+10))
        for fraction in [Double.nan, .infinity, -1, 0, 2, 0.1, 0.9] {
            state.progress(stage: "rendering", fraction: fraction, at: start+10)
            XCTAssertEqual(state.fraction, 0.9)
            XCTAssertEqual(state.estimate(at: start+10), good)
        }
        state.progress(stage: "rendering", fraction: 1, at: start+20)
        let rendered = try XCTUnwrap(state.estimate(at: start+20))
        state.progress(stage: "encoding", fraction: 0.3, at: start+20)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(state.estimate(at: start+20)).fraction, rendered.fraction)
        XCTAssertEqual(try XCTUnwrap(state.estimate(at: start+20)?.remaining).seconds, 15, accuracy: 1e-10,
                       "only rendering reports real progress")
        state.progress(stage: "rendering", fraction: 0.5, at: start+21)
        XCTAssertEqual(state.stage, "encoding")
        XCTAssertLessThanOrEqual(try XCTUnwrap(state.estimate(at: start+1000)).fraction, 0.99)
    }
}
