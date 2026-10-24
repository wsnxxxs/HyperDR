import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender
import Testing
@testable import HyperDREditorCore

@MainActor @Suite struct UprightEditorTests {
    @Test func uprightIsOneUndoStepCachesLinesAndNeverAppliesAStaleAnalysis() async throws {
        let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 800, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        context.translateBy(x: 0, y: 600)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(3)
        for x in stride(from: 160, through: 640, by: 80) {
            context.move(to: CGPoint(x: x - 20, y: 80))
            context.addLine(to: CGPoint(x: x + 20, y: 520))
            context.strokePath()
        }
        let image = try #require(context.makeImage())
        let fake = FakeEditorRendering()
        await fake.configure { $0.thumbnailImage = image; $0.defaultPhoto.size = PixelSize(width: 800, height: 600) }
        let editor = RecipeEditor(renderer: fake)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.attach(undoManager: undo)
        try await editor.open(URL(fileURLWithPath: "/tmp/upright-test.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        editor.autoUpright(.level)
        #expect(editor.uprightStatus == .analyzing(.level))
        await editor.settle()
        #expect(editor.uprightStatus == .idle)
        #expect(abs(editor.recipe.geometry.angle + 5.19) < 0.3)
        let analyses = await fake.requests.filter(\.keepsSource)
        #expect(analyses.count == 1 && analyses[0].recipe.geometry == .identity)
        #expect(undo.canUndo)
        undo.undo()
        #expect(editor.recipe.geometry == .identity && !undo.canUndo)
        editor.autoUpright(.auto)
        await editor.settle()
        #expect(await fake.requests.filter(\.keepsSource).count == 1, "mode switches reuse source lines")
        editor.autoUpright(.full)
        await editor.settle()
        #expect(editor.uprightStatus == .noLines)
        editor.isEditingCrop = false
        #expect(editor.uprightStatus == .idle)
        // Force a new source so no cached lines can skip the held render.
        try await editor.open(URL(fileURLWithPath: "/tmp/upright-next.jpg"))
        await editor.settle()
        editor.isEditingCrop = true
        await fake.holdRenders()
        editor.autoUpright(.level)
        while await fake.heldRenderCount == 0 { await Task.yield() }
        editor.autoUpright(.vertical) // Supersedes the first request.
        editor.apply(.geometry) { $0.geometry.angle = 3 }
        await fake.releaseRenders()
        await editor.settle()
        #expect(editor.recipe.geometry.angle == 3 && editor.uprightStatus == .idle)
        await fake.configure { $0.renderError = .unsupported("upright_test") }
        editor.autoUpright(.auto)
        await editor.settle()
        #expect(editor.uprightStatus == .failed)
        await fake.configure { $0.renderError = nil }
        editor.autoUpright(.level)
        await editor.close()
        #expect(editor.recipe.geometry == .identity && editor.uprightStatus == .idle && editor.uprightLines == nil)
    }
}
