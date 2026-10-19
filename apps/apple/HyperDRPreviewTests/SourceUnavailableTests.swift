import AppKit
import Foundation
import HyperDRKit
import XCTest
@testable import HyperDR

/// The photo's file going missing or being changed while it is open
/// (parity batch 7 §3): what the editor keeps, what it stops doing and how it
/// finds its way back.
@MainActor final class SourceUnavailableTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixtures/a.jpg")
    private let b = URL(fileURLWithPath: "/fixtures/b.jpg")
    private let missing = UserFacingError(code: "source_missing")
    private var preview: EditorPreview {
        EditorPreview(pixelSize: PixelSize(width: 6000, height: 4000),
            source: SourceSummary(domain: .hdr, colorName: "Display P3", degradationReasons: []), hasGain: true)
    }
    private var spoken: [(String, Bool)] = []
    private var savedDeliver: ((String, Bool) -> Void)?

    override func setUp() async throws {
        spoken = []
        savedDeliver = NoticeAnnouncement.deliver
        NoticeAnnouncement.deliver = { [weak self] in self?.spoken.append(($0, $1)) }
    }

    override func tearDown() async throws {
        if let savedDeliver { NoticeAnnouncement.deliver = savedDeliver }
    }

    private func opened(ticker: FrameTicker? = nil) async -> (EditorModel, ScriptedEditorServices, ManualFrameTicker) {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        model.open([a])
        await eventually { services.streams[self.a] != nil }
        services.streams[a]?.yield(.reference(preview))
        services.streams[a]?.yield(.edited(preview))
        await eventually { model.document?.phase == .ready && services.refresh != nil }
        return (model, services, ticker)
    }

    private func flush(_ ticker: ManualFrameTicker) async {
        await eventually { ticker.isWaiting }
        ticker.tick()
        await settle()
    }

    private func becomeUnavailable(_ model: EditorModel, _ services: ScriptedEditorServices) async {
        services.refresh?.yield(.failed(missing))
        await eventually { model.sourceUnavailable != nil }
    }

    func testAMissingFileKeepsTheFrameAndTheControlsButStopsExportAndAI() async {
        let (model, services, _) = await opened()
        await becomeUnavailable(model, services)
        XCTAssertTrue(model.hasEditedFrame, "the last frame stays")
        XCTAssertNil(model.editingLockReason, "controls are not locked")
        XCTAssertEqual(model.export.blockerKey, "export.blocker.sourceMissing")
        XCTAssertEqual(model.aiBlockReason(), "ai.blocker.sourceMissing")
        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(spoken.first?.1, true, "high priority")
        XCTAssertEqual(spoken.first?.0, AppStrings.format("source.missing.announce %@", "a.jpg"))
    }

    func testOtherPreviewFailuresDoNotEnterTheState() async {
        let (model, services, _) = await opened()
        services.refresh?.yield(.failed(UserFacingError(code: "raw_budget")))
        await eventually { model.document?.previewError != nil }
        XCTAssertNil(model.sourceUnavailable)
        XCTAssertTrue(spoken.isEmpty)
    }

    func testAdjustmentsAreRecordedButNotRenderedWhileTheFileIsMissing() async {
        let (model, services, ticker) = await opened()
        await becomeUnavailable(model, services)
        let before = services.submitted.count
        model.adjust("brightness", to: 1.3)
        model.adjust("brightness", to: 1.4)
        ticker.tick()
        await settle()
        XCTAssertEqual(services.submitted.count, before, "nothing is submitted")
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(model.control("brightness").value, 1.4)
        model.undo()
        XCTAssertNotEqual(model.control("brightness").value, 1.4, "undo works as usual")
    }

    func testRetryRendersTheCurrentValuesOnceAndAFrameClearsTheState() async {
        let (model, services, ticker) = await opened()
        await becomeUnavailable(model, services)
        model.adjust("brightness", to: 1.3)
        let before = services.submitted.count
        model.retrySource()
        await flush(ticker)
        await eventually { services.submitted.count == before + 1 }
        XCTAssertEqual(services.submitted.last?["brightness"], .number(1.3))
        XCTAssertNotNil(model.sourceUnavailable, "still unavailable until a frame arrives")
        spoken = []
        services.refresh?.yield(.edited(preview, isLatest: true))
        await eventually { model.sourceUnavailable == nil }
        XCTAssertNil(model.export.blockerKey)
        XCTAssertEqual(spoken.map(\.0), [AppStrings.format("source.found.announce %@", "a.jpg")])
        XCTAssertEqual(spoken.first?.1, false)
    }

    func testTheTimerRetriesWhileTheAppIsInFront() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        model.sourceRetryInterval = .milliseconds(30)
        var active = false
        model.appIsActive = { active }
        model.open([a])
        await eventually { services.streams[self.a] != nil }
        services.streams[a]?.yield(.reference(preview))
        services.streams[a]?.yield(.edited(preview))
        await eventually { model.document?.phase == .ready && services.refresh != nil }
        await becomeUnavailable(model, services)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(services.submitted.isEmpty, "not while the app is in the background")
        active = true
        await eventually(timeout: .seconds(5)) { !services.submitted.isEmpty }
        model.closeDocument()
    }

    func testComingToTheFrontRetriesAtOnce() async {
        let (model, services, ticker) = await opened()
        await becomeUnavailable(model, services)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await flush(ticker)
        await eventually { !services.submitted.isEmpty }
        model.closeDocument()
    }

    func testClosingOrSwitchingThePhotoLeavesTheState() async {
        let (model, services, _) = await opened()
        await becomeUnavailable(model, services)
        model.closeDocument()
        XCTAssertNil(model.sourceUnavailable)
        XCTAssertNil(model.export.blockerKey == "export.blocker.sourceMissing" ? "stuck" : nil)
    }

    // MARK: Finding the file again

    func testALocatedFileWithTheSameContentKeepsAdjustmentsAndUndo() async {
        let (model, services, ticker) = await opened()
        model.adjust("brightness", to: 1.3)
        await flush(ticker)
        await becomeUnavailable(model, services)
        let handle = model.photo!.handle
        services.relinkHandler = { url in EditorPhoto(url: url, name: url.lastPathComponent, formatLabel: "JPEG", byteCount: 1, handle: handle) }
        let before = services.submitted.count
        model.locateSource(b)
        await flush(ticker)
        await eventually { model.photo?.url == self.b }
        XCTAssertEqual(model.document?.name, "b.jpg")
        XCTAssertEqual(model.control("brightness").value, 1.3, "adjustments stay")
        XCTAssertTrue(model.canUndo)
        await eventually { services.submitted.count > before }
        services.refresh?.yield(.edited(preview, isLatest: true))
        await eventually { model.sourceUnavailable == nil }
    }

    func testADifferentFileIsOpenedAsAnotherPhoto() async {
        let (model, services, _) = await opened()
        await becomeUnavailable(model, services)
        services.relinkHandler = { _ in throw UserFacingError(code: "source_different") }
        model.locateSource(b)
        await eventually { services.streams[self.b] != nil }
        XCTAssertNil(model.sourceUnavailable)
        XCTAssertNil(model.alert)
        model.closeDocument()
    }

    func testAnyOtherLocateFailureIsAnAlert() async {
        let (model, services, _) = await opened()
        await becomeUnavailable(model, services)
        services.relinkHandler = { _ in throw UserFacingError(code: "source_unreadable") }
        model.locateSource(b)
        await eventually { model.alert?.code == "source_unreadable" }
        XCTAssertNotNil(model.sourceUnavailable)
    }

    func testTheLocatePanelIsOpenedForLocatingNotForOpening() {
        let window = EditorWindowState()
        window.locateSource()
        XCTAssertTrue(window.isImporting)
        XCTAssertTrue(window.isLocating)
    }

    // MARK: A file changed by another app

    func testAReplacedFileReopensFromDefaultsAndSaysSo() async {
        let (model, services, _) = await opened()
        model.adjust("brightness", to: 1.3)
        services.streams[a] = nil
        services.refresh?.yield(.sourceReplaced)
        await eventually { services.streams[self.a] != nil }
        services.streams[a]?.yield(.reference(preview))
        services.streams[a]?.yield(.edited(preview))
        await eventually { model.canvasNotice != nil }
        XCTAssertEqual(model.canvasNotice, .sourceReplaced(name: "a.jpg"))
        XCTAssertNotEqual(model.control("brightness").value, 1.3, "the old adjustments do not carry over")
        model.adjust("brightness", to: 1.1)
        XCTAssertNil(model.canvasNotice, "the first edit clears it")
    }

    func testAReplacedFileDuringAnExportWaitsForTheExportAndThenReopens() async {
        let (model, services, _) = await opened()
        model.export.phase = .running
        services.streams[a] = nil
        services.refresh?.yield(.sourceReplaced)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(services.streams[a], "the export is not interrupted and nothing is reopened")
        XCTAssertNil(model.pendingPhotoSwitch, "no question is asked either")
        model.export.phase = .failed
        model.resumeReplacedReopen()
        await eventually { services.streams[self.a] != nil }
        services.streams[a]?.yield(.reference(preview))
        services.streams[a]?.yield(.edited(preview))
        await eventually { model.canvasNotice == .sourceReplaced(name: "a.jpg") }
    }

    // MARK: Work data gone

    func testAnExpiredSessionOnThePreviewPathClosesThePhotoWithTheAlert() async {
        let (model, services, _) = await opened()
        services.refresh?.yield(.failed(UserFacingError(code: "session_expired")))
        await eventually { model.alert?.code == "session_expired" }
        XCTAssertNil(model.document)
        XCTAssertNil(model.sourceUnavailable)
    }

    // MARK: The history

    func testAnExportHistoryRefreshThatFindsTheFileMissingKeepsTheListAndEntersTheState() async throws {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        let model = EditorModel(services: services, ticker: ManualFrameTicker())
        await model.loadExportServices()
        model.open([a])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        let key = try await services.exportKey(model.photo!, options: model.effectiveOptions(), frame: nil)
        services.historyByURL[a] = [ExportHistoryItem(
            version: ExportVersion(number: 1, createdAt: Date(), encodingID: "adaptive",
                                   result: ExportResult(export: "v1", fileName: "a.heic", byteCount: 1, pixelSize: PixelSize(width: 1, height: 1))),
            key: key, options: model.edit)]
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.exportVersions.count == 1 }
        services.metadataHandler = { throw UserFacingError(code: "source_missing") }
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.sourceUnavailable != nil }
        XCTAssertEqual(model.exportVersions.map(\.id), ["v1"], "the list is frozen, not emptied")
        XCTAssertNotNil(model.transferItem(for: "v1"), "a version can still be dragged out")
    }
}
