import AppKit
import HyperDREngine
import SwiftUI
import XCTest
import HyperDRDesign
@testable import HyperDR

/// The RAW states of docs/design/raw-states.md in the views: the sentences for
/// an unsupported camera, the camera and lens group, the About row, and the
/// "Preparing camera support" prompt on the canvas.
@MainActor final class RawStatesTests: XCTestCase {
    private let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")

    private func text(_ resource: LocalizedStringResource, _ locale: Locale) -> String {
        var resource = resource; resource.locale = locale
        return String(localized: resource)
    }

    // MARK: Errors (R-V3)

    func testUnsupportedCameraNamesTheModelInTheSentenceAndAddsNoDetail() {
        let error = UserFacingError(code: "raw_unsupported", detail: "Leica M11-P", variant: "camera")
        let sentence = ErrorText(error)
        XCTAssertEqual(text(sentence.title, en), "This camera’s RAW isn’t supported")
        XCTAssertEqual(text(sentence.message, en), "HyperDR develops RAW with macOS, which doesn’t support the Leica M11-P yet. macOS updates add new cameras; you can also convert the file to DNG or TIFF first.")
        XCTAssertEqual(text(sentence.title, zh), "不支持这台相机的 RAW")
        XCTAssertTrue(text(sentence.message, zh).contains("Leica M11-P"))
        XCTAssertNil(sentence.detail)
        XCTAssertFalse(sentence.body(locale: en).contains("\n\n"), "the model is not listed again below")
    }

    func testUnsupportedCameraWithoutAModelAndAnUnmarkedErrorSayThisCamera() {
        for error in [UserFacingError(code: "raw_unsupported", variant: "camera"), UserFacingError(code: "raw_unsupported")] {
            let sentence = ErrorText(error)
            XCTAssertEqual(text(sentence.title, en), "This camera’s RAW isn’t supported")
            XCTAssertTrue(text(sentence.message, en).contains("doesn’t support this camera yet"))
            XCTAssertNil(sentence.detail)
        }
    }

    func testUnsupportedDNGHasItsOwnTitleAndSentence() {
        let sentence = ErrorText(UserFacingError(code: "raw_unsupported", variant: "dng"))
        XCTAssertEqual(text(sentence.title, en), "Can’t open this DNG")
        XCTAssertEqual(text(sentence.message, en), "macOS can’t decode this DNG file. Export it again from the camera maker’s software or a DNG converter, then try again.")
        XCTAssertEqual(text(sentence.title, zh), "无法打开这个 DNG")
        XCTAssertNil(sentence.detail)
        XCTAssertNil(ErrorText(UserFacingError(code: "raw_unsupported", detail: "x", variant: "dng")).detail)
    }

    func testAnUnreadableFileIsNeverReportedAsAnUnsupportedCamera() {
        let sentence = ErrorText(UserFacingError(code: "source_unreadable"))
        XCTAssertNotEqual(text(sentence.title, en), "This camera’s RAW isn’t supported")
        XCTAssertFalse(text(sentence.message, en).contains("camera"))
    }

    // MARK: Camera and lens (R-V4)

    func testTheEngineLineNamesTheDecoderAndMarksDNG() {
        XCTAssertEqual(CameraGroup.engineText("8", locale: en), "macOS · decoder 8")
        XCTAssertEqual(CameraGroup.engineText("8.dng", locale: en), "macOS · decoder 8 · DNG")
        XCTAssertEqual(CameraGroup.engineText("7", locale: zh), "macOS 系统 · 解码器 7")
        XCTAssertEqual(CameraGroup.engineText("8.dng", locale: zh), "macOS 系统 · 解码器 8 · DNG")
    }

    // MARK: About and diagnostics (R-V5)

    func testTheAboutRowAndSystemVersionComeFromTheModelAndLeaveOutTheBuild() async throws {
        let (model, _) = try await openRAW(supported: true, decoder: "8.dng")
        XCTAssertEqual(SettingsDiagnostics.raw(model, locale: en), "Decoder 8 · DNG · macOS build 25A123")
        XCTAssertEqual(SettingsDiagnostics.raw(model, locale: zh), "解码器 8 · DNG · macOS 构建 25A123")
        XCTAssertFalse(SettingsDiagnostics.system().lowercased().contains("build"))
        XCTAssertTrue(SettingsDiagnostics.system().hasPrefix("macOS "))
        let text = await model.diagnosticText
        XCTAssertTrue(text.contains("decoder 8.dng"), text)
        XCTAssertTrue(text.contains("macOS build 25A123"), text)
        let (plain, _) = try await openJPEG()
        XCTAssertNil(SettingsDiagnostics.raw(plain, locale: en))
        let (raw, _) = try await openRAW(supported: true, decoder: "8")
        XCTAssertEqual(SettingsDiagnostics.raw(raw, locale: en), "Decoder 8 · macOS build 25A123")
        XCTAssertEqual(AppStrings.string("settings.diag.raw", locale: en), "RAW (this photo)")
        XCTAssertEqual(AppStrings.string("settings.diag.raw", locale: zh), "RAW 显影（当前照片）")
    }

    // MARK: Fixtures

    private func openRAW(supported: Bool, decoder: String = "8", camera: String = "Sony ILCE-7RM5", lens: String? = "FE 70-200mm F2.8 GM OSS II")
        async throws -> (EditorModel, ScriptedEditorServices) {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        let url = URL(fileURLWithPath: "/fixtures/DSC01468.ARW")
        let preview = EditorPreview(pixelSize: PixelSize(width: 9504, height: 6336), source: SourceSummary(
            domain: .sceneReferred, colorName: "Display P3", degradationReasons: [],
            raw: RawCapabilities(supported: true, lensCorrectionSupported: supported, decoderVersion: decoder, osBuild: "25A123")),
            hasGain: false)
        services.usesFactsGate = true
        model.open([url])
        await eventually(timeout: .seconds(5)) { services.streams[url] != nil }
        services.streams[url]?.yield(.reference(preview)); services.streams[url]?.yield(.edited(preview))
        await eventually(timeout: .seconds(5)) { model.document?.phase == .ready }
        await eventually(timeout: .seconds(5)) { services.factsWaiters[url] != nil }
        services.factsWaiters.removeValue(forKey: url)?.resume(returning: CaptureFacts(model: camera, lens: lens))
        await eventually(timeout: .seconds(5)) { model.captureFacts.model == camera }
        return (model, services)
    }

    private func openJPEG() async throws -> (EditorModel, ScriptedEditorServices) {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        let url = URL(fileURLWithPath: "/fixtures/old.jpg")
        let preview = EditorPreview(pixelSize: PixelSize(width: 600, height: 400), source:
            SourceSummary(domain: .sdr, colorName: "sRGB", degradationReasons: []), hasGain: false)
        model.open([url])
        await eventually(timeout: .seconds(5)) { services.streams[url] != nil }
        services.streams[url]?.yield(.reference(preview)); services.streams[url]?.yield(.edited(preview))
        await eventually(timeout: .seconds(5)) { model.document?.phase == .ready }
        return (model, services)
    }

    // MARK: Pictures

    private static let directory: URL? = {
        guard let name = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    private let variants: [(name: String, scheme: ColorScheme, locale: String)] = [
        ("light-en", .light, "en"), ("dark-en", .dark, "en"), ("light-zh-Hans", .light, "zh-Hans"), ("dark-zh-Hans", .dark, "zh-Hans")]

    private func render<V: View>(_ view: V, scheme: ColorScheme, locale: String, size: CGSize? = nil) throws -> NSBitmapImageRep {
        let root = view
            .environment(ViewerSessionState())
            .environment(\.canvasSpinnerTurn, 0)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: locale))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let fitting = size ?? host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: fitting), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: fitting)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    @discardableResult
    private func snapshots<V: View>(_ state: String, size: CGSize? = nil, distinct: Int = 4, _ view: () -> V) throws -> Int {
        var pictures: Set<Data> = []
        var height = 0
        for variant in variants {
            let bitmap = try render(view(), scheme: variant.scheme, locale: variant.locale, size: size)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            pictures.insert(png)
            height = bitmap.pixelsHigh
            if let directory = Self.directory { try png.write(to: directory.appendingPathComponent("rawv-\(state)-\(variant.name).png")) }
        }
        XCTAssertEqual(pictures.count, distinct, "\(state): the variants that should differ do")
        return height
    }

    private func backdrop<V: View>(_ content: V) -> some View {
        ZStack { Color.hdr.previewBackdrop; content }.frame(width: 640, height: 400)
    }

    func testTheSlowOpenSnapshots() throws {
        // Without a photograph: the stage text, the name, Cancel (raw-states §9.2).
        try snapshots("slow-open-panel", size: CGSize(width: 640, height: 400), distinct: 2) {
            backdrop(FirstFrameProgress(label: "stage.reading", slowFileName: "A_very_long_file_name_from_a_slow_disk_0001.JPG", cancel: {}))
        }
        // Over an earlier photograph: the corner chip with Cancel after its text.
        try snapshots("slow-open-chip", size: CGSize(width: 640, height: 400), distinct: 2) {
            backdrop(SlowOpenChip(label: "stage.reading", fileName: "IMG_0001.JPG", cancel: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(Space.s3))
        }
        // Before 1.5 s there is neither the name nor Cancel.
        let quick = try render(backdrop(FirstFrameProgress(label: "stage.reading")), scheme: .dark, locale: "en", size: CGSize(width: 640, height: 400))
        let slow = try render(backdrop(FirstFrameProgress(label: "stage.reading", slowFileName: "IMG_0001.JPG", cancel: {})), scheme: .dark, locale: "en",
                              size: CGSize(width: 640, height: 400))
        XCTAssertNotEqual(quick.representation(using: .png, properties: [:]), slow.representation(using: .png, properties: [:]))
    }

    func testThePreparingPanelAndCardSnapshots() throws {
        // Over the photograph the prompt is dark in both appearances: only the language differs.
        try snapshots("preparing-panel", size: CGSize(width: 640, height: 400), distinct: 2) {
            backdrop(CameraSupportPanel(fileName: "DSC01468.ARW", canCancel: true, cancel: {}))
        }
        try snapshots("preparing-card", size: CGSize(width: 640, height: 400), distinct: 2) {
            backdrop(CameraSupportCard(fileName: "DSC01468.ARW", canCancel: true, cancel: {})
                .frame(maxHeight: .infinity, alignment: .bottom).padding(Space.s4))
        }
    }

    func testCameraGroupSnapshots() async throws {
        let (supported, _) = try await openRAW(supported: true)
        try snapshots("camera-group") { CameraGroup(model: supported, startsExpanded: true).frame(width: Layout.inspectorWidth).background(Color.hdr.surfacePanel) }
        let (unsupported, _) = try await openRAW(supported: false, decoder: "7", camera: "Leica C (Typ 112)", lens: nil)
        try snapshots("camera-group-unsupported") { CameraGroup(model: unsupported, startsExpanded: true).frame(width: Layout.inspectorWidth).background(Color.hdr.surfacePanel) }
        let (dng, _) = try await openRAW(supported: true, decoder: "8.dng")
        _ = released(dng)
        try snapshots("camera-group-dng") { CameraGroup(model: dng, startsExpanded: true).frame(width: Layout.inspectorWidth).background(Color.hdr.surfacePanel) }
    }

    /// The page as a release shows it: with a version and build.
    private func released(_ model: EditorModel) -> EditorModel {
        var about = AboutInformation()
        about.version = "1.0"; about.buildNumber = "42"; about.engineABI = 3
        model.preferences.about = about
        return model
    }

    func testTheAboutPageShowsTheRAWRowForACameraRAWAndForADNG() async throws {
        let (raw, _) = try await openRAW(supported: true)
        _ = released(raw)
        try snapshots("about-raw", size: CGSize(width: 520, height: 560)) { AboutSettings(model: raw).frame(width: 520).background(Color.hdr.surfacePanel) }
        let (dng, _) = try await openRAW(supported: true, decoder: "8.dng")
        try snapshots("about-dng", size: CGSize(width: 520, height: 560)) { AboutSettings(model: dng).frame(width: 520).background(Color.hdr.surfacePanel) }
        let (jpeg, _) = try await openJPEG()
        _ = released(jpeg)
        try snapshots("about-jpeg", size: CGSize(width: 520, height: 560)) { AboutSettings(model: jpeg).frame(width: 520).background(Color.hdr.surfacePanel) }
    }

    /// The two alerts as the system draws them: an icon, the title, the sentence and OK.
    private struct AlertSketch: View {
        let error: UserFacingError
        @Environment(\.locale) private var locale
        var body: some View {
            let text = ErrorText(error)
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(Color.hdr.warn)
                Text(verbatim: text.title(locale: locale)).font(.headline).multilineTextAlignment(.center)
                Text(verbatim: text.body(locale: locale)).font(.callout).multilineTextAlignment(.center)
                    .foregroundStyle(Color.hdr.inkMuted).fixedSize(horizontal: false, vertical: true)
                // The system's default button is a filled accent; this is the app's own filled button, which keeps its contrast.
                Button { } label: { Text(verbatim: "OK").frame(maxWidth: .infinity) }.buttonStyle(.hdrPrimary)
            }
            .padding(20).frame(width: 300).background(Color.hdr.surfacePanel)
        }
    }

    func testTheAboutPageSaysNoneForAnEmptyModelList() {
        let model = EditorModel(services: ScriptedEditorServices())
        XCTAssertTrue(model.ai.models.filter(\.isEnabled).isEmpty, "a model with nothing loaded has no enabled model")
        XCTAssertEqual(SettingsDiagnostics.models(model, locale: en), "None")
        XCTAssertEqual(SettingsDiagnostics.models(model, locale: zh), "无")
    }

    func testTheUnsupportedCameraAndDNGAlerts() throws {
        try snapshots("alert-camera") { AlertSketch(error: UserFacingError(code: "raw_unsupported", detail: "Leica M11-P", variant: "camera")) }
        try snapshots("alert-dng") { AlertSketch(error: UserFacingError(code: "raw_unsupported", variant: "dng")) }
    }

    // MARK: The lens correction switch (M3 §12.4, B11)

    func testTheLensCorrectionIsOnByDefaultAndTheSummaryFollowsTheSwitch() async throws {
        let (model, services) = try await openRAW(supported: true)
        XCTAssertTrue(model.edit.lensCorrection)
        XCTAssertEqual(model.cameraSummaryKey, "camera.summary.on")
        XCTAssertEqual(model.effectiveOptions()["lensCorrection"], .bool(true))
        model.setLensCorrection(false)
        XCTAssertFalse(model.edit.lensCorrection)
        XCTAssertEqual(model.cameraSummaryKey, "camera.summary.off")
        XCTAssertEqual(model.effectiveOptions()["lensCorrection"], .bool(false))
        await eventually(timeout: .seconds(5)) { services.submitted.last?["lensCorrection"] == .bool(false) }
        let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")
        XCTAssertEqual(AppStrings.string("camera.summary.off", locale: en), "Lens correction off")
        XCTAssertEqual(AppStrings.string("camera.summary.off", locale: zh), "镜头校正关")
    }

    func testTheSwitchIsOneUndoStepAndRedoes() async throws {
        let (model, _) = try await openRAW(supported: true)
        let undo = model.undoManager
        model.setLensCorrection(false)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, EditorModel.undoActionName("lensCorrection"))
        XCTAssertNotEqual(undo.undoActionName, EditorModel.undoActionName("somethingElse"))
        model.setLensCorrection(false)   // no change, no step
        model.undo()
        XCTAssertTrue(model.edit.lensCorrection)
        XCTAssertEqual(model.cameraSummaryKey, "camera.summary.on")
        XCTAssertFalse(undo.canUndo)
        model.redo()
        XCTAssertFalse(model.edit.lensCorrection)
        XCTAssertEqual(model.cameraSummaryKey, "camera.summary.off")
    }

    /// The original is the same development of the file, so it follows the
    /// switch (geometry must match when comparing); its adjustments stay neutral.
    func testTheOriginalFollowsTheLensCorrectionSwitchAndUndo() async throws {
        let (model, services) = try await openRAW(supported: true)
        let initial = try XCTUnwrap(model.referenceOptions)
        XCTAssertEqual(initial["lensCorrection"], .bool(true))
        services.referenceHandler = { _ in model.edit.lensCorrection ? nil : EditorPreview(pixelSize: PixelSize(width: 9504, height: 6336),
            source: SourceSummary(domain: .sceneReferred, colorName: "Display P3", degradationReasons: []), hasGain: false) }
        let revision = model.frameRevision
        model.setLensCorrection(false)
        XCTAssertEqual(model.referenceOptions?["lensCorrection"], .bool(false))
        await eventually(timeout: .seconds(5)) { services.referenceRenders.count == 1 }
        XCTAssertEqual(services.referenceRenders.last?["lensCorrection"], .bool(false))
        var expected = initial
        expected["lensCorrection"] = .bool(false)
        XCTAssertEqual(services.referenceRenders.last, expected)
        await eventually(timeout: .seconds(5)) { model.frameRevision != revision }
        model.undo()
        XCTAssertEqual(model.referenceOptions, initial)
        await eventually(timeout: .seconds(5)) { services.referenceRenders.count == 2 }
        XCTAssertEqual(services.referenceRenders.last, initial)
    }

    func testAnOriginalRenderedBeforeASecondSwitchIsDiscarded() async throws {
        let (model, services) = try await openRAW(supported: true)
        services.referenceHandler = { options in
            if options["lensCorrection"] == .bool(false) { try await Task.sleep(for: .seconds(30)) }
            return EditorPreview(pixelSize: PixelSize(width: 9504, height: 6336),
                source: SourceSummary(domain: .sceneReferred, colorName: "Display P3", degradationReasons: []), hasGain: false)
        }
        let revision = model.frameRevision
        model.setLensCorrection(false)
        await eventually(timeout: .seconds(5)) { services.referenceRenders.count == 1 }
        model.setLensCorrection(true)
        await eventually(timeout: .seconds(5)) { services.referenceRenders.count == 2 }
        await eventually(timeout: .seconds(5)) { model.frameRevision != revision }
        XCTAssertEqual(model.referenceOptions?["lensCorrection"], .bool(true))
        XCTAssertEqual(model.frameRevision, revision &+ 1)
    }

    /// A failed original keeps the earlier frame on screen, so the original
    /// details must keep using the options that frame was rendered with.
    func testAFailedOriginalRendersTheOriginalDetailsWithTheShownOptions() async throws {
        let (model, services) = try await openRAW(supported: true)
        let initial = try XCTUnwrap(model.referenceOptions)
        services.referenceHandler = { _ in throw UserFacingError(code: "decode_failed") }
        model.setLensCorrection(false)
        await eventually(timeout: .seconds(5)) { services.referenceRenders.count == 1 }
        await eventually(timeout: .seconds(5)) { model.referenceOptions == initial }
        XCTAssertEqual(model.referenceOptions, initial)
        // The next edit finds the original out of step with the switch and tries again.
        model.editChanged()
        await eventually(timeout: .seconds(5)) { services.referenceRenders.count == 2 }
    }

    func testAnOriginalRenderingWhenThePhotoIsClosedIsDiscarded() async throws {
        let (model, services) = try await openRAW(supported: true)
        var gate: CheckedContinuation<EditorPreview?, Error>?
        services.referenceHandler = { _ in try await withCheckedThrowingContinuation { gate = $0 } }
        model.setLensCorrection(false)
        await eventually(timeout: .seconds(5)) { gate != nil }
        model.closeDocument()
        let revision = model.frameRevision
        gate?.resume(returning: EditorPreview(pixelSize: PixelSize(width: 9504, height: 6336),
            source: SourceSummary(domain: .sceneReferred, colorName: "Display P3", degradationReasons: []), hasGain: false))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.frameRevision, revision)
        XCTAssertNil(model.document)
    }

    /// The result is only applied while its options are still the model's.
    func testAnOriginalForOptionsThatAreNoLongerCurrentIsDiscarded() async throws {
        let (model, services) = try await openRAW(supported: true)
        let initial = try XCTUnwrap(model.referenceOptions)
        let revision = model.frameRevision
        services.referenceHandler = { _ in
            model.referenceOptions = initial   // as if a newer state had been reached meanwhile
            return EditorPreview(pixelSize: PixelSize(width: 9504, height: 6336),
                source: SourceSummary(domain: .sceneReferred, colorName: "Display P3", degradationReasons: []), hasGain: false)
        }
        model.setLensCorrection(false)
        await eventually(timeout: .seconds(5)) { services.referenceRenders.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.frameRevision, revision)
        XCTAssertEqual(model.shownReferenceOptions, initial)
    }

    func testNoOriginalIsRenderedWhenThereIsNoSwitchToTurn() async throws {
        let (unsupported, services) = try await openRAW(supported: false)
        unsupported.setLensCorrection(false)
        let (jpeg, jpegServices) = try await openJPEG()
        jpeg.setLensCorrection(false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(services.referenceRenders.isEmpty)
        XCTAssertTrue(jpegServices.referenceRenders.isEmpty)
    }

    func testAnUnsupportedLensOrAnotherKindOfPhotoHasNoSwitchToTurn() async throws {
        let (unsupported, _) = try await openRAW(supported: false)
        XCTAssertEqual(unsupported.cameraSummaryKey, "camera.summary.unsupported")
        let undo = unsupported.undoManager
        unsupported.setLensCorrection(false)
        XCTAssertTrue(unsupported.edit.lensCorrection)
        XCTAssertFalse(undo.canUndo)
        let (jpeg, _) = try await openJPEG()
        XCTAssertNil(jpeg.cameraSummaryKey)
        jpeg.setLensCorrection(false)
        XCTAssertTrue(jpeg.edit.lensCorrection)
    }

    /// The group shows a real switch only where macOS can correct the lens.
    func testTheGroupDrawsTheSwitchOnlyForASupportedLens() async throws {
        func switches(in view: NSView) -> Int {
            view.subviews.reduce(view is NSSwitch ? 1 : 0) { $0 + switches(in: $1) }
        }
        func count(_ model: EditorModel) -> Int {
            let host = NSHostingView(rootView: CameraGroup(model: model, startsExpanded: true).frame(width: Layout.inspectorWidth))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let found = switches(in: host)
            window.close()
            return found
        }
        let (supported, _) = try await openRAW(supported: true)
        let (unsupported, _) = try await openRAW(supported: false, decoder: "7", camera: "Leica C (Typ 112)", lens: nil)
        XCTAssertEqual(count(supported), 1)
        XCTAssertEqual(count(unsupported), 0)
    }

    func testThePhotoOfAnotherKindHasNoCameraGroup() async throws {
        let (jpeg, _) = try await openJPEG()
        let marker = Text(verbatim: "marker").frame(width: Layout.inspectorWidth)
        let alone = try render(marker, scheme: .light, locale: "en")
        let with = try render(VStack(spacing: 0) { marker; CameraGroup(model: jpeg, startsExpanded: true) }, scheme: .light, locale: "en")
        XCTAssertEqual(alone.pixelsHigh, with.pixelsHigh)
    }

    // MARK: The canvas while preparing

    func testTheCanvasShowsThePromptOnlyWhileTheModelIsPreparing() async throws {
        let clock = PreparingClock()
        let services = ScriptedEditorServices(); services.openClock = clock
        let model = EditorModel(services: services)
        let url = URL(fileURLWithPath: "/fixtures/DSC01468.ARW")
        model.open([url])
        await eventually(timeout: .seconds(5)) { clock.waiting }
        let window = EditorWindowState()
        let before = try render(backdrop(CanvasStatus(model: model, window: window)), scheme: .dark, locale: "en", size: CGSize(width: 640, height: 400))
        clock.advance()
        await eventually(timeout: .seconds(5)) { model.document?.isPreparingCameraSupport == true }
        let during = try render(backdrop(CanvasStatus(model: model, window: window)), scheme: .dark, locale: "en", size: CGSize(width: 640, height: 400))
        XCTAssertNotEqual(before.representation(using: .png, properties: [:]), during.representation(using: .png, properties: [:]))
        XCTAssertTrue(model.canCancelOpen)
        model.cancelOpen()
        XCTAssertNil(model.document); XCTAssertNil(model.alert)
        clock.advance()
    }
}

/// A clock that waits for the test to say 1.5 s have passed.
@MainActor private final class PreparingClock: EditorOpenClock {
    var now: Duration = .zero
    private(set) var waiting = false
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep(until deadline: Duration) async throws {
        waiting = true
        await withCheckedContinuation { waiter = $0 }
    }
    func advance() { waiter?.resume(); waiter = nil }
}
