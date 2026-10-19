import AppKit
import Observation
import SwiftUI
import XCTest
import HyperDRDesign
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

    /// What would have been spoken; nothing reaches the system.
    private var spoken: [String] = []
    private var originalDeliver: ((String) -> Void)?

    override func setUp() async throws {
        spoken = []
        originalDeliver = CameraSupportAnnouncement.deliver
        CameraSupportAnnouncement.deliver = { [weak self] in self?.spoken.append($0) }
    }

    override func tearDown() async throws {
        if let originalDeliver { CameraSupportAnnouncement.deliver = originalDeliver }
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
        OpenCancellation.cancel(model, locale: Locale(identifier: "en"))
        XCTAssertEqual(spoken, ["Opening cancelled"], "said once, to the recorder")
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
        XCTAssertTrue(OpenCancelKeyRule.handle(escape(), context: context(), model: model, locale: Locale(identifier: "en")))
        XCTAssertNil(model.document); XCTAssertFalse(model.canCancelOpen); XCTAssertNil(model.alert)
        XCTAssertEqual(spoken, ["Opening cancelled"])
    }

    func testEscapeBelongsToASheetAnAlertOrAMenuFirst() async {
        let (model, _) = await opening()
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(), context: context(sheet: true), model: model))
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(), context: context(modal: true), model: model))
        XCTAssertFalse(OpenCancelKeyRule.handle(escape(), context: context(key: false), model: model))
        XCTAssertTrue(model.canCancelOpen, "nothing was cancelled")
        XCTAssertEqual(spoken, [], "and nothing was said")
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

    // MARK: A restore that is slow before it knows the photo (N10)

    func testARestoreStillLookingForItsPhotoIsSlowAfterOnePointFiveSecondsAndNeverARaw() async {
        let clock = Clock(); defer { clock.finish() }
        let services = ScriptedEditorServices(); services.openClock = clock; services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.launch()
        await eventually(timeout: .seconds(3)) { services.restoreWaiter != nil }
        clock.advance(to: .milliseconds(1499))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.isRestoringSlowly)
        clock.advance(to: .milliseconds(1500))
        await eventually(timeout: .seconds(3)) { model.isRestoringSlowly }
        XCTAssertNil(model.document, "nothing is known about the photo yet")
        XCTAssertTrue(model.canCancelOpen)
        model.cancelOpen()
        XCTAssertFalse(model.isRestoringSlowly); XCTAssertFalse(model.canCancelOpen)
        services.restoreWaiter?.resume(returning: .none); services.restoreWaiter = nil
    }

    func testTheSlowRestoreHandsOverToTheDocumentsOwnSlowFlag() async {
        let clock = Clock(); defer { clock.finish() }
        let services = ScriptedEditorServices(); services.openClock = clock; services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.launch()
        await eventually(timeout: .seconds(3)) { services.restoreWaiter != nil }
        clock.advance(to: .seconds(2))
        await eventually(timeout: .seconds(3)) { model.isRestoringSlowly }
        services.restoreWaiter?.resume(returning: .restored(services.placeholder(for: jpeg))); services.restoreWaiter = nil
        await eventually(timeout: .seconds(3)) { model.document?.isOpeningSlowly == true }
        XCTAssertFalse(model.isRestoringSlowly)
        XCTAssertEqual(model.document?.isPreparingCameraSupport, false)
    }

    func testTheCanvasOffersCancelWhileARestoreIsSlow() async throws {
        let clock = Clock(); defer { clock.finish() }
        let services = ScriptedEditorServices(); services.openClock = clock; services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.launch()
        await eventually(timeout: .seconds(3)) { services.restoreWaiter != nil }
        func picture() throws -> [UInt8] {
            let host = NSHostingView(rootView: CanvasView(model: model, window: EditorWindowState(), padding: 0)
                .environment(\.locale, Locale(identifier: "en")).frame(width: 600, height: 400))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return Array(UnsafeBufferPointer(start: bitmap.bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
        }
        let waiting = try picture()
        clock.advance(to: .seconds(2))
        await eventually(timeout: .seconds(3)) { model.isRestoringSlowly }
        XCTAssertNotEqual(try picture(), waiting, "the slow restore shows its progress and Cancel")
        services.restoreWaiter?.resume(returning: .none); services.restoreWaiter = nil
    }

    // MARK: The corner chip's height (N8)

    func testTheCornerChipIs26PointsHighWithAndWithoutCancel() {
        func height<V: View>(_ view: V) -> CGFloat {
            NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "en"))).fittingSize.height
        }
        let plain = height(Label { Text("stage.reading") } icon: { CanvasSpinner(size: 12) }
            .frame(height: BusyChip.contentHeight).hdrOverlayChip())
        let slow = height(SlowOpenChip(label: "stage.reading", fileName: "A.jpg", cancel: {}))
        XCTAssertEqual(plain, 26, accuracy: 0.5)
        XCTAssertEqual(slow, 26, accuracy: 0.5)
    }
}
