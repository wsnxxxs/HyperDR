import Foundation
import HyperDRRecipe
import HyperDRRender
import Testing
@testable import HyperDREditorCore

@MainActor private final class ImmediateClock: EditorFrameClock {
    func nextFrame() async throws { await Task.yield() }
}

@MainActor private func openEditor(_ domain: InputDomain = .sdr, undo: UndoManager? = nil) async throws
    -> (RecipeEditor, FakeEditorRendering) {
    let fake = FakeEditorRendering()
    let editor = RecipeEditor(renderer: fake, frameClock: ImmediateClock(), detailIdle: .zero)
    if let undo {
        undo.groupsByEvent = false
        editor.attach(undoManager: undo)
    }
    let url = URL(fileURLWithPath: "/tmp/look-\(UUID().uuidString).jpg")
    await fake.configure { $0.photos[url] = .init(domain: domain) }
    try await editor.open(url)
    await editor.settle()
    return (editor, fake)
}

private let film = LUTReference(contentHash: "sha256:01", name: "Film")
private let venice = LUTReference(contentHash: "sha256:02", name: "Venice")

@MainActor @Suite struct LookSpacesTests {
    @Test func choosingTakesTheLibrarySpacesAndDroppingIsOneStep() async throws {
        let undo = UndoManager()
        let (editor, _) = try await openEditor(.rawEDR, undo: undo)
        undo.beginUndoGrouping()
        editor.chooseLook(film, input: "slog3-sgamut3cine", output: "rec709")
        undo.endUndoGrouping()
        #expect(editor.recipe.look == film)
        #expect(editor.recipe.conditionValue("look.input")?.stringValue == "slog3-sgamut3cine")
        #expect(editor.recipe.conditionValue("look.output")?.stringValue == "rec709")

        editor.dropLook(venice.contentHash)
        #expect(editor.recipe.look == film, "another LUT's removal leaves the look")
        undo.beginUndoGrouping()
        editor.dropLook(film.contentHash)
        undo.endUndoGrouping()
        #expect(editor.recipe.look == nil)
        undo.undo()
        #expect(editor.recipe.look == film)
    }

    @Test func aLogInputOutsideRAWStaysAtItsDefault() async throws {
        let (editor, _) = try await openEditor(.sdr)
        editor.chooseLook(film, input: "vlog-vgamut", output: "rec709")
        #expect(editor.recipe.conditionValue("look.input")?.stringValue == "srgb")
        #expect(editor.recipe.conditionValue("look.output")?.stringValue == "rec709")
    }

    @Test func libraryChangesReachOnlyTheLookOnThatLUT() async throws {
        let (editor, _) = try await openEditor(.sdr)
        editor.chooseLook(film, input: "srgb", output: "srgb")
        editor.adoptLookSpaces(venice.contentHash, input: "rec709", output: "rec709")
        #expect(editor.recipe.conditionValue("look.input")?.stringValue == "srgb")
        editor.adoptLookSpaces(film.contentHash, input: "rec709", output: "p3")
        #expect(editor.recipe.conditionValue("look.input")?.stringValue == "rec709")
        #expect(editor.recipe.conditionValue("look.output")?.stringValue == "p3")
    }

    @Test func onlyASpaceChosenOnTheSameLookIsRecorded() {
        var old = Recipe(inputDomain: .sdr)
        old.look = film
        var new = old
        new.setValue(.string("rec709"), for: "look.output")
        let chosen = Recipe.chosenLookSpaces(from: old, to: new)
        #expect(chosen?.contentHash == film.contentHash && chosen?.input == nil && chosen?.output == "rec709")
        // A different LUT is a choice of LUT, not of its spaces.
        var other = new
        other.look = venice
        #expect(Recipe.chosenLookSpaces(from: old, to: other) == nil)
        var strength = old
        strength.setValue(.number(50), for: "look.strength")
        #expect(Recipe.chosenLookSpaces(from: old, to: strength) == nil)
    }
}

@MainActor @Suite struct LookPreviewTests {
    @Test func previewsRenderOnlyWhileAPickerIsShown() async throws {
        let (editor, fake) = try await openEditor(.sdr)
        let lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        await editor.installLUT(lut)
        let reference = LUTReference(contentHash: lut.contentHash, name: "Identity")
        let looks = [LookPreviews.Look(reference: reference, input: "rec709", output: "rec709")]
        let previews = LookPreviews()
        previews.update(editor, looks: looks)
        try await Task.sleep(for: .milliseconds(400))
        #expect(previews.images.isEmpty)

        let before = await fake.completed.count
        previews.shown(true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(previews.images[LookPreviews.none] != nil)
        #expect(previews.images[lut.contentHash] != nil)
        let requests = await fake.completed.dropFirst(before)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.keepsSource && max($0.size.width, $0.size.height) == LookPreviews.side })
        let previewed = try #require(requests.first { $0.recipe.look != nil })
        #expect(previewed.recipe.conditionValue("look.input")?.stringValue == "rec709")

        // The same inputs render nothing more; hidden, nothing renders.
        previews.update(editor, looks: looks)
        previews.shown(false)
        var recipe = editor.recipe
        recipe.setValue(.number(0.5), for: "tone.exposure")
        editor.setRecipe(recipe)
        previews.update(editor, looks: looks)
        try await Task.sleep(for: .milliseconds(400))
        await editor.settle()
        #expect(await fake.completed.dropFirst(before).filter(\.keepsSource).count == 2)
    }

    @Test func theBaseLeavesOutTheLookButKeepsItsStrength() {
        var recipe = Recipe(inputDomain: .sdr)
        recipe.look = film
        recipe.setValue(.bool(false), for: "look.enabled")
        recipe.setValue(.string("p3"), for: "look.input")
        recipe.setValue(.number(40), for: "look.strength")
        let base = LookPreviews.base(recipe)
        #expect(base.look == nil && base.conditionValue("look.enabled")?.boolValue == false && base.value(for: "look.input") == nil)
        #expect(base.conditionValue("look.strength")?.numberValue == 40)
        recipe.setValue(.number(0), for: "look.strength")
        #expect(LookPreviews.base(recipe).conditionValue("look.strength")?.numberValue == 0)
    }
}

@MainActor @Suite struct LookPreviewRegressionTests {
    @Test func disabledAndZeroStrengthChoicesMatchTheirPreviews() async throws {
        let (editor, _) = try await openEditor()
        for (enabled, strength) in [(false, 40.0), (true, 0.0)] {
            var recipe = editor.recipe
            recipe.setValue(.bool(enabled), for: "look.enabled")
            recipe.setValue(.number(strength), for: "look.strength")
            editor.setRecipe(recipe)
            let look = LookPreviews.Look(reference: film, input: "rec709", output: "p3")
            let preview = LookPreviews.recipe(LookPreviews.base(editor.recipe), with: look)
            editor.chooseLook(film, input: look.input, output: look.output)
            #expect(editor.recipe == preview)
        }
    }

    @Test func spaceEditsUndoAndRedoNotifyTheLibraryButDomainFallbackDoesNot() async throws {
        let undo = UndoManager()
        let (editor, _) = try await openEditor(.sdr, undo: undo)
        var changes: [(String?, String?)] = []
        editor.onLookSpacesChanged = { old, new in
            if let chosen = Recipe.chosenLookSpaces(from: old, to: new) {
                changes.append((chosen.input, chosen.output))
            }
        }
        editor.chooseLook(film, input: "vlog-vgamut", output: "rec709")
        #expect(changes.isEmpty, "The SDR fallback must not overwrite the library's Log input")
        editor.adoptLookSpaces(film.contentHash, input: "srgb", output: "p3")
        #expect(changes.isEmpty, "Adoption already has the library's spaces")
        undo.undo()
        #expect(changes.count == 1 && changes.last?.1 == "rec709")
        undo.redo()
        #expect(changes.count == 2 && changes.last?.1 == "p3")
        var recipe = editor.recipe
        recipe.setValue(.string("srgb"), for: "look.output")
        editor.setRecipe(recipe)
        #expect(changes.count == 3 && changes.last?.1 == "srgb")
        undo.undo()
        #expect(changes.count == 4 && changes.last?.1 == "p3")
    }

    @Test func selectingALogLookAndFinishingItsCanvasRenderRefreshesPreviews() async throws {
        let (editor, fake) = try await openEditor(.rawEDR)
        let lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        await editor.installLUT(lut)
        let reference = LUTReference(contentHash: lut.contentHash, name: "Log")
        let looks = [LookPreviews.Look(reference: reference, input: "slog3-sgamut3cine", output: "rec709")]
        let previews = LookPreviews()
        previews.update(editor, looks: looks)
        previews.shown(true)
        defer { previews.shown(false) }
        try await Task.sleep(for: .milliseconds(600))
        let before = await fake.completed.filter(\.keepsSource).count
        editor.chooseLook(reference, input: looks[0].input, output: looks[0].output)
        previews.update(editor, looks: looks)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await fake.completed.filter(\.keepsSource).count > before,
                "Changing only the active LUT must invalidate the preview key")
        await editor.settle()
        let afterChoice = await fake.completed.filter(\.keepsSource).count
        previews.update(editor, looks: looks)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await fake.completed.filter(\.keepsSource).count > afterChoice,
                "A completed development must retry previews that needed it")
    }

    @Test func startingADragCancelsAPreviewAlreadyWaitingForTheRenderer() async throws {
        let (editor, fake) = try await openEditor()
        let previews = LookPreviews()
        previews.update(editor, looks: [])
        await fake.holdRenders()
        previews.shown(true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await fake.heldRenderCount == 1)
        editor.editingChanged(try #require(Adjustments.declaration("tone.exposure")), true)
        previews.update(editor, looks: [])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.cancelled.contains(where: \.keepsSource))
        #expect(previews.images.isEmpty)
        await fake.releaseRenders()
        editor.editingChanged(try #require(Adjustments.declaration("tone.exposure")), false)
        previews.update(editor, looks: [])
        try await Task.sleep(for: .milliseconds(500))
        #expect(previews.images[LookPreviews.none] != nil)
        previews.shown(false)
    }
}

extension LookPreviewRegressionTests {
    @Test func failedSpaceWritesDoNotOverwriteANewerEditOrAnotherLook() async throws {
        let (editor, _) = try await openEditor()
        editor.chooseLook(film, input: "rec709", output: "p3")
        // The disk reply is for an older edit: preserve the more recent one.
        editor.reconcileLookSpaces(film.contentHash, attemptedInput: "srgb", attemptedOutput: "p3",
                                   input: "srgb", output: "srgb")
        #expect(editor.recipe.conditionValue("look.input")?.stringValue == "rec709")
        editor.reconcileLookSpaces(venice.contentHash, attemptedInput: "rec709", attemptedOutput: "p3",
                                   input: "srgb", output: "srgb")
        #expect(editor.recipe.conditionValue("look.output")?.stringValue == "p3")
    }
}
