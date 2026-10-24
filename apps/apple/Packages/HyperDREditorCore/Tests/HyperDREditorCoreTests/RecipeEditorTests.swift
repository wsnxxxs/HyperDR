import CoreGraphics
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
        editor = RecipeEditor(renderer: fake, frameClock: ImmediateFrameClock(), detailIdle: .zero)
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

    /// Choosing a library LUT writes the look and the spaces the library
    /// records for it at once (`AdjustmentPanel.set(_:reference:in:)`): one
    /// step, named for the LUT, that undoes all three.
    @Test func choosingALUTWithItsSpacesIsOneStep() async throws {
        let h = Harness(undo: true)
        try await h.open(.rawEDR, name: "a.arw")
        h.step {
            var recipe = h.editor.recipe
            recipe.look = LUTReference(contentHash: "sha256:01", name: "Kodak 2383")
            recipe.setValue(.string("p3"), for: "look.input")
            recipe.setValue(.string("hlg"), for: "look.output")
            h.editor.setRecipe(recipe)
        }
        h.step {
            var recipe = h.editor.recipe
            recipe.look = LUTReference(contentHash: "sha256:02", name: "Venice")
            recipe.setValue(.string("slog3-sgamut3"), for: "look.input")
            recipe.setValue(.string("rec709"), for: "look.output")
            h.editor.setRecipe(recipe)
        }
        #expect(h.undoManager.undoActionName == "undo.look.lut")
        h.undoManager.undo()
        #expect(h.editor.recipe.look?.name == "Kodak 2383")
        #expect(h.editor.recipe.value(for: "look.input") == .string("p3"))
        #expect(h.editor.recipe.value(for: "look.output") == .string("hlg"))
        #expect(h.undoManager.undoActionName == "undo.look.lut")
        h.undoManager.undo()
        #expect(h.editor.recipe == Recipe(inputDomain: .rawEDR))
        #expect(!h.undoManager.canUndo)
    }

    @Test func aDiscreteEditEndsAnOpenDragFirst() async throws {
        let h = Harness(undo: true)
        try await h.open()
        let exposure = declaration("tone.exposure")
        // A drag registers nothing until it ends (an empty explicit group
        // would itself count as an undo step here).
        h.editor.editingChanged(exposure, true)
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.5))
        // Reset All while the drag is open: the drag is committed first, and
        // the two are separate steps although one event registers both (R22-002).
        h.step { h.editor.resetAll() }
        #expect(!h.editor.isDragging)
        #expect(h.undoManager.undoActionName == "undo.resetAll")
        h.undoManager.undo()
        #expect(h.editor.recipe.value(for: "tone.exposure") == .number(0.5))
        #expect(h.undoManager.undoActionName == "undo.tone.exposure")
        h.undoManager.undo()
        #expect(h.editor.recipe == Recipe(inputDomain: .sdr))
        // The ruler, still coasting, reports its end later: nothing more happens.
        h.editor.editingChanged(exposure, false)
        #expect(!h.undoManager.canUndo)
    }

    @Test func undoWhileARulerCoasts() async throws {
        let h = Harness(undo: true)
        try await h.open()
        let exposure = declaration("tone.exposure")
        // A drag registers nothing until it ends (an empty explicit group
        // would itself count as an undo step here).
        h.editor.editingChanged(exposure, true)
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.5))
        // The iOS undo button: commit the drag, then undo (an event's group
        // is closed by undo itself; this manager has no event groups).
        h.step { h.editor.commitDrag() }
        h.undoManager.undo()
        #expect(h.editor.recipe == Recipe(inputDomain: .sdr))
        // The coasting ruler's last writes neither overwrite the undo nor add steps.
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.7))
        h.editor.editingChanged(exposure, false)
        #expect(h.editor.recipe == Recipe(inputDomain: .sdr))
        #expect(!h.undoManager.canUndo)
        #expect(h.undoManager.canRedo)
        h.undoManager.redo()
        #expect(h.editor.recipe.value(for: "tone.exposure") == .number(0.5))
    }

    /// R22-004: only the abandoned control's writes are dropped; a switch
    /// thrown while the ruler still coasts is an edit of its own.
    @Test func otherControlsWriteWhileARulerCoasts() async throws {
        let h = Harness(undo: true)
        try await h.open()
        let exposure = declaration("tone.exposure")
        h.editor.editingChanged(exposure, true)
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.5))
        h.step { h.editor.resetAll() }
        h.step {
            var recipe = h.editor.recipe
            recipe.setValue(.bool(false), for: "hdr.enabled")
            h.editor.setRecipe(recipe)
        }
        #expect(h.editor.recipe.value(for: "hdr.enabled") == .bool(false))
        #expect(h.undoManager.undoActionName == "undo.hdr.enabled")
        // A coasting write carrying both keeps the switch, not the exposure.
        var coasting = h.editor.recipe
        coasting.setValue(.number(0.8), for: "tone.exposure")
        h.editor.setRecipe(coasting)
        #expect(h.editor.recipe.isDefault("tone.exposure"))
        h.editor.editingChanged(exposure, false)
        h.undoManager.undo()
        #expect(h.editor.recipe.value(for: "hdr.enabled") != .bool(false))
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

    @Test func aPhotoThatFailsToOpenKeepsThePreviousPhotosUndo() async throws {
        let h = Harness(undo: true)
        try await h.open(.sdr)
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 1)) }
        await h.fake.configure { $0.openError = .noSource }
        await #expect(throws: EditorRenderingError.noSource) { try await h.open(.sdr, name: "b.jpg") }
        #expect(h.undoManager.undoActionName == "undo.tone.exposure")
        h.undoManager.undo()
        #expect(h.editor.recipe.isDefault("tone.exposure"))
    }

    @Test func aPhotoThatOpensDropsThePreviousPhotosUndoAtOnce() async throws {
        let h = Harness(undo: true)
        try await h.open(.sdr)
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 1)) }
        let edited = h.editor.recipe
        // b opens; its first frame has not come yet.
        await h.fake.configure { $0.holdRenders() }
        try await h.editor.open(URL(fileURLWithPath: "/tmp/b.jpg"))
        #expect(!h.undoManager.canUndo)
        // Putting a back keeps nothing of b, and finds no step of a either.
        try await h.editor.open(URL(fileURLWithPath: "/tmp/a.jpg"), restoring: edited)
        #expect(h.editor.recipe == edited)
        #expect(!h.undoManager.canUndo)
        await h.fake.configure { $0.releaseRenders() }
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

    @Test func anInactiveLUTNeedsNoInstall() async throws {
        let h = Harness()
        try await h.open()
        var recipe = h.editor.recipe
        recipe.look = LUTReference(contentHash: "sha256:missing", name: "Missing")
        recipe.setValue(.bool(false), for: "look.enabled")
        h.editor.setRecipe(recipe)
        await h.editor.settle()
        #expect(h.editor.renderFailure == nil)
        #expect(h.editor.frame?.request.recipe.look != nil)
        recipe.setValue(nil, for: "look.enabled")
        recipe.setValue(.number(0), for: "look.strength")
        h.editor.setRecipe(recipe)
        await h.editor.settle()
        #expect(h.editor.renderFailure == nil)
        recipe.setValue(nil, for: "look.strength")
        h.editor.setRecipe(recipe)
        await h.editor.settle()
        #expect(h.editor.renderFailure != nil)
    }

    @Test func bypassedGroupsAreARenderOption() async throws {
        let h = Harness()
        try await h.open()
        h.editor.bypassedGroups = [.light]
        await h.editor.settle()
        #expect(h.editor.frame?.request.bypassedGroups == [.light])
        #expect(h.editor.frame?.request.recipe == Recipe(inputDomain: .sdr))
    }

    @Test func theOriginalKeepsTheSourcesRange() {
        for domain in InputDomain.allCases {
            var recipe = Recipe(inputDomain: domain)
            recipe.setValue(.bool(false), for: "hdr.enabled")
            recipe.setValue(.number(1), for: "tone.exposure")
            #expect(recipe.original.conditionValue("hdr.enabled") == .bool(domain != .sdr))
            #expect(recipe.original.isDefault("tone.exposure"))
            #expect(recipe.original.hdrSource == HDRSource.defaultSource(for: domain))
        }
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

    @Test func aChangedFileAsksToOpenAgain() async throws {
        let h = Harness()
        try await h.open()
        await h.fake.configure { $0.renderError = .sourceChanged }
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.5))
        await h.editor.settle()
        #expect(h.editor.sourceChanged)
        await h.fake.configure { $0.renderError = nil }
        try await h.open(name: "b.jpg")
        #expect(!h.editor.sourceChanged)
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

    /// R22-005: an open whose caller was cancelled before it began does not
    /// supersede the open in progress.
    @Test func aCancelledOpenDoesNotSupersede() async throws {
        let h = Harness()
        let a = URL(fileURLWithPath: "/tmp/old.jpg"), b = URL(fileURLWithPath: "/tmp/new.jpg")
        let current = Task { @MainActor in try await h.editor.open(b) }
        while !h.editor.isOpening { await Task.yield() }
        let stale = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await h.editor.open(a)
        }
        await #expect(throws: CancellationError.self) { try await stale.value }
        try await current.value
        #expect(h.editor.source?.url == b)
        #expect(await h.fake.opened == [b])
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

    /// R22-006: a prediction belongs to one RAW development. A new one
    /// predicts again after its drag, not during it; another preview size
    /// does not.
    @Test func aNewDevelopmentPredictsAgain() async throws {
        let h = Harness()
        try await h.open(.rawEDR, name: "r.dng")
        var recipe = h.editor.recipe
        recipe.setHDRSource(.capturedAI)
        h.editor.setRecipe(recipe)
        await h.editor.settle()
        #expect(h.editor.aiStatus == .ready && !h.editor.isModelGainPending)
        let shot = h.editor.recipe

        let temperature = declaration("develop.temperature")
        h.editor.editingChanged(temperature, true)
        h.editor.setRecipe(setting(h.editor.recipe, "develop.temperature", 5500))
        await h.editor.settle()
        #expect(h.editor.aiStatus == .computing)
        #expect(h.editor.isModelGainPending)
        #expect(await h.fake.predictions.count == 1)
        h.editor.editingChanged(temperature, false)
        await h.editor.settle()
        #expect(await h.fake.predictions.count == 2)
        #expect(h.editor.aiStatus == .ready && !h.editor.isModelGainPending)

        // Another preview size keeps the prediction.
        h.editor.canvasPixelSize = PixelSize(width: 3840, height: 2160)
        await h.editor.settle()
        #expect(await h.fake.predictions.count == 2)
        #expect(!h.editor.isModelGainPending)
        // Back to the first development: Render loads it as a new source, so
        // the frame comes back pending and it is predicted again, once.
        h.editor.setRecipe(shot)
        await h.editor.settle()
        #expect(await h.fake.predictions.count == 3)
        #expect(h.editor.aiStatus == .ready && !h.editor.isModelGainPending)
    }

    /// A whole frame without the gain it asked for (the renderer dropped the
    /// prediction) predicts again, once.
    @Test func aLostPredictionIsMadeAgain() async throws {
        let h = Harness()
        try await h.open()
        chooseAI(h)
        await h.editor.settle()
        await h.fake.forgetPredictions()
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.5))
        await h.editor.settle()
        #expect(await h.fake.predictions.count == 2)
        #expect(!h.editor.isModelGainPending)
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

@MainActor @Suite struct RecipeEditorCanvasLayerTests {
    /// The default fake photo is 6000 × 4000; a viewport at 1:1 on part of it.
    private let zoomed = CanvasViewport(visible: CGRect(x: 1000, y: 1000, width: 1200, height: 800), displayedWidth: 6000)

    @Test func aDetailFollowsTheViewportAndTheRecipe() async throws {
        let h = Harness()
        try await h.open()
        h.editor.setViewport(zoomed)
        await h.editor.settle()
        let detail = try #require(h.editor.shownDetail)
        #expect(detail.request.size == PixelSize(width: 6000, height: 4000))
        #expect(detail.request.region == RecipeEditor.detailRegion(visible: zoomed.visible, source: detail.request.size))
        #expect(detail.request.region!.contains(zoomed.visible))
        #expect(h.editor.shownOriginalDetail == nil)

        // An edit drops the detail with the frame it belonged to; the new one follows the new frame.
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.5))
        await h.editor.settle()
        #expect(h.editor.shownDetail?.request.recipe == h.editor.recipe)

        // Fitted again, the preview has enough pixels.
        let regions = await h.fake.completed.filter { $0.region != nil }.count
        h.editor.setViewport(CanvasViewport(visible: CGRect(x: 0, y: 0, width: 6000, height: 4000), displayedWidth: 1200))
        await h.editor.settle()
        #expect(h.editor.detailFrame == nil)
        #expect(await h.fake.completed.filter { $0.region != nil }.count == regions)
    }

    /// An export gets the memory: the frames stay (the viewer can compare),
    /// details go, nothing renders until it ends, then the details come back.
    @Test func anExportKeepsTheShownFrameAndRendersNothingUntilItEnds() async throws {
        let h = Harness()
        try await h.open()
        h.editor.setViewport(zoomed)
        await h.editor.settle()
        let shown = try #require(h.editor.frame), original = try #require(h.editor.originalFrame)
        #expect(h.editor.shownDetail != nil)
        await h.editor.yieldToExport()
        #expect(await h.fake.yields == 1)
        #expect(h.editor.frame?.request == shown.request && h.editor.originalFrame?.request == original.request)
        #expect(h.editor.detailFrame == nil)
        let before = await h.fake.requests.count
        // A canvas resize and a pan while exporting wait.
        h.editor.canvasPixelSize = PixelSize(width: 3000, height: 2000)
        h.editor.setViewport(CanvasViewport(visible: CGRect(x: 3000, y: 2000, width: 1200, height: 800), displayedWidth: 6000))
        await h.editor.settle()
        #expect(await h.fake.requests.count == before)
        h.editor.resumeAfterExport()
        await h.editor.settle()
        #expect(!h.editor.isYieldingToExport)
        #expect(h.editor.originalFrame?.request.recipe == h.editor.recipe.original)
        let detail = try #require(h.editor.shownDetail)
        #expect(detail.request.region!.contains(CGRect(x: 3000, y: 2000, width: 1200, height: 800)))
    }

    /// The edit an export captured is the one the canvas shows: a render
    /// still pending or running lands before the editor gives anything up.
    @Test func anExportLetsTheCapturedEditLandFirst() async throws {
        let h = Harness()
        try await h.open()
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.7))
        await h.editor.yieldToExport()
        #expect(h.editor.frame?.request.recipe == h.editor.recipe)
        h.editor.resumeAfterExport()
    }

    /// Two exports at once: renders wait for the second to end too.
    @Test func overlappingExportsResumeAfterTheLast() async throws {
        let h = Harness()
        try await h.open()
        await h.editor.yieldToExport()
        await h.editor.yieldToExport()
        let before = await h.fake.requests.count
        h.editor.resumeAfterExport()
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.4))
        await h.editor.settle()
        #expect(h.editor.isYieldingToExport)
        #expect(await h.fake.requests.count == before)
        h.editor.resumeAfterExport()
        await h.editor.settle()
        #expect(!h.editor.isYieldingToExport && h.editor.frame?.request.recipe == h.editor.recipe)
    }

    @Test func anExportKeepsAShownOriginal() async throws {
        let h = Harness()
        try await h.open()
        var both = zoomed
        both.showsOriginal = true
        h.editor.setViewport(both)
        await h.editor.settle()
        let original = try #require(h.editor.originalFrame)
        await h.editor.yieldToExport()
        #expect(h.editor.originalFrame?.request == original.request)
        #expect(h.editor.originalDetailFrame == nil)
        h.editor.resumeAfterExport()
        await h.editor.settle()
        #expect(h.editor.shownOriginalDetail != nil)
    }

    @Test func noDetailWhileDraggingAndTheOriginalOnlyWhenShown() async throws {
        let h = Harness()
        try await h.open()
        let exposure = declaration("tone.exposure")
        h.editor.editingChanged(exposure, true)
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.3))
        h.editor.setViewport(zoomed)
        await h.editor.settle()
        #expect(await h.fake.requests.allSatisfy { $0.region == nil })
        h.editor.editingChanged(exposure, false)
        await h.editor.settle()
        #expect(h.editor.shownDetail != nil)
        #expect(h.editor.shownOriginalDetail == nil)

        var both = zoomed
        both.showsOriginal = true
        h.editor.setViewport(both)
        await h.editor.settle()
        let original = try #require(h.editor.shownOriginalDetail)
        #expect(original.request.recipe == h.editor.recipe.original)
    }

    @Test func onlyAnSDROnlyDragPreviewsSDR() async throws {
        let h = Harness()
        try await h.open()
        h.editor.editingChanged(declaration("tone.exposure"), true)
        await h.editor.settle()
        #expect(!h.editor.previewsAsSDR)
        h.editor.editingChanged(declaration("hdr.sdrRolloff"), true)
        #expect(h.editor.previewsAsSDR)
    }
}

@MainActor @Suite struct RecipeEditorExportTests {
    /// P7-3b-U: the capture is the recipe as edited, not the preview's bypass,
    /// with the model it uses and the LUT its look takes effect with.
    @Test func theCaptureFreezesRecipeModelAndLUT() async throws {
        let h = Harness()
        try await h.open()
        let lut = try ColorLUT(cube: "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8))
        var recipe = h.editor.recipe
        recipe.setHDRSource(.ai)
        recipe.look = LUTReference(contentHash: lut.contentHash, name: "Film")
        h.editor.setRecipe(recipe)
        h.editor.bypassedGroups = [.light]
        #expect(throws: EditorRenderingError.missingLUT(lut.contentHash)) { try h.editor.exportCapture() }
        await h.editor.installLUT(lut)
        await h.editor.settle()
        let capture = try h.editor.exportCapture()
        #expect(capture.recipe == h.editor.recipe)
        // The model is the recipe's own selection, frozen with it; Kit
        // resolves the full identity from it.
        #expect(capture.recipe.hdrSource == .ai)
        #expect(capture.recipe.conditionValue("hdr.model") == h.editor.recipe.conditionValue("hdr.model"))
        #expect(capture.recipe.conditionValue("hdr.model")?.stringValue == "research-cnn-v1")
        #expect(capture.lut == lut)
        #expect(capture.peakStops == capture.automaticValues["hdr.range"] ?? 3)
    }
}

extension RecipeEditorAITests {
    @Test(arguments: ["hdr-off", "source", "bypass"])
    func noModelNeededCancelsThePredictionAndClearsComputing(stop: String) async throws {
        let h = Harness()
        try await h.open()
        await h.fake.holdPredictions()
        chooseAI(h)
        while await h.fake.heldPredictionCount == 0 { await Task.yield() }
        var recipe = h.editor.recipe
        switch stop {
        case "hdr-off": recipe.setValue(.bool(false), for: "hdr.enabled"); h.editor.setRecipe(recipe)
        case "source": recipe.setHDRSource(.expand); h.editor.setRecipe(recipe)
        default: h.editor.bypassedGroups = [.hdr]
        }
        #expect(h.editor.aiStatus == .idle)
        while await h.fake.heldPredictionCount != 0 { await Task.yield() }
        await h.editor.settle()
        #expect(h.editor.aiStatus == .idle)
        h.editor.bypassedGroups = []
        recipe = h.editor.recipe
        recipe.setHDRSource(.ai)
        recipe.setValue(.bool(true), for: "hdr.enabled")
        h.editor.setRecipe(recipe)
        #expect(h.editor.aiStatus == .computing)
        await h.fake.releasePredictions()
        await h.editor.settle()
        #expect(h.editor.aiStatus == .ready)
        #expect(await h.fake.predictions.count == 2)
    }

    @Test func rawDragCancelsTheObsoletePredictionAndHDRCanStayOff() async throws {
        let h = Harness()
        try await h.open(.rawEDR, name: "drag.dng")
        await h.fake.holdPredictions()
        var recipe = h.editor.recipe
        recipe.setHDRSource(.capturedAI)
        h.editor.setRecipe(recipe)
        while await h.fake.heldPredictionCount == 0 { await Task.yield() }
        let temperature = declaration("develop.temperature")
        h.editor.editingChanged(temperature, true)
        h.editor.setRecipe(setting(h.editor.recipe, "develop.temperature", 5500))
        while await h.fake.heldPredictionCount != 0 { await Task.yield() }
        #expect(h.editor.aiStatus == .computing)
        #expect(await h.fake.predictions.count == 1)
        recipe = h.editor.recipe
        recipe.setValue(.bool(false), for: "hdr.enabled")
        h.editor.setRecipe(recipe)
        #expect(h.editor.aiStatus == .idle)
        h.editor.editingChanged(temperature, false)
        await h.editor.settle()
        #expect(h.editor.aiStatus == .idle)
        #expect(await h.fake.predictions.count == 1)
        recipe.setValue(.bool(true), for: "hdr.enabled")
        h.editor.setRecipe(recipe)
        #expect(h.editor.aiStatus == .computing)
        await h.fake.releasePredictions()
        await h.editor.settle()
        #expect(h.editor.aiStatus == .ready)
    }

    @Test func undoRedoOfHDRRestoresTheAppropriateAIState() async throws {
        let h = Harness(undo: true)
        try await h.open()
        await h.fake.holdPredictions()
        h.step { chooseAI(h) }
        while await h.fake.heldPredictionCount == 0 { await Task.yield() }
        h.step {
            var recipe = h.editor.recipe
            recipe.setValue(.bool(false), for: "hdr.enabled")
            h.editor.setRecipe(recipe)
        }
        #expect(h.editor.aiStatus == .idle)
        h.undoManager.undo()
        #expect(h.editor.aiStatus == .computing)
        await h.fake.releasePredictions()
        await h.editor.settle()
        #expect(h.editor.aiStatus == .ready)
        h.undoManager.redo()
        #expect(h.editor.aiStatus == .idle)
        h.undoManager.undo()
        await h.editor.settle()
        #expect(h.editor.aiStatus == .ready)
    }

    @Test func failedAndCancelledPredictionsDoNotLeaveAComputingState() async throws {
        let h = Harness()
        try await h.open()
        await h.fake.configure { $0.modelBehavior = .fail("test failure") }
        chooseAI(h)
        await h.editor.settle()
        #expect(h.editor.aiStatus == .failed("test failure"))
        var recipe = h.editor.recipe
        recipe.setValue(.bool(false), for: "hdr.enabled")
        h.editor.setRecipe(recipe)
        #expect(h.editor.aiStatus == .idle)
        recipe.setValue(.bool(true), for: "hdr.enabled")
        h.editor.setRecipe(recipe)
        #expect(h.editor.aiStatus == .failed("test failure"))
        await h.fake.configure { $0.modelBehavior = .cancel }
        h.editor.retryModelGain()
        await h.editor.settle()
        #expect(h.editor.aiStatus == .idle)
        await h.fake.configure { $0.modelBehavior = .succeed }
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 0.25))
        await h.editor.settle()
        #expect(h.editor.aiStatus == .ready)
    }

    @Test(arguments: [false, true])
    func pendingPredictionCannotUpdateAnotherPhotoOrAClosedEditor(close: Bool) async throws {
        let h = Harness()
        try await h.open()
        await h.fake.holdPredictions()
        chooseAI(h)
        while await h.fake.heldPredictionCount == 0 { await Task.yield() }
        if close { await h.editor.close() } else { try await h.open(name: "next.jpg") }
        await h.fake.releasePredictions()
        await h.editor.settle()
        #expect(h.editor.aiStatus == .idle)
        if close { #expect(h.editor.source == nil) }
        else { #expect(h.editor.source?.url.lastPathComponent == "next.jpg") }
    }

    @Test func aFailedPhotoOpenRestartsOnlyThePreviousPhotosNeededPrediction() async throws {
        let h = Harness()
        try await h.open()
        await h.fake.holdPredictions()
        chooseAI(h)
        while await h.fake.heldPredictionCount == 0 { await Task.yield() }
        await h.fake.holdOpens()
        await h.fake.configure { $0.openError = .unsupported("test open failure") }
        let opening = Task { try await h.editor.open(URL(fileURLWithPath: "/tmp/unreadable.jpg")) }
        while await h.fake.heldOpenCount == 0 { await Task.yield() }
        #expect(h.editor.aiStatus == .idle)
        await h.fake.releaseOpens()
        _ = await opening.result
        #expect(h.editor.source?.url.lastPathComponent == "a.jpg")
        #expect(h.editor.aiStatus == .computing)
        await h.fake.releasePredictions()
        await h.editor.settle()
        #expect(h.editor.aiStatus == .ready)
    }

    @Test func unavailableRemainsUnavailableWhenHDRIsDisabledOrEditorCloses() async throws {
        let h = Harness()
        try await h.open()
        await h.fake.configure { $0.modelBehavior = .unavailable("unsupported device") }
        chooseAI(h)
        await h.editor.settle()
        var recipe = h.editor.recipe
        recipe.setValue(.bool(false), for: "hdr.enabled")
        h.editor.setRecipe(recipe)
        #expect(h.editor.aiStatus == .unavailable("unsupported device"))
        await h.editor.close()
        #expect(h.editor.aiStatus == .unavailable("unsupported device"))
    }
}

@MainActor @Suite struct RecipeEditorOpeningTests {
    private func preview(width: Int = 8) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: 4,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func embeddedPlaceholderPrecedesTheFirstFrameAndClearsWhenItArrives() async throws {
        let h = Harness()
        let image = try preview()
        await h.fake.configure { $0.embeddedPreview = image }
        await h.fake.holdOpens()
        await h.fake.holdRenders()
        let opening = Task { try await h.editor.open(URL(fileURLWithPath: "/tmp/placeholder.dng")) }
        while await h.fake.heldOpenCount == 0 { await Task.yield() }
        #expect(h.editor.isOpening)
        #expect(h.editor.openingPhase == .reading)
        #expect(h.editor.placeholder?.width == image.width)
        #expect(h.editor.placeholderURL?.lastPathComponent == "placeholder.dng")
        #expect(h.editor.placeholderID != nil)
        #expect(h.editor.placeholderPixelSize == PixelSize(width: 6000, height: 4000))
        #expect(h.editor.frame == nil)
        await h.fake.releaseOpens()
        try await opening.value
        #expect(!h.editor.isOpening)
        #expect(h.editor.openingPhase == .rendering)
        #expect(h.editor.placeholder != nil)
        await h.fake.releaseRenders()
        await h.editor.settle()
        #expect(h.editor.frame != nil)
        #expect(h.editor.openingPhase == nil)
        #expect(h.editor.placeholder == nil)
    }

    @Test func aFailedFirstFrameKeepsTheOldFrameSourceAndAnError() async throws {
        let h = Harness()
        try await h.open(name: "old.jpg")
        let old = try #require(h.editor.frameSource)
        let image = try preview()
        await h.fake.configure { $0.embeddedPreview = image; $0.renderError = .unsupported("preview failed") }
        try await h.editor.open(URL(fileURLWithPath: "/tmp/new.jpg"))
        await h.editor.settle()
        #expect(h.editor.source?.url.lastPathComponent == "new.jpg")
        #expect(h.editor.frameSource?.id == old.id)
        #expect(h.editor.frame?.request.sourceID == old.id)
        #expect(h.editor.renderFailure != nil)
        #expect(h.editor.openingPhase == nil)
        #expect(h.editor.placeholder == nil)
    }

    @Test(arguments: [false, true])
    func aFailedOrCancelledOpenClearsItsPlaceholder(cancel: Bool) async throws {
        let h = Harness()
        let image = try preview()
        await h.fake.configure { $0.embeddedPreview = image; $0.openError = .unsupported("test") }
        await h.fake.holdOpens()
        let opening = Task { try await h.editor.open(URL(fileURLWithPath: "/tmp/failure.dng")) }
        while await h.fake.heldOpenCount == 0 { await Task.yield() }
        #expect(h.editor.placeholder != nil)
        if cancel { opening.cancel() } else { await h.fake.releaseOpens() }
        _ = await opening.result
        #expect(!h.editor.isOpening)
        #expect(h.editor.openingPhase == nil)
        #expect(h.editor.placeholder == nil)
    }

    @Test func aNewerOpenOwnsThePlaceholderAndCloseClearsIt() async throws {
        let h = Harness()
        let firstImage = try preview(), secondImage = try preview(width: 12)
        await h.fake.configure { $0.embeddedPreview = firstImage }
        await h.fake.holdOpens()
        await h.fake.holdRenders()
        let first = Task { try await h.editor.open(URL(fileURLWithPath: "/tmp/first.dng")) }
        while await h.fake.heldOpenCount == 0 { await Task.yield() }
        await h.fake.configure { $0.embeddedPreview = secondImage }
        let second = Task { try await h.editor.open(URL(fileURLWithPath: "/tmp/second.dng")) }
        _ = await first.result
        while await h.fake.opened.count < 2 { await Task.yield() }
        #expect(h.editor.placeholder?.width == secondImage.width)
        await h.fake.releaseOpens()
        try await second.value
        #expect(h.editor.openingPhase == .rendering)
        await h.editor.close()
        await h.fake.releaseRenders()
        await h.editor.settle()
        #expect(h.editor.openingPhase == nil)
        #expect(h.editor.placeholder == nil)
    }
}

@MainActor @Suite struct RecipeEditorOriginalFailureTests {
    @Test func failedOriginalDevelopmentCannotShowOldPixelsAndCanRetry() async throws {
        let h = Harness()
        try await h.open(.rawEDR, name: "original.dng")
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 1))
        await h.editor.settle()
        await h.fake.configure { fake in
            fake.renderErrorForRequest = { request in
                request.recipe.isDefault("tone.exposure") ? .unsupported("original failed") : nil
            }
        }
        h.editor.setRecipe(setting(h.editor.recipe, "develop.temperature", 4500))
        // Invalidated synchronously, before the replacement can fail.
        #expect(h.editor.originalFrame == nil)
        #expect(h.editor.shownOriginalDetail == nil)
        await h.editor.settle()
        #expect(h.editor.originalFrame == nil)
        #expect(h.editor.originalFailure != nil)
        #expect(h.editor.renderFailure == nil)
        #expect(h.editor.frame?.request.recipe == h.editor.recipe)
        let failedCount = await h.fake.requests.count
        h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 2))
        await h.editor.settle()
        #expect(await h.fake.requests.count == failedCount + 1)
        #expect(h.editor.originalFailure != nil)
        await h.fake.configure { $0.renderErrorForRequest = nil }
        let recipe = h.editor.recipe
        h.editor.retryRendering()
        await h.editor.settle()
        #expect(h.editor.originalFailure == nil)
        #expect(h.editor.originalFrame?.request.recipe == recipe.original)
        #expect(h.editor.recipe == recipe)
    }

    @Test func draggingInvalidatesOriginalBeforeFinalRenderAndUndoRedoFollowDevelopment() async throws {
        let h = Harness(undo: true)
        try await h.open(.rawEDR, name: "drag-original.dng")
        let temperature = declaration("develop.temperature")
        h.step {
            h.editor.editingChanged(temperature, true)
            h.editor.setRecipe(setting(h.editor.recipe, temperature.id, 4500))
            #expect(h.editor.originalFrame == nil)
            h.editor.editingChanged(temperature, false)
        }
        await h.editor.settle()
        #expect(h.editor.originalFrame?.request.recipe == h.editor.recipe.original)
        h.undoManager.undo()
        #expect(h.editor.originalFrame == nil)
        await h.editor.settle()
        #expect(h.editor.originalFrame?.request.recipe == h.editor.recipe.original)
        h.undoManager.redo()
        #expect(h.editor.originalFrame == nil)
        await h.editor.settle()
        #expect(h.editor.originalFrame?.request.recipe == h.editor.recipe.original)
    }

    @Test func newerDevelopmentAutomaticallyRetriesAndCloseClearsFailure() async throws {
        let h = Harness()
        await h.fake.configure { $0.renderError = .unsupported("temporary") }
        try await h.open(.rawEDR)
        #expect(h.editor.originalFailure != nil)
        await h.fake.configure { $0.renderError = nil }
        h.editor.setRecipe(setting(h.editor.recipe, "develop.temperature", 4700))
        #expect(h.editor.originalFailure == nil)
        await h.editor.settle()
        #expect(h.editor.originalFrame?.request.recipe == h.editor.recipe.original)
        await h.fake.configure { $0.renderError = .unsupported("temporary") }
        h.editor.setRecipe(setting(h.editor.recipe, "develop.temperature", 4800))
        await h.editor.settle()
        #expect(h.editor.originalFailure != nil)
        await h.editor.close()
        #expect(h.editor.originalFailure == nil)
        #expect(h.editor.originalFrame == nil)
    }

    @Test func cancelledOriginalCannotPublishOverNewerDevelopment() async throws {
        let h = Harness()
        try await h.open(.rawEDR)
        await h.fake.holdRenders()
        h.editor.setRecipe(setting(h.editor.recipe, "develop.temperature", 4500))
        while await h.fake.heldRenderCount < 2 { await Task.yield() }
        h.editor.setRecipe(setting(h.editor.recipe, "develop.temperature", 4900))
        #expect(h.editor.originalFrame == nil)
        await h.fake.releaseRenders()
        await h.editor.settle()
        #expect(h.editor.originalFrame?.request.recipe == h.editor.recipe.original)
        #expect(h.editor.originalFailure == nil)
        #expect(await h.fake.cancelled.contains { $0.recipe.value(for: "develop.temperature") == .number(4500) })
    }

    @Test func retryEditedPreviewKeepsLastFrameUntilSuccessWithoutUndoStep() async throws {
        let h = Harness(undo: true)
        try await h.open()
        let old = h.editor.frame?.request
        await h.fake.configure { $0.renderError = .unsupported("edited failed") }
        h.step { h.editor.setRecipe(setting(h.editor.recipe, "tone.exposure", 1)) }
        await h.editor.settle()
        #expect(h.editor.renderFailure != nil)
        #expect(h.editor.frame?.request == old)
        let recipe = h.editor.recipe
        await h.fake.configure { $0.renderError = nil }
        h.editor.retryRendering()
        #expect(h.editor.renderFailure != nil)
        await h.editor.settle()
        #expect(h.editor.renderFailure == nil)
        #expect(h.editor.frame?.request.recipe == recipe)
        h.undoManager.undo()
        #expect(h.editor.recipe.isDefault("tone.exposure"))
        await h.editor.settle()
    }
}
