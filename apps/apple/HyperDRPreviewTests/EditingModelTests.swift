import AppKit
import Observation
import Synchronization
import HyperDRDesign
import HyperDRRecipe
import XCTest
@testable import HyperDR

/// The Mac model around the recipe editor: the lock, undo and its names, the
/// split between AppKit text history and editor history, and what follows a
/// drag (p7-2b §4). The editor's own rules are tested in HyperDREditorCore.
@MainActor final class EditingModelTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/fixtures/a.jpg")
    private let exposure = Adjustments.declaration("tone.exposure")!

    private func opened() async -> EditorModel {
        let model = EditorModel(services: FakeEditorServices(openDelay: .zero))
        XCTAssertNil(model.editingLockReason)
        model.open([url])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        XCTAssertFalse(model.isEditingLocked)
        return model
    }

    private func value(_ model: EditorModel) -> Double { model.recipeNumber(exposure.id) ?? 0 }

    /// G-08: from the moment a photo starts opening until its first edited
    /// frame the editor cannot change the photo.
    func testNothingCanBeEditedBeforeTheFirstEditedFrame() async {
        let services = FakeEditorServices(openDelay: .zero)
        await services.fakeRendering?.holdRenders()
        let model = EditorModel(services: services)
        model.open([url])
        XCTAssertEqual(model.document?.phase, .opening)
        XCTAssertEqual(model.editingLockReason, .loading)
        XCTAssertFalse(model.canResetAll)
        XCTAssertFalse(model.canOpenDocument, "a photo is still opening")
        model.selectEncoding("pq")
        XCTAssertNotEqual(model.exportChoices.encoding, "pq")
        await services.fakeRendering?.releaseRenders()
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        XCTAssertNil(model.editingLockReason)
        XCTAssertTrue(model.canResetAll)
        model.closeDocument()
    }

    func testADragIsOneUndoStepNamedAfterItsControl() async {
        let model = await opened()
        let initial = value(model)
        model.editor.editingChanged(exposure, true)
        for step in 1...10 { model.adjustRecipe(exposure.id, to: Double(step) / 10) }
        XCTAssertTrue(model.canUndo, "Undo would end the open drag first")
        model.editor.editingChanged(exposure, false)
        XCTAssertEqual(model.undoActionName, AdjustmentText.undoName(exposure))
        model.undo()
        XCTAssertEqual(value(model), initial)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(value(model), 1)
        model.closeDocument()
    }

    func testUndoDuringADragCommitsItFirst() async {
        let model = await opened()
        model.adjustRecipe(exposure.id, to: 0.3)
        model.editor.editingChanged(exposure, true)
        model.adjustRecipe(exposure.id, to: 0.9)
        // ⌘Z ends the open drag as its own step first (R22-004).
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertFalse(model.editor.isDragging)
        XCTAssertEqual(value(model), 0.3)
        model.undo()
        XCTAssertEqual(value(model), 0)
        model.closeDocument()
    }

    func testGroupResetAndResetAllAreNamedSteps() async {
        let model = await opened()
        model.adjustRecipe(exposure.id, to: 0.5)
        model.adjustRecipe("tone.contrast", to: 1.3)
        model.editor.resetGroup(exposure.group)
        XCTAssertEqual(model.undoActionName, AdjustmentText.undoName(.group(exposure.group)))
        model.undo()
        XCTAssertEqual(value(model), 0.5)
        model.resetAll()
        XCTAssertEqual(model.undoActionName, AdjustmentText.undoName(.all))
        XCTAssertNil(model.recipeNumber(exposure.id))
        model.closeDocument()
    }

    func testCompareAndPeekDoNotAffectUndoAndNewPhotosResetViewState() async {
        let model = await opened()
        model.toggleCompare()
        XCTAssertEqual(model.viewMode, .compare)
        model.setSplitRatio(2)
        XCTAssertEqual(model.splitRatio, 0.95)
        model.beginPeekOriginal()
        XCTAssertTrue(model.isPeekingOriginal)
        model.endPeekOriginal()
        XCTAssertEqual(model.viewMode, .compare)
        XCTAssertFalse(model.canUndo)
        model.adjustRecipe(exposure.id, to: 0.7)
        model.open([URL(fileURLWithPath: "/fixtures/b.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready && model.document?.name == "b.jpg" }
        XCTAssertEqual(model.splitRatio, 0.5)
        XCTAssertEqual(model.viewMode, .edited)
        XCTAssertFalse(model.canUndo)
        XCTAssertNil(model.recipeNumber(exposure.id))
        model.closeDocument()
    }

    func testCloseClearsUndo() async {
        let model = await opened()
        model.adjustRecipe(exposure.id, to: 0.7)
        XCTAssertTrue(model.canUndo)
        model.closeDocument()
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.isEditingLocked)
    }

    /// A file changed on disk (R23-001): the canvas asks to open it again and
    /// nothing is exported from it meanwhile.
    func testAChangedFileAsksToBeOpenedAgain() async {
        // A file that exists: a missing one would be "can't find it" instead.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("changed-\(UUID()).jpg")
        FileManager.default.createFile(atPath: file.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: file) }
        let services = FakeEditorServices(openDelay: .zero)
        let model = EditorModel(services: services)
        model.open([file])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        await services.fakeRendering!.configure { $0.renderError = .sourceChanged }
        model.adjustRecipe(exposure.id, to: 0.5)
        await eventually { model.sourceChanged }
        XCTAssertEqual(model.export.blockerKey, "export.blocker.sourceChanged")
        await services.fakeRendering!.configure { $0.renderError = nil }
        model.reopenChangedSource()
        await eventually { model.document?.phase == .ready && !model.sourceChanged }
        XCTAssertNil(model.recipeNumber(exposure.id), "the photo is read again from the defaults")
        model.closeDocument()
    }

    func testDetachingClearsEditorHistory() async {
        let model = await opened()
        model.adjustRecipe(exposure.id, to: 0.7)
        model.attach(undoManager: nil)
        XCTAssertFalse(model.undoManager.groupsByEvent)
        XCTAssertFalse(model.canUndo)
        model.closeDocument()
    }

}

@MainActor private final class TextUndoDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(_ manager: UndoManager) { self.manager = manager }
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

extension EditingModelTests {
    func testSharedWindowTextHistoryAndEditorHistoryAreIndependent() async {
        let model = await opened()
        let shared = UndoManager()
        model.attach(undoManager: shared)
        XCTAssertTrue(shared.groupsByEvent)
        let delegate = TextUndoDelegate(shared)
        let text = NSTextView(frame: .zero)
        text.delegate = delegate
        text.allowsUndo = true
        text.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        await eventually(timeout: .seconds(2)) { shared.canUndo }
        // No window/event dispatch in this test: explicitly finish the one
        // automatic event group that AppKit normally closes at event end.
        if shared.groupingLevel > 0 { shared.endUndoGrouping() }
        model.adjustRecipe(exposure.id, to: 0.7)
        model.adjustRecipe(exposure.id, to: 0.8)
        model.undo(firstResponder: nil)
        XCTAssertEqual(value(model), 0.7)
        XCTAssertEqual(text.string, "hello")
        XCTAssertTrue(model.canUndo(firstResponder: text))
        model.undo(firstResponder: text)
        XCTAssertEqual(text.string, "")
        XCTAssertEqual(value(model), 0.7)
        model.redo(firstResponder: text)
        XCTAssertEqual(text.string, "hello")
        model.redo(firstResponder: nil)
        XCTAssertEqual(value(model), 0.8)
        text.isFieldEditor = true
        XCTAssertTrue(EditorModel.routesUndoToText(text))
        XCTAssertTrue(shared.groupsByEvent)
        model.closeDocument()
    }
}
