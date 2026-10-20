import AppKit
import SwiftUI
import XCTest
import HyperDRDesign
import HyperDRRecipe
@testable import HyperDR

/// The glue between the editor model and the design components: how the
/// scope data is handed over, and how a held arrow key on a control becomes
/// one undo step of the recipe editor.
@MainActor final class InspectorWiringTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/fixtures/a.jpg")

    private func opened() async -> EditorModel {
        let model = EditorModel(services: FakeEditorServices(openDelay: .zero))
        model.open([url])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        return model
    }

    // MARK: Scopes

    /// The scopes measure what the canvas draws: a prediction coming in or a
    /// bypass changes the picture without changing the recipe (R27-002).
    func testScopesMeasureAgainWhenThePredictionArrivesOrAGroupIsBypassed() async throws {
        let services = FakeEditorServices(openDelay: .zero)
        let fake = try XCTUnwrap(services.fakeRendering)
        await fake.holdPredictions()
        let model = EditorModel(services: services)
        model.open([url])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        let size = EditorModel.scopeSize(try XCTUnwrap(model.editor.source).pixelSize)
        func measured(_ what: String, _ match: (EditorRenderRequest) -> Bool) async {
            for _ in 0..<5000 {
                if await fake.requests.contains(where: { $0.size == size && $0.region == nil && match($0) }) { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("the scopes never measured \(what)")
        }
        var recipe = model.editor.recipe
        recipe.setValue(.string("ai"), for: "hdr.source")
        model.editor.setRecipe(recipe)
        await eventually(timeout: .seconds(3)) { model.editor.isModelGainPending }
        await fake.releasePredictions()
        await measured("the predicted picture") { $0.recipe == recipe && $0.usesModelGain }
        model.editor.bypassedGroups = [.light]
        await measured("the bypassed picture") { $0.recipe == recipe && $0.bypassedGroups == [.light] }
        model.closeDocument()
    }

    /// A → B → A while B is still being measured: the scopes end on A, not on
    /// B's late result (R34-001).
    func testReturningToAMeasuredPictureDropsTheMeasurementInBetween() async throws {
        let services = FakeEditorServices(openDelay: .zero)
        let fake = try XCTUnwrap(services.fakeRendering)
        let model = EditorModel(services: services)
        model.open([url])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        let a = model.editor.recipe
        await eventually(timeout: .seconds(3)) { model.scopedRequest?.recipe == a && model.scopingRequest == nil }
        var b = a
        b.setValue(.number(1), for: "tone.exposure")
        await fake.holdRenders()
        model.editor.setRecipe(b)
        model.startScopes()
        XCTAssertEqual(model.scopingRequest?.recipe, b)
        model.editor.setRecipe(a)
        model.startScopes()
        XCTAssertNil(model.scopingRequest, "B's measurement is dropped")
        await fake.releaseRenders()
        await model.scopeTask?.value
        await settle(50)
        XCTAssertEqual(model.scopedRequest?.recipe, a)
        model.closeDocument()
    }

    func testScopeContentFollowsTheMeasurementAndThePhase() async {
        let model = await opened()
        // The fake's frames are measured once; start again from nothing.
        await eventually(timeout: .seconds(3)) { model.scopes.current != nil }
        await settle(50)
        model.scopes.update(original: .some(nil), current: .some(nil), waveform: .some(nil))
        XCTAssertEqual(ScopeSection.content(scopes: model.scopes, phase: .ready), .measuring)
        XCTAssertEqual(ScopeSection.content(scopes: model.scopes,
                                            phase: .failed(UserFacingError(code: "x"))), .unavailable)
        let bins = HistogramData.bins
        let flat = [UInt32](repeating: 1, count: bins)
        let histogram = HistogramData(total: bins, luma: flat, red: flat, green: flat, blue: flat)
        let waveform = WaveformData(columns: 2, counts: [UInt32](repeating: 3, count: 2 * WaveformData.rows))
        model.scopes.update(original: .some(histogram), current: .some(histogram), waveform: .some(waveform))
        guard case .data(let data) = ScopeSection.content(scopes: model.scopes, phase: .ready) else {
            return XCTFail("measured scopes are data")
        }
        XCTAssertEqual(data.current?.luma, flat)
        XCTAssertEqual(data.original?.red, flat)
        XCTAssertEqual(data.waveform?.columns, 2)
        XCTAssertEqual(data.waveform?.rows, WaveformData.rows)
        XCTAssertEqual(data.waveform?.counts.count, 2 * WaveformData.rows)
    }

    // MARK: Held arrow keys (batch 4 §2.4)

    private func arrow(_ type: NSEvent.EventType, repeating: Bool = false) -> ArrowKeyInput {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: repeating, keyCode: 126)!
        return ArrowKeyInput(event)!
    }

    private let exposure = Adjustments.declaration("tone.exposure")!
    private var step: Double { exposure.step ?? 0.01 }

    private func value(_ model: EditorModel) -> Double {
        model.editor.recipe.value(for: exposure.id)?.numberValue ?? 0
    }

    /// The row's binding and bracket, as the adjustment inspector wires them.
    private func row(_ model: EditorModel) -> (binding: Binding<Double>, editing: (Bool) -> Void) {
        let binding = Binding<Double>(get: { self.value(model) }, set: { value in
            var recipe = model.editor.recipe
            recipe.setValue(.number(value), for: self.exposure.id)
            model.editor.setRecipe(recipe)
        })
        return (binding, { model.editor.editingChanged(self.exposure, $0) })
    }

    /// A held arrow through the slider's own entry (`ArrowKeyEditing.perform`),
    /// driven by constructed key events: the first key-down begins the
    /// session, the repeats step, the key-up ends it, and one undo takes back
    /// the whole hold.
    func testAHeldArrowIsOneUndoStep() async {
        let model = await opened()
        let initial = value(model)
        let (binding, editing) = row(model)
        var keys = ArrowKeyEditing()
        var phases: [Bool] = []
        for input in [arrow(.keyDown), arrow(.keyDown, repeating: true), arrow(.keyDown, repeating: true), arrow(.keyUp)] {
            keys.perform(input, verticalOnly: false, notify: { phases.append($0); editing($0) }) { steps in
                binding.wrappedValue += Double(steps) * step
            }
        }
        XCTAssertEqual(phases, [true, false], "one session for the whole hold")
        XCTAssertEqual(value(model), initial + 3 * step, accuracy: 1e-6)
        XCTAssertEqual(model.undoActionName, AdjustmentText.undoName(exposure))
        model.undo()
        XCTAssertEqual(value(model), initial, accuracy: 1e-6, "one undo takes back the whole hold")
        XCTAssertFalse(model.canUndo)
        model.closeDocument()
    }

    func testTwoSeparatePressesAreTwoUndoSteps() async {
        let model = await opened()
        let initial = value(model)
        let (binding, editing) = row(model)
        var keys = ArrowKeyEditing()
        for _ in 0..<2 {
            for input in [arrow(.keyDown), arrow(.keyUp)] {
                keys.perform(input, verticalOnly: false, notify: editing) { steps in
                    binding.wrappedValue += Double(steps) * step
                }
            }
        }
        model.undo()
        XCTAssertEqual(value(model), initial + step, accuracy: 1e-6)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(value(model), initial, accuracy: 1e-6)
        XCTAssertFalse(model.canUndo)
        model.closeDocument()
    }

    /// The window going away mid-hold: the key-up never comes, and `finish`
    /// (focus loss, disabling, removal) still closes the session, so the
    /// edit is one undo step and nothing stays open.
    func testALostKeyUpStillEndsTheHoldWhenTheControlLetsGo() async {
        let model = await opened()
        let initial = value(model)
        let (binding, editing) = row(model)
        var keys = ArrowKeyEditing()
        for input in [arrow(.keyDown), arrow(.keyDown, repeating: true)] {
            keys.perform(input, verticalOnly: false, notify: editing) { steps in
                binding.wrappedValue += Double(steps) * step
            }
        }
        XCTAssertTrue(keys.isOpen)
        keys.finish(editing)
        XCTAssertFalse(keys.isOpen)
        XCTAssertFalse(model.editor.isDragging)
        model.undo()
        XCTAssertEqual(value(model), initial, accuracy: 1e-6)
        XCTAssertFalse(model.canUndo)
        model.closeDocument()
    }
}
