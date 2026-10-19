import AppKit
import Observation
import SwiftUI
import XCTest
@testable import HyperDR

/// The open that is slow without being a RAW (raw-states §9): the model's
/// flag, the cancellation the button and Escape share, and the screens.
@MainActor final class OpenCancelTests: XCTestCase {
    private let jpeg = URL(fileURLWithPath: "/fixtures/big.jpg")
    private let old = URL(fileURLWithPath: "/fixtures/old.jpg")
    private let raw = URL(fileURLWithPath: "/fixtures/one.ARW")
    private var preview: EditorPreview {
        EditorPreview(pixelSize: PixelSize(width: 100, height: 80), source:
            SourceSummary(domain: .sdr, colorName: "sRGB", degradationReasons: []), hasGain: false)
    }

    @MainActor private final class Clock: EditorOpenClock {
        var now: Duration = .zero
        private var waiters: [(Duration, CheckedContinuation<Void, Never>)] = []
        func sleep(until deadline: Duration) async throws {
            if now >= deadline { return }
            await withCheckedContinuation { waiters.append((deadline, $0)) }
        }
        func advance(to instant: Duration) {
            now = instant
            let ready = waiters.filter { $0.0 <= now }
            waiters.removeAll { $0.0 <= now }
            for (_, waiter) in ready { waiter.resume() }
        }
        func finish() { advance(to: .seconds(1000)) }
    }

    // MARK: The model

    func testASlowNonRawOpenIsFlaggedAtOnePointFiveSecondsAndClearedByTheFirstFrame() async {
        let clock = Clock(); defer { clock.finish() }
        let services = ScriptedEditorServices(); services.openClock = clock
        let model = EditorModel(services: services)
        model.open([jpeg])
        await eventually(timeout: .seconds(3)) { services.streams[self.jpeg] != nil }
        clock.advance(to: .milliseconds(1499))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.document?.isOpeningSlowly, false)
        clock.advance(to: .milliseconds(1500))
        await eventually(timeout: .seconds(3)) { model.document?.isOpeningSlowly == true }
        XCTAssertEqual(model.document?.isPreparingCameraSupport, false, "never both")
        XCTAssertTrue(model.canCancelOpen)
        services.streams[jpeg]?.yield(.reference(preview))
        await eventually(timeout: .seconds(3)) { model.document?.phase == .rendering }
        XCTAssertEqual(model.document?.isOpeningSlowly, false)
    }

    func testARawIsPreparingNotSlow() async {
        let clock = Clock(); defer { clock.finish() }
        let services = ScriptedEditorServices(); services.openClock = clock
        let model = EditorModel(services: services)
        model.open([raw])
        await eventually(timeout: .seconds(3)) { services.streams[self.raw] != nil }
        clock.advance(to: .milliseconds(1500))
        await eventually(timeout: .seconds(3)) { model.document?.isPreparingCameraSupport == true }
        XCTAssertEqual(model.document?.isOpeningSlowly, false)
    }

    func testOpeningOverAPhotoFlagsTheNewDocumentOnlyAndCancelGoesBack() async {
        let clock = Clock(); defer { clock.finish() }
        let services = ScriptedEditorServices(); services.openClock = clock
        let model = EditorModel(services: services)
        model.open([old])
        await eventually(timeout: .seconds(3)) { services.streams[self.old] != nil }
        services.streams[old]?.yield(.reference(preview)); services.streams[old]?.yield(.edited(preview))
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        model.open([jpeg])
        await eventually(timeout: .seconds(3)) { services.streams[self.jpeg] != nil }
        clock.advance(to: .seconds(2))
        await eventually(timeout: .seconds(3)) { model.document?.isOpeningSlowly == true }
        OpenCancellation.cancel(model)
        XCTAssertEqual(model.document?.name, old.lastPathComponent)
        XCTAssertEqual(model.document?.isOpeningSlowly, false)
        XCTAssertNil(model.alert); XCTAssertFalse(model.canCancelOpen)
    }

    // MARK: Escape (§9.4)

    private func escape(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    private func context(sheet: Bool = false, modal: Bool = false, key: Bool = true) -> OpenCancelKeyRule.Context {
        .init(isKeyWindow: key, hasAttachedSheet: sheet, hasModalWindow: modal, firstResponder: nil)
    }

    private func opening() async -> (EditorModel, ScriptedEditorServices) {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        model.open([jpeg])
        await eventually(timeout: .seconds(3)) { services.streams[self.jpeg] != nil }
        return (model, services)
    }

    func testEscapeCancelsAnUncommittedOpenAtAnyTimeWithNoFocusNeeded() async {
        let (model, _) = await opening()
        XCTAssertTrue(OpenCancelKeyRule.handle(escape(), context: context(), model: model))
        XCTAssertNil(model.document); XCTAssertFalse(model.canCancelOpen); XCTAssertNil(model.alert)
    }

    func testEscapeBelongsToASheetAnAlertOrAMenuFirst() async {
        let (model, _) = await opening()
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(), context: context(sheet: true), model: model))
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(), context: context(modal: true), model: model))
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(), context: context(key: false), model: model))
        XCTAssertTrue(model.canCancelOpen, "nothing was cancelled")
    }

    func testOnlyAPlainEscapeCancels() async {
        let (model, _) = await opening()
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(.command), context: context(), model: model))
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(.shift), context: context(), model: model))
        let other = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        XCTAssertFalse(OpenCancelKeyRule.handle(other, context: context(), model: model))
        XCTAssertTrue(model.canCancelOpen)
    }

    func testEscapeWithNothingToCancelIsLeftToTheCanvasAndTheSystem() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(), context: context(), model: model))
    }

    func testEscapeAlsoLetsGoOfTheOriginalHeldOverTheOldPhoto() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        model.open([old])
        await eventually(timeout: .seconds(3)) { services.streams[self.old] != nil }
        services.streams[old]?.yield(.reference(preview)); services.streams[old]?.yield(.edited(preview))
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        model.beginPeekOriginal()
        XCTAssertTrue(model.isPeekingOriginal)
        model.open([jpeg])
        await eventually(timeout: .seconds(3)) { services.streams[self.jpeg] != nil }
        XCTAssertTrue(OpenCancelKeyRule.handle(escape(), context: context(), model: model))
        XCTAssertFalse(model.isPeekingOriginal)
        XCTAssertEqual(model.document?.name, old.lastPathComponent)
    }
}
