import AppKit
import HyperDRDesign
@_spi(Testing) import HyperDREngine
import SwiftUI
import XCTest
@testable import HyperDR

/// V-T1: the model's thumbnails reach the four places that show them
/// (docs/design/m3-export.md §20). The views are mounted in an offscreen
/// window with the real model and fake services, and the pictures are looked
/// at: the fake services hand back a magenta image, which nothing else in the
/// panel is. Nothing here sends an event to the system.
@MainActor final class ExportThumbnailViewTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/tmp/thumbnail-view-first.jpg")
    private let next = URL(fileURLWithPath: "/tmp/thumbnail-view-second.jpg")
    private let destination = URL(fileURLWithPath: "/tmp/thumbnail-view-result.heic")

    // MARK: Fixtures

    private func magenta(width: Int = 6, height: Int = 4) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func frame() async throws -> PreviewFrame {
        let engine = try await Engine(), session = try engine.openPreview(source: TinyPhoto.url)
        defer { session.close() }
        return try await session.renderFrame(EngineRequest(settings: ["preview_max_edge": .number(8)]))
    }

    private func preview(_ frame: PreviewFrame?) -> EditorPreview {
        EditorPreview(pixelSize: PixelSize(width: 64, height: 48),
            source: SourceSummary(domain: .sdr, colorName: "Display P3", degradationReasons: []), hasGain: true, frame: frame)
    }

    /// The editor's clock, fixed: a running export's elapsed time is then the same in every picture.
    private let fixedNow = Date(timeIntervalSinceReferenceDate: 810_000_000)

    private func ready(frame: PreviewFrame?) async -> (EditorModel, FakeEditorServices) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        services.preview = preview(frame)
        let now = fixedNow
        let model = EditorModel(services: services, ticker: ManualFrameTicker(), now: { now })
        await model.loadExportServices(); model.open([source])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        return (model, services)
    }

    private func result(_ id: String) -> ExportResult {
        ExportResult(export: id, fileName: "result.heic", byteCount: 10, pixelSize: PixelSize(width: 64, height: 48),
                     saved: SavedLocation(fileName: "result.heic", folderLabel: "…/Pictures", reveal: {}))
    }

    // MARK: Looking at a view

    /// With $HDR_SNAPSHOT_DIR set, the pictures are also written to the host's
    /// temporary folder as `m3v-thumbnail-<name>.png`, like the other M3 snapshots.
    private static func write(_ bitmap: NSBitmapImageRep, as name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: folder).lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("m3v-thumbnail-\(name).png"))
    }

    /// Mounts the view, runs the main loop for `seconds` (long enough for its
    /// tasks), and reads what it draws.
    private func look<V: View>(_ view: V, _ name: String? = nil, scheme: ColorScheme = .light, seconds: Double = 0.4,
                               until condition: (@MainActor () -> Bool)? = nil) async throws -> NSBitmapImageRep {
        let root = view
            .background(Color.hdr.surfacePanel)
            .fixedSize()
            .environment(ViewerSessionState())
            .environment(\.exportProgressClock, fixedNow)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en"))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(seconds), giveUp = Date().addingTimeInterval(seconds + 8)
        repeat {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline || (!(condition?() ?? true) && Date() < giveUp)
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let name { try Self.write(bitmap, as: name) }
        return bitmap
    }

    /// How many sampled pixels are the fake image's magenta.
    private func magentaPixels(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent - c.greenComponent > 0.3, c.blueComponent - c.greenComponent > 0.3 { count += 1 }
            }
        }
        return count
    }

    // MARK: The mapping

    func testTheStatesMapToTheBoxsContent() throws {
        let image = try magenta(width: 8, height: 4)
        if case .loading(let spins) = ThumbnailState.loading.content() { XCTAssertFalse(spins) } else { XCTFail("loading") }
        if case .loading(let spins) = ThumbnailState.loading.content(showsSpinner: true) { XCTAssertTrue(spins) } else { XCTFail("loading with a spinner") }
        if case .unavailable = ThumbnailState.unavailable.content(showsSpinner: true) {} else { XCTFail("unavailable") }
        if case .image(_, let ratio) = ThumbnailState.ready(image).content() { XCTAssertEqual(ratio, 2) } else { XCTFail("ready") }
    }

    // MARK: The summary column

    func testTheSummaryShowsLoadingThenThePictureThenNone() async throws {
        let picture = try magenta()
        // Loading: no edited frame yet.
        let (loadingModel, _) = await ready(frame: nil)
        let loading = try await look(ExportSettingsHost(model: loadingModel), "summary-loading")
        XCTAssertEqual(loadingModel.exportSummaryThumbnail, .loading)
        XCTAssertEqual(magentaPixels(loading), 0)
        loadingModel.closeDocument()

        // Ready.
        let shown = try await frame()
        let (model, services) = await ready(frame: shown)
        services.thumbnailHandler = { _, _ in picture }
        let readyPicture = try await look(ExportSettingsHost(model: model), "summary-ready", until: { model.exportSummaryThumbnail == .ready(picture) })
        XCTAssertGreaterThan(magentaPixels(readyPicture), 1000, "the picture fills the 172 × 115 box (fit, 3:2)")
        model.closeDocument()

        // None: the picture could not be made.
        let (failing, failingServices) = await ready(frame: shown)
        failingServices.thumbnailHandler = { _, _ in nil }
        let none = try await look(ExportSettingsHost(model: failing), "summary-none", until: { failing.exportSummaryThumbnail == .unavailable })
        XCTAssertEqual(magentaPixels(none), 0)
        XCTAssertNotEqual(none.representation(using: .png, properties: [:]), loading.representation(using: .png, properties: [:]),
                          "none (the photo icon) is not the empty loading box")
        failing.closeDocument()
    }

    func testSwitchingPhotoEmptiesTheSummary() async throws {
        let picture = try magenta(), shown = try await frame()
        let (model, services) = await ready(frame: shown)
        services.thumbnailHandler = { _, _ in picture }
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(picture) }
        let before = try await look(ExportSettingsHost(model: model), seconds: 0.2)
        XCTAssertGreaterThan(magentaPixels(before), 1000, "the first photo's picture is on show")
        services.preview = preview(nil)
        model.open([next])
        XCTAssertEqual(model.exportSummaryThumbnail, .loading, "no picture of the last photo while the next one opens")
        let after = try await look(ExportSettingsHost(model: model), seconds: 0.3)
        XCTAssertEqual(magentaPixels(after), 0)
        model.closeDocument()
    }

    // MARK: Progress and result

    func testProgressAndResultShowTheFrozenPictureEvenWhenTheResultIsStale() async throws {
        let picture = try magenta(), shown = try await frame()
        let (model, services) = await ready(frame: shown)
        services.thumbnailHandler = { _, _ in picture }
        model.startExport(destination: destination, token: model.prepareExport()!)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber && model.export.thumbnail == .ready(picture) }
        let progress = try await look(ExportSheet(model: model, window: EditorWindowState()), "progress-ready", seconds: 0.2)
        XCTAssertEqual(ExportPresentation.PanelMode(phase: model.export.phase), .progress)
        XCTAssertGreaterThan(magentaPixels(progress), 200, "72 × 48")

        services.sendExport(.finished(result: result("v1"), failure: nil))
        await eventually(timeout: .seconds(10)) { model.export.phase == .succeeded }
        let done = try await look(ExportSheet(model: model, window: EditorWindowState()), "result-ready", seconds: 0.2)
        XCTAssertGreaterThan(magentaPixels(done), magentaPixels(progress), "96 × 64 is larger")

        // The picture was exported with the old parameters; the current ones do not replace it.
        services.thumbnailHandler = { _, _ in nil }
        model.adjust("brightness", to: 1.2)
        await eventually(timeout: .seconds(10)) { model.export.isResultStale }
        let stale = try await look(ExportSheet(model: model, window: EditorWindowState()), "result-stale", seconds: 0.2)
        XCTAssertGreaterThan(magentaPixels(stale), 1000, "still the exported version, not dimmed away")
        model.closeDocument()
    }

    func testAProgressViewThatIsStillWaitingShowsAnEmptyBoxWithoutASpinnerOrAnIcon() async throws {
        let (model, services) = await ready(frame: nil)
        model.startExport(destination: destination, token: model.prepareExport()!)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
        XCTAssertEqual(model.export.thumbnail, .loading)
        // Before the spinner's half second and well after it: the same picture,
        // so nothing turned up in the box.
        let early = try await look(ExportSheet(model: model, window: EditorWindowState()), seconds: 0.1)
        let late = try await look(ExportSheet(model: model, window: EditorWindowState()), "progress-loading", seconds: 0.8)
        XCTAssertEqual(magentaPixels(late), 0)
        XCTAssertEqual(early.representation(using: .png, properties: [:]), late.representation(using: .png, properties: [:]),
                       "a progress box never grows a spinner")
        // And it is not the placeholder, which has the photo icon in it.
        model.export.thumbnail = .unavailable
        let none = try await look(ExportSheet(model: model, window: EditorWindowState()), "progress-none", seconds: 0.1)
        XCTAssertNotEqual(none.representation(using: .png, properties: [:]), late.representation(using: .png, properties: [:]),
                          "loading is the empty box, none is the photo icon")
        model.closeDocument()
    }

    // MARK: History

    func testHistoryRowsReadTheirPictureWhenTheyAppear() async throws {
        let picture = try magenta()
        let (model, services) = await ready(frame: nil)
        var asked: [String] = []
        services.versionThumbnailHandler = { _, id in asked.append(id); return id == "a" ? picture : nil }
        services.historyByURL[source] = ["a", "b"].enumerated().map { index, id in
            ExportHistoryItem(version: ExportVersion(number: 2 - index, createdAt: .now, encodingID: "adaptive", result: result(id)),
                              key: "key-\(id)", options: model.edit)
        }
        model.refreshExportMetadata()
        await eventually(timeout: .seconds(10)) { model.exportVersions.count == 2 }
        XCTAssertTrue(asked.isEmpty, "nothing is read before a row is on screen")
        let history = try await look(ExportHistorySheet(model: model), "history", until: { model.versionThumbnails["a"] == .ready(picture) && model.versionThumbnails["b"] == .unavailable })
        XCTAssertEqual(Set(asked), ["a", "b"])
        XCTAssertEqual(asked.count, 2, "each is read once")
        XCTAssertGreaterThan(magentaPixels(history), 500, "60 × 40 for the first row only")
        model.closeDocument()
    }
}

/// The settings view alone, as the sheet shows it while the export is set up.
private struct ExportSettingsHost: View {
    let model: EditorModel
    var body: some View { ExportSheet(model: model, window: EditorWindowState()) }
}
