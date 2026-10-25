import CoreGraphics
import Metal
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

    // MARK: A pick that outlives its mode

    func testAPickStillBeingSampledDoesNotSpoilTheNextMode() async {
        let picker = WhiteBalancePicker()
        picker.photoPoint = { _ in CGPoint(x: 0.5, y: 0.5) }
        var release: CheckedContinuation<Void, Never>?
        picker.pick = { _ in
            await withCheckedContinuation { release = $0 }
            throw CancellationError()
        }
        picker.begin()
        picker.click(at: .zero)
        XCTAssertTrue(picker.isSampling)
        // Another photo arrives while the first pick is out.
        picker.reset()
        XCTAssertFalse(picker.isSampling)
        picker.begin()
        XCTAssertTrue(picker.isActive)
        release?.resume()
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(picker.isActive, "the old pick does not end the new mode")
        XCTAssertFalse(picker.isSampling)
        XCTAssertNil(picker.notice, "nor write its notice into it")
        picker.move(to: .zero)
        XCTAssertNotNil(picker.hover, "the new mode follows the pointer")
    }

    // MARK: What the canvas draws

    private func texture() throws -> any MTLTexture {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1,
                                                                  mipmapped: false)
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    func testTheLoupeReadsTheSideOfTheSplitUnderThePointer() throws {
        let frames = WhiteBalanceFrames(original: try texture(), edited: try texture(), shown: .compare,
                                        splitRatio: 0.25, imageFrame: CGRect(x: 100, y: 0, width: 400, height: 300))
        XCTAssertEqual(frames.side(at: CGPoint(x: 150, y: 10)), .original)
        XCTAssertEqual(frames.side(at: CGPoint(x: 250, y: 10)), .edited)
        var original = frames
        original.shown = .original
        XCTAssertEqual(original.side(at: CGPoint(x: 450, y: 10)), .original)
        var withoutOriginal = frames
        withoutOriginal.original = nil
        XCTAssertEqual(withoutOriginal.side(at: CGPoint(x: 150, y: 10)), .edited)
    }

    func testNoPointIsTakenWhileThePhotoIsDrawnThroughTheCrop() {
        // 4000×3000 cropped to the middle 2000×2000, drawn in 800×600: the visible
        // rectangle is (100, 0, 600, 600) and (160, 300) is 10 % across it.
        let frame = CGRect(x: 100, y: 0, width: 600, height: 600)
        let point = WhiteBalanceFrames.photoPoint(CGPoint(x: 160, y: 300), in: frame, drawsThroughCrop: false)
        XCTAssertEqual(point?.x ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(point?.y ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertNil(WhiteBalanceFrames.photoPoint(CGPoint(x: 160, y: 300), in: frame, drawsThroughCrop: true))
        XCTAssertNil(WhiteBalanceFrames.photoPoint(CGPoint(x: 20, y: 300), in: frame, drawsThroughCrop: false))
    }
}
