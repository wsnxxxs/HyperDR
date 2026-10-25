import CoreGraphics
import XCTest
@testable import HyperDR

@MainActor
final class TargetPickerTests: XCTestCase {
    private final class Log { var applied: [CGFloat] = []; var finished = 0 }

    private func picker(_ log: Log, delay: Duration = .zero) -> TargetPicker {
        let picker = TargetPicker()
        picker.photoPoint = { CGPoint(x: $0.x / 100, y: $0.y / 100) }
        picker.begin = { _ in
            if delay != .zero { try await Task.sleep(for: delay) }
            return TargetPicker.Drag(apply: { log.applied.append($0) }, finish: { log.finished += 1 }, marks: ["a": 0.5])
        }
        return picker
    }

    func testADragRaisesByTheDistanceMovedUpAndFinishesOnce() async throws {
        let log = Log(), picker = picker(log)
        picker.start()
        picker.press(at: CGPoint(x: 50, y: 50))
        try await Task.sleep(for: .milliseconds(30))
        picker.move(to: CGPoint(x: 50, y: 20))
        picker.release()
        XCTAssertEqual(log.applied.last, 30, "up is positive")
        XCTAssertEqual(log.finished, 1)
        XCTAssertEqual(picker.marks, ["a": 0.5])
        XCTAssertTrue(picker.isActive, "the mode stays on for the next press")
        XCTAssertFalse(picker.isPressing)
    }

    func testALiftBeforeTheSampleArrivesStillFinishesTheDrag() async throws {
        let log = Log(), picker = picker(log, delay: .milliseconds(40))
        picker.start()
        picker.press(at: CGPoint(x: 50, y: 50))
        picker.move(to: CGPoint(x: 50, y: 40))
        picker.release()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(log.applied, [10], "the drag so far is applied once, when the sample arrives")
        XCTAssertEqual(log.finished, 1)
        XCTAssertFalse(picker.isPressing)
    }

    func testAPressOffThePhotoDoesNothing() async throws {
        let log = Log()
        let picker = picker(log)
        picker.photoPoint = { _ in nil }
        picker.start()
        picker.press(at: CGPoint(x: 5, y: 5))
        XCTAssertFalse(picker.isPressing)
        XCTAssertEqual(log.finished, 0)
    }

    func testResetDropsASampleStillBeingRead() async throws {
        let log = Log(), picker = picker(log, delay: .milliseconds(40))
        picker.start()
        picker.press(at: CGPoint(x: 50, y: 50))
        picker.reset()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(log.applied.isEmpty, "nothing is written to another photo")
        XCTAssertFalse(picker.isActive || picker.isPressing)
        picker.start()
        picker.press(at: CGPoint(x: 50, y: 50))
        XCTAssertTrue(picker.isPressing, "a new press is not blocked by the old one")
    }

    /// A second drag that starts while the first one's sample is still being
    /// read keeps its own origin and its own step: the first is applied by
    /// its displacement and finished, then the second by its own.
    func testASecondDragBeforeTheFirstSampleArrivesKeepsItsOwnOriginAndStep() async throws {
        let log = Log(), picker = picker(log, delay: .milliseconds(40))
        picker.start()
        picker.press(at: CGPoint(x: 50, y: 100))
        picker.move(to: CGPoint(x: 50, y: 80))
        picker.release()
        picker.press(at: CGPoint(x: 50, y: 20))
        XCTAssertTrue(picker.isPressing, "the lifted press no longer holds the picker")
        picker.move(to: CGPoint(x: 50, y: 10))
        picker.release()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(log.applied, [20, 10], "each drag is applied by its own rise")
        XCTAssertEqual(log.finished, 2, "one step for each drag")
    }
}
