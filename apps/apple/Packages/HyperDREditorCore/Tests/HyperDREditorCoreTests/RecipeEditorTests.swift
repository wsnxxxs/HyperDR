import Foundation
import HyperDRRecipe
import HyperDRRender
import Testing
@testable import HyperDREditorCore

/// Renders as soon as the main actor yields, so a burst of synchronous edits
/// lands in one frame.
@MainActor private final class ImmediateFrameClock: EditorFrameClock {
    func nextFrame() async throws { await Task.yield() }
}

@MainActor private struct Harness {
    let fake = FakeEditorRendering()
    let undoManager = UndoManager()
    let editor: RecipeEditor

    /// Undo steps go to `undoManager` only with `undo`; without it, writes
    /// need no undo grouping.
    init(undo: Bool = false) {
        editor = RecipeEditor(renderer: fake, frameClock: ImmediateFrameClock())
        undoManager.groupsByEvent = false
        if undo { editor.attach(undoManager: undoManager) }
    }

    func open(_ domain: InputDomain = .sdr, name: String = "a.jpg") async throws {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        await fake.configure { $0.photos[url] = .init(domain: domain) }
        try await editor.open(url)
        await editor.settle()
    }

    /// Undo and redo outside an event group need explicit grouping.
    func step(_ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }
}

private func declaration(_ id: String) -> ParameterDeclaration { Adjustments.declaration(id)! }

private func setting(_ recipe: Recipe, _ id: String, _ value: Double) -> Recipe {
    var recipe = recipe
    recipe.setValue(.number(value), for: id)
    return recipe
}

@MainActor @Suite struct RecipeEditorUndoTests {
    @Test func oneDragIsOneStep() async throws {
        let h = Harness(undo: true)
        try await h.open()
        let exposure = declaration("tone.exposure")
        h.step {
            h.editor.editingChanged(exposure, true)
            for value in stride(from: 0.1, through: 1.0, by: 0.1) {
                h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", value))
            }
            h.editor.editingChanged(exposure, false)
        }
        #expect(h.undoManager.canUndo)
        #expect(h.undoManager.undoActionName == "undo.tone.exposure")
        h.undoManager.undo()
        #expect(h.editor.recipe.isDefault("tone.exposure"))
        #expect(!h.undoManager.canUndo)
        h.undoManager.redo()
        #expect(h.editor.recipe.value(for: "tone.exposure") == .number(1.0))
    }

    @Test func eachDiscreteWriteIsOneStep() async throws {
        let h = Harness(undo: true)
        try await h.open()
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "tone.contrast", 20)) }
        h.step {
            var recipe = h.editor.recipe
            recipe.setValue(.bool(false), for: "hdr.enabled")
            h.editor.setRecipe(recipe)
        }
        #expect(h.undoManager.undoActionName == "undo.hdr.enabled")
        h.undoManager.undo()
        #expect(h.editor.recipe.isDefault("hdr.enabled"))
        #expect(h.undoManager.undoActionName == "undo.tone.contrast")
        h.undoManager.undo()
        #expect(h.editor.recipe == Recipe(inputDomain: .sdr))
    }

    @Test func aDiscreteEditEndsAnOpenDragFirst() async throws {
        let h = Harness(undo: true)
        try await h.open()
        h.step {
            h.editor.editingChanged(declaration("tone.exposure"), true)
            h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.5))
        }
        // The drag is committed before Reset All registers; both land in the
        // event's undo group, as a click during a drag would.
        h.step { h.editor.resetAll() }
        #expect(!h.editor.isDragging)
        #expect(h.undoManager.undoActionName == "undo.resetAll")
        h.undoManager.undo()
        #expect(h.editor.recipe == Recipe(inputDomain: .sdr))
        h.undoManager.redo()
        #expect(h.editor.recipe == Recipe(inputDomain: .sdr))
        #expect(h.undoManager.canUndo)
    }

    @Test func resetNames() async throws {
        let h = Harness(undo: true)
        try await h.open()
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 1)) }
        h.step { h.editor.resetGroup(.light) }
        #expect(h.undoManager.undoActionName == "undo.resetGroup %@")
        h.undoManager.undo()
        #expect(h.editor.recipe.value(for: "tone.exposure") == .number(1))

        // Through the binding, as the controls write: two changes in one group
        // read as the group's reset, one change as that control's.
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "tone.shadows", 30)) }
        h.step { h.editor.setRecipe(h.editor.recipe.resetting(.light)) }
        #expect(h.undoManager.undoActionName == "undo.resetGroup %@")
        h.undoManager.undo()
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "color.vibrance", 10)) }
        h.step { h.editor.setRecipe(h.editor.recipe.resettingAll()) }
        #expect(h.undoManager.undoActionName == "undo.resetAll")
        #expect(RecipeEdit.classify(from: setting(Recipe(), "tone.exposure", 1), to: Recipe()) == .parameter("tone.exposure"))
    }

    @Test func viewStateAndBypassAreNotUndone() async throws {
        let h = Harness(undo: true)
        try await h.open()
        h.editor.bypassedGroups = [.light]
        h.editor.canvasPixelSize = PixelSize(width: 1000, height: 800)
        #expect(!h.undoManager.canUndo)
        #expect(h.editor.recipe == Recipe(inputDomain: .sdr))
    }

    @Test func aNewPhotoClearsUndoAndStartsFromItsDomain() async throws {
        let h = Harness(undo: true)
        try await h.open(.sdr)
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 1)) }
        h.editor.bypassedGroups = [.hdr]
        try await h.open(.rawEDR, name: "b.dng")
        #expect(!h.undoManager.canUndo)
        #expect(h.editor.recipe == Recipe(inputDomain: .rawEDR))
        #expect(h.editor.bypassedGroups.isEmpty)
        #expect(h.editor.source?.domain == .rawEDR)
    }

    @Test func actionNamesComeFromTheHost() async throws {
        let h = Harness(undo: true)
        h.editor.undo.actionName = { edit in edit == .resetAll ? "Reset All" : "other" }
        try await h.open()
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 1)) }
        h.step { h.editor.resetAll() }
        #expect(h.undoManager.undoActionName == "Reset All")
    }
}

@MainActor @Suite struct RecipeEditorRenderTests {
    @Test func aBurstOfEditsRendersOnce() async throws {
        let h = Harness()
        try await h.open()
        let before = await h.fake.requests.count
        for value in [10.0, 20, 30] { h.editor.setRecipe(setting(h.editor.recipe, "tone.contrast", value)) }
        await h.editor.settle()
        let requests = await h.fake.requests.dropFirst(before)
        let edited = requests.filter { $0.recipe.value(for: "tone.contrast") != nil }
        #expect(edited.count == 1)
        #expect(edited.first?.recipe.value(for: "tone.contrast") == .number(30))
        #expect(h.editor.frame?.request.recipe == h.editor.recipe)
    }

    @Test func aNewRequestCancelsTheOneInFlight() async throws {
        let h = Harness()
        try await h.open()
        await h.fake.holdRenders()
        h.editor.setRecipe(setting(h.editor.recipe, "tone.contrast", 10))
        while await h.fake.heldRenderCount == 0 { await Task.yield() }
        h.editor.setRecipe(setting(h.editor.recipe, "tone.contrast", 20))
        while await h.fake.cancelled.isEmpty { await Task.yield() }
        await h.fake.releaseRenders()
        await h.editor.settle()
        #expect(await h.fake.cancelled.map { $0.recipe.value(for: "tone.contrast") } == [.number(10)])
        #expect(h.editor.frame?.request.recipe.value(for: "tone.contrast") == .number(20))
    }

    @Test func aDragFrameInFlightLandsAndTheNewestFollows() async throws {
        let h = Harness()
        try await h.open()
        let exposure = declaration("tone.exposure")
        let before = await h.fake.completed.count
        await h.fake.holdRenders()
        h.editor.editingChanged(exposure, true)
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.1))
        while await h.fake.heldRenderCount == 0 { await Task.yield() }
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.2))
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.3))
        for _ in 0..<10 { await Task.yield() }
        #expect(await h.fake.cancelled.isEmpty)
        await h.fake.releaseRenders()
        await h.editor.settle()
        let drag = await h.fake.completed.dropFirst(before)
        #expect(drag.compactMap { $0.recipe.value(for: "tone.exposure")?.numberValue } == [0.1, 0.3])
        #expect(drag.allSatisfy { $0.isInteractive })
        h.editor.editingChanged(exposure, false)
        await h.editor.settle()
        #expect(h.editor.frame?.request.isInteractive == false)
    }

    @Test func bypassedGroupsAreARenderOption() async throws {
        let h = Harness()
        try await h.open()
        h.editor.bypassedGroups = [.light]
        await h.editor.settle()
        #expect(h.editor.frame?.request.bypassedGroups == [.light])
        #expect(h.editor.frame?.request.recipe == Recipe(inputDomain: .sdr))
    }

    @Test func theOriginalFollowsDevelopmentOnly() async throws {
        let h = Harness()
        try await h.open(.rawEDR, name: "c.dng")
        let first = await h.fake.completed.filter { $0.recipe == Recipe(inputDomain: .rawEDR) }.count
        #expect(h.editor.originalFrame != nil)
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 1))
        await h.editor.settle()
        #expect(await h.fake.completed.filter { $0.recipe.isDefault("tone.exposure") }.count == first)
        h.editor.setRecipe(setting(h.editor.recipe, "develop.sharpness", 40))
        await h.editor.settle()
        #expect(h.editor.originalFrame?.request.recipe == setting(Recipe(inputDomain: .rawEDR), "develop.sharpness", 40))
    }

    @Test func previewSizeFollowsRenderTiersAndDoesNotShrink() async throws {
        let source = PixelSize(width: 6000, height: 4000)
        #expect(RecipeEditor.previewSize(source: source, canvasSide: 1100) == PixelSize(width: 1280, height: 853))
        #expect(RecipeEditor.previewSize(source: PixelSize(width: 800, height: 600), canvasSide: 4000)
                == PixelSize(width: 800, height: 600))
        #expect(RecipeEditor.previewSize(source: nil, canvasSide: 2100) == PixelSize(width: 2560, height: 2560))

        let h = Harness()
        try await h.open()
        h.editor.canvasPixelSize = PixelSize(width: 2100, height: 1400)
        #expect(h.editor.previewSize == PixelSize(width: 2560, height: 1707))
        h.editor.canvasPixelSize = PixelSize(width: 900, height: 600)
        #expect(h.editor.previewSize == PixelSize(width: 2560, height: 1707))
    }

    @Test func aNewerOpenSupersedesAnOlderOne() async throws {
        let h = Harness()
        let a = URL(fileURLWithPath: "/tmp/one.jpg"), b = URL(fileURLWithPath: "/tmp/two.dng")
        await h.fake.configure { $0.photos[b] = .init(domain: .rawEDR) }
        async let first: Void = h.editor.open(a)
        async let second: Void = h.editor.open(b)
        let results = await [(try? first) != nil, (try? second) != nil]
        #expect(results.contains(true))
        #expect(h.editor.source?.url == (results[1] ? b : a))
        // The renderer holds the photo the editor shows.
        #expect(await h.fake.opened.last == h.editor.source?.url)
    }
}

@MainActor @Suite struct RecipeEditorAITests {
    private func chooseAI(_ h: Harness) {
        var recipe = h.editor.recipe
        recipe.setHDRSource(.ai)
        h.editor.setRecipe(recipe)
    }

    @Test func renderingWithoutAIUntilThePredictionIsReady() async throws {
        let h = Harness()
        try await h.open()
        await h.fake.holdPredictions()
        chooseAI(h)
        #expect(h.editor.aiStatus == .computing)
        while await h.fake.heldPredictionCount == 0 { await Task.yield() }
        // Editing goes on meanwhile, and the frames are without AI.
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.5))
        while h.editor.frame?.request.recipe.value(for: "tone.exposure") == nil { await Task.yield() }
        #expect(h.editor.frame?.request.usesModelGain == false)
        #expect(h.editor.isModelGainPending)
        await h.fake.releasePredictions()
        await h.editor.settle()
        #expect(h.editor.aiStatus == .ready)
        #expect(h.editor.frame?.request.usesModelGain == true)
        #expect(!h.editor.isModelGainPending)
        #expect(await h.fake.predictions == ["research-cnn-v1"])
        // Back to expansion and to AI again: the prediction is kept.
        var recipe = h.editor.recipe
        recipe.setHDRSource(.expand)
        h.editor.setRecipe(recipe)
        chooseAI(h)
        await h.editor.settle()
        #expect(await h.fake.predictions.count == 1)
    }

    @Test func aFailedPredictionKeepsTheChoice() async throws {
        let h = Harness()
        try await h.open()
        await h.fake.configure { $0.modelBehavior = .fail("out of memory") }
        chooseAI(h)
        await h.editor.settle()
        #expect(h.editor.aiStatus == .failed("out of memory"))
        #expect(h.editor.recipe.hdrSource == .ai)
        #expect(h.editor.unavailableOptions.isEmpty)
        #expect(h.editor.frame?.request.usesModelGain == false)
    }

    @Test func anUnavailableModelDisablesTheAIOptions() async throws {
        let h = Harness()
        try await h.open()
        await h.fake.configure { $0.modelBehavior = .unavailable("no Neural Engine") }
        chooseAI(h)
        await h.editor.settle()
        #expect(h.editor.aiStatus == .unavailable("no Neural Engine"))
        #expect(h.editor.unavailableOptions == ["hdr.source": ["ai", "capturedAI"]])
        try await h.open(.rawEDR, name: "d.dng")
        #expect(h.editor.unavailableOptions["hdr.source"] != nil)
    }

    @Test func aNewPhotoForgetsThePrediction() async throws {
        let h = Harness()
        try await h.open()
        chooseAI(h)
        await h.editor.settle()
        try await h.open(.sdr, name: "e.jpg")
        #expect(h.editor.aiStatus == .idle)
        chooseAI(h)
        await h.editor.settle()
        #expect(await h.fake.predictions.count == 2)
    }
}
