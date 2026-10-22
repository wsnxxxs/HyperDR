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
        #expect(base.look == nil && base.value(for: "look.enabled") == nil && base.value(for: "look.input") == nil)
        #expect(base.conditionValue("look.strength")?.numberValue == 40)
        recipe.setValue(.number(0), for: "look.strength")
        #expect(LookPreviews.base(recipe).conditionValue("look.strength")?.numberValue == 100)
    }
}
