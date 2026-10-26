import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDREditorCore

@MainActor @Suite struct RAWBrightnessTests {
    @Test func preferenceAppliesOnlyToNewRAWAndCalibrationSurvivesRestoration() async throws {
        let fake = FakeEditorRendering(includesModel: false)
        await fake.configure { $0.defaultPhoto.domain = .rawEDR; $0.cameraExposureBias = 0.37 }
        let editor = RecipeEditor(renderer: fake)
        let url = URL(fileURLWithPath: "/tmp/camera-brightness.dng")
        try await editor.open(url)
        #expect(editor.recipe.rawExposureBias == nil)
        try await editor.open(url, matchesCameraPreview: true)
        await editor.settle()
        #expect(editor.recipe.rawExposureBias == 0.37)
        #expect(editor.recipe.original.rawExposureBias == 0.37)
        #expect(try editor.exportCapture().recipe.rawExposureBias == 0.37)
        #expect(await fake.cameraCalibrationCount == 1)
        let saved = try Recipe.decode(editor.recipe.encoded())
        await fake.configure { $0.cameraExposureBias = -1 }
        try await editor.open(url, restoring: saved, matchesCameraPreview: true)
        #expect(editor.recipe == saved)
        await fake.configure { $0.defaultPhoto.domain = .sdr }
        try await editor.open(url, matchesCameraPreview: true)
        #expect(editor.recipe.rawExposureBias == nil)
        #expect(await fake.cameraCalibrationCount == 1)
        await editor.close()
    }

    @Test func defaultIsOffAndPersistsAcrossSettingsInstances() {
        let name = "RAWBrightness-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!RAWBrightnessPreference.load(from: defaults))
        RAWBrightnessPreference.save(true, to: defaults)
        #expect(RAWBrightnessPreference.load(from: defaults))
        RAWBrightnessPreference.save(false, to: defaults)
        #expect(!RAWBrightnessPreference.load(from: defaults))
    }
}
