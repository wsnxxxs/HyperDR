import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import HyperDRDesign
@testable import HyperDR

/// The export views' decisions (M3-V): what the presentation says for each
/// state of the model, how an export starts and what cancelling the save
/// panel does, the lock's emphasis, paste, the Dock bar and the error
/// sentences by variant.
@MainActor final class ExportViewsTests: XCTestCase {
    private let en = Locale(identifier: "en")
    private let zh = Locale(identifier: "zh-Hans")
    private let source = URL(fileURLWithPath: "/tmp/first.jpg")
    private let target = URL(fileURLWithPath: "/tmp/chosen.heic")

    private func ready() async -> (EditorModel, FakeEditorServices) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        let model = EditorModel(services: services, ticker: ManualFrameTicker())
        await model.loadExportServices()
        model.open([source])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        return (model, services)
    }

    // MARK: Where a copy was saved (N3)

    func testTheSavedFolderIsTheNameTheServiceStoredAndUnknownWithoutOne() {
        let named = SavedLocation(fileName: "a.heic", folderLabel: "…/图片")
        XCTAssertEqual(ExportPresentation.savedFolder(named, locale: zh), "…/图片")
        XCTAssertEqual(ExportPresentation.savedFolder(SavedLocation(fileName: "a.heic", folderLabel: ""), locale: en), "Unknown location")
        XCTAssertEqual(ExportPresentation.savedFolder(SavedLocation(fileName: "a.heic", folderLabel: ""), locale: zh), "未知位置")
        XCTAssertEqual(ExportPresentation.savedFolder(nil, locale: en), "")
        XCTAssertEqual(ExportAnnouncer.folderName(named, locale: zh), "图片", "spoken without the path marks")
    }

    func testShowInFinderUsesTheSavedCopysOwnRevealAction() async {
        let (model, _) = await ready()
        var revealed = 0
        model.export.result = ExportResult(export: "v1", fileName: "a.heic", byteCount: 1, pixelSize: PixelSize(width: 1, height: 1),
            saved: SavedLocation(fileName: "a.heic", folderLabel: "…/Pictures", reveal: { revealed += 1 }))
        XCTAssertTrue(ExportFlow.canShowInFinder(model: model, version: "v1"))
        ExportFlow.showInFinder(model: model, version: "v1")
        XCTAssertEqual(revealed, 1)
        XCTAssertFalse(ExportFlow.canShowInFinder(model: model, version: "other"), "another version has no authority")
    }

    /// Without a reveal authority the button is off and nothing else finds the
    /// file: the view layer has no way to ask for an internal one.
    func testWithoutARevealAuthorityShowInFinderIsOff() async {
        let (model, _) = await ready()
        let saved = SavedLocation(fileName: "a.heic", folderLabel: "…/Pictures")
        XCTAssertFalse(saved.canReveal)
        model.export.result = ExportResult(export: "v1", fileName: "a.heic", byteCount: 1, pixelSize: PixelSize(width: 1, height: 1), saved: saved)
        XCTAssertFalse(ExportFlow.canShowInFinder(model: model, version: "v1"))
        ExportFlow.showInFinder(model: model, version: "v1")
    }

    // MARK: Presentation

    func testFormatGroupsFollowTheProcessingMode() {
        let hdr = ExportPresentation.groups(for: .hdr)
        XCTAssertEqual(hdr.map(\.ids), [["adaptive", "iso-gainmap-jpeg"], ["pq", "hlg", "avif-pq", "avif-hlg"]])
        XCTAssertEqual(hdr.map(\.columns), [2, 4])
        let color = ExportPresentation.groups(for: .colorOnly)
        XCTAssertEqual(color.map(\.ids), [["sdr-jpeg", "sdr-tiff"]])
        XCTAssertEqual(color.map(\.columns), [2])
        // Every format the preferences know has a card in one of the two modes.
        XCTAssertEqual(Set((hdr + color).flatMap(\.ids)), Set(Preferences.encodings))
    }

    func testTheFourHEVCReasonsAndTheirSentences() {
        let keys = ["err.server.hevc_unavailable", "err.server.hevc_main10_unavailable",
                    "err.server.hevc_probe_failed", "err.server.something_else"]
        XCTAssertEqual(keys.map { ExportPresentation.reason($0) }, [.hevc, .main10, .probe, .generic])
        let shorts = keys.map { AppStrings.string(ExportPresentation.shortReasonKey($0), locale: en) }
        XCTAssertEqual(shorts, ["No HEVC encoder", "No 10-bit HEVC", "HEVC check failed", "Not on this Mac"])
        XCTAssertEqual(AppStrings.string(ExportPresentation.shortReasonKey(keys[0]), locale: zh), "没有 HEVC 编码器")
        // The full reason names the format.
        let full = ExportPresentation.blockerText(keys[1], formatName: "HEIC PQ", locale: en)
        XCTAssertTrue(full.contains("HEIC PQ") && full.contains("10-bit HEVC"), full)
        XCTAssertTrue(ExportPresentation.isFormatReason(keys[0]))
        // A model sentence is shown as it is.
        XCTAssertEqual(ExportPresentation.blockerText("export.blocker.ai", formatName: "x", locale: en),
                       "Wait for AI processing to finish.")
        XCTAssertTrue(ExportPresentation.isFolderBlocker("err.server.export_folder_unset"))
        XCTAssertFalse(ExportPresentation.isFolderBlocker("export.blocker.ai"))
    }

    func testButtonTitlesFollowTheFormatAndWhetherASavePanelFollows() {
        XCTAssertEqual(ExportPresentation.primaryActionKey(encoding: "adaptive", asksForPlace: true), "export.action.exportEllipsis")
        XCTAssertEqual(ExportPresentation.primaryActionKey(encoding: "sdr-jpeg", asksForPlace: true), "export.action.saveJPEG")
        XCTAssertEqual(ExportPresentation.primaryActionKey(encoding: "sdr-tiff", asksForPlace: true), "export.action.saveTIFF")
        // A fixed folder has no second step, so no ellipsis.
        XCTAssertEqual(ExportPresentation.primaryActionKey(encoding: "sdr-jpeg", asksForPlace: false), "export.action.export")
        XCTAssertEqual(AppStrings.string("export.action.saveJPEG", locale: en), "Save JPEG…")
        XCTAssertEqual(AppStrings.string("export.toolbar.saveJPEG", locale: en), "Save JPEG")
        XCTAssertEqual(ExportPresentation.toolbarTitleKey(encoding: "pq"), "editor.export")
        XCTAssertEqual(ExportPresentation.toolbarTitleKey(encoding: "sdr-tiff"), "export.toolbar.saveTIFF")
    }

    func testTheSubtitleSaysWhereTheEditStands() {
        let expected: [DocumentStatus: String?] = [.waiting: nil, .notExported: "Not exported",
            .modifiedSinceExport: "Edited since export", .exportedNotSaved: "Exported, not saved", .saved: "Saved"]
        for (status, text) in expected {
            XCTAssertEqual(ExportPresentation.documentStatusKey(status, isExporting: false).map { AppStrings.string($0, locale: en) }, text)
        }
        // Running wins over whatever the status was.
        XCTAssertEqual(ExportPresentation.documentStatusKey(.saved, isExporting: true), "docStatus.exporting")
    }

    func testTheProgressBarIsStillWhenStoppingSweepsWithoutAnEstimateAndHoldsWhenOver() {
        let estimate = ExportEstimate(fraction: 0.4, remaining: .seconds(10), isOverdue: false)
        XCTAssertEqual(ExportPresentation.progressStyle(isStopping: false, estimate: estimate), .determinate(0.4))
        XCTAssertEqual(ExportPresentation.progressStyle(isStopping: false, estimate: nil), .indeterminate)
        XCTAssertEqual(ExportPresentation.progressStyle(isStopping: false,
            estimate: ExportEstimate(fraction: 0.99, remaining: .zero, isOverdue: true)), .overdue)
        XCTAssertEqual(ExportPresentation.progressStyle(isStopping: true, estimate: estimate), .stopped(0.4))
        XCTAssertEqual(ExportPresentation.progressStyle(isStopping: true, estimate: nil), .stopped(0))
        // No number without an estimate, and never 100 until it is done.
        XCTAssertNil(ExportPresentation.percent(estimate: nil, isDone: false))
        XCTAssertEqual(ExportPresentation.percent(estimate: ExportEstimate(fraction: 1, remaining: .zero, isOverdue: false), isDone: false), 0.99)
        XCTAssertEqual(ExportPresentation.percent(estimate: ExportEstimate(fraction: 1, remaining: .zero, isOverdue: false), isDone: true), 1)
    }

    func testTheStatusLineNamesTheStageTheTimeAndTheEstimate() {
        func line(_ phase: ExportState.Phase, _ stage: String?, _ workflow: Workflow = .hdr, estimate: ExportEstimate?,
                  elapsed: Double = 21, locale: Locale) -> String {
            ExportPresentation.statusLine(ExportPresentation.statusParts(phase: phase, stage: stage, workflow: workflow,
                estimate: estimate), elapsed: elapsed, locale: locale)
        }
        let seconds = ExportEstimate(fraction: 0.5, remaining: .seconds(8), isOverdue: false)
        XCTAssertEqual(line(.running, "process", estimate: seconds, locale: en), "Computing HDR · 0:21 elapsed · about 10 s left")
        XCTAssertEqual(line(.running, "process", .colorOnly, estimate: seconds, locale: en), "Grading · 0:21 elapsed · about 10 s left")
        XCTAssertEqual(line(.running, "process", estimate: seconds, locale: zh), "计算 HDR · 已用 0:21 · 约 10 秒后完成")
        XCTAssertEqual(line(.preparing, nil, estimate: nil, elapsed: 0, locale: en), "Preparing · 0:00 elapsed · first export, estimating the time")
        XCTAssertTrue(line(.running, "decode", estimate: ExportEstimate(fraction: 0.99, remaining: .zero, isOverdue: true), locale: en)
            .hasSuffix("almost done, a little longer than expected"))
        XCTAssertTrue(line(.running, "encode", estimate: ExportEstimate(fraction: 0.9, remaining: .seconds(2), isOverdue: false), locale: en)
            .hasSuffix("almost done"))
        XCTAssertTrue(line(.running, "verify", estimate: ExportEstimate(fraction: 0.5, remaining: .seconds(150), isOverdue: false), locale: en)
            .hasSuffix("about 3 min left"))
        // Writing to the chosen place has no estimate to give.
        XCTAssertEqual(line(.saving, "verify", estimate: ExportEstimate(fraction: 0.99, remaining: nil, isOverdue: false), elapsed: 75, locale: en),
                       "Saving… · 1:15 elapsed")
    }

    func testTheCanvasCapsuleReadsLikeTheStatusLine() {
        let estimate = ExportEstimate(fraction: 0.72, remaining: .seconds(8), isOverdue: false)
        let parts = ExportPresentation.statusParts(phase: .running, stage: "encode", workflow: .hdr, estimate: estimate)
        XCTAssertEqual(ExportPresentation.capsuleText(estimate: estimate, parts: parts, locale: en), "Exporting 72% · about 10 s left")
        XCTAssertEqual(ExportPresentation.capsuleText(estimate: estimate, parts: parts, locale: zh), "正在导出 72% · 约 10 秒后完成")
        let none = ExportPresentation.statusParts(phase: .running, stage: "encode", workflow: .hdr, estimate: nil)
        XCTAssertEqual(ExportPresentation.capsuleText(estimate: nil, parts: none, locale: en), "Exporting … · first export, estimating the time")
    }

    func testThePanelFollowsThePhase() {
        typealias Mode = ExportPresentation.PanelMode
        let modes = [ExportState.Phase.idle, .cancelled, .preparing, .running, .finishing, .saving, .succeeded, .failed].map(Mode.init(phase:))
        XCTAssertEqual(modes, [.settings, .settings, .progress, .progress, .progress, .progress, .result, .failure])
        XCTAssertEqual(Mode.settings.width, 760)
        XCTAssertEqual(Mode.progress.width, 560)
    }

    func testResultFactsAndPeakAreWordedInTheLanguage() {
        var result = ExportResult(export: "v", fileName: "a.jpg", byteCount: 18_400_000, pixelSize: PixelSize(width: 6000, height: 4000),
                                  headroomStops: 2.5, selfVerified: true, elapsed: .seconds(21.4))
        let facts = ExportPresentation.resultFacts(result, locale: en)
        XCTAssertEqual(facts.size, "6000 × 4000 · 18.4 MB")
        XCTAssertEqual(facts.peak?.ratio, "5.7")
        XCTAssertEqual(facts.peak?.stops, "+2.5 EV")
        XCTAssertTrue(facts.isVerified)
        XCTAssertEqual(facts.time, "0:21")
        result.headroomStops = nil
        XCTAssertNil(ExportPresentation.resultFacts(result, locale: en).peak, "an SDR file has no peak row")
        XCTAssertEqual(ExportPresentation.peak(stops: -0.5, locale: en).stops, "−0.5 EV")
    }

    func testHistoryMetaListsTheVersionsFacts() {
        var version = ExportVersion(number: 3, createdAt: Date(timeIntervalSince1970: 1_760_000_000), encodingID: "iso-gainmap-jpeg",
                                    result: ExportResult(export: "v3", fileName: "a.jpg", byteCount: 18_400_000,
                                                         pixelSize: PixelSize(width: 6000, height: 4000)))
        let manual = ExportPresentation.historyMeta(version, locale: en).replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(manual.contains("HDR JPEG · 6000 × 4000 · 18.4 MB · manual"), manual)
        version.modelName = "CNN"; version.hasFrame = true
        let ai = ExportPresentation.historyMeta(version, locale: en).replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(ai.hasSuffix("AI · CNN · this version has a frame"), ai)
        XCTAssertTrue(ExportPresentation.historyMeta(version, locale: zh).replacingOccurrences(of: "\u{00A0}", with: " ").contains("AI · CNN"))
        // A line may break before a dot, never after one: no plain space follows a dot, and "AI · CNN" is one piece.
        let raw = ExportPresentation.historyMeta(version, locale: en)
        XCTAssertFalse(raw.contains("· "), raw)
        XCTAssertTrue(raw.contains("AI\u{00A0}·\u{00A0}CNN"), raw)
    }

    // MARK: Errors

    func testErrorSentencesFollowTheVariantTheModelGave() {
        /// The sentence in English, whatever the language of the test run.
        func english(_ error: UserFacingError) -> String {
            var message = ErrorText(error).message
            message.locale = en
            return String(localized: message)
        }
        let frame = english(UserFacingError(code: "export_memory_budget", variant: "frame"))
        let plain = english(UserFacingError(code: "export_memory_budget", variant: "noFrame"))
        XCTAssertTrue(frame.contains("Remove the frame"), frame)
        XCTAssertTrue(plain.contains("Close other apps"), plain)
        XCTAssertEqual(english(UserFacingError(code: "export_memory_budget")), plain,
                       "an unmarked error is read as an export without a frame")
        let jpeg = english(UserFacingError(code: "export_dimension_limit"))
        let color = english(UserFacingError(code: "export_dimension_limit", variant: "color"))
        XCTAssertTrue(jpeg.contains("HEIC or TIFF"), jpeg)
        XCTAssertTrue(color.contains("16-bit TIFF"), color)
        for code in ["export_failed", "convert_timeout", "export_dimension_limit", "export_memory_budget"] {
            XCTAssertTrue(ErrorText.isKnown(code), code)
        }
        // The engine's last line stays the secondary text.
        XCTAssertEqual(ErrorText(UserFacingError(code: "export_failed", detail: "engine said no")).detail, "engine said no")
    }

    // MARK: Starting an export

    func testCancellingTheSavePanelStartsNothingAndConfirmingStartsAtThatFile() async {
        let (model, services) = await ready()
        var asked: [(String, UTType)] = []
        var finish: ((URL?) -> Void)?
        let chooser: ExportSavePanel.Chooser = { name, type, completion in asked.append((name, type)); finish = completion }
        ExportFlow.begin(model: model, choosePlace: chooser)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, model.suggestedFileName)
        XCTAssertEqual(asked.first?.1, model.exportContentType)
        finish?(nil)
        XCTAssertTrue(services.exportCalls.isEmpty, "cancel makes no job")
        XCTAssertEqual(model.export.phase, .idle)
        XCTAssertTrue(model.exportVersions.isEmpty)
        finish?(target)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
        XCTAssertEqual(services.exportCalls.first?.destination, target)
        XCTAssertTrue(model.export.isInFlight)
    }

    func testASaveFailureIsWordedAndOfferedSettingsByTheModelsMarkNotThePreference() {
        let chosen = UserFacingError(code: "export_folder_unwritable", detail: "x", variant: "destination")
        let fixed = UserFacingError(code: "export_folder_unwritable")
        // A chosen place that failed while the preference says "folder": Save As… only, and no Settings.
        for mode in [Preferences.SaveMode.ask, .folder] {
            let wording = ExportPresentation.saveFailure(chosen, mode: mode, locale: en)
            XCTAssertTrue(wording.sentence.hasPrefix("Not saved: HyperDR can’t write to the chosen location"), "\(mode)")
            XCTAssertFalse(wording.offersSettings, "\(mode)")
        }
        // The fixed folder that failed while the preference says "ask": its own sentence and Settings.
        for mode in [Preferences.SaveMode.ask, .folder] {
            let wording = ExportPresentation.saveFailure(fixed, mode: mode, locale: en)
            XCTAssertTrue(wording.sentence.contains("chosen folder"), "\(mode)")
            XCTAssertTrue(wording.offersSettings, "\(mode)")
        }
        let expired = ExportPresentation.saveFailure(UserFacingError(code: "session_expired"), mode: .ask, locale: en)
        XCTAssertFalse(expired.offersSettings)
        XCTAssertNotEqual(expired.sentence, AppStrings.string("export.save.failed", locale: en))
        XCTAssertEqual(ErrorText(chosen).body(locale: en).split(separator: "\n").first.map(String.init),
                       "HyperDR can’t write to the chosen location. Choose another location and try again.")
    }

    func testAHistoryNoteNamesTheMissingFieldsOrSaysTheModelFellBack() {
        let model = EditorModel(services: ScriptedEditorServices())
        let known = ExportPresentation.fallbackNote(ExportFallbackReason(code: .missingCaptureFields,
            missingCaptureFields: ["iso", "f_number"]), model: model, locale: en)
        XCTAssertTrue(known.contains("ISO") && known.contains("aperture"), known)
        let unknown = ExportPresentation.fallbackNote(ExportFallbackReason(code: .unknown, missingCaptureFields: []), model: model, locale: en)
        XCTAssertTrue(unknown.hasPrefix("Couldn’t use the selected model, so "), unknown)
        XCTAssertFalse(unknown.contains("%"), "the model's name fills the sentence")
        XCTAssertTrue(ExportPresentation.fallbackNote(ExportFallbackReason(code: .unknown, missingCaptureFields: []), model: model, locale: zh)
            .hasPrefix("未能使用所选模型，已改用"))
        XCTAssertTrue(known.hasPrefix("Some capture data is missing (ISO and aperture), so "), known)
    }

    func testASavePanelAnsweredAfterThePhotoChangedStartsNothing() async {
        let (model, services) = await ready()
        var finish: ((URL?) -> Void)?
        ExportFlow.begin(model: model) { _, _, completion in finish = completion }
        XCTAssertNotNil(finish)
        model.open([URL(fileURLWithPath: "/tmp/second.jpg")])
        await eventually(timeout: .seconds(10)) { model.document?.name == "second.jpg" && model.document?.phase == .ready }
        finish?(target)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(services.exportCalls.isEmpty, "the panel was for the first photo")
        XCTAssertEqual(model.export.phase, .idle)
    }

    func testAFixedFolderStartsWithoutAskingForAPlace() async {
        let (model, services) = await ready()
        var p = model.preferences.value; p.saveMode = .folder
        services.folder = ExportFolder(label: "…/Pictures/HyperDR", ready: true)
        model.updatePreferences(p)
        await model.loadExportServices()
        var asked = false
        ExportFlow.begin(model: model) { _, _, _ in asked = true }
        XCTAssertFalse(asked)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
        XCTAssertNil(services.exportCalls.first?.destination)
    }

    func testABlockedExportNeverOpensTheSavePanel() async {
        let (model, _) = await ready()
        model.selectEncoding("sdr-jpeg")
        var p = model.preferences.value; p.saveMode = .folder
        model.updatePreferences(p)   // a fixed folder that is not set is a blocker
        XCTAssertNotNil(model.export.blockerKey)
        var asked = false
        ExportFlow.begin(model: model) { _, _, _ in asked = true }
        XCTAssertFalse(asked)
        XCTAssertEqual(model.export.phase, .idle)
    }

    // MARK: The lock's flash

    func testTheLockFlashesAndFallsBackBySelf() async {
        let window = EditorWindowState()
        XCTAssertFalse(window.isEmphasizingLock)
        window.emphasizeLock()
        XCTAssertTrue(window.isEmphasizingLock)
        await eventually(timeout: .seconds(3), "the flash falls back") { !window.isEmphasizingLock }
    }

    func testTheExportCommandOpensThePanel() {
        let window = EditorWindowState()
        window.openExport()
        XCTAssertTrue(window.showsExport)
    }

    // MARK: Paste

    func testPastingPictureDataOnlyGivesTheHintNotAnAlert() async {
        let (model, _) = await ready()
        PasteImport.interpret(urls: [], hasImageData: true, model: model)
        XCTAssertEqual(model.notice, .clipboardImageUnsupported)
        XCTAssertNil(model.alert)
        XCTAssertEqual(AppStrings.string("paste.imageData", locale: en).hasPrefix("The clipboard holds image content"), true)
    }

    func testPastingAnOpenableFileOpensItAndAnUnsupportedOneAlerts() async {
        let (model, _) = await ready()
        let other = URL(fileURLWithPath: "/tmp/second.jpg")
        PasteImport.interpret(urls: [other], hasImageData: false, model: model)
        await eventually(timeout: .seconds(10)) { model.document?.name == "second.jpg" }
        PasteImport.interpret(urls: [URL(fileURLWithPath: "/tmp/notes.txt")], hasImageData: false, model: model)
        await eventually(timeout: .seconds(5), "the same alert a drop gives") { model.alert != nil }
    }

    func testPastedProvidersAreReadAsFileURLs() async throws {
        let (model, _) = await ready()
        let provider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/third.jpg") as NSURL)
        PasteImport.handle([provider], model: model)
        await eventually(timeout: .seconds(10)) { model.document?.name == "third.jpg" }
    }

    // MARK: Dock

    func testTheDockBarFollowsTheExportAndTheIconJumpsOnlyInTheBackground() {
        let estimate = ExportEstimate(fraction: 0.4, remaining: .seconds(5), isOverdue: false)
        XCTAssertEqual(DockProgress.bar(phase: .running, estimate: estimate), .determinate(0.4))
        XCTAssertEqual(DockProgress.bar(phase: .preparing, estimate: nil), .indeterminate)
        XCTAssertEqual(DockProgress.bar(phase: .saving, estimate: ExportEstimate(fraction: 0.99, remaining: nil, isOverdue: false)), .determinate(0.99))
        for phase in [ExportState.Phase.idle, .succeeded, .failed, .cancelled] {
            XCTAssertEqual(DockProgress.bar(phase: phase, estimate: estimate), .none, "\(phase)")
        }
        XCTAssertTrue(DockProgress.shouldBounce(from: .running, to: .succeeded, appIsActive: false))
        XCTAssertTrue(DockProgress.shouldBounce(from: .saving, to: .failed, appIsActive: false))
        XCTAssertFalse(DockProgress.shouldBounce(from: .running, to: .succeeded, appIsActive: true))
        XCTAssertFalse(DockProgress.shouldBounce(from: .running, to: .cancelled, appIsActive: false), "a stop the user asked for")
        XCTAssertFalse(DockProgress.shouldBounce(from: .idle, to: .succeeded, appIsActive: false))
    }

    // MARK: Photo switch

    func testThePhotoSwitchQuestionNamesTheFileAndTheExport() async throws {
        let (model, services) = await ready()
        model.startExport(destination: target, token: model.prepareExport()!)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
        let other = URL(fileURLWithPath: "/tmp/IMG_2041.HEIC")
        model.open([other])
        XCTAssertEqual(model.pendingPhotoSwitch?.kind, .open(other))
        XCTAssertEqual(model.pendingPhotoSwitch?.displayName, "IMG_2041.HEIC")
        XCTAssertEqual(AppStrings.string(PhotoSwitchAlert.stopKey(try XCTUnwrap(model.pendingPhotoSwitch)), locale: en),
                       "Stop Export and Open")
        XCTAssertEqual(AppStrings.format("switchPhoto.open %@", locale: en, "IMG_2041.HEIC"),
                       "Opening “IMG_2041.HEIC” stops this export. The unfinished file won’t be saved.")
        model.resolvePhotoSwitch(stop: false)
        XCTAssertNil(model.pendingPhotoSwitch)
        XCTAssertTrue(model.export.isInFlight, "keep exporting")
        XCTAssertEqual(AppStrings.string(PhotoSwitchAlert.stopKey(PhotoSwitchRequest(kind: .close, displayName: "x")), locale: en),
                       "Stop Export and Close")
    }
}
