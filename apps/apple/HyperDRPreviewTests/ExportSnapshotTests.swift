import AppKit
import SwiftUI
import XCTest
import HyperDRDesign
@testable import HyperDR

/// The M3 views in the app, with the real model and catalogue, in light and
/// dark, English and Chinese, for the states of docs/design/apple/m3-*.png:
/// the export panel (settings, progress, result, failure), the inspector
/// while an export runs and after it ends, export history and the LUT library.
/// Each picture has to have something on it and to differ by theme and
/// language; with $HDR_SNAPSHOT_DIR set they are also written to the host's
/// temporary folder as `m3v-<state>-<variant>.png`.
@MainActor final class ExportSnapshotTests: XCTestCase {
    private let variants: [(name: String, scheme: ColorScheme, locale: String)] = [
        ("light-en", .light, "en"), ("dark-en", .dark, "en"),
        ("light-zh-Hans", .light, "zh-Hans"), ("dark-zh-Hans", .dark, "zh-Hans"),
    ]
    /// The editor's clock: fixed, and moved by the test, so every picture of a
    /// running export shows the same elapsed time and the same percentage.
    private final class Clock { var now = Date(timeIntervalSinceReferenceDate: 810_000_000) }
    private let clock = Clock()
    private let source = URL(fileURLWithPath: "/fixtures/DSC04127.jpg")
    private let target = URL(fileURLWithPath: "/fixtures/out/DSC04127.heic")

    private static let snapshotDirectory: URL? = {
        guard let name = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("snapshots are written to \(directory.path)")
        return directory
    }()

    // MARK: Fixtures

    private func ready(domain: InputDomain = .sdr, timings: Bool = true) async -> (EditorModel, FakeEditorServices) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        services.preview = EditorPreview(pixelSize: PixelSize(width: 6000, height: 4000),
            source: SourceSummary(domain: domain, colorName: "sRGB", degradationReasons: [], colorSource: "assumed"),
            hasGain: true, unadjusted: nil, hasCaptureMetadata: false)
        if timings {
            services.timings = [ExportTimingSample(kind: .init(isRAW: false, encoding: "adaptive", isAI: false, hasFrame: false, verifies: true),
                                                   pixels: 24_000_000, stages: [3, 9, 6, 2])]
        }
        services.library = [LUTItem(id: "a", name: "Kodak Portra 400", input: .srgb, output: .srgb, byteCount: 1_200_000),
                            LUTItem(id: "b", name: "Fuji Classic Neg", input: .rec709, output: .p3, byteCount: 940_000),
                            LUTItem(id: "c", name: "Cinema Teal", input: .slog3SGamut3Cine, output: .rec709, byteCount: 38_000)]
        services.folder = ExportFolder(label: "…/Pictures", ready: true)
        let clock = clock
        let model = EditorModel(services: services, ticker: ManualFrameTicker(), now: { clock.now })
        await model.loadExportServices()
        model.open([source])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        return (model, services)
    }

    private func start(_ model: EditorModel, _ services: FakeEditorServices) async {
        model.startExport(destination: target)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
    }

    /// Fourteen seconds into an export that is encoding, 72% through that stage.
    private func runForFourteenSeconds(_ services: FakeEditorServices, _ model: EditorModel) async throws {
        clock.now += 14
        services.sendExport(.progress(stage: "encode", fraction: 0.72, at: clock.now.addingTimeInterval(-3)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.export.stage, "encode")
    }

    /// What the engine does when an export finishes: the version enters the
    /// history under the key of the edit that was exported.
    private func finish(_ model: EditorModel, _ services: FakeEditorServices, result: ExportResult, failure: UserFacingError? = nil) async throws {
        let key = try await services.exportKey(model.photo!, options: model.effectiveOptions(), frame: nil)
        services.historyByURL[source] = [ExportHistoryItem(
            version: ExportVersion(number: 1, createdAt: clock.now, encodingID: "adaptive", result: result), key: key, options: model.edit)]
        services.sendExport(.finished(result: result, failure: failure))
        await eventually(timeout: .seconds(10)) { model.export.phase == .succeeded }
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.exportVersions.first?.matchesCurrent == true }
    }

    private func finishedResult(saved: Bool = true) -> ExportResult {
        ExportResult(export: "v1", fileName: "DSC04127.heic", byteCount: 18_400_000,
                     pixelSize: PixelSize(width: 6000, height: 4000), headroomStops: 2.5, selfVerified: true, elapsed: .seconds(21),
                     saved: saved ? SavedLocation(fileName: "DSC04127.heic", folderLabel: "…/Pictures",
                                              url: URL(fileURLWithPath: "/fixtures/Pictures/DSC04127.heic")) : nil)
    }

    // MARK: Rendering

    private func render<V: View>(_ view: V, scheme: ColorScheme, locale: String, width: CGFloat? = nil) throws -> NSBitmapImageRep {
        let root = view
            .background(Color.hdr.surfacePanel)
            .fixedSize(horizontal: width == nil, vertical: true)
            .frame(width: width)
            .environment(ViewerSessionState())
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: locale))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func distinctColours(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(bitmap.pixelsWide / 97, 1), stepY = max(bitmap.pixelsHigh / 89, 1)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return seen.count
    }

    /// Every variant of one state, checked and (when asked) written.
    @discardableResult
    private func snapshots<V: View>(_ state: String, minimumHeight: Int = 100, width: CGFloat? = nil,
                                    _ view: () -> V) throws -> [String: NSBitmapImageRep] {
        var pictures: [String: NSBitmapImageRep] = [:]
        var data: Set<Data> = []
        for variant in variants {
            let bitmap = try render(view(), scheme: variant.scheme, locale: variant.locale, width: width)
            XCTAssertGreaterThan(distinctColours(bitmap), 25, "\(state) \(variant.name) is blank")
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, minimumHeight, "\(state) \(variant.name) is too short")
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            data.insert(png)
            pictures[variant.name] = bitmap
            if let directory = Self.snapshotDirectory {
                try png.write(to: directory.appendingPathComponent("m3v-\(state)-\(variant.name).png"))
            }
        }
        XCTAssertEqual(data.count, 4, "\(state): light, dark, English and Chinese differ")
        return pictures
    }

    // MARK: Export panel

    func testSettingsWithTwoHEICCardsUnavailable() async throws {
        let (model, _) = await ready()
        var capabilities = try await FakeEditorServices().encodingCapabilities()
        capabilities.main10 = false; capabilities.encoderReason = "hevc_main10_unavailable"
        model.exportCapabilities = capabilities; model.syncExportState()
        model.selectEncoding("iso-gainmap-jpeg")
        XCTAssertEqual(model.export.encodingID, "iso-gainmap-jpeg")
        try snapshots("export-settings", minimumHeight: 380) { ExportSheet(model: model, window: EditorWindowState()) }
    }

    func testSettingsWithTheSelectedFormatUnavailableShowsTheReasonInTheFooter() async throws {
        let (model, _) = await ready()
        var capabilities = try await FakeEditorServices().encodingCapabilities()
        capabilities.main8 = false; capabilities.main10 = false; capabilities.encoderReason = "hevc_unavailable"
        model.exportCapabilities = capabilities; model.syncExportState()
        XCTAssertEqual(model.export.blockerKey, "err.server.hevc_unavailable")
        let pictures = try snapshots("export-unavailable", minimumHeight: 380) { ExportSheet(model: model, window: EditorWindowState()) }
        XCTAssertNotNil(pictures["light-en"])
    }

    func testColorOnlySettingsAfterAStop() async throws {
        let (model, services) = await ready()
        model.selectEncoding("sdr-jpeg")
        try await Task.sleep(for: .milliseconds(50))
        model.startExport(destination: URL(fileURLWithPath: "/fixtures/out/a.jpg"))
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
        model.cancelExport()
        await eventually(timeout: .seconds(10)) { model.export.phase == .cancelled }
        try snapshots("export-color-stopped", minimumHeight: 330) { ExportSheet(model: model, window: EditorWindowState()) }
    }

    func testProgressView() async throws {
        let (model, services) = await ready()
        await start(model, services)
        try await runForFourteenSeconds(services, model)
        services.sendExport(.log("encode tile 4/12"))
        await eventually(timeout: .seconds(10)) { model.export.lastLine != nil }
        XCTAssertEqual(ExportPresentation.PanelMode(phase: model.export.phase), .progress)
        try snapshots("export-progress", minimumHeight: 260) { ExportSheet(model: model, window: EditorWindowState()) }
    }

    func testProgressViewWithoutAnEstimateOnAFirstExport() async throws {
        let (model, services) = await ready(timings: false)
        await start(model, services)
        services.sendExport(.progress(stage: "decode", fraction: 0, at: clock.now))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.export.estimate(at: clock.now))
        try snapshots("export-progress-first", minimumHeight: 260) { ExportSheet(model: model, window: EditorWindowState()) }
    }

    func testResultSavedAndNotSaved() async throws {
        let (model, services) = await ready()
        await start(model, services)
        try await finish(model, services, result: finishedResult())
        XCTAssertFalse(model.export.isResultStale)
        try snapshots("result-saved", minimumHeight: 300) { ExportSheet(model: model, window: EditorWindowState()) }

        // Adjusting past the export marks it as an earlier version.
        model.adjust("brightness", to: 1.2)
        await eventually(timeout: .seconds(10)) { model.export.isResultStale }
        try snapshots("result-stale", minimumHeight: 300) { ExportSheet(model: model, window: EditorWindowState()) }

        // The chosen place could not be written.
        let (second, secondServices) = await ready()
        await start(second, secondServices)
        try await finish(second, secondServices, result: finishedResult(saved: false), failure: UserFacingError(code: "export_folder_unwritable"))
        XCTAssertNotNil(second.export.saveFailure)
        try snapshots("result-save-failed", minimumHeight: 300) { ExportSheet(model: second, window: EditorWindowState()) }
    }

    func testTheEndedCardSaysWhenItIsAnEarlierEdit() async throws {
        let (model, services) = await ready()
        await start(model, services)
        try await finish(model, services, result: finishedResult())
        let window = EditorWindowState()
        let current = try render(ExportStatusHost(model: model, window: window), scheme: .light, locale: "en")
        model.adjust("brightness", to: 1.2)
        await eventually(timeout: .seconds(10)) { model.export.isResultStale }
        let earlier = try render(ExportStatusHost(model: model, window: window), scheme: .light, locale: "en")
        XCTAssertNotEqual(current.representation(using: .png, properties: [:]), earlier.representation(using: .png, properties: [:]),
                          "an edit made after the export shows on the card")
        XCTAssertGreaterThan(earlier.pixelsHigh, current.pixelsHigh, "the tag takes a row")
    }

    func testReopeningAfterDismissingShowsTheResultThatStillMatches() async throws {
        let (model, services) = await ready()
        await start(model, services)
        try await finish(model, services, result: finishedResult())
        model.export.dismissOutcome()
        func mode(_ wantsSettings: Bool = false) -> ExportPresentation.PanelMode {
            .init(phase: model.export.phase, hasMatchingResult: model.export.result != nil && !model.export.isResultStale,
                  wantsSettings: wantsSettings)
        }
        XCTAssertEqual(model.export.phase, .idle)
        XCTAssertEqual(mode(), .result, "the result is still the current edit's")
        XCTAssertEqual(mode(true), .settings, "Export Again still goes to the settings")
        model.adjust("brightness", to: 1.2)
        await eventually(timeout: .seconds(10)) { model.export.isResultStale }
        XCTAssertEqual(mode(), .settings, "an earlier edit's result is not offered again")
    }

    func testFailurePanel() async throws {
        let (model, services) = await ready()
        await start(model, services)
        services.sendExport(.log("tile 7: allocation failed (need 2.1 GB, have 1.4 GB)"))
        services.sendExport(.finished(result: nil, failure: UserFacingError(code: "export_memory_budget")))
        await eventually(timeout: .seconds(10)) { model.export.phase == .failed }
        try snapshots("export-failure", minimumHeight: 240) { ExportSheet(model: model, window: EditorWindowState()) }
    }

    // MARK: Inspector

    private func inspector(_ model: EditorModel, _ window: EditorWindowState) -> some View {
        VStack(spacing: 0) {
            ExportStatusHost(model: model, window: window)
            InspectorContent(model: model, window: window)
        }
        .frame(width: Layout.inspectorWidth)
    }

    func testLockedInspectorWhileExporting() async throws {
        let (model, services) = await ready()
        await start(model, services)
        try await runForFourteenSeconds(services, model)
        XCTAssertEqual(model.editingLockReason, .exporting)
        let window = EditorWindowState()
        try snapshots("locked", minimumHeight: 700) { inspector(model, window) }
        // The card while the lock answers a touch: the outline, the glow and the note in the accent.
        let flashWindow = EditorWindowState()
        try snapshots("locked-flash", minimumHeight: 700) { flashWindow.emphasizeLock(); return inspector(model, flashWindow) }
        // Touching the lock lights the card.
        window.emphasizeLock()
        let calm = try render(inspector(model, EditorWindowState()), scheme: .light, locale: "en", width: nil)
        let flashing = try render(inspector(model, window), scheme: .light, locale: "en", width: nil)
        XCTAssertNotEqual(calm.representation(using: .png, properties: [:]), flashing.representation(using: .png, properties: [:]))
    }

    func testEndedCardsStayUntilClosed() async throws {
        let (model, services) = await ready()
        await start(model, services)
        try await finish(model, services, result: finishedResult())
        XCTAssertNil(model.editingLockReason, "the inspector is open again")
        let window = EditorWindowState()
        try snapshots("ended-saved", minimumHeight: 700) { inspector(model, window) }
        model.export.dismissOutcome()
        XCTAssertEqual(model.export.phase, .idle)

        await start(model, services)
        services.sendExport(.finished(result: nil, failure: UserFacingError(code: "export_memory_budget", variant: "noFrame")))
        await eventually(timeout: .seconds(10)) { model.export.phase == .failed }
        try snapshots("ended-failed", minimumHeight: 700) { inspector(model, window) }
        // The generic failure does not say "Export failed" twice.
        XCTAssertEqual(ExportStatusHost.failureLine(UserFacingError(code: "export_failed"), locale: Locale(identifier: "en")),
                       "The export didn’t finish.")
        XCTAssertEqual(ExportStatusHost.failureLine(UserFacingError(code: "export_memory_budget", variant: "noFrame"), locale: Locale(identifier: "en")),
                       "Not enough memory to export")
    }

    func testLUTGroupStates() async throws {
        let (model, _) = await ready()
        model.selectLUT("a")
        await eventually(timeout: .seconds(10)) { model.lut.selection?.id == "a" }
        try snapshots("lut-group", minimumHeight: 120) { LUTGroup(model: model, window: EditorWindowState(), startsExpanded: true).padding(Space.s4).frame(width: Layout.inspectorWidth) }
        // Spaces that cannot work together keep the look, say why, and stop the strength.
        model.setLUTSpaces(input: .slog3SGamut3Cine, output: .rec709)
        XCTAssertNotNil(model.lut.spaceIssueKey)
        try snapshots("lut-group-issue", minimumHeight: 160) { LUTGroup(model: model, window: EditorWindowState(), startsExpanded: true).padding(Space.s4).frame(width: Layout.inspectorWidth) }
    }

    // MARK: History and library

    func testHistorySheet() async throws {
        let (model, services) = await ready()
        let first = try await services.exportKey(model.photo!, options: model.effectiveOptions(), frame: nil)
        let now = clock.now
        // Version 3 is the newest, so it is the latest time and the top row.
        func item(_ n: Int, key: String, saved: Bool, model name: String?) -> ExportHistoryItem {
            var result = finishedResult(saved: saved); result.export = "v\(n)"; result.fileName = "DSC04127-\(n).heic"
            return ExportHistoryItem(version: ExportVersion(number: n, createdAt: now.addingTimeInterval(Double(n - 4) * 3600),
                encodingID: n == 2 ? "iso-gainmap-jpeg" : "adaptive", modelName: name,
                fallbackNote: n == 2 ? "Missing aperture; used the CNN alone" : nil, hasFrame: n == 3, result: result),
                key: key, options: model.edit)
        }
        services.historyByURL[source] = [item(1, key: first, saved: true, model: nil), item(2, key: "other", saved: false, model: "CNN"),
                                        item(3, key: "older", saved: true, model: nil)]
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.exportVersions.count == 3 }
        try snapshots("history", minimumHeight: 360) { ExportHistorySheet(model: model) }
    }

    func testEmptyHistoryAndLibrary() async throws {
        let (model, services) = await ready()
        try snapshots("history-empty", minimumHeight: 300) { ExportHistorySheet(model: model) }
        services.library = []
        model.lut.library = []
        try snapshots("library-empty", minimumHeight: 300) { LUTLibrarySheet(model: model) }
    }

    func testLUTLibrarySheet() async throws {
        let (model, _) = await ready()
        model.selectLUT("a")
        await eventually(timeout: .seconds(10)) { model.lut.selection?.id == "a" }
        try snapshots("library", minimumHeight: 340) { LUTLibrarySheet(model: model) }
    }
}
