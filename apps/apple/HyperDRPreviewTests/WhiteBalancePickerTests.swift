import CoreGraphics
import XCTest
@testable import HyperDR

/// The white balance eyedropper's state (adjust-controls F1): a click on the
/// photo samples there and ends the mode, a click off it does nothing,
/// Escape ends it without writing, and what the pick said is kept for the
/// temperature row until the next pick or the next photo.
@MainActor final class WhiteBalancePickerTests: XCTestCase {
    private func picker(result: WhiteBalancePick = .applied, fails: Bool = false,
                        onPick: @escaping (CGPoint) -> Void = { _ in }) -> WhiteBalancePicker {
        let picker = WhiteBalancePicker()
        // The photo fills x 100…300, y 50…150 on the canvas.
        picker.photoPoint = { point in
            let frame = CGRect(x: 100, y: 50, width: 200, height: 100)
            guard frame.contains(point) else { return nil }
            return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
        }
        picker.pick = { point in
            onPick(point)
            if fails { throw CancellationError() }
            return result
        }
        return picker
    }

    private func settle(_ picker: WhiteBalancePicker) async {
        for _ in 0..<50 where picker.isSampling { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAClickOnThePhotoSamplesThereAndEndsTheMode() async {
        var picked: CGPoint?
        let picker = picker { picked = $0 }
        picker.begin()
        picker.click(at: CGPoint(x: 200, y: 100))
        await settle(picker)
        XCTAssertEqual(picked, CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(picker.isActive)
        XCTAssertNil(picker.notice)
    }

    func testAClickOffThePhotoKeepsWaiting() async {
        var picked = false
        let picker = picker { _ in picked = true }
        picker.begin()
        picker.click(at: CGPoint(x: 20, y: 20))
        await settle(picker)
        XCTAssertFalse(picked)
        XCTAssertTrue(picker.isActive)
    }

    func testAHeldValueAndAFailureLeaveANoticeUntilTheNextPick() async {
        let clamped = picker(result: .clamped)
        clamped.begin()
        clamped.click(at: CGPoint(x: 150, y: 80))
        await settle(clamped)
        XCTAssertEqual(clamped.notice, .clamped)
        clamped.begin()
        XCTAssertNil(clamped.notice, "starting again clears it")

        let failing = picker(fails: true)
        failing.begin()
        failing.click(at: CGPoint(x: 150, y: 80))
        await settle(failing)
        XCTAssertEqual(failing.notice, .failed)
        XCTAssertFalse(failing.isActive)
        failing.reset()
        XCTAssertNil(failing.notice, "another photo drops it")
    }

    func testCancelEndsWithoutWritingAndToggleStartsAgain() {
        var picked = false
        let picker = picker { _ in picked = true }
        picker.toggle()
        XCTAssertTrue(picker.isActive)
        picker.move(to: CGPoint(x: 150, y: 80))
        XCTAssertNotNil(picker.hover)
        picker.cancel()
        XCTAssertFalse(picker.isActive)
        XCTAssertNil(picker.hover)
        XCTAssertFalse(picked)
        picker.toggle()
        picker.toggle()
        XCTAssertFalse(picker.isActive)
    }

    func testTheLoupeEncodesLinearPixelsForTheScreen() throws {
        // Mid grey 18 % linear is about 46 % encoded.
        let values: [Float] = [0.18, 0.18, 0.18, 1,  1, 0, 2, 1,
                               0, 0, 0, 1,           0.5, 0.5, 0.5, 1]
        let image = try XCTUnwrap(WhiteBalancePicker.image(values, width: 2, height: 2))
        XCTAssertEqual(image.width, 2)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertEqual(Int(data[0]), 118, accuracy: 1)
        XCTAssertEqual(Int(data[4]), 255, "above white is held at white")
        XCTAssertEqual(Int(data[5]), 0)
        XCTAssertEqual(Int(data[8]), 0)
    }
}
