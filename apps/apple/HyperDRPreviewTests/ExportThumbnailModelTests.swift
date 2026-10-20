import AppKit
import HyperDRRender
import XCTest
@testable import HyperDR

@MainActor final class ExportThumbnailModelTests: XCTestCase {
    private let source = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-first.jpg")
    private let next = URL(fileURLWithPath: "/tmp/thumbnail-second.jpg")
    private let destination = URL(fileURLWithPath: "/tmp/thumbnail-result.heic")

    private func image(_ red: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
    /// The exposure of the edit a frame shows; nil at its default.
    nonisolated private static func exposure(_ frame: EditorFrame) -> Double? {
        frame.request.recipe.value(for: "tone.exposure")?.numberValue
    }
    private func ready() async -> (EditorModel, FakeEditorServices, ScriptedRendering) {
        let rendering = ScriptedRendering()
        let services = FakeEditorServices(openDelay: .zero, rendering: rendering)
        let model = EditorModel(services: services)
        await model.loadExportServices(); model.open([source])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        return (model, services, rendering)
    }
    private func start(_ model: EditorModel, _ services: FakeEditorServices) async {
        model.startExport(destination: destination, token: model.prepareExport()!)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
    }
    private func result(_ id: String) -> ExportResult {
        ExportResult(export: id, fileName: "result.heic", byteCount: 10, pixelSize: PixelSize(width: 64, height: 48))
    }

    func testSummaryTracksOnlyWhileTheSheetOwnsItAndClearsOnSwitch() async throws {
        let a = try image(0.1), b = try image(0.8)
        let (model, _, rendering) = await ready()
        rendering.thumbnailHandler = { frame, _ in Self.exposure(frame) == nil ? a : b }
        XCTAssertTrue(rendering.thumbnailCalls.isEmpty)
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(a) }
        model.adjustRecipe("tone.exposure", to: 0.8)
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(b) }
        XCTAssertEqual(Set(rendering.thumbnailCalls), [344])
        tracking.cancel(); await tracking.value
        let calls = rendering.thumbnailCalls.count
        model.adjustRecipe("tone.exposure", to: 0.2)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(rendering.thumbnailCalls.count, calls, "no owner, no summary work")
        model.open([next])
        XCTAssertEqual(model.exportSummaryThumbnail, .loading)
        model.closeDocument()
        XCTAssertEqual(model.exportSummaryThumbnail, .unavailable)
    }

    func testAdmissionFreezesTheSameImagePassedToTheServiceAndHistory() async throws {
        let a = try image(0.1), b = try image(0.8)
        let (model, services, rendering) = await ready()
        rendering.thumbnailHandler = { frame, _ in Self.exposure(frame) == nil ? a : b }
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(a) }
        await start(model, services)
        XCTAssertTrue(services.exportCalls[0].thumbnail === a)
        XCTAssertEqual(model.export.thumbnail, .ready(a))
        model.adjustRecipe("tone.exposure", to: 0.8)
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(b) }
        XCTAssertEqual(model.export.thumbnail, .ready(a))
        services.sendExport(.finished(result: result("v1"), failure: nil))
        await eventually(timeout: .seconds(10)) { model.export.phase == .succeeded }
        XCTAssertEqual(model.versionThumbnail("v1"), .ready(a))
        XCTAssertTrue(services.versionThumbnailCalls.isEmpty)
        model.closeDocument()
    }

    func testExportWithoutASheetStillMakesOnlyTheSmallAdmissionImage() async throws {
        let a = try image(0.5)
        let (model, services, rendering) = await ready()
        rendering.thumbnailHandler = { _, _ in a }
        await start(model, services)
        XCTAssertEqual(rendering.thumbnailCalls, [256])
        XCTAssertTrue(services.exportCalls[0].thumbnail === a)
        services.sendExport(.finished(result: result("direct"), failure: nil))
        await eventually(timeout: .seconds(10)) { model.export.phase == .succeeded }
        model.closeDocument()
    }

    func testHistoryLoadsSeriallyCachesUnavailableAndDiscardsOldPhotoReplies() async throws {
        let (model, services, _) = await ready()
        let a = try image(0.4)
        var replies: [CheckedContinuation<CGImage?, Never>] = []
        services.versionThumbnailHandler = { _, _ in await withCheckedContinuation { replies.append($0) } }
        model.exportVersions = ["a", "b", "c"].map { ExportVersion(number: 1, createdAt: .now, encodingID: "adaptive", result: result($0)) }
        XCTAssertEqual(model.versionThumbnail("a"), .loading)
        XCTAssertEqual(model.versionThumbnail("b"), .loading)
        await eventually(timeout: .seconds(10)) { replies.count == 1 }
        XCTAssertEqual(services.versionThumbnailCalls, ["a"])
        replies.removeFirst().resume(returning: a)
        await eventually(timeout: .seconds(10)) { services.versionThumbnailCalls.count == 2 }
        XCTAssertEqual(model.versionThumbnail("a"), .ready(a))
        replies.removeFirst().resume(returning: nil)
        await eventually(timeout: .seconds(10)) { model.versionThumbnail("b") == .unavailable }
        XCTAssertEqual(services.versionThumbnailCalls, ["a", "b"])
        XCTAssertEqual(model.versionThumbnail("c"), .loading)
        await eventually(timeout: .seconds(10)) { replies.count == 1 }
        let oldWorker = model.versionThumbnailTask
        model.open([next])
        XCTAssertTrue(model.versionThumbnails.isEmpty)
        replies.removeFirst().resume(returning: a)
        await oldWorker?.value
        XCTAssertTrue(model.versionThumbnails.isEmpty)
        for i in 0..<25 { model.cacheVersionThumbnail(.ready(a), id: "cache-\(i)") }
        XCTAssertEqual(model.versionThumbnails.count, 20)
        XCTAssertNil(model.versionThumbnails["cache-0"])
        model.closeDocument()
    }

    func testPreviewFailureAndGenerationFailureBecomeUnavailable() async throws {
        let a = try image(0.3)
        let (model, _, rendering) = await ready()
        rendering.thumbnailHandler = { _, _ in nil }
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { rendering.thumbnailCalls.count == 1 && model.exportSummaryThumbnail == .unavailable }
        rendering.thumbnailHandler = { _, _ in a }
        model.adjustRecipe("tone.exposure", to: 0.4)
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(a) }
        // A file that is there: its renders failing is not a missing file.
        try Data([1]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        rendering.failRenders(of: source, with: ScriptedFailure())
        model.adjustRecipe("tone.exposure", to: 0.6)
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .unavailable }
        XCTAssertNotNil(model.document?.previewError)
        model.closeDocument()
    }
}
