import XCTest
@testable import HyperDR

/// What VoiceOver is told of an export (M3 §19): each moment once, nothing
/// for progress, nothing before the file is written.
@MainActor final class ExportAnnouncerTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/tmp/first.jpg")
    private let target = URL(fileURLWithPath: "/tmp/chosen.heic")
    private let en = Locale(identifier: "en")

    private final class Spoken { var items: [ExportAnnouncer.Announcement] = [] }

    private func setUp(locale: Locale? = nil) async -> (EditorModel, FakeEditorServices, ExportAnnouncer, Spoken) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        let model = EditorModel(services: services, ticker: ManualFrameTicker())
        await model.loadExportServices()
        model.open([source])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        let spoken = Spoken()
        let announcer = ExportAnnouncer(model: model, locale: locale ?? en) { spoken.items.append($0) }
        announcer.start()
        return (model, services, announcer, spoken)
    }

    private func begin(_ model: EditorModel, _ services: FakeEditorServices) async {
        model.startExport(destination: target, token: model.prepareExport()!)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
    }

    private func result(saved: Bool) -> ExportResult {
        ExportResult(export: "v1", fileName: "first.heic", byteCount: 1_000, pixelSize: PixelSize(width: 6000, height: 4000),
                     saved: saved ? SavedLocation(fileName: "first.heic", folderLabel: "…/Pictures",
                                                  url: URL(fileURLWithPath: "/fixtures/Pictures/first.heic")) : nil)
    }

    func testStartedThenSavedAreEachSpokenOnceAndProgressIsSilent() async throws {
        let (model, services, announcer, spoken) = await setUp(); _ = announcer
        await begin(model, services)
        await eventually(timeout: .seconds(5)) { spoken.items.count == 1 }
        XCTAssertEqual(spoken.items.first?.text, "Exporting “\(model.document?.name ?? "")” as Adaptive HDR.")
        for fraction in stride(from: 0.1, through: 0.9, by: 0.2) {
            services.sendExport(.progress(stage: "encode", fraction: fraction, at: Date()))
        }
        services.sendExport(.finishing); services.sendExport(.saving)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(spoken.items.count, 1, "no percentages, stages or 'finishing'")
        services.sendExport(.finished(result: result(saved: true), failure: nil))
        await eventually(timeout: .seconds(5)) { spoken.items.count == 2 }
        XCTAssertEqual(spoken.items.last?.text, "Export finished. Adaptive HDR saved to “Pictures”.")
        XCTAssertFalse(try XCTUnwrap(spoken.items.last).isHigh)
        XCTAssertFalse(spoken.items.last!.text.contains("/"), "a folder's name, never its path")
    }

    func testFinishedWithoutASaveIsHighPriority() async throws {
        let (model, services, announcer, spoken) = await setUp(); _ = announcer
        await begin(model, services)
        services.sendExport(.finished(result: result(saved: false), failure: UserFacingError(code: "export_folder_unwritable")))
        await eventually(timeout: .seconds(5)) { spoken.items.count == 2 }
        XCTAssertEqual(spoken.items.last?.text, "Export finished, but first.heic wasn’t saved: HyperDR can’t write to the chosen location.")
        XCTAssertTrue(spoken.items.last!.isHigh)
    }

    func testAFailureNamesTheCardTitleAtHighPriority() async throws {
        let (model, services, announcer, spoken) = await setUp(); _ = announcer
        await begin(model, services)
        services.sendExport(.finished(result: nil, failure: UserFacingError(code: "export_memory_budget")))
        await eventually(timeout: .seconds(5)) { spoken.items.count == 2 }
        XCTAssertTrue(spoken.items.last!.text.hasPrefix("Export failed. "))
        XCTAssertGreaterThan(spoken.items.last!.text.count, "Export failed. ".count)
        XCTAssertTrue(spoken.items.last!.isHigh)
    }

    func testStoppingIsSpokenOnlyWhenItHasStopped() async throws {
        let (model, services, announcer, spoken) = await setUp(); _ = announcer
        await begin(model, services)
        await eventually(timeout: .seconds(5)) { spoken.items.count == 1 }
        model.cancelExport()
        await eventually(timeout: .seconds(5)) { model.export.phase == .cancelled }
        await eventually(timeout: .seconds(5)) { spoken.items.count == 2 }
        XCTAssertEqual(spoken.items.last?.text, "Export stopped. Nothing was saved.")
    }

    func testTheSecondExportIsSpokenAgain() async throws {
        let (model, services, announcer, spoken) = await setUp(); _ = announcer
        await begin(model, services)
        services.sendExport(.finished(result: result(saved: true), failure: nil))
        await eventually(timeout: .seconds(5)) { spoken.items.count == 2 }
        await begin(model, services)
        await eventually(timeout: .seconds(5)) { spoken.items.count == 3 }
        XCTAssertTrue(spoken.items.last!.text.hasPrefix("Exporting"))
    }

    func testChineseSentencesAndFolderNames() async throws {
        let zh = Locale(identifier: "zh-Hans")
        let (model, services, announcer, spoken) = await setUp(locale: zh); _ = announcer
        await begin(model, services)
        services.sendExport(.finished(result: result(saved: true), failure: nil))
        await eventually(timeout: .seconds(5)) { spoken.items.count == 2 }
        XCTAssertTrue(spoken.items[0].text.hasPrefix("开始导出“"))
        XCTAssertTrue(spoken.items[1].text.hasPrefix("导出完成，") && spoken.items[1].text.hasSuffix("已保存到“Pictures”。"))
    }
}
