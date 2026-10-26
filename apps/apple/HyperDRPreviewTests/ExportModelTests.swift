import AppKit
import XCTest
import HyperDRDesign
import HyperDRKit
import HyperDRRecipe
import HyperDRRender
@testable import HyperDR

@MainActor final class ExportModelTests: XCTestCase {
    let source = URL(fileURLWithPath: "/tmp/first.jpg")
    let second = URL(fileURLWithPath: "/tmp/second.jpg")
    let target = URL(fileURLWithPath: "/tmp/result.heic")
    func ready(_ services: FakeEditorServices? = nil) async -> (EditorModel, FakeEditorServices) {
        let s = services ?? FakeEditorServices(openDelay: .zero)
        let m = EditorModel(services: s)
        await m.loadExportServices()
        m.open([source])
        await eventually(timeout: .seconds(10)) { m.document?.phase == .ready && !m.suggestedFileName.isEmpty }
        return (m,s)
    }
    func running(_ m: EditorModel, _ s: FakeEditorServices, destination: URL? = nil) async {
        startPreparedExport(m, destination: destination ?? target)
        await eventually(timeout: .seconds(10)) { s.hasExportSubscriber }
    }
    func result(_ id: String = "version") -> ExportResult {
        ExportResult(export: id, fileName: "result.heic", byteCount: 100, pixelSize: PixelSize(width: 6000, height: 4000))
    }
    func testNilSavePanelCancellationDoesNotStartAnything() async {
        let (m,s) = await ready()
        startPreparedExport(m, destination: nil)
        XCTAssertTrue(s.exportCalls.isEmpty); XCTAssertEqual(m.export.phase, .idle)
    }
    func testDestinationIsForwardedAndSelectedDeliveryNeverSavesTwice() async {
        let (m,s) = await ready()
        await running(m,s)
        XCTAssertEqual(s.exportCalls.first?.destination, target)
        s.sendExport(.finishing)
        await eventually(timeout: .seconds(10)) { m.export.phase == .finishing }
        s.sendExport(.saving)
        await eventually(timeout: .seconds(10)) { m.export.phase == .saving }
        var r = result(); r.saved = SavedLocation(fileName: "result.heic", folderLabel: "Chosen")
        s.sendExport(.finished(result: r, failure: nil))
        await eventually(timeout: .seconds(10)) { !m.export.isInFlight }
        XCTAssertEqual(m.export.result?.saved?.folderLabel, "Chosen"); XCTAssertTrue(s.saveCalls.isEmpty)
        XCTAssertEqual(m.export.phase, .succeeded)
    }
    func testExportLocksEditsUndoFrameAndLUTButKeepsViewerAndOpenEnabled() async {
        let (m,s) = await ready()
        m.adjustRecipe("tone.exposure", to: 1)
        await running(m,s)
        let before = m.exportChoices; let frame = m.frame
        XCTAssertEqual(m.editingLockReason, .exporting); XCTAssertTrue(m.isEditingLocked)
        XCTAssertTrue(m.canOpenDocument); XCTAssertFalse(m.canUndo)
        let recipe = m.editor.recipe
        m.selectEncoding("sdr-tiff"); m.resetAll(); m.undo()
        XCTAssertEqual(m.editor.recipe, recipe)
        var newFrame = frame; newFrame.isEnabled.toggle(); m.frame = newFrame
        XCTAssertEqual(m.exportChoices,before); XCTAssertEqual(m.frame,frame)
        XCTAssertEqual(m.lut.importBlockerKey, "lut.importBlocker.exporting")
        await m.importLUTs([URL(fileURLWithPath: "/tmp/a.cube")])
        XCTAssertTrue(s.library.isEmpty)
        m.setSplitRatio(0.75); m.beginPeekOriginal(); m.showsHighlightZebra = true; m.previewsAsSDR = true
        XCTAssertEqual(m.splitRatio,0.75); XCTAssertTrue(m.isPeekingOriginal); XCTAssertTrue(m.showsHighlightZebra)
        m.canvas.zoomIn()
        s.sendExport(.finished(result: result(), failure: nil))
        await eventually(timeout: .seconds(10)) { !m.isEditingLocked }
        XCTAssertTrue(m.canUndo)
    }
    func testContinueExportDiscardsTheSwitchAndLatestRequestReplacesPrevious() async {
        let (m,s) = await ready(); await running(m,s)
        m.open([second]); XCTAssertEqual(m.pendingPhotoSwitch?.kind,.open(second))
        m.closeDocument(); XCTAssertEqual(m.pendingPhotoSwitch?.kind,.close)
        m.open([URL(fileURLWithPath: "/tmp/a.txt"), second])
        XCTAssertEqual(m.pendingPhotoSwitch?.kind,.open(second))
        m.resolvePhotoSwitch(stop:false)
        XCTAssertNil(m.pendingPhotoSwitch); XCTAssertEqual(m.photo?.url,source); XCTAssertEqual(s.exportCancelCount,0)
        s.sendExport(.finished(result:result(),failure:nil))
        await eventually(timeout:.seconds(10)) { !m.export.isInFlight }
        XCTAssertEqual(m.photo?.url,source)
    }
    func testStoppingSwitchWaitsForCancellationCleanupThenOpensLatestFile() async {
        let (m,s) = await ready(); let gate = ExportModelGate()
        s.exportCancelHandler = { await gate.wait() }
        await running(m,s)
        m.open([second]); m.resolvePhotoSwitch(stop:true)
        await eventually(timeout:.seconds(10)) { gate.isWaiting }
        XCTAssertEqual(m.photo?.url,source); XCTAssertTrue(m.export.isStopping)
        let latest = URL(fileURLWithPath:"/tmp/latest.jpg"); m.open([latest])
        gate.release()
        await eventually(timeout:.seconds(10)) { m.photo?.url == latest && m.document?.phase == .ready }
        XCTAssertNil(m.pendingPhotoSwitch); XCTAssertEqual(s.exportCancelCount,1)
    }
    func testNaturalCompletionAutomaticallyOpensOrClosesPendingPhoto() async {
        for closes in [false,true] {
            let (m,s) = await ready(); await running(m,s)
            if closes { m.closeDocument() } else { m.open([second]) }
            s.sendExport(.finished(result:result(),failure:nil))
            await eventually(timeout:.seconds(10)) { closes ? m.document == nil : m.photo?.url == self.second }
            XCTAssertNil(m.pendingPhotoSwitch); XCTAssertEqual(s.exportCancelCount,0)
        }
    }
    func testPreparationCancellationDoesNotOpenUntilTheStartCallDrains() async {
        let (m,s) = await ready(); let gate = ExportModelGate()
        s.exportStartHandler = { await gate.wait() }
        startPreparedExport(m, destination:target)
        await eventually(timeout:.seconds(10)) { gate.isWaiting }
        m.open([second]); m.resolvePhotoSwitch(stop:true)
        await eventually(timeout:.seconds(10)) { s.exportCancelCount == 1 }
        XCTAssertEqual(m.photo?.url,source)
        gate.release()
        await eventually(timeout:.seconds(10)) { m.photo?.url == self.second }
    }
    func testSaveFailureRetainsResultAndCancellationHasNoOutcomeCard() async {
        let (m,s) = await ready(); await running(m,s)
        s.sendExport(.finished(result:result(),failure:UserFacingError(code:"export_folder_unwritable",variant:"destination")))
        await eventually(timeout:.seconds(10)) { m.export.phase == .succeeded }
        XCTAssertNotNil(m.export.result); XCTAssertEqual(m.export.saveFailure?.code,"export_folder_unwritable")
        XCTAssertEqual(m.export.saveFailure?.variant, "destination")
        m.export.dismissOutcome(); XCTAssertEqual(m.export.phase,.idle); XCTAssertNotNil(m.export.result)
        await running(m,s)
        s.sendExport(.finished(result:result(),failure:UserFacingError(code:"cancelled")))
        await eventually(timeout:.seconds(10)) { m.export.phase == .cancelled }
        XCTAssertNil(m.export.result); XCTAssertNil(m.export.failure)
    }
    func testFixedFolderSaveIsObservedAndCanBeStoppedBeforeSwitch() async {
        let (m,s) = await ready(); let gate = ExportModelGate()
        s.exportSaveHandler = { _,_ in await gate.wait(); try Task.checkCancellation(); return SavedLocation(fileName:"fixed.heic",folderLabel:"fixed") }
        var p=m.preferences.value; p.saveMode = .folder
        _ = try? await s.setExportFolder(URL(fileURLWithPath:"/tmp/fixed"))
        await m.setExportFolder(URL(fileURLWithPath:"/tmp/fixed")); m.updatePreferences(p)
        startPreparedExport(m, destination:nil)
        await eventually(timeout:.seconds(10)) { s.hasExportSubscriber }
        XCTAssertNil(s.exportCalls.last?.destination)
        s.sendExport(.finished(result:result(),failure:nil))
        await eventually(timeout:.seconds(10)) { gate.isWaiting && m.export.phase == .saving }
        m.open([second]);m.resolvePhotoSwitch(stop:true)
        XCTAssertEqual(m.photo?.url,source)
        gate.release()
        await eventually(timeout:.seconds(10)) { m.photo?.url == self.second }
        XCTAssertEqual(s.saveCalls.count,1)
    }
    func testExportFailureUsesSnapshotVariantAndLastLogDetail() async {
        let (m,s) = await ready(); m.selectEncoding("sdr-jpeg")
        await running(m,s,destination:URL(fileURLWithPath:"/tmp/out.jpg"))
        s.sendExport(.log("last engine line")); s.sendExport(.finished(result:nil,failure:UserFacingError(code:"export_dimension_limit")))
        await eventually(timeout:.seconds(10)) { m.export.phase == .failed }
        XCTAssertEqual(m.export.failure?.variant,"color"); XCTAssertEqual(m.export.failure?.detail,"last engine line")
        m.export.dismissOutcome()
        await running(m,s,destination:URL(fileURLWithPath:"/tmp/out.jpg"))
        s.sendExport(.finished(result:nil,failure:UserFacingError(code:"export_memory_budget")))
        await eventually(timeout:.seconds(10)) { m.export.phase == .failed }
        XCTAssertEqual(m.export.failure?.variant,"noFrame")
        m.export.dismissOutcome(); m.selectEncoding("avif-pq")
        await running(m,s,destination:URL(fileURLWithPath:"/tmp/out.avif"))
        s.sendExport(.finished(result:nil,failure:UserFacingError(code:"export_dimension_limit")))
        await eventually(timeout:.seconds(10)) { m.export.phase == .failed }
        XCTAssertEqual(m.export.failure?.variant,"avif")
    }
    func testPreviewRefreshDoesNotBlockExportAndInvalidTargetDoesNotReachKit() async {
        let (m,s) = await ready(); m.requestBusy()
        XCTAssertNil(m.export.blockerKey)
        startPreparedExport(m, destination:URL(fileURLWithPath:"/tmp/wrong.jpg"))
        await eventually(timeout:.seconds(10)) { m.export.phase == .failed }
        XCTAssertEqual(m.export.failure?.code,"invalid_options");XCTAssertTrue(s.exportCalls.isEmpty)
    }
    func testCurrentPhotoHistoryRestoreAndAutomaticResultAreLatestWins() async throws {
        let (m,s) = await ready()
        let initial=m.exportChoices
        let key=try await s.exportKey(m)
        let item=ExportHistoryItem(version:ExportVersion(number:7,createdAt:Date(),encodingID:"adaptive",result:result()),recipeSnapshot: key,options:initial)
        s.historyByURL[source]=[item];m.refreshExportMetadata()
        await eventually(timeout:.seconds(10)) { m.exportVersions.first?.matchesCurrent == true }
        XCTAssertEqual(m.exportVersions.first?.number,7);XCTAssertEqual(m.documentStatus,.exportedNotSaved)
        m.setExportQuality(55)
        await eventually(timeout:.seconds(10)) { m.exportVersions.first?.matchesCurrent == false }
        XCTAssertTrue(m.export.isResultStale);XCTAssertEqual(m.documentStatus,.modifiedSinceExport)
        m.adjustRecipe("tone.exposure", to: 1.5)
        await settle() // the model sees the edit before the restore
        // Restoring brings back the version's recipe and format (P7-3b-U), as one undo step.
        m.restore("version")
        XCTAssertEqual(m.exportChoices,initial);XCTAssertNotEqual(m.recipeNumber("tone.exposure"),1.5)
        await eventually(timeout:.seconds(10)) { m.exportVersions.first?.matchesCurrent == true }
        m.undo()
        XCTAssertEqual(m.recipeNumber("tone.exposure"),1.5)
        m.open([second])
        await eventually(timeout:.seconds(10)) { m.photo?.url == self.second && !m.suggestedFileName.isEmpty }
        XCTAssertTrue(m.exportVersions.isEmpty);XCTAssertNil(m.export.result)
    }
    /// R36-001: a version's look whose LUT left the library comes back from
    /// the photo's own copy, so the restored recipe previews and exports.
    func testRestoringALookThatLeftTheLibraryInstallsThePhotosCopy() async throws {
        let (m,s) = await ready()
        let lut=try ColorLUT(cube:"LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        s.sessionLUTs[lut.contentHash]=lut
        let key=try await s.exportKey(m)
        var recipe=key.recipe;recipe.look=LUTReference(contentHash:lut.contentHash,name:"Gone")
        let made=RecipeExportSnapshot(recipe:recipe,source:key.source)
        s.historyByURL[source]=[ExportHistoryItem(version:ExportVersion(number:3,createdAt:Date(),encodingID:"adaptive",result:result()),
                                                  recipeSnapshot:made,options:m.exportChoices)]
        m.refreshExportMetadata()
        await eventually(timeout:.seconds(10)) { m.exportVersions.count == 1 }
        m.restore("version")
        await eventually(timeout:.seconds(10)) { m.editor.recipe.look == recipe.look }
        XCTAssertNoThrow(try m.captureExport());XCTAssertTrue(m.lut.failures.isEmpty)
        m.undo();XCTAssertNil(m.editor.recipe.look,"the restore is one undo step")
    }
    /// R36-002: the gamut the panel shows is the one the planner writes, and
    /// a version made from the current choices matches them.
    func testChoicesGamutIsThePlannersAndAVersionMatchesTheChoicesThatMadeIt() {
        for encoding in ExportEncoding.allCases { for hdr in [true,false] { for gamut in ["auto","srgb","p3"] {
            var c=ExportChoices();c.encoding=encoding.rawValue;c.outputGamut=gamut
            let plan=ExportPlanner.plan(ExportPlanRequest(choice:.custom(c.customFormat),
                source:.init(domain:.sdr,pixelSize:.init(width:96,height:64)),edit:.init(hdrEnabled:hdr,peakStops:hdr ? 2 : 0)))
            XCTAssertEqual(plan.gamut,c.gamut,"\(encoding) hdr \(hdr) \(gamut)")
            let resolved=ResolvedExportSnapshot(snapshot:RecipeExportSnapshot(recipe:Recipe(),
                source:RecipeSourceRevision(sha256:"a",byteCount:1,modificationDate:Date())),plan:plan)
            XCTAssertEqual(ExportChoices(resolved).customFormat,c.customFormat,"\(encoding) hdr \(hdr) \(gamut)")
        }}}
    }
    /// The custom format's long edge (p7-3c-export §1.3 B): the picker's
    /// choices, what a typed number becomes, the format Kit plans from, and
    /// the memory blocker's largest admitted long edge.
    func testLongEdgeChoicesTheFormatAndTheMemoryAction() async throws {
        XCTAssertEqual(ExportLongEdge.choices(photo: 3000, current: nil), [nil, 2560, 2160, 1080])
        XCTAssertEqual(ExportLongEdge.choices(photo: 3000, current: 1234), [nil, 2560, 2160, 1234, 1080])
        XCTAssertEqual(ExportLongEdge.choices(photo: nil, current: nil), [nil, 3840, 2560, 2160, 1080])
        XCTAssertNil(ExportLongEdge.normalized(3000, photo: 3000))
        XCTAssertNil(ExportLongEdge.normalized(0, photo: 3000))
        XCTAssertNil(ExportLongEdge.normalized(nil, photo: 3000))
        XCTAssertEqual(ExportLongEdge.normalized(2999, photo: 3000), 2999)

        let (m,_) = await ready()
        let photo = try XCTUnwrap(m.exportPhotoLongEdge)
        m.setExportLongEdge(photo + 10)
        XCTAssertNil(m.exportChoices.longEdge, "never larger than the photo")
        m.setExportLongEdge(photo - 1)
        XCTAssertEqual(m.export.longEdge, photo - 1)
        XCTAssertEqual(m.exportChoices.customFormat.longEdge, photo - 1)
        XCTAssertEqual(try m.captureExport().request.choice.customFormat?.longEdge, photo - 1)
        XCTAssertEqual(ExportChoices(m.exportChoices.customFormat), m.exportChoices, "a version restores its size")

        var request = ExportPlanRequest(choice: .custom(.init(encoding: .avifPq)),
            source: .init(domain: .sdr, pixelSize: .init(width: 6000, height: 4000)), edit: .init(hdrEnabled: true, peakStops: 2))
        // AVIF rows hold no whole planes: refuse one byte below what the photo needs.
        guard case .memory(let needed, _, _, _)? = ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: 1))
            .blockers.first(where: { $0.code == "export_memory_exceeded" }) else { return XCTFail("AVIF admission") }
        let budget = FixedExportMemoryBudget(bytes: needed - 1)
        let refused = ExportPlanner.plan(request, budget: budget)
        XCTAssertNotNil(ExportLongEdge.memoryBlocker(refused))
        let edge = try XCTUnwrap(ExportLongEdge.admissible(refused))
        request.choice = .custom(.init(encoding: .avifPq, longEdge: edge))
        XCTAssertNil(ExportLongEdge.memoryBlocker(ExportPlanner.plan(request, budget: budget)))
        XCTAssertNil(ExportLongEdge.admissible(ExportPlanner.plan(request, budget: FixedExportMemoryBudget(bytes: 8_000_000_000))))
    }
    /// A run that ran out of memory offers the largest long edge that fits
    /// (Kit's typed refusal); Kit's reasons read in the shared words; the
    /// plan request carries the encoder facts (K6).
    func testOutOfMemoryCarriesTheLongEdgeAndTheReasonsTheirWords() async throws {
        let error = UserFacingError(RecipeExportError.memoryExceeded(.memory(needed: 5_000_000_000, available: 1_000_000_000,
            size: .init(width: 6000, height: 4000), maxLongEdge: 2400)))
        XCTAssertEqual(error.code, "export_memory_budget")
        XCTAssertEqual(error.suggestedLongEdge, 2400)
        let (m,s) = await ready()
        XCTAssertEqual(try m.captureExport().request.capabilities, m.exportCapabilities?.exportFacts)
        await running(m,s)
        s.sendExport(.finished(result: nil, failure: error))
        await eventually(timeout: .seconds(10)) { m.export.phase == .failed }
        XCTAssertEqual(m.export.failure?.suggestedLongEdge, 2400)

        XCTAssertEqual(ExportBlockReason.photosNotAvailable(.notVerified).destinationShortPhrase, .notYetAvailable)
        XCTAssertNil(ExportBlockReason.hdrOff(.pq).destinationShortPhrase)
        XCTAssertEqual(ExportBlockReason.encoderUnavailable(.pq, .main10Unavailable).phrase, .hevcMain10Unavailable)
        XCTAssertEqual(ExportNotice.ceiling(stops: 3, scope: .format(.pq)).phrase, .ceiling(stops: "+3", byFormat: true))
        XCTAssertEqual(ExportBlockReason.memory(needed: 3_100_000_000, available: 900_000_000, size: .init(width: 1, height: 1),
            maxLongEdge: 10).phrase, .memory(needed: "3.1 GB", available: "900 MB"))
    }
    /// R36-003: Render's errors read as the messages Kit's already had.
    func testRenderErrorsMapToExistingMessages() {
        XCTAssertEqual(UserFacingError.service(RenderError.sourceChanged).code,"source_changed")
        XCTAssertEqual(UserFacingError.service(RenderError.cannotOpenSource).code,"source_unreadable")
        XCTAssertEqual(UserFacingError.service(RenderError.cannotDecodeSource).code,"decode_failed")
        XCTAssertEqual(UserFacingError.service(RenderError.invalidSize).code,"internal_error")
        XCTAssertEqual(UserFacingError.service(RenderError.invalidRegion).code,"internal_error")
        XCTAssertEqual(UserFacingError.service(RenderError.allocationFailed).code,"out_of_memory")
        XCTAssertEqual(UserFacingError.service(RenderError.aiNotAvailable).code,"model_not_ready")
    }
    func testCapabilitiesUseSourceBitDepthAndKeepUnavailableSelection() async {
        let (m,s)=await ready()
        var c=try! await s.encodingCapabilities();c.main8=true;c.main10=false;c.encoderReason="hevc_main10_unavailable"
        m.exportCapabilities=c;m.syncExportState()
        XCTAssertNil(m.export.encodingAvailability["adaptive"]!)
        XCTAssertEqual(m.export.encodingAvailability["pq"]!,"err.server.hevc_main10_unavailable")
        m.source.domain = .hdr;m.syncExportState()
        XCTAssertEqual(m.export.encodingAvailability["adaptive"]!,"err.server.hevc_main10_unavailable")
        XCTAssertEqual(m.exportChoices.encoding,"adaptive");XCTAssertNotNil(m.export.blockerKey)
    }
    func testEmptyWorkspaceAllowsLibraryImportAndImagePasteIsNotice() async {
        let s=FakeEditorServices(); let m=EditorModel(services:s)
        XCTAssertNil(m.editingLockReason);XCTAssertFalse(m.isEditingLocked)
        s.importedLUT=LUTItem(id:"a",name:"A",input:.srgb,output:.srgb)
        await m.importLUTs([URL(fileURLWithPath:"/tmp/a.cube")]);XCTAssertEqual(m.lut.library.count,1)
        m.pasteFiles([],containsImageData:true);XCTAssertEqual(m.notice,.clipboardImageUnsupported);XCTAssertNil(m.alert)
    }
    func testTerminationContinuesOrWaitsForCancellationAtAllPhases() async {
        for phase in [ExportState.Phase.preparing,.running,.finishing,.saving] {
            let (m,s)=await ready();m.export.phase=phase
            let gate=ExportModelGate();s.exportCancelHandler={ await gate.wait() }
            let coordinator=TerminationCoordinator(); var reply:Bool?
            coordinator.request(editor:m,confirmStop:{false},reply:{reply=$0})
            await eventually(timeout:.seconds(10)) { reply != nil }
            XCTAssertEqual(reply,false);XCTAssertEqual(s.exportCancelCount,0)
            reply=nil
            coordinator.request(editor:m,confirmStop:{true},reply:{reply=$0})
            await eventually(timeout:.seconds(10)) { gate.isWaiting }
            XCTAssertNil(reply);gate.release()
            await eventually(timeout:.seconds(10)) { reply == true }
        }
    }
    func testSessionExpiredClearsCanvasAndReportsReopen() async {
        let (m,s)=await ready();await running(m,s)
        s.sendExport(.finished(result:nil,failure:UserFacingError(code:"session_expired")))
        await eventually(timeout:.seconds(10)) { m.document == nil }
        XCTAssertEqual(m.alert?.code,"session_expired");XCTAssertFalse(m.hasEditedFrame)
    }
}

@MainActor private final class ExportModelGate {
    private var continuation: CheckedContinuation<Void,Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation=$0 } }
    func release() { let c=continuation;continuation=nil;c?.resume() }
}

@MainActor extension ExportModelTests {
    /// A plan Kit refuses reads as the message its blocker already has.
    func testPlanBlockersMapToTheirOwnMessages() {
        XCTAssertEqual(UserFacingError.service(RecipeExportError.planBlocked(["export_memory_exceeded"])).code, "export_memory_budget")
        XCTAssertEqual(UserFacingError.service(RecipeExportError.planBlocked(["unsupported_format"])).code, "unsupported_format")
        XCTAssertEqual(UserFacingError.service(RecipeExportError.planBlocked(["other"])).code, "export_failed")
    }
    func testFrameExportCarriesSnapshotAndSelectsFrameMemoryVariant() async {
        let (m,s)=await ready()
        var frame=m.frame;frame.isEnabled=true;frame.showsCamera=false;frame.showsExposure=false;frame.showsDate=false
        m.frame=frame
        await running(m,s)
        XCTAssertNotNil(s.exportCalls[0].job.snapshot.frame)
        XCTAssertEqual(m.frame,frame)
        s.sendExport(.finished(result:nil,failure:UserFacingError(code:"export_memory_budget")))
        await eventually(timeout:.seconds(10)) { m.export.phase == .failed }
        XCTAssertEqual(m.export.failure?.variant,"frame")
    }
    func testOutputSettingsAndRememberedPreferencesNeverRestoreImageAdjustments() async {
        let (m,s)=await ready()
        m.selectEncoding("sdr-jpeg");m.setOutputGamut("p3");m.setExportQuality(72)
        XCTAssertEqual(m.export.outputGamut,"p3");XCTAssertEqual(m.export.gamut,.p3)
        XCTAssertEqual(m.exportChoices.customFormat.quality,72)
        XCTAssertFalse(m.canUndo,"export choices are not edits")
        m.selectEncoding("sdr-tiff");XCTAssertNil(m.exportQuality)
        m.adjustRecipe("tone.exposure", to: 1.7)
        m.open([second]);await eventually(timeout:.seconds(10)) { m.photo?.url == self.second }
        XCTAssertEqual(m.exportChoices.encoding,"sdr-tiff");XCTAssertNotEqual(m.recipeNumber("tone.exposure"),1.7)
        XCTAssertEqual(s.preferences.dictionary(forKey:Preferences.key)?["rememberOutput"] as? Bool,true)
        var p=m.preferences.value;p.rememberOutput=false;m.updatePreferences(p)
        m.open([source]);await eventually(timeout:.seconds(10)) { m.photo?.url == self.source }
        XCTAssertEqual(m.exportChoices.encoding,"adaptive")
        let folder=URL(fileURLWithPath:"/tmp/kept-folder");await m.setExportFolder(folder)
        m.resetPreferences();XCTAssertEqual(m.preferences.exportFolder.label,"kept-folder")
    }
    /// The lossless cards: a card keeps the HDR output of the file already
    /// chosen, HDR output off writes the SDR file without leaving the HDR
    /// panel, and the TIFF depth survives a turn through SDR.
    func testLosslessCardsSwitchHDROutputAndDepth() async {
        let (m,_)=await ready()
        XCTAssertEqual(m.losslessEncoding(.tiff),.hdrTIFF16,"from an HDR format, HDR output starts on")
        m.selectEncoding(m.losslessEncoding(.tiff).rawValue)
        XCTAssertEqual(m.exportChoices.encoding,"hdr-tiff-16");XCTAssertNil(m.exportQuality)
        m.setTIFFDepth(32);XCTAssertEqual(m.exportChoices.encoding,"hdr-tiff-32")
        m.setOutputGamut("rec2020");XCTAssertEqual(m.export.gamut,.rec2020)
        m.setLosslessHDR(false)
        XCTAssertEqual(m.exportChoices.encoding,"sdr-tiff");XCTAssertEqual(m.workflow,.hdr)
        XCTAssertFalse(m.exportChoices.writesHDR);XCTAssertEqual(m.export.gamut,.p3,"an SDR TIFF has no Rec. 2020")
        m.selectEncoding(m.losslessEncoding(.dng).rawValue)
        XCTAssertEqual(m.exportChoices.encoding,"sdr-dng","the DNG card keeps HDR output off")
        m.setLosslessHDR(true);XCTAssertEqual(m.exportChoices.encoding,"hdr-dng")
        m.selectEncoding(m.losslessEncoding(.tiff).rawValue)
        XCTAssertEqual(m.exportChoices.encoding,"hdr-tiff-32","the depth is kept")
        XCTAssertEqual(m.exportChoices.customFormat.gamut,.rec2020)
        m.selectEncoding("sdr-jpeg");XCTAssertEqual(m.workflow,.colorOnly)
        XCTAssertEqual(m.losslessEncoding(.dng),.sdrDNG,"from the SDR JPEG, HDR output starts off")
    }
    func testStaleHistoryResponseCannotReplaceTheNewPhotoHistory() async {
        let (m,s)=await ready();let gate=ExportModelGate();var resumed=false
        s.metadataHandler={ await gate.wait(); resumed=true }
        m.refreshExportMetadata();await eventually(timeout:.seconds(10)) { gate.isWaiting }
        s.metadataHandler=nil
        m.open([second]);await eventually(timeout:.seconds(10)) { m.photo?.url == self.second && !m.suggestedFileName.isEmpty }
        gate.release()
        await eventually(timeout:.seconds(10)) { resumed }
        XCTAssertTrue(m.exportVersions.isEmpty);XCTAssertTrue(m.suggestedFileName.hasPrefix("second"))
    }
}

@MainActor extension ExportModelTests {
    /// The frame's look carries over to the next photo; being on does not, so
    /// an export never carries a frame nobody turned on for that photo.
    func testEachPhotoOpensWithoutAFrameButKeepsTheLook() async {
        let (m,s)=await ready()
        var frame=m.frame; frame.isEnabled=true; frame.style = .label; frame.textFace = .monospaced; m.frame=frame
        XCTAssertNotNil(m.frameLayout)
        m.open([second])
        await eventually(timeout:.seconds(10)) { m.photo?.url == second && m.document?.phase == .ready }
        XCTAssertFalse(m.frame.isEnabled)
        XCTAssertEqual(m.frame.style, .label); XCTAssertEqual(m.frame.textFace, .monospaced)
        await running(m,s)
        XCTAssertNil(s.exportCalls.first?.job.snapshot.frame)
        s.sendExport(.finished(result:result(),failure:nil))
        await eventually(timeout:.seconds(10)) { !m.export.isInFlight }
    }
    func testExportCarriesNoFrameWhileTheSwitchIsOff() async {
        let (m,s)=await ready()
        XCTAssertFalse(m.frame.isEnabled)
        await running(m,s)
        XCTAssertNil(s.exportCalls.first?.job.snapshot.frame)
        s.sendExport(.finished(result:result(),failure:nil))
        await eventually(timeout:.seconds(10)) { !m.export.isInFlight }
    }
    func testTerminationAlertHasOnlyTwoActionsAndBothKeyboardDefaultsContinue() {
        let alert=HyperDRApplicationDelegate.terminationAlert(name:"photo.jpg")
        XCTAssertEqual(alert.buttons.count,2)
        XCTAssertEqual(alert.buttons[0].keyEquivalent,"\r")
        XCTAssertTrue(HyperDRApplicationDelegate.continuesOnEscape(keyCode:53,modifiers:[],window:alert.window,alert:alert))
        XCTAssertFalse(HyperDRApplicationDelegate.continuesOnEscape(keyCode:53,modifiers:[.command],window:alert.window,alert:alert))
        XCTAssertFalse(HyperDRApplicationDelegate.continuesOnEscape(keyCode:53,modifiers:[],window:nil,alert:alert))
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell)
        XCTAssertTrue(alert.buttons[1].keyEquivalent.isEmpty)
    }
}

@MainActor extension ExportModelTests {
    func testFailedReplacementReloadsThePreviousPhotosHistory() async throws {
        let (m,s)=await ready()
        let key=try await s.exportKey(m)
        s.historyByURL[source]=[ExportHistoryItem(version:ExportVersion(number:3,createdAt:Date(),encodingID:"adaptive",result:result()),recipeSnapshot: key,options:m.exportChoices)]
        m.refreshExportMetadata()
        await eventually(timeout:.seconds(10)) { m.exportVersions.count == 1 }
        s.openFailures[second]=UserFacingError(code:"source_unreadable")
        m.open([second])
        await eventually(timeout:.seconds(10)) { m.alert != nil && m.exportVersions.count == 1 }
        XCTAssertEqual(m.photo?.url,source);XCTAssertTrue(m.exportVersions[0].matchesCurrent)
    }
}

@MainActor extension ExportModelTests {
    func testExpiredHistorySaveClearsPhotoAndCancelsItsInFlightExport() async throws {
        let (m,s)=await ready()
        let key=try await s.exportKey(m)
        s.historyByURL[source]=[ExportHistoryItem(version:ExportVersion(number:1,createdAt:Date(),encodingID:"adaptive",result:result()),recipeSnapshot: key,options:m.exportChoices)]
        m.refreshExportMetadata();await eventually(timeout:.seconds(10)) { m.exportVersions.count == 1 }
        await running(m,s)
        s.exportSaveHandler={ _,_ in throw UserFacingError(code:"session_expired") }
        m.saveExport("version",destination:target)
        await eventually(timeout:.seconds(10)) { m.document == nil && s.exportCancelCount == 1 }
        XCTAssertEqual(m.alert?.code,"session_expired");XCTAssertFalse(m.export.isInFlight)
        s.sendExport(.finished(result:result(),failure:nil))
        m.open([second]);await eventually(timeout:.seconds(10)) { m.photo?.url == self.second }
        XCTAssertNil(m.export.result)
    }
}

@MainActor extension ExportModelTests {
    func testStandaloneHistorySaveAlsoWaitsBeforeTerminationReply() async throws {
        let (m,s)=await ready();let gate=ExportModelGate()
        let key=try await s.exportKey(m)
        s.historyByURL[source]=[ExportHistoryItem(version:ExportVersion(number:1,createdAt:Date(),encodingID:"adaptive",result:result()),recipeSnapshot: key,options:m.exportChoices)]
        m.refreshExportMetadata();await eventually(timeout:.seconds(10)) { m.exportVersions.count == 1 }
        s.exportSaveHandler={ _,_ in await gate.wait();try Task.checkCancellation();return SavedLocation(fileName:"result.heic",folderLabel:"out") }
        m.saveExport("version",destination:target)
        await eventually(timeout:.seconds(10)) { gate.isWaiting }
        let needsConfirm=await m.needsTerminationConfirmation()
        XCTAssertTrue(needsConfirm);XCTAssertTrue(m.isSavingForTermination);XCTAssertEqual(m.terminationFileName,"result.heic")
        let coordinator=TerminationCoordinator();var reply:Bool?
        coordinator.request(editor:m,confirmStop:{true},reply:{reply=$0})
        await eventually(timeout:.seconds(10)) { s.exportCancelCount == 1 }
        XCTAssertNil(reply);gate.release()
        await eventually(timeout:.seconds(10)) { reply == true }
        XCTAssertTrue(m.saveTasks.isEmpty)
    }
}

extension ExportModelTests {
    func testDiagnosticsDescribeTheExportPlanOfTheCurrentEdits() async {
        let (m,_) = await ready()
        m.setExportQuality(70)
        let text = await m.diagnosticText
        XCTAssertTrue(text.contains("\nExport plan: "), text)
        XCTAssertTrue(text.contains("quality 70"), text)
        XCTAssertFalse(text.contains(self.source.path))
    }

    func testDiagnosticsWithoutAPhotoSaySo() async {
        let text = await EditorModel(services: FakeEditorServices(openDelay: .zero)).diagnosticText
        XCTAssertTrue(text.hasSuffix("Export plan: no photo open"))
    }
}

@MainActor extension ExportModelTests {
    func testLateHistorySaveExpirationMustNotCloseNewPhoto() async throws {
        let (m,s)=await ready();let gate=ExportModelGate()
        let key=try await s.exportKey(m)
        s.historyByURL[source]=[ExportHistoryItem(version:ExportVersion(number:1,createdAt:Date(),encodingID:"adaptive",result:result()),recipeSnapshot: key,options:m.exportChoices)]
        m.refreshExportMetadata();await eventually(timeout:.seconds(10)) { m.exportVersions.count == 1 }
        s.exportSaveHandler={ _,_ in await gate.wait();throw UserFacingError(code:"session_expired") }
        m.saveExport("version",destination:target)
        await eventually(timeout:.seconds(10)) { gate.isWaiting }
        m.open([second]);await eventually(timeout:.seconds(10)) { m.photo?.url == self.second && m.document?.phase == .ready }
        gate.release();await eventually(timeout:.seconds(10)) { m.saveTasks.isEmpty }
        XCTAssertEqual(m.photo?.url,second);XCTAssertNil(m.alert)
    }
}

@MainActor extension ExportModelTests {
    func testRenderedRowEventsReachTheETAWithRealFractions() async throws {
        let s = FakeEditorServices(openDelay: .zero)
        let start = Date(timeIntervalSince1970: 100)
        let m = EditorModel(services: s, now: { start })
        m.open([URL(fileURLWithPath: "/tmp/source.ARW")])
        await eventually(timeout: .seconds(3)) { m.document?.phase == .ready }
        m.timingHistory = [.init(kind: .init(isRAW: true, encoding: "adaptive", isAI: false, hasFrame: false, verifies: true),
            pixels: 24e6, stages: [5,100,10,5])]
        await running(m,s)
        s.sendExport(.progress(stage: "rendering", fraction: 0.1, at: start+10))
        await eventually(timeout: .seconds(3)) { m.export.fraction == 0.1 }
        let low = try XCTUnwrap(m.export.estimate(at: start+10))
        s.sendExport(.progress(stage: "rendering", fraction: 0.9, at: start+10))
        await eventually(timeout: .seconds(3)) { m.export.fraction == 0.9 }
        let high = try XCTUnwrap(m.export.estimate(at: start+10))
        XCTAssertLessThan(try XCTUnwrap(high.remaining), try XCTUnwrap(low.remaining))
        XCTAssertGreaterThanOrEqual(high.fraction, low.fraction)
        m.cancelExport()
        await eventually(timeout: .seconds(3)) { !m.export.isInFlight }
    }
}

@MainActor extension ExportModelTests {
    func testFixedFolderDestinationIsCapturedAtStart() async {
        let (m,s)=await ready()
        await m.setExportFolder(URL(fileURLWithPath:"/tmp/alpha"))
        var p=m.preferences.value;p.saveMode = .folder;m.updatePreferences(p)
        startPreparedExport(m, destination:nil)
        await eventually(timeout:.seconds(10)) { s.hasExportSubscriber }
        XCTAssertEqual(m.export.destination,.folder(label:"alpha"))
        await m.setExportFolder(URL(fileURLWithPath:"/tmp/beta"))
        s.sendExport(.finished(result:result(),failure:nil))
        await eventually(timeout:.seconds(10)) { !m.export.isInFlight }
        XCTAssertEqual(m.export.result?.saved?.folderLabel,"alpha","Changing preferences must not redirect an export already running toward alpha")
    }
    func testFolderChangeBeforeExportTaskStartsOnlyAffectsTheNextExport() async {
        let (m,s) = await ready()
        await m.setExportFolder(URL(fileURLWithPath: "/tmp/alpha"))
        var preferences = m.preferences.value; preferences.saveMode = .folder; m.updatePreferences(preferences)
        startPreparedExport(m, destination: nil)
        let next = try? await s.setExportFolder(URL(fileURLWithPath: "/tmp/beta"))
        if let next { m.preferences.exportFolder = next }
        await eventually(timeout: .seconds(3)) { s.hasExportSubscriber }
        s.sendExport(.finished(result: result(), failure: nil))
        await eventually(timeout: .seconds(3)) { !m.export.isInFlight }
        XCTAssertEqual(m.export.result?.saved?.folderLabel, "alpha")
        startPreparedExport(m, destination: nil)
        await eventually(timeout: .seconds(3)) { s.exportCalls.count == 2 && s.hasExportSubscriber }
        s.sendExport(.finished(result: result("next"), failure: nil))
        await eventually(timeout: .seconds(3)) { !m.export.isInFlight }
        XCTAssertEqual(m.export.result?.saved?.folderLabel, "beta")
    }
}

@MainActor extension ExportModelTests {
    func testETAWithoutAFrameUsesThePhotoPixels() async throws {
        let (m,s)=await ready()
        let size=try XCTUnwrap(m.document?.pixelSize)
        let pixels=Double(size.width)*Double(size.height)
        s.timings=[ExportTimingSample(kind:.init(isRAW:false,encoding:"adaptive",isAI:false,hasFrame:false,verifies:true),pixels:pixels,stages:[10,20,30,4])]
        m.refreshExportMetadata();await eventually(timeout:.seconds(10)) { !m.timingHistory.isEmpty }
        await running(m,s)
        XCTAssertNil(s.exportCalls.first?.job.snapshot.frame)
        XCTAssertEqual(try XCTUnwrap(m.export.durations)[0],10,accuracy:0.0001,"Without a frame, ETA must use the exported photo's pixels")
        m.cancelExport();await eventually(timeout:.seconds(10)) { !m.export.isInFlight }
        // R46-001: a long edge shrinks what is written, and the estimate with it.
        let edge = min(1080, max(size.width, size.height) - 1)
        m.setExportLongEdge(edge)
        let fitted = ExportPixelSize(width: size.width, height: size.height).fitted(longEdge: edge)
        await running(m,s)
        await eventually(timeout:.seconds(10)) { m.export.durations != nil }
        XCTAssertEqual(try XCTUnwrap(m.export.durations)[0], 10 * Double(fitted.width) * Double(fitted.height) / pixels, accuracy: 0.0001)
        m.cancelExport();await eventually(timeout:.seconds(10)) { !m.export.isInFlight }
    }

    func testEnabledFrameETAUsesTheActualExportCanvas() async throws {
        let (m,s) = await ready()
        let size = try XCTUnwrap(m.document?.pixelSize)
        let pixels = Double(size.width) * Double(size.height)
        m.timingHistory = [.init(kind: .init(isRAW: false, encoding: "adaptive", isAI: false, hasFrame: true, verifies: true),
            pixels: pixels, stages: [10,20,30,4])]
        var frame = m.frame; frame.isEnabled = true; m.frame = frame
        let layout = try XCTUnwrap(m.frameLayout)
        await running(m,s)
        XCTAssertNotNil(s.exportCalls.first?.job.snapshot.frame)
        XCTAssertEqual(try XCTUnwrap(m.export.durations)[0], 10 * Double(layout.width) * Double(layout.height) / pixels, accuracy: 0.0001)
        m.cancelExport()
        await eventually(timeout: .seconds(3)) { !m.export.isInFlight }
    }
}

/// Test callers follow the same mandatory preparation protocol as both save modes.
@MainActor func startPreparedExport(_ model: EditorModel, destination: URL?,
                                    file: StaticString = #filePath, line: UInt = #line) {
    guard let token = model.prepareExport() else {
        XCTFail("Expected an export preparation token", file: file, line: line)
        return
    }
    model.startExport(destination: destination, token: token)
}
