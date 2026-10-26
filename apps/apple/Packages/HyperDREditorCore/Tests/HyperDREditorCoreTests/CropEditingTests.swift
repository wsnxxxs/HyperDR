import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDREditorCore

@MainActor @Suite struct CropEditingTests {
    @Test func geometryGesturesOnlyUpdateDisplayUntilCropCloses() async throws {
        let fake = FakeEditorRendering()
        let editor = RecipeEditor(renderer: fake)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.attach(undoManager: undo)
        try await editor.open(URL(fileURLWithPath: "/tmp/crop-test.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        await editor.settle()
        let before = await fake.requests.count
        editor.editingGeometry(true)
        for angle in 1...12 {
            // Duplicate begin notifications must not split a gesture's undo.
            editor.editingGeometry(true)
            var recipe = editor.recipe
            recipe.geometry.angle = Double(angle)
            editor.setRecipe(recipe)
            await editor.settle()
        }
        editor.editingGeometry(false)
        await editor.settle()
        #expect(await fake.requests.count == before)
        undo.undo()
        #expect(editor.recipe.geometry == .identity)
        #expect(!undo.canUndo)
        await editor.settle()
        #expect(await fake.requests.count == before)
        undo.redo()
        await editor.settle()
        editor.isEditingCrop = false
        await editor.settle()
        let final = await fake.requests.dropFirst(before).filter { !$0.recipe.geometry.isIdentity }
        #expect(final.count == 2, "one edited render and one comparison original")
        #expect(final.allSatisfy { $0.recipe.geometry.angle == 12 && !$0.isInteractive })
        await editor.close()
    }
    /// The crop pane renders the whole photo: its frame is current although the
    /// recipe has a crop, so the host never waits for a render that will not come.
    @Test func theWholePhotoIsCurrentWhileTheCropIsEdited() async throws {
        let fake = FakeEditorRendering()
        let editor = RecipeEditor(renderer: fake)
        try await editor.open(URL(fileURLWithPath: "/tmp/crop-current.jpg"))
        var recipe = editor.recipe
        recipe.geometry.angle = 5
        editor.setRecipe(recipe)
        await editor.settle()
        #expect(editor.frameIsCurrent)
        editor.isEditingCrop = true
        await editor.settle()
        #expect(editor.frame?.request.recipe.geometry == .identity)
        #expect(editor.frameIsCurrent)
        editor.editingGeometry(true)
        recipe.geometry.angle = 9
        editor.setRecipe(recipe)
        editor.editingGeometry(false)
        await editor.settle()
        #expect(editor.frameIsCurrent)
        recipe.setValue(.number(0.5), for: "tone.exposure")
        editor.setRecipe(recipe)
        #expect(!editor.frameIsCurrent, "an edit of the photo itself waits for its render")
        await editor.settle()
        #expect(editor.frameIsCurrent)
        editor.isEditingCrop = false
        #expect(!editor.frameIsCurrent, "leaving the pane waits for the cropped render")
        await editor.settle()
        #expect(editor.frameIsCurrent)
        await editor.close()
    }

    @Test func closingCropCommitsAnOpenGestureAndMixedEditsStillRender() async throws {
        let fake = FakeEditorRendering()
        let editor = RecipeEditor(renderer: fake)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.attach(undoManager: undo)
        try await editor.open(URL(fileURLWithPath: "/tmp/crop-close-test.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        await editor.settle()
        let before = await fake.requests.count
        editor.editingGeometry(true)
        var recipe = editor.recipe
        recipe.geometry.angle = 7
        recipe.setValue(.number(0.5), for: "tone.exposure")
        editor.setRecipe(recipe)
        await editor.settle()
        #expect(await fake.requests.count > before, "non-geometry edits still update the underlying photo")
        editor.isEditingCrop = false
        #expect(!editor.isDragging)
        await editor.settle()
        #expect(editor.frame?.request.recipe.geometry.angle == 7)
        #expect(editor.frame?.request.isInteractive == false)
        undo.undo()
        #expect(editor.recipe.geometry == .identity && !undo.canUndo)
        await editor.close()
    }

    @Test func endingCropInteractionIsIdempotentAndCannotEndOtherGestures() async throws {
        let fake = FakeEditorRendering()
        let editor = RecipeEditor(renderer: fake)
        try await editor.open(URL(fileURLWithPath: "/tmp/crop-lifecycle.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        await editor.settle()
        let before = await fake.requests.count
        editor.editingGeometry(true)
        var recipe = editor.recipe
        recipe.geometry.angle = 9
        editor.setRecipe(recipe)
        #expect(editor.endCropInteraction())
        #expect(!editor.endCropInteraction() && !editor.isDragging)
        recipe.geometry.angle = 10
        editor.setRecipe(recipe)
        #expect(editor.recipe.geometry.angle == 9, "late cancelled gesture writes are suppressed")
        editor.editingGeometry(false)
        await editor.settle()
        #expect(await fake.requests.count == before)
        let exposure = Adjustments.declaration("tone.exposure")!
        editor.editingChanged(exposure, true)
        #expect(!editor.endCropInteraction())
        editor.editingGeometry(false)
        #expect(editor.isDragging, "late crop teardown cannot end an adjustment drag")
        editor.editingChanged(exposure, false)
        await editor.settle()
        await editor.close()
    }

    @Test func closingAnActiveTurnGestureOnlyRendersTheFinalSize() async throws {
        let fake = FakeEditorRendering()
        let editor = RecipeEditor(renderer: fake)
        try await editor.open(URL(fileURLWithPath: "/tmp/crop-turn-close.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        await editor.settle()
        let before = await fake.requests.count
        editor.editingGeometry(true)
        var recipe = editor.recipe
        recipe.geometry = recipe.geometry.turnedLeft()
        editor.setRecipe(recipe)
        editor.isEditingCrop = false
        await editor.settle()
        let submitted = await fake.requests.dropFirst(before)
        #expect(submitted.count == 2, "one edited and one comparison render, without the outgoing preview size")
        #expect(submitted.allSatisfy { $0.size == editor.previewSize && !$0.isInteractive })
        await editor.close()
    }

    @Test(arguments: [0.0, 5.0])
    func cancellingCropCommitsTheActiveGestureBeforeRestoringEntry(previousAngle: Double) async throws {
        let fake = FakeEditorRendering()
        let editor = RecipeEditor(renderer: fake)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.attach(undoManager: undo)
        try await editor.open(URL(fileURLWithPath: "/tmp/crop-cancel-active.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        await editor.settle()
        let before = await fake.requests.count
        let entry = editor.recipe.geometry
        var recipe = editor.recipe
        recipe.geometry.angle = previousAngle
        editor.setRecipe(recipe)
        editor.editingGeometry(true)
        recipe.geometry.angle = 10
        editor.setRecipe(recipe)
        // Gesture completion and Esc can register in the same AppKit event.
        undo.beginUndoGrouping()
        editor.cancelCrop(restoring: entry)
        undo.endUndoGrouping()
        #expect(!editor.isDragging && editor.recipe.geometry == entry)
        await editor.settle()
        #expect(await fake.requests.count == before)
        undo.undo()
        #expect(editor.recipe.geometry.angle == 10, "Undo Esc restores the state immediately before Esc")
        undo.undo()
        #expect(editor.recipe.geometry.angle == previousAngle, "the drag is a separate step")
        if previousAngle != 0 { undo.undo() }
        #expect(editor.recipe.geometry == entry && !undo.canUndo)
        await editor.close()
    }

    @Test func cancellingCropRestoresEntryInsideAnAbandonedWriteWindow() async throws {
        let fake = FakeEditorRendering()
        let editor = RecipeEditor(renderer: fake)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.attach(undoManager: undo)
        try await editor.open(URL(fileURLWithPath: "/tmp/crop-cancel-abandoned.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        await editor.settle()
        let entry = editor.recipe.geometry
        var recipe = editor.recipe
        recipe.geometry.angle = 5
        editor.setRecipe(recipe)
        editor.editingGeometry(true)
        recipe.geometry.angle = 10
        editor.setRecipe(recipe)
        editor.commitDrag()
        undo.undo()
        #expect(editor.recipe.geometry.angle == 5)
        // The gesture has not sent its end notification; binding restoration
        // would be discarded by the abandoned-write protection here.
        editor.cancelCrop(restoring: entry)
        #expect(editor.recipe.geometry == entry && !editor.isDragging)
        editor.editingGeometry(false)
        undo.undo()
        #expect(editor.recipe.geometry.angle == 5)
        undo.redo()
        #expect(editor.recipe.geometry == entry)
        await editor.close()
    }

    @Test func cancellingAnUnchangedCropAddsNoUndoStep() async throws {
        let fake = FakeEditorRendering()
        let editor = RecipeEditor(renderer: fake)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.attach(undoManager: undo)
        try await editor.open(URL(fileURLWithPath: "/tmp/crop-cancel-unchanged.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        let entry = editor.recipe.geometry
        editor.editingGeometry(true)
        editor.cancelCrop(restoring: entry)
        editor.cancelCrop(restoring: entry)
        #expect(!editor.isDragging && !undo.canUndo)
        #expect(editor.recipe.geometry == entry)
        // No stale suppression remains to swallow the next discrete edit.
        var recipe = editor.recipe
        recipe.geometry.angle = 5
        editor.setRecipe(recipe)
        #expect(editor.recipe.geometry.angle == 5)
        undo.undo()
        #expect(editor.recipe.geometry == entry && !undo.canUndo)
        await editor.close()
    }

}
