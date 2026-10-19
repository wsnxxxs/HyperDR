import Foundation
import HyperDREngine
import XCTest
@testable import HyperDR

@MainActor final class EditorSupplementTests: XCTestCase {
    func testNoticesAreBundledInApplication() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"))
        XCTAssertTrue(url.path.contains("HyperDR.app/Contents/Resources/"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("License"))
        XCTAssertGreaterThan(text.utf8.count, 1000)
    }

    func testAboutValuesAreStructuredAndRAWIdentityComesFromEngine() async {
        let services = LiveEditorServices()
        let about = await services.aboutInformation()
        XCTAssertEqual(about.version, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(about.buildNumber, Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertEqual(about.engineABI, Engine.abiVersion)
        XCTAssertNil(about.osBuild); XCTAssertNil(about.decoderVersion)
        let scripted = ScriptedEditorServices()
        let model = EditorModel(services: scripted)
        model.preferences.about = about
        var source = SourceSummary(domain: .sceneReferred, colorName: "P3", degradationReasons: [])
        source.raw = RawCapabilities(supported: true, lensCorrectionSupported: true, decoderVersion: "engine-decoder", osBuild: "engine-build")
        let url = URL(fileURLWithPath: "/fixtures/about.ARW")
        model.open([url])
        await eventually(timeout: .seconds(3)) { scripted.streams[url] != nil }
        let frame = EditorPreview(pixelSize: PixelSize(width: 10, height: 10), source: source, hasGain: false)
        scripted.streams[url]?.yield(.reference(frame))
        scripted.streams[url]?.yield(.edited(frame))
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        XCTAssertEqual(model.aboutInformation.osBuild, "engine-build")
        XCTAssertEqual(model.aboutInformation.decoderVersion, "engine-decoder")
        model.closeDocument()
        XCTAssertNil(model.aboutInformation.osBuild)
        XCTAssertNil(model.aboutInformation.decoderVersion)
    }

    func testImportFailuresIdentifyOnlyTheFileAndLibraryKeepsByteCount() async {
        let services = FakeEditorServices()
        let model = EditorModel(services: services)
        await model.importLUTs([URL(fileURLWithPath: "/private/secret/Bad.cube"), URL(fileURLWithPath: "/other/Broken.cube")])
        XCTAssertEqual(model.lut.failures.map(\.detail), ["Bad.cube", "Broken.cube"])
        XCTAssertEqual(model.lut.failures.map(\.code), ["lut_invalid", "lut_invalid"])
        services.importedLUT = LUTItem(id: "id", name: "Good.cube", input: .srgb, output: .srgb, byteCount: 1234)
        await model.importLUTs([URL(fileURLWithPath: "/private/Good.cube")])
        XCTAssertEqual(model.lut.library.first?.byteCount, 1234)
        XCTAssertTrue(model.lut.failures.isEmpty)
    }

    func testFolderActionDoesNotExposeURLAndRoutesFailure() async {
        let model = EditorModel(services: FakeEditorServices())
        var calls = 0
        let target = ExportFolderTarget(reveal: { calls += 1 }) { _, _ in throw UserFacingError(code: "internal_error") }
        model.preferences.exportFolder = ExportFolder(label: "Selected", ready: true, target: target)
        await model.revealExportFolder()
        XCTAssertEqual(calls, 1); XCTAssertNil(model.preferences.failure)
        let failure = ExportFolderTarget(reveal: { throw UserFacingError(code: "export_folder_unwritable") }) { _, _ in throw UserFacingError(code: "internal_error") }
        model.preferences.exportFolder.target = failure
        await model.revealExportFolder()
        XCTAssertEqual(model.preferences.failure?.code, "export_folder_unwritable")
        model.preferences.exportFolder.ready = false
        model.preferences.failure = nil
        await model.revealExportFolder()
        XCTAssertNil(model.preferences.failure)
    }
}
