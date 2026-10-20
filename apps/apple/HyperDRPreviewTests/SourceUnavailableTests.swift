import AppKit
import Foundation
import HyperDRKit
import HyperDRRecipe
import XCTest
@testable import HyperDR

/// The photo's file going missing while it is open (parity batch 7 §3): what
/// the editor keeps, what it stops doing and how it finds its way back.
@MainActor final class SourceUnavailableTests: XCTestCase {
    private var directory: URL!
    private var a: URL { directory.appendingPathComponent("a.jpg") }
    private var b: URL { directory.appendingPathComponent("b.jpg") }
    private var spoken: [(String, Bool)] = []
    private var savedDeliver: ((String, Bool) -> Void)?

    override func setUp() async throws {
        spoken = []
        savedDeliver = NoticeAnnouncement.deliver
        NoticeAnnouncement.deliver = { [weak self] in self?.spoken.append(($0, $1)) }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: a)
        try Data([2]).write(to: b)
    }

    override func tearDown() async throws {
        if let savedDeliver { NoticeAnnouncement.deliver = savedDeliver }
        try? FileManager.default.removeItem(at: directory)
    }

    private func opened() async -> (EditorModel, ScriptedEditorServices) {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await openReady(model, a)
        return (model, services)
    }

    private func setExposure(_ value: Double, _ model: EditorModel) {
        var recipe = model.editor.recipe
        recipe.setValue(.number(value), for: "tone.exposure")
        model.editor.setRecipe(recipe)
    }

    private func exposure(_ model: EditorModel) -> Double? {
        model.editor.recipe.value(for: "tone.exposure")?.numberValue
    }

    /// The file goes away and the next render of it fails.
    private func becomeUnavailable(_ model: EditorModel, _ services: ScriptedEditorServices) async {
        try? FileManager.default.removeItem(at: a)
        services.scripted.failRenders(of: a, with: UserFacingError(code: "decode_failed"))
        setExposure(0.25, model)
        await eventually { model.sourceUnavailable != nil }
    }

    /// The file is back and renders of it work again.
    private func comeBack(_ services: ScriptedEditorServices) async {
        try? Data([1]).write(to: a)
        services.scripted.failRenders(of: a, with: nil)
    }

    func testAMissingFileKeepsTheFrameAndTheControlsButStopsExport() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        XCTAssertTrue(model.hasEditedFrame, "the last frame stays")
        XCTAssertNil(model.editingLockReason, "controls are not locked")
        XCTAssertEqual(model.export.blockerKey, "export.blocker.sourceMissing")
        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(spoken.first?.1, true, "high priority")
        XCTAssertEqual(spoken.first?.0, AppStrings.format("source.missing.announce %@", "a.jpg"))
        model.closeDocument()
    }

    func testOtherRenderFailuresDoNotEnterTheState() async {
        let (model, services) = await opened()
        services.scripted.failRenders(of: a, with: UserFacingError(code: "decode_failed"))
        setExposure(0.25, model)
        await eventually { model.document?.previewError != nil }
        XCTAssertNil(model.sourceUnavailable)
        XCTAssertTrue(spoken.isEmpty)
        model.closeDocument()
    }

    func testAdjustmentsAndUndoWorkWhileTheFileIsMissing() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        setExposure(0.5, model)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(exposure(model), 0.5)
        model.undo()
        XCTAssertEqual(exposure(model), 0.25, "undo works as usual")
        model.closeDocument()
    }

    func testRetryEndsTheStateOnceTheFileIsBack() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        model.retrySource()
        XCTAssertNotNil(model.sourceUnavailable, "still missing")
        await comeBack(services)
        spoken = []
        model.retrySource()
        XCTAssertNil(model.sourceUnavailable)
        XCTAssertNil(model.export.blockerKey)
        XCTAssertEqual(spoken.map(\.0), [AppStrings.format("source.found.announce %@", "a.jpg")])
        XCTAssertEqual(spoken.first?.1, false)
        XCTAssertTrue(model.canUndo, "the photo's steps stay")
        model.closeDocument()
    }

    func testTheTimerRetriesWhileTheAppIsInFront() async {
        let (model, services) = await opened()
        model.sourceRetryInterval = .milliseconds(30)
        var active = false
        model.appIsActive = { active }
        await becomeUnavailable(model, services)
        await comeBack(services)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(model.sourceUnavailable, "not while the app is in the background")
        active = true
        await eventually(timeout: .seconds(5)) { model.sourceUnavailable == nil }
        model.closeDocument()
    }

    func testComingToTheFrontRetriesAtOnce() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        await comeBack(services)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await eventually { model.sourceUnavailable == nil }
        model.closeDocument()
    }

    func testClosingThePhotoLeavesTheState() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        model.closeDocument()
        XCTAssertNil(model.sourceUnavailable)
        XCTAssertNotEqual(model.export.blockerKey, "export.blocker.sourceMissing")
    }

    // MARK: Finding the file again

    func testALocatedFileWithTheSameContentKeepsTheAdjustments() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        let handle = model.photo!.handle
        services.relinkHandler = { url in EditorPhoto(url: url, name: url.lastPathComponent, formatLabel: "JPEG", byteCount: 1, handle: handle) }
        model.locateSource(b)
        await eventually { model.photo?.url == self.b }
        XCTAssertEqual(model.document?.name, "b.jpg")
        await eventually { model.editor.source?.url == self.b && model.sourceUnavailable == nil }
        XCTAssertEqual(exposure(model), 0.25, "adjustments stay")
        model.closeDocument()
    }

    func testADifferentFileIsOpenedAsAnotherPhoto() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        services.relinkHandler = { _ in throw UserFacingError(code: "source_different") }
        model.locateSource(b)
        await eventually { model.photo?.url == self.b && model.document?.phase == .ready }
        XCTAssertNil(model.sourceUnavailable)
        XCTAssertNil(model.alert)
        XCTAssertNil(exposure(model), "another photo starts from its defaults")
        model.closeDocument()
    }

    func testAnyOtherLocateFailureIsAnAlert() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        services.relinkHandler = { _ in throw UserFacingError(code: "source_unreadable") }
        model.locateSource(b)
        await eventually { model.alert?.code == "source_unreadable" }
        XCTAssertNotNil(model.sourceUnavailable)
        model.closeDocument()
    }

    func testTheLocatePanelIsOpenedForLocatingNotForOpening() {
        let window = EditorWindowState()
        window.locateSource()
        XCTAssertTrue(window.isImporting)
        XCTAssertTrue(window.isLocating)
        // Cancelled: the panel never reports a choice, only that it closed.
        window.isImporting = false
        window.importPanelEnded()
        XCTAssertFalse(window.isLocating, "the next Open… is an ordinary open")
    }

    func testTheLocateButtonWaitsWhileTheChosenFileIsBeingChecked() async {
        let (model, services) = await opened()
        await becomeUnavailable(model, services)
        let handle = model.photo!.handle
        var release: CheckedContinuation<Void, Never>?
        services.relinkHandler = { url in
            await withCheckedContinuation { release = $0 }
            return EditorPhoto(url: url, name: url.lastPathComponent, formatLabel: "JPEG", byteCount: 1, handle: handle)
        }
        model.locateSource(b)
        await eventually { model.isRelinking && release != nil }
        model.locateSource(b)
        release?.resume()
        await eventually { !model.isRelinking }
        model.closeDocument()
    }

    func testARecordRefreshThatFindsTheFileMissingNoLongerCallsAnyVersionCurrent() async throws {
        let services = FakeEditorServices(openDelay: .zero)
        let model = EditorModel(services: services)
        await model.loadExportServices()
        model.open([a])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        let key = try await services.exportKey(model.photo!, options: model.effectiveOptions(), frame: nil)
        services.historyByURL[a] = [ExportHistoryItem(
            version: ExportVersion(number: 1, createdAt: Date(), encodingID: "adaptive",
                                   result: ExportResult(export: "v1", fileName: "a.heic", byteCount: 1, pixelSize: PixelSize(width: 1, height: 1))),
            key: key, options: model.exportChoices)]
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.exportVersions.first?.matchesCurrent == true }
        services.metadataHandler = { throw UserFacingError(code: "source_missing") }
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.sourceUnavailable != nil }
        XCTAssertEqual(model.exportVersions.first?.matchesCurrent, false, "so its settings can be restored")
        XCTAssertTrue(model.export.isResultStale || model.export.result == nil)
    }

    // MARK: The history

    func testAnExportHistoryRefreshThatFindsTheFileMissingKeepsTheListAndEntersTheState() async throws {
        let services = FakeEditorServices(openDelay: .zero)
        let model = EditorModel(services: services)
        await model.loadExportServices()
        model.open([a])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        let key = try await services.exportKey(model.photo!, options: model.effectiveOptions(), frame: nil)
        services.historyByURL[a] = [ExportHistoryItem(
            version: ExportVersion(number: 1, createdAt: Date(), encodingID: "adaptive",
                                   result: ExportResult(export: "v1", fileName: "a.heic", byteCount: 1, pixelSize: PixelSize(width: 1, height: 1))),
            key: key, options: model.exportChoices)]
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.exportVersions.count == 1 }
        services.metadataHandler = { throw UserFacingError(code: "source_missing") }
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.sourceUnavailable != nil }
        XCTAssertEqual(model.exportVersions.map(\.id), ["v1"], "the list is frozen, not emptied")
        XCTAssertNotNil(model.transferItem(for: "v1"), "a version can still be dragged out")
    }
}
