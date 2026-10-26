import Foundation
import HyperDRRender
import XCTest
@testable import HyperDR

@MainActor final class RAWDecoderSettingsTests: XCTestCase {
    func testStoredChoiceFeedsNewOpensAndChangingItKeepsTheCurrentRecipe() async throws {
        let services = FakeEditorServices(openDelay: .zero)
        RAWDecoderPreference.raw8.save(to: services.preferences)
        let renderer = try XCTUnwrap(services.fakeRendering)
        let model = EditorModel(services: services)
        XCTAssertEqual(model.preferences.value.rawDecoder, .raw8)
        model.open([URL(fileURLWithPath: "/tmp/first-raw.dng")])
        await eventually { model.document?.phase == .ready }
        let firstChoices = await renderer.rawDecoderPreferences
        XCTAssertEqual(firstChoices, [.raw8])
        let currentRecipe = model.editor.recipe
        var preferences = model.preferences.value
        preferences.rawDecoder = .raw9
        model.updatePreferences(preferences)
        XCTAssertEqual(RAWDecoderPreference.load(from: services.preferences), .raw9)
        XCTAssertEqual(model.editor.recipe, currentRecipe)
        let next = URL(fileURLWithPath: "/tmp/next-raw.dng")
        model.open([next])
        await eventually { model.photo?.url == next && model.document?.phase == .ready }
        let nextChoices = await renderer.rawDecoderPreferences
        XCTAssertEqual(nextChoices, [.raw8, .raw9])
        model.resetPreferences()
        XCTAssertEqual(Preferences.load(from: services.preferences).rawDecoder, .automatic)
        XCTAssertEqual(RAWDecoderPreference.load(from: services.preferences), .automatic)
        model.closeDocument()
    }

    func testLegacyPreferencesAndInvalidChoicesKeepAutomatic() {
        let name = "RAWDecoderSettingsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["histogramRGB": true], forKey: Preferences.key)
        defaults.set("raw10", forKey: RAWDecoderPreference.key)
        let legacy = Preferences.load(from: defaults)
        XCTAssertTrue(legacy.histogramRGB)
        XCTAssertEqual(legacy.rawDecoder, .automatic)
        for choice in RAWDecoderPreference.allCases {
            var preferences = legacy
            preferences.rawDecoder = choice
            preferences.save(to: defaults)
            XCTAssertEqual(Preferences.load(from: defaults, supportsRAW9: true), preferences)
        }
    }

    func testRAW9ReadsAsAutomaticWhereTheSystemHasNoRAW9() {
        let name = "RAWDecoderSettingsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        RAWDecoderPreference.raw9.save(to: defaults)
        XCTAssertEqual(Preferences.load(from: defaults, supportsRAW9: false).rawDecoder, .automatic)
        XCTAssertEqual(Preferences.load(from: defaults, supportsRAW9: true).rawDecoder, .raw9)
        RAWDecoderPreference.libRAW.save(to: defaults)
        XCTAssertEqual(Preferences.load(from: defaults, supportsRAW9: false).rawDecoder, .libRAW)
    }

    func testUnsupportedDecoderHasSpecificLocalizedWording() {
        let failure = UserFacingError(RenderError.unsupportedRAWDecoder("9.dng"))
        XCTAssertEqual(failure.code, "raw_decoder_unavailable")
        let text = ErrorText(failure)
        XCTAssertTrue(text.body(locale: Locale(identifier: "en")).contains("RAW developer 9.dng"))
        XCTAssertTrue(text.body(locale: Locale(identifier: "zh-Hans")).contains("RAW 开发器 9.dng"))
        XCTAssertFalse(text.body.contains("unsupportedRAWDecoder"))
    }
}
