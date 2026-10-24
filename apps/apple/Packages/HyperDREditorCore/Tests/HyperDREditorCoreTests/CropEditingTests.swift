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

}
