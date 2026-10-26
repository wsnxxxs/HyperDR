import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDREditorCore

@Suite struct RAWDecoderPreferenceStorageTests {
    @Test func missingAndUnknownChoicesPreserveAutomaticDefault() throws {
        let name = "RAWDecoderPreferenceTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(RAWDecoderPreference.load(from: defaults) == .automatic)
        let invalidChoices: [Any] = ["", "raw10", "9.dng", "libRAW", 9, ["choice": "raw8"]]
        for invalid in invalidChoices {
            defaults.set(invalid, forKey: RAWDecoderPreference.key)
            #expect(RAWDecoderPreference.load(from: defaults) == .automatic)
        }
    }

    @Test(arguments: RAWDecoderPreference.allCases)
    func eachChoiceSurvivesANewDefaultsInstance(choice: RAWDecoderPreference) throws {
        let name = "RAWDecoderPreferenceTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        choice.save(to: defaults)
        let reopened = try #require(UserDefaults(suiteName: name))
        #expect(RAWDecoderPreference.load(from: reopened) == choice)
        #expect(choice.generation == (choice == .raw8 ? 8 : choice == .raw9 ? 9 : nil))
    }
}

@MainActor @Suite struct RAWDecoderPreferenceOpeningTests {
    @Test(arguments: RAWDecoderPreference.allCases)
    func theEditorPassesANewPhotosChoiceToItsRenderer(choice: RAWDecoderPreference) async throws {
        let renderer = FakeEditorRendering()
        // This plumbing test needs no textures or GPU work.
        await renderer.configure { $0.renderError = .unsupported("CPU-only preference test") }
        let editor = RecipeEditor(renderer: renderer)
        try await editor.open(URL(fileURLWithPath: "/tmp/new-raw.dng"), rawDecoderPreference: choice)
        #expect(await renderer.rawDecoderPreferences == [choice])
        await editor.close()
    }

    @Test(arguments: [false, true])
    func aRestoredRecipeIgnoresTheGlobalChoice(legacy: Bool) async throws {
        let renderer = FakeEditorRendering()
        await renderer.configure {
            $0.defaultPhoto = .init(domain: .rawEDR)
            $0.renderError = .unsupported("CPU-only preference test")
        }
        let editor = RecipeEditor(renderer: renderer)
        let recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: legacy ? nil : "9.dng")
        try await editor.open(URL(fileURLWithPath: "/tmp/saved-raw.dng"), restoring: recipe,
                              rawDecoderPreference: .raw8)
        #expect(await renderer.rawDecoderPreferences == [.automatic])
        #expect(editor.recipe.rawDecoderVersion == recipe.rawDecoderVersion)
        await editor.close()
    }
}
