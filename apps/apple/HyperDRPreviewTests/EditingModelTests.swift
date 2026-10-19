import AppKit
import Observation
import Synchronization
import HyperDRKit
import XCTest
@testable import HyperDR

@MainActor final class EditingModelTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/fixtures/a.jpg")

    private func opened(domain: InputDomain = .sdr, tagged: Bool = false,
                        identity: [String: Double]? = nil) async -> (EditorModel, FakeEditorServices, UndoManager) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(1))
        services.preview = EditorPreview(pixelSize: PixelSize(width: 6000, height: 4000),
            source: SourceSummary(domain: domain, colorName: "sRGB", degradationReasons: [],
                                  colorSource: tagged ? "icc" : "assumed"), hasGain: true,
            unadjusted: identity)
        let model = EditorModel(services: services)
        let undo = UndoManager()
        model.attach(undoManager: undo)
        XCTAssertTrue(model.isEditingLocked)
        model.open([url])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        XCTAssertFalse(model.isEditingLocked)
        return (model, services, model.undoManager)
    }

    func testDragAndRepeatedArrowKeysEachUndoAsOneStepButSingleKeysStaySeparate() async {
        let (model, _, undo) = await opened()
        let initial = model.control("brightness").value
        // A drag and a held arrow have the same explicit begin/end boundary.
        for target in [0.4, 0.8] {
            model.beginAdjusting("brightness")
            for value in stride(from: target - 0.2, through: target, by: 0.01) {
                model.adjust("brightness", to: value)
            }
            model.endAdjusting("brightness")
        }
        model.undo()
        XCTAssertEqual(model.control("brightness").value, 0.4)
        model.undo()
        XCTAssertEqual(model.control("brightness").value, initial)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(model.control("brightness").value, 0.4)
        undo.removeAllActions()
        model.adjust("brightness", to: 0.5)
        model.adjust("brightness", to: 0.6)
        model.undo()
        XCTAssertEqual(model.control("brightness").value, 0.5)
        model.undo()
        XCTAssertEqual(model.control("brightness").value, 0.4)
        model.beginAdjusting("brightness")
        model.adjust("brightness", to: 0.8)
        model.adjust("brightness", to: 0.4)
        model.endAdjusting("brightness")
        XCTAssertFalse(model.canUndo)
    }

    func testQuantizationAndStableControlObjects() async {
        let (model, _, _) = await opened()
        let value = model.control("brightness")
        model.adjust("brightness", to: 0.6372)
        XCTAssertTrue(value === model.control("brightness"))
        XCTAssertEqual(value.value, 0.64)
        model.adjust("hdrStrength", to: 0.4567)
        XCTAssertEqual(model.control("hdrStrength").value, 0.46)
        model.adjust("hdrRange", to: 2.567)
        XCTAssertEqual(model.control("hdrRange").value, 2.6)
        model.adjust("brightness", to: -.infinity)
        XCTAssertEqual(value.value, 0.64)
        model.setAuto("aiHdrRange")
        XCTAssertTrue(model.control("aiHdrRange").isAuto)
        XCTAssertEqual(ControlFormat.integer.quantize(2.6), 3)
        XCTAssertEqual(ControlFormat.fixed2.quantize(0.637), 0.64)
        XCTAssertEqual(ControlFormat.percentOrAuto.quantize(0.637), 0.64)
    }

    func testVisibilityAndSourceDependentBrightness() async {
        let (model, _, _) = await opened()
        XCTAssertEqual(model.control("brightness").range.lowerBound, 0)
        XCTAssertTrue(model.control("areaCoverage").isVisible)
        XCTAssertFalse(model.control("modelStrength").isVisible)
        model.setWorkflow(.colorOnly)
        for key in ["hdrStrength", "hdrRange", "areaCoverage", "expansionStart", "modelStrength"] {
            XCTAssertFalse(model.control(key).isVisible, key)
        }
        XCTAssertTrue(model.control("brightness").isVisible)
        model.setWorkflow(.hdr)
        model.setAIMode(.optimized)
        await eventually(timeout: .seconds(3)) { !model.ai.isComputing }
        XCTAssertTrue(model.control("modelStrength").isVisible)
        XCTAssertFalse(model.control("hdrStrength").isVisible)
        XCTAssertFalse(model.control("areaCoverage").isVisible)
        let (hdr, _, _) = await opened(domain: .hdr)
        XCTAssertLessThan(hdr.control("brightness").range.lowerBound, 0)
        XCTAssertFalse(hdr.control("areaCoverage").isVisible)
        hdr.setAIMode(.optimized)
        XCTAssertEqual(hdr.ai.mode, .manual)
        let (raw, _, _) = await opened(domain: .sceneReferred)
        XCTAssertFalse(raw.inputColor.isVisible)
        let (tagged, _, _) = await opened(tagged: true)
        XCTAssertFalse(tagged.inputColor.isEnabled)
        XCTAssertNotNil(tagged.inputColor.disabledReasonKey)
        let color = tagged.inputColor.selection
        tagged.selectInputColor("p3")
        XCTAssertEqual(tagged.inputColor.selection, color)
    }

    func testFormatClampIsPartOfTheSameUndoAndDraggingDefersCorrection() async {
        let (model, _, undo) = await opened()
        model.selectEncoding("pq")
        model.adjust("hdrRange", to: 3.8)
        undo.removeAllActions()
        model.selectEncoding("hlg")
        XCTAssertEqual(model.control("hdrRange").range.upperBound, 2.3)
        XCTAssertEqual(model.control("hdrRange").value, 2.3)
        model.undo()
        XCTAssertEqual(model.control("hdrRange").value, 3.8)
        XCTAssertFalse(model.canUndo)
        model.beginAdjusting("hdrRange")
        model.adjust("hdrRange", to: 3.7)
        model.selectEncoding("adaptive")
        XCTAssertEqual(model.control("hdrRange").value, 3)
        XCTAssertEqual(model.control("hdrRange").range.upperBound, 3)
        model.endAdjusting("hdrRange")
        XCTAssertEqual(model.control("hdrRange").value, 3)
        XCTAssertEqual(model.control("hdrRange").range.upperBound, 3)
    }

    func testSourceIdentityStaysUnquantizedAndTracksFormatCeilings() async {
        let identity = ["brightness": 0.0, "hdrStrength": 1.0, "hdrRange": 3.80731]
        let (model, _, _) = await opened(domain: .hdr, identity: identity)
        XCTAssertEqual(model.control("hdrRange").value, 3)
        model.selectEncoding("pq")
        XCTAssertEqual(model.control("hdrRange").value, 3.80731)
        XCTAssertEqual(model.control("hdrRange").defaultValue, 3.80731)
        XCTAssertEqual(model.outputCeilingStops, 3.80731)
        model.adjust("hdrRange", to: 3.2)
        model.resetControl("hdrRange")
        XCTAssertEqual(model.control("hdrRange").value, 3.80731)
    }

    func testAIReusesGainAndRecomputesForInputColorAndRestoresWithWorkflow() async {
        let (model, services, _) = await opened()
        model.setAIMode(.optimized)
        XCTAssertTrue(model.isEditingLocked)
        XCTAssertFalse(model.canUndo)
        await eventually(timeout: .seconds(3)) { !model.ai.isComputing }
        XCTAssertEqual(services.gainComputations.count, 1)
        model.adjust("aiBrightness", to: 0.3)
        model.setAIMode(.manual)
        model.setAIMode(.optimized)
        await eventually(timeout: .seconds(3)) { !model.ai.isComputing }
        XCTAssertEqual(services.gainComputations.count, 1)
        model.selectInputColor("p3")
        await eventually(timeout: .seconds(3)) { !model.ai.isComputing }
        XCTAssertEqual(services.gainComputations.count, 2)
        model.setWorkflow(.colorOnly)
        XCTAssertEqual(model.ai.mode, .manual)
        model.setWorkflow(.hdr)
        await eventually(timeout: .seconds(3)) { !model.ai.isComputing }
        XCTAssertEqual(model.ai.mode, .optimized)
        XCTAssertEqual(services.gainComputations.count, 2)
        model.resetAll()
        XCTAssertEqual(model.ai.mode, .manual)
        XCTAssertEqual(model.notice, .resetDone)
        XCTAssertEqual(model.workflow, .hdr)
    }

    func testAIFailureFallbackAndEligibility() async {
        let (model, services, _) = await opened()
        services.gainFailure = UserFacingError(code: "model_unknown")
        model.setAIMode(.optimized)
        await eventually(timeout: .seconds(3)) { !model.ai.isComputing }
        XCTAssertEqual(model.ai.mode, .manual)
        XCTAssertEqual(model.ai.availability, .unavailable(reasonKey: "ai.unavailable.unknownModel"))
        XCTAssertEqual(model.notice, .aiFailed(reasonKey: "ai.unavailable.unknownModel"))
        XCTAssertTrue(model.control("brightness").isEnabled)
        XCTAssertEqual(model.ai.models.count, 1, "EXIF model hidden without capture data")
        model.edit.choices["lutInput"] = "hlg"
        XCTAssertEqual(model.aiBlockReason(), "ai.unavailable.lutInput")
        model.edit.choices["lutInput"] = "srgb"
        XCTAssertNil(model.aiBlockReason())
    }

    func testCompareAndPeekDoNotAffectUndoAndNewPhotosResetViewState() async {
        let (model, _, _) = await opened()
        model.toggleCompare()
        XCTAssertEqual(model.viewMode, .compare)
        model.setSplitRatio(2)
        XCTAssertEqual(model.splitRatio, 0.95)
        model.nudgeSplit(by: -0.05)
        XCTAssertEqual(model.splitRatio, 0.9, accuracy: 1e-12)
        model.beginPeekOriginal()
        XCTAssertTrue(model.isPeekingOriginal)
        XCTAssertEqual(model.viewMode, .compare)
        model.endPeekOriginal()
        XCTAssertEqual(model.viewMode, .compare)
        XCTAssertFalse(model.canUndo)
        model.adjust("brightness", to: 0.7)
        model.open([URL(fileURLWithPath: "/fixtures/b.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        XCTAssertEqual(model.splitRatio, 0.5)
        XCTAssertEqual(model.viewMode, .edited)
        XCTAssertFalse(model.canUndo)
        XCTAssertNotEqual(model.control("brightness").value, 0.7)
    }

    func testCloseCancelsAIAndClearsUndo() async {
        let (model, services, _) = await opened()
        services.gainDelay = .seconds(1)
        model.setAIMode(.optimized)
        model.closeDocument()
        XCTAssertFalse(model.ai.isComputing)
        XCTAssertTrue(model.isEditingLocked)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.ai.availability, .unavailable(reasonKey: "ai.unavailable.noPhoto"))
    }
}

extension EditingModelTests {
    func testGainMustFinishBeforeSubmittingAndAppliedWaitsForSuccessfulFrame() async throws {
        let (model, services, _) = await opened()
        // Deterministic gates for gain and rendering; advancing the frame
        // ticker while inference is suspended must submit no AI request.
        model.closeDocument()
        let ticker = ManualFrameTicker()
        let gated = EditorModel(services: services, ticker: ticker)
        gated.open([url])
        await eventually(timeout: .seconds(3)) { gated.document?.phase == .ready }
        services.autoCompletesRefreshes = false
        var gain: CheckedContinuation<Void, Error>?
        services.gainGate = { try await withCheckedThrowingContinuation { gain = $0 } }
        let before = services.receivedOptions.count
        gated.adjust("brightness", to: 0.8) // pending manual frame
        gated.setAIMode(.optimized)
        await eventually(timeout: .seconds(3)) { gain != nil }
        ticker.tick()
        await settle(100)
        XCTAssertEqual(services.receivedOptions.count, before)
        XCTAssertTrue(gated.ai.isComputing)
        gain?.resume(); gain = nil
        await eventually(timeout: .seconds(3)) { !gated.ai.isComputing }
        XCTAssertEqual(gated.ai.availability, .cached)
        ticker.tick()
        await eventually(timeout: .seconds(3)) { services.receivedOptions.count == before + 1 }
        XCTAssertEqual(services.receivedOptions.last?["useModel"], .bool(true))
        XCTAssertEqual(gated.ai.availability, .cached, "manual pixels are still visible")
        let photo = try XCTUnwrap(gated.photo)
        services.sendRefresh(.edited(services.preview, isLatest: true), for: photo)
        await eventually(timeout: .seconds(3)) {
            if case .applied = gated.ai.availability { return true }; return false
        }
        gated.selectInputColor("p3") // changed gain input, same race through editChanged
        await eventually(timeout: .seconds(3)) { gain != nil }
        ticker.tick()
        await settle(100)
        XCTAssertEqual(services.receivedOptions.count, before + 1)
        gain?.resume(); gain = nil
        await eventually(timeout: .seconds(3)) { !gated.ai.isComputing }
        ticker.tick()
        await eventually(timeout: .seconds(3)) { services.receivedOptions.count == before + 2 }
        services.sendRefresh(.failed(UserFacingError(code: "render_failed")), for: photo)
        await eventually(timeout: .seconds(3)) { gated.ai.mode == .manual }
        XCTAssertEqual(gated.notice, .aiFailed(reasonKey: "ai.unavailable.failed"))
        gated.closeDocument()
    }

    func testIncompatibleLUTCallsDoNotComputeOrRegisterUndo() async {
        let (model, services, undo) = await opened()
        for input in ["hlg", "pq", "slog3-sgamut3cine"] {
            model.edit.choices["lutInput"] = input
            model.setAIMode(.optimized)
            XCTAssertEqual(model.ai.mode, .manual)
            XCTAssertFalse(undo.canUndo)
            XCTAssertTrue(services.gainComputations.isEmpty)
        }
        for input in ["srgb", "p3", "rec709"] {
            model.edit.choices["lutInput"] = input
            XCTAssertNil(model.aiBlockReason())
        }
    }

    func testBusyGracePeriodAndOpenCommandBoundaries() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(10), previewDelay: .milliseconds(1))
        let model = EditorModel(services: services)
        XCTAssertTrue(model.canOpenDocument)
        model.open([url])
        XCTAssertFalse(model.canOpenDocument)
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        XCTAssertTrue(model.canOpenDocument)
        services.previewDelay = .seconds(2)
        model.adjust("brightness", to: 0.8)
        XCTAssertFalse(model.document?.isRefreshing ?? true)
        try await Task.sleep(for: .milliseconds(150))
        model.adjust("brightness", to: 0.9) // resets the grace period
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(model.document?.isRefreshing ?? true)
        await eventually(timeout: .seconds(2)) { model.document?.isRefreshing == true }
        model.closeDocument()
        XCTAssertTrue(model.canOpenDocument)
        XCTAssertNil(model.document)
        let (ai, _, _) = await opened()
        ai.setAIMode(.optimized)
        XCTAssertFalse(ai.canOpenDocument)
        ai.closeDocument()
    }
}

extension EditingModelTests {
    func testSourceReplacementCancelsInferenceAndReopensEvenWhileEditingIsLocked() async throws {
        let (model, services, _) = await opened()
        let old = try XCTUnwrap(model.photo)
        services.gainDelay = .seconds(1)
        model.setAIMode(.optimized)
        model.open([URL(fileURLWithPath: "/fixtures/blocked.jpg")])
        XCTAssertEqual(model.photo, old, "user opens are disabled during inference")
        services.sendRefresh(.sourceReplaced, for: old)
        await eventually(timeout: .seconds(3)) {
            model.photo != old && model.document?.phase == .ready
        }
        XCTAssertFalse(model.ai.isComputing)
        XCTAssertEqual(model.ai.mode, .manual)
        XCTAssertEqual(model.photo?.url, old.url)
        model.closeDocument()
    }

    func testDiscreteResetEndsTheDragAndDetachingClearsEditorHistory() async {
        let (model, _, undo) = await opened()
        model.beginAdjusting("brightness")
        model.adjust("brightness", to: 0.9)
        model.resetControl("brightness")
        model.undo()
        XCTAssertEqual(model.control("brightness").value, 0.9)
        model.undo()
        XCTAssertEqual(model.control("brightness").value, 0.6)
        model.attach(undoManager: nil)
        XCTAssertFalse(undo.groupsByEvent)
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(model.canRedo)
    }
}

@MainActor private final class TextUndoDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(_ manager: UndoManager) { self.manager = manager }
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

extension EditingModelTests {
    func testSharedWindowTextHistoryAndEditorHistoryAreIndependent() async {
        let (model, _, _) = await opened()
        let shared = UndoManager()
        model.attach(undoManager: shared)
        XCTAssertTrue(shared.groupsByEvent)
        let delegate = TextUndoDelegate(shared)
        let text = NSTextView(frame: .zero)
        text.delegate = delegate
        text.allowsUndo = true
        text.insertText("hello", replacementRange: NSRange(location:0,length:0))
        await eventually(timeout:.seconds(2)) { shared.canUndo }
        // No window/event dispatch in this test: explicitly finish the one
        // automatic event group that AppKit normally closes at event end.
        if shared.groupingLevel > 0 { shared.endUndoGrouping() }
        model.adjust("brightness",to:0.7)
        model.adjust("brightness",to:0.8)
        model.undo(firstResponder:nil)
        XCTAssertEqual(model.control("brightness").value,0.7)
        XCTAssertEqual(text.string,"hello")
        XCTAssertTrue(model.canUndo(firstResponder:text))
        model.undo(firstResponder:text)
        XCTAssertEqual(text.string,"")
        XCTAssertEqual(model.control("brightness").value,0.7)
        XCTAssertTrue(model.canRedo(firstResponder:text))
        model.redo(firstResponder:text)
        XCTAssertEqual(text.string,"hello")
        model.redo(firstResponder:nil)
        XCTAssertEqual(model.control("brightness").value,0.8)
        XCTAssertTrue(shared.groupsByEvent)
    }
}

extension EditingModelTests {
    func testMaskAndOutputCeilingAreObservableAndUseCurrentDefaults() async {
        let (model,_,_) = await opened()
        let maskChanges = Mutex(0), ceilingChanges = Mutex(0)
        withObservationTracking { _ = model.maskKey } onChange: { maskChanges.withLock { $0 += 1 } }
        model.showMask(for:"hdrStrength")
        XCTAssertEqual(maskChanges.withLock { $0 },1)
        withObservationTracking { _ = model.outputCeilingStops } onChange: { ceilingChanges.withLock { $0 += 1 } }
        model.adjust("hdrRange",to:2.8)
        XCTAssertEqual(ceilingChanges.withLock { $0 },1)
        XCTAssertEqual(model.outputCeilingStops,2.8)
        model.setWorkflow(.colorOnly)
        XCTAssertEqual(model.outputCeilingStops,0)
        XCTAssertNil(model.maskKey)
        let (hdr,_,_) = await opened(domain:.hdr,identity:["brightness":0,"hdrStrength":1,"hdrRange":3.80731])
        hdr.selectEncoding("pq")
        XCTAssertEqual(hdr.control("hdrRange").defaultValue,3.80731)
        hdr.selectEncoding("hlg")
        XCTAssertEqual(hdr.control("hdrRange").defaultValue,2.3)
        XCTAssertEqual(hdr.outputCeilingStops,2.3)
    }
}

extension EditingModelTests {
    func testReviewerNSTextViewProbeThroughActualAttachAndRouting() async {
        let (model, _, _) = await opened()
        let shared = UndoManager()
        model.attach(undoManager: shared)
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width:200,height:100))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let text = NSTextView(frame:NSRect(x:0,y:0,width:200,height:100),textContainer:container)
        let delegate = TextUndoDelegate(shared)
        text.delegate = delegate; text.allowsUndo = true
        text.insertText("hello",replacementRange:NSRange(location:0,length:0))
        XCTAssertEqual(text.string,"hello")
        if shared.groupingLevel > 0 { shared.endUndoGrouping() }
        model.adjust("brightness",to:0.7)
        model.undo(firstResponder:text)
        XCTAssertEqual(text.string,"")
        XCTAssertEqual(model.control("brightness").value,0.7)
        model.redo(firstResponder:text)
        XCTAssertEqual(text.string,"hello")
        model.undo(firstResponder:NSResponder())
        XCTAssertEqual(model.control("brightness").value,0.6)
        text.isFieldEditor = true
        XCTAssertTrue(EditorModel.routesUndoToText(text))
        model.undo(firstResponder:text)
        XCTAssertEqual(text.string,"")
        XCTAssertTrue(shared.groupsByEvent)
        model.closeDocument()
    }
}
