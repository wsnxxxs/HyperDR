import Foundation
import XCTest
import HyperDRKit
import HyperDRRecipe
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
    func testRowReportHistoryKeepsPullReadTimeInEncodingETA() throws {
        let plan = ExportPlanner.plan(.init(choice: .custom(.init(encoding: .isoGainMapJPEG)),
            source: .init(domain: .sdr, pixelSize: .init(width: 96, height: 64)),
            edit: .init(peakStops: 2)))
        let snapshot = RecipeExportSnapshot(recipe: Recipe(),
            source: .init(sha256: "digest", byteCount: 1, modificationDate: .distantPast))
        let resolved = ResolvedExportSnapshot(snapshot: snapshot, plan: plan)
        let resolvedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved))
        // New reports separate nine seconds of pull reads; old reports include
        // those reads in encoding and omit the read key. Both describe 11 s.
        for separateRead in [true, false] {
            var seconds = ["rendering": 1.0, "encoding": separateRead ? 1.0 : 10.0]
            if separateRead { seconds["read"] = 9 }
            let report: [String: Any] = ["schema": "hyperdr.recipe-export/v1",
                "system": ["width": 96, "height": 64, "bitDepth": 8, "orientation": 1,
                    "auxiliaryGain": true, "hdrReadable": true, "verifiedHeadroomStops": []],
                "stageSeconds": seconds, "resplitReasons": [], "transparentBackground": "black-sdr",
                "usesRowInput": true]
            let object: [String: Any] = ["id": String(repeating: "a", count: 32),
                "name": "photo.jpg", "byteCount": 3, "createdAt": 0, "sourceDigest": "digest",
                "options": [:], "sequence": 1, "key": ["rawValue": "key"],
                "reportJSON": try JSONSerialization.data(withJSONObject: report).base64EncodedString(),
                "resolvedSnapshot": resolvedJSON]
            let record = try JSONDecoder().decode(ExportRecord.self,
                from: JSONSerialization.data(withJSONObject: object))
            let timing = try XCTUnwrap(ExportHistoryItem(record).timing)
            XCTAssertEqual(timing.stages[1], 1, "rendering only prepares rows")
            let durations = try XCTUnwrap(ExportETA.durations(history: [timing], kind: timing.kind, pixels: timing.pixels))
            let encodingStart = Date(timeIntervalSince1970: 100)
            let estimate = try XCTUnwrap(ExportETA.estimate(at: encodingStart+2, startedAt: encodingStart-1,
                stageAt: encodingStart, stage: "encoding", durations: durations, fractionFloor: 0))
            XCTAssertEqual(try XCTUnwrap(estimate.remaining).seconds, 8, accuracy: 1e-10)
            XCTAssertFalse(estimate.isOverdue)
        }
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
    func testKitsMeasureFillsAFirstExportAndOvertakesAnOverdueHistory() throws {
        let start = Date(timeIntervalSince1970: 100)
        // A first export: no history, Kit's rows alone.
        let first = ExportState(); first.startedAt = start; first.stageAt = start; first.phase = .running
        first.progress(stage: "developing", fraction: 0, at: start)
        XCTAssertNil(first.estimate(at: start+5), "nothing measured yet")
        first.progress(stage: "encoding", fraction: 0, at: start+5, overall: 0)
        first.progress(stage: "encoding", fraction: 0, at: start+15, overall: 0.3)
        let measured = try XCTUnwrap(first.estimate(at: start+15))
        XCTAssertEqual(measured.fraction, 0.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(measured.remaining).seconds, 10 * 0.7 / 0.3, accuracy: 1e-6)
        XCTAssertFalse(measured.isOverdue)
        first.progress(stage: "encoding", fraction: 0, at: start+16, overall: 0.2)
        XCTAssertEqual(try XCTUnwrap(first.estimate(at: start+16)).fraction, 0.3, accuracy: 1e-9, "never moves back")
        // A history that thought it would be done by now: the rows still run.
        let late = ExportState(); late.startedAt = start; late.stageAt = start; late.durations = [1, 1, 1, 1]; late.phase = .running
        late.progress(stage: "encoding", fraction: 0, at: start, overall: 0)
        late.progress(stage: "encoding", fraction: 0, at: start+20, overall: 0.5)
        let ahead = try XCTUnwrap(late.estimate(at: start+20))
        XCTAssertFalse(ahead.isOverdue)
        XCTAssertGreaterThan(ahead.fraction, 0.5 - 1e-9)
        XCTAssertNotNil(ahead.remaining)
        // Saving still holds at 99%.
        late.phase = .saving
        XCTAssertEqual(late.estimate(at: start+21)?.fraction, 0.99)
    }
}
