import AppKit
import HyperDREngine
import XCTest
@testable import HyperDR

@MainActor final class ExportThumbnailModelTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/tmp/thumbnail-first.jpg")
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
    private func frame(_ exposure: Double = 0) async throws -> PreviewFrame {
        let photo = try TinyPhoto(); defer { photo.remove() }
        let engine = try await Engine(), session = try engine.openPreview(source: photo.url)
        defer { session.close() }
        return try await session.renderFrame(EngineRequest(settings: ["preview_max_edge": .number(8), "exposure_bias": .number(exposure)]))
    }
    private func preview(_ frame: PreviewFrame?) -> EditorPreview {
        EditorPreview(pixelSize: PixelSize(width: 64, height: 48),
            source: SourceSummary(domain: .sdr, colorName: "Display P3", degradationReasons: []), hasGain: true, frame: frame)
    }
    private func ready(_ frame: PreviewFrame? = nil) async -> (EditorModel, FakeEditorServices) {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        services.preview = preview(frame)
        let model = EditorModel(services: services, ticker: ManualFrameTicker())
        await model.loadExportServices(); model.open([source])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        return (model, services)
    }
    private func start(_ model: EditorModel, _ services: FakeEditorServices) async {
        model.startExport(destination: destination, token: model.prepareExport()!)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
    }
    private func result(_ id: String) -> ExportResult {
        ExportResult(export: id, fileName: "result.heic", byteCount: 10, pixelSize: PixelSize(width: 64, height: 48))
    }

    func testSummaryTracksOnlyWhileTheSheetOwnsItAndClearsOnSwitch() async throws {
        let first = try await frame(), second = try await frame(0.8)
        let a = try image(0.1), b = try image(0.8)
        let (model, services) = await ready(first)
        services.thumbnailHandler = { value, _ in value === first ? a : b }
        XCTAssertTrue(services.thumbnailCalls.isEmpty)
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(a) }
        XCTAssertEqual(services.thumbnailCalls, [344])
        for _ in 0..<10 { model.apply(.edited(preview(second))) }
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(b) }
        XCTAssertEqual(services.thumbnailCalls, [344, 344])
        tracking.cancel(); await tracking.value
        model.apply(.edited(preview(first)))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(services.thumbnailCalls, [344, 344])
        model.open([next])
        XCTAssertEqual(model.exportSummaryThumbnail, .loading)
        model.closeDocument()
        XCTAssertEqual(model.exportSummaryThumbnail, .unavailable)
    }

    func testAdmissionFreezesTheSameImagePassedToTheServiceAndHistory() async throws {
        let first = try await frame(), second = try await frame(0.8)
        let a = try image(0.1), b = try image(0.8)
        let (model, services) = await ready(first)
        services.thumbnailHandler = { value, _ in value === first ? a : b }
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(a) }
        await start(model, services)
        XCTAssertTrue(services.exportCalls[0].thumbnail === a)
        XCTAssertEqual(model.export.thumbnail, .ready(a))
        model.apply(.edited(preview(second)))
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(b) }
        XCTAssertEqual(model.export.thumbnail, .ready(a))
        services.sendExport(.finished(result: result("v1"), failure: nil))
        await eventually(timeout: .seconds(10)) { model.export.phase == .succeeded }
        XCTAssertEqual(model.versionThumbnail("v1"), .ready(a))
        XCTAssertTrue(services.versionThumbnailCalls.isEmpty)
        model.closeDocument()
    }

    func testMissingAdmissionFrameFillsMemoryWithoutBackfillingTheRecord() async throws {
        let actual = try await frame(), a = try image(0.2)
        let (model, services) = await ready()
        services.thumbnailHandler = { _, _ in a }
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .loading }
        await start(model, services)
        XCTAssertNil(services.exportCalls[0].thumbnail)
        XCTAssertEqual(model.export.thumbnail, .loading)
        model.apply(.edited(preview(actual)))
        await eventually(timeout: .seconds(10)) { model.export.thumbnail == .ready(a) }
        XCTAssertNil(services.exportCalls[0].thumbnail)
        services.sendExport(.finished(result: result("no-disk-thumb"), failure: nil))
        await eventually(timeout: .seconds(10)) { model.export.phase == .succeeded }
        XCTAssertEqual(model.versionThumbnail("no-disk-thumb"), .unavailable)
        XCTAssertEqual(model.export.thumbnail, .ready(a))
        model.closeDocument()
    }

    func testExportWithoutASheetStillMakesOnlyTheSmallAdmissionImage() async throws {
        let actual = try await frame(), a = try image(0.5)
        let (model, services) = await ready(actual)
        services.thumbnailHandler = { _, _ in a }
        await start(model, services)
        XCTAssertEqual(services.thumbnailCalls, [256])
        XCTAssertTrue(services.exportCalls[0].thumbnail === a)
        services.sendExport(.finished(result: result("direct"), failure: nil))
        await eventually(timeout: .seconds(10)) { model.export.phase == .succeeded }
        model.closeDocument()
    }

    func testHistoryLoadsSeriallyCachesUnavailableAndDiscardsOldPhotoReplies() async throws {
        let (model, services) = await ready()
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
        let actual = try await frame()
        let (model, services) = await ready(actual)
        services.thumbnailHandler = { _, _ in nil }
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { services.thumbnailCalls.count == 1 && model.exportSummaryThumbnail == .unavailable }
        model.apply(.reference(preview(actual)))
        XCTAssertEqual(model.exportSummaryThumbnail, .loading)
        XCTAssertEqual(services.thumbnailCalls.count, 1)
        model.apply(.failed(UserFacingError(code: "decode_failed")))
        XCTAssertEqual(model.exportSummaryThumbnail, .unavailable)
        model.closeDocument()
    }
}
