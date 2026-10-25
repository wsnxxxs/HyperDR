import Foundation
import CoreGraphics
import HyperDRRecipe
import HyperDRRender
import Testing
@testable import HyperDREditorCore

@MainActor @Suite struct ProgressivePreviewTests {
    @Test func refinementKeepsEditsDragAndUndoAndDefersAI() async throws {
        let fake = FakeEditorRendering()
        await fake.configure { $0.defaultPhoto = .init(domain: .rawEDR, isDraftPreview: true) }
        await fake.holdRefinements()
        let editor = RecipeEditor(renderer: fake)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.attach(undoManager: undo)
        try await editor.open(URL(fileURLWithPath: "/tmp/progressive.arw"))
        while await fake.heldRefinementCount == 0 { await Task.yield() }
        #expect(editor.frame?.isDraftPreview == true)
        #expect(editor.isRefiningPreview && !editor.isOpening)
        #expect(await fake.predictions.isEmpty)

        let exposure = try #require(Adjustments.declaration("tone.exposure"))
        undo.beginUndoGrouping()
        editor.editingChanged(exposure, true)
        var changed = editor.recipe
        changed.setValue(.number(1), for: exposure.id)
        changed.setHDRSource(.capturedAI)
        editor.setRecipe(changed)
        await fake.releaseRefinements()
        // Refine in the middle of a drag; it must leave the drag intact.
        while editor.isRefiningPreview { await Task.yield() }
        #expect(editor.isDragging && editor.recipe == changed)
        #expect(editor.frame?.isDraftPreview == false)
        #expect(await fake.predictions.isEmpty)
        editor.editingChanged(exposure, false)
        undo.endUndoGrouping()
        await editor.settle()
        #expect(editor.frame?.request.recipe == changed)
        #expect(!editor.isRefiningPreview)
        #expect(editor.aiStatus == .ready)
        #expect(await fake.predictions.count == 1)
        undo.undo()
        #expect(editor.recipe != changed)
        await editor.close()
    }

    @Test func aFailedRefinementStaysVisibleAndAnEditRestoresAIAndDetails() async throws {
        let fake = FakeEditorRendering()
        await fake.configure {
            $0.defaultPhoto = .init(domain: .rawEDR, isDraftPreview: true)
            $0.refinementError = .unsupported("Injected refinement failure")
        }
        let editor = RecipeEditor(renderer: fake, detailIdle: .zero)
        try await editor.open(URL(fileURLWithPath: "/tmp/retry.arw"))
        await editor.settle()
        #expect(editor.frame?.isDraftPreview == true)
        #expect(editor.renderFailure != nil && !editor.isRefiningPreview)
        #expect(await fake.refinementCount == 1) // no automatic retry loop
        editor.setViewport(.init(visible: CGRect(x: 0, y: 0, width: 256, height: 256), displayedWidth: 6000))
        await fake.configure { $0.refinementError = nil }
        var changed = editor.recipe
        changed.setHDRSource(.capturedAI)
        editor.setRecipe(changed)
        await editor.settle()
        #expect(await fake.refinementCount == 2)
        #expect(editor.renderFailure == nil && !editor.isRefiningPreview)
        #expect(editor.frame?.isDraftPreview == false && editor.aiStatus == .ready)
        #expect(await fake.requests.contains { $0.region != nil })
        await editor.close()
    }

    @Test func closeCancelsRefinementAndCannotPublishTheOldPhoto() async throws {
        let fake = FakeEditorRendering(includesModel: false)
        await fake.configure { $0.defaultPhoto = .init(domain: .rawEDR, isDraftPreview: true) }
        await fake.holdRefinements()
        let editor = RecipeEditor(renderer: fake)
        try await editor.open(URL(fileURLWithPath: "/tmp/old.arw"))
        while await fake.heldRefinementCount == 0 { await Task.yield() }
        #expect(editor.isRefiningPreview)
        await editor.close()
        await fake.releaseRefinements()
        await editor.settle()
        #expect(!editor.isRefiningPreview)
        #expect(editor.source == nil && editor.frame == nil)
    }
}
