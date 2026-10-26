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

    @Test func aLogLookOutsideRAWIsNotSelected() async throws {
        let (editor, _) = try await openEditor(.sdr)
        editor.chooseLook(film, input: "vlog-vgamut", output: "rec709")
        #expect(editor.recipe.look == nil)
        #expect(editor.recipe.value(for: "look.input") == nil)
        #expect(editor.recipe.value(for: "look.output") == nil)
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

    @Test func incompatibleLibraryWriteRemovesTheLookAndFailureRestoresIt() async throws {
        let (editor, _) = try await openEditor(.sdr)
        editor.chooseLook(venice, input: "srgb", output: "rec709")
        let before = editor.recipe
        editor.adoptLookSpaces(venice.contentHash, input: "vlog-vgamut", output: "rec709")
        #expect(editor.recipe.look == nil)
        editor.reconcileLookSpaces(venice.contentHash, attemptedInput: "vlog-vgamut", attemptedOutput: "rec709", input: "srgb", output: "rec709")
        #expect(editor.recipe == before)
        editor.adoptLookSpaces(venice.contentHash, input: "vlog-vgamut", output: "rec709")
        editor.chooseLook(film, input: "srgb", output: "srgb")
        let newer = editor.recipe
        editor.reconcileLookSpaces(venice.contentHash, attemptedInput: "vlog-vgamut", attemptedOutput: "rec709", input: "srgb", output: "rec709")
        #expect(editor.recipe == newer)
    }

    @Test func changingBetweenBuiltInAndImportedLooksUndoesAsOneStep() async throws {
        let undo = UndoManager()
        let (editor, _) = try await openEditor(.rawEDR, undo: undo)
        undo.beginUndoGrouping()
        editor.apply(.parameter(Recipe.filmID)) { $0.setValue(.string("portra400"), for: Recipe.filmID) }
        undo.endUndoGrouping()
        let builtIn = editor.recipe
        undo.beginUndoGrouping()
        editor.chooseLook(venice, input: "slog3-sgamut3cine", output: "rec709")
        undo.endUndoGrouping()
        #expect(editor.recipe.look == venice)
        #expect(editor.recipe.conditionValue(Recipe.filmID) == .string("none"))
        undo.undo()
        #expect(editor.recipe == builtIn)
        undo.redo()
        let imported = editor.recipe
        undo.beginUndoGrouping()
        editor.apply(.parameter(Recipe.filmID)) { $0.setValue(.string("gold200"), for: Recipe.filmID) }
        undo.endUndoGrouping()
        #expect(editor.recipe.look == nil)
        undo.undo()
        #expect(editor.recipe == imported)
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
        #expect(previews.images[LookPreviews.filmKey("portra400")] != nil)
        // None, each built-in film stock, and the library's LUT.
        let requests = await fake.completed.dropFirst(before)
        #expect(requests.count == Adjustments.filmStocks.count + 1)
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
        #expect(await fake.completed.dropFirst(before).filter(\.keepsSource).count == Adjustments.filmStocks.count + 1)
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

    @Test func theTilesCompareColourWithoutTheEffects() {
        var recipe = Recipe(inputDomain: .sdr)
        recipe.setValue(.number(80), for: "effect.grain")
        recipe.setValue(.number(50), for: "effect.halation")
        recipe.setValue(.number(0.5), for: "tone.exposure")
        let base = LookPreviews.base(recipe)
        #expect(base.isDefault("effect.grain") && base.isDefault("effect.halation"))
        #expect(base.value(for: "tone.exposure") == .number(0.5), "the photo's own edit stays")
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

    @Test func spaceEditsUndoAndRedoNotifyTheLibraryButRejectedChoicesDoNot() async throws {
        let undo = UndoManager()
        let (editor, _) = try await openEditor(.sdr, undo: undo)
        var changes: [(String?, String?)] = []
        editor.onLookSpacesChanged = { old, new in
            if let chosen = Recipe.chosenLookSpaces(from: old, to: new) {
                changes.append((chosen.input, chosen.output))
            }
        }
        editor.chooseLook(film, input: "vlog-vgamut", output: "rec709")
        #expect(changes.isEmpty, "A rejected choice cannot overwrite the library's Log input")
        undo.beginUndoGrouping()
        editor.chooseLook(film, input: "srgb", output: "rec709")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        editor.adoptLookSpaces(film.contentHash, input: "srgb", output: "p3")
        undo.endUndoGrouping()
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

    @Test func selectingALogLookKeepsAlreadyPreparedPreviews() async throws {
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
        await fake.holdRenders()
        editor.chooseLook(reference, input: looks[0].input, output: looks[0].output)
        previews.update(editor, looks: looks)
        try await Task.sleep(for: .milliseconds(350))
        #expect(await fake.completed.filter(\.keepsSource).count == before,
                "The canvas development must finish before picker work starts")
        await fake.releaseRenders()
        await editor.settle()
        let afterChoice = await fake.completed.filter(\.keepsSource).count
        previews.update(editor, looks: looks)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await fake.completed.filter(\.keepsSource).count == afterChoice,
                "Every look already prepared its own rendition before selection")
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
        await editor.settle()
        previews.update(editor, looks: [])
        try await Task.sleep(for: .milliseconds(500))
        #expect(previews.images[LookPreviews.none] != nil)
        previews.shown(false)
    }

    @Test func choosingAStockAndChangingEffectsReuseCompletedColourThumbnails() async throws {
        let (editor, fake) = try await openEditor()
        let previews = LookPreviews()
        previews.update(editor, looks: [])
        previews.shown(true)
        defer { previews.shown(false) }
        try await Task.sleep(for: .milliseconds(600))
        let before = await fake.completed.filter(\.keepsSource).count
        #expect(before == Adjustments.filmStocks.count)
        var recipe = editor.recipe
        recipe.setValue(.string("portra400"), for: Recipe.filmID)
        recipe.setValue(.number(100), for: "effect.grain")
        editor.setRecipe(recipe)
        previews.update(editor, looks: [])
        await editor.settle()
        previews.update(editor, looks: [])
        try await Task.sleep(for: .milliseconds(350))
        #expect(await fake.completed.filter(\.keepsSource).count == before)
        // Changes that really alter the colour thumbnails still refresh them.
        recipe.setValue(.number(50), for: "look.filmStrength")
        editor.setRecipe(recipe)
        previews.update(editor, looks: [])
        await editor.settle()
        previews.update(editor, looks: [])
        try await Task.sleep(for: .milliseconds(600))
        #expect(await fake.completed.filter(\.keepsSource).count > before)
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


extension LookPreviewRegressionTests {
    @Test func aFailedPreviewIsRetriedWhenThePickerReopens() async throws {
        let (editor, fake) = try await openEditor()
        await fake.configure {
            $0.renderErrorForRequest = {
                $0.keepsSource && $0.recipe.conditionValue(Recipe.filmID)?.stringValue == "portra400"
                    ? .unsupported("temporary") : nil
            }
        }
        let previews = LookPreviews()
        previews.update(editor, looks: [])
        previews.shown(true)
        try await Task.sleep(for: .milliseconds(500))
        let original = try #require(previews.images[LookPreviews.none])
        #expect(previews.images[LookPreviews.filmKey("portra400")] == nil)
        let rendered = await fake.completed.filter(\.keepsSource).count
        previews.shown(false)
        await fake.configure { $0.renderErrorForRequest = nil }
        previews.shown(true)
        defer { previews.shown(false) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(previews.images[LookPreviews.none] === original)
        #expect(previews.images[LookPreviews.filmKey("portra400")] != nil)
        #expect(await fake.completed.filter(\.keepsSource).count == rendered + 1,
                "Only the missing tile needs another render")
    }

    @Test func aBadImportDoesNotDisableOtherLibraryLUTs() async throws {
        let (editor, _) = try await openEditor(.rawEDR)
        let data = Data("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n".utf8)
        var installed: [String: LUTReference] = [:]
        let failed = await editor.installLibraryLUTs([
            LibraryLUT(id: "first", name: "First"),
            LibraryLUT(id: "broken", name: "Broken"),
            LibraryLUT(id: "last", name: "Last")
        ], cube: { $0 == "broken" ? Data("invalid".utf8) : data }, installed: { installed[$0] = $1 })
        #expect(failed == ["Broken"])
        #expect(Set(installed.keys) == ["first", "last"])
        for id in ["first", "last"] {
            let reference = try #require(installed[id])
            #expect(editor.hasLUT(reference.contentHash))
            editor.chooseLook(reference, input: "flog2c-fgamutc", output: "rec709")
            #expect(editor.recipe.look == reference)
        }
    }
}

@MainActor @Suite struct AutomaticLookPreviewIntegrationTests {
    @Test func rawPickerRendersEveryLookBeforeAnySelection() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        try FileManager.default.copyItem(at: fixture, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try RenderSession()
        let editor = RecipeEditor(renderer: session, frameClock: ImmediateClock())
        editor.canvasPixelSize = PixelSize(width: 256, height: 256)
        try await editor.open(url)
        await editor.settle()
        #expect(editor.source?.domain == .rawEDR)
        #expect(!editor.isRefiningPreview && editor.frameIsCurrent)

        let display = try ColorLUT(cube: "# display\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        let supplied = ProcessInfo.processInfo.environment["HYPERDR_TEST_LUT"]
        let log = try supplied.map { try ColorLUT(contentsOf: URL(fileURLWithPath: $0)) }
            ?? ColorLUT(cube: "# log\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        await editor.installLUT(display)
        await editor.installLUT(log)
        let looks = [
            LookPreviews.Look(reference: LUTReference(contentHash: display.contentHash, name: "Display"),
                              input: "srgb", output: "srgb"),
            LookPreviews.Look(reference: LUTReference(contentHash: log.contentHash, name: "Log"),
                              input: "slog3-sgamut3cine", output: "rec709")
        ]
        let recipe = editor.recipe
        let canvas = editor.frame?.request
        let previews = LookPreviews()
        previews.update(editor, looks: looks)
        previews.shown(true)
        defer { previews.shown(false) }
        let expected = Set([LookPreviews.none, display.contentHash, log.contentHash]
            + Adjustments.filmStocks.dropFirst().map(LookPreviews.filmKey))
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(30)
        while Set(previews.images.keys) != expected, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Set(previews.images.keys) == expected,
                "Opening the picker alone must produce display, Log and all film thumbnails")
        #expect(editor.recipe == recipe && editor.recipe.look == nil)
        #expect(editor.frame?.request == canvas, "Preview preparation must not replace the canvas")
        await editor.close()
    }
}
