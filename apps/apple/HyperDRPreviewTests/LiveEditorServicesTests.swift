import CoreGraphics
import ImageIO
import Foundation
import HyperDRKit
import XCTest
@testable import HyperDR

@MainActor final class LiveEditorServicesTests: XCTestCase {
    private func environment() throws -> (URL, URL, KitConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "photo", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "photo", withExtension: "jpg"))
        let source = root.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: fixture, to: source)
        let config = KitConfiguration(supportDirectory: root.appendingPathComponent("support"),
            cacheDirectory: root.appendingPathComponent("cache"))
        return (root, source, config)
    }

    func testRealJPEGFramesFullSizeFailureRollbackAndRestore() async throws {
        let (root, source, config) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let (preferences, suite) = UserDefaults.ephemeral()
        defer { preferences.removePersistentDomain(forName: suite) }
        var starts = 0, stops = 0
        let lifecycle = LiveEditorServices.Lifecycle(start: { kit in starts += 1; await kit.start() },
                                                     stop: { kit in stops += 1; kit.stop() })
        let services = LiveEditorServices(configuration: config, preferences: preferences, lifecycle: lifecycle)
        let model = EditorModel(services: services)
        await eventually(timeout: .seconds(15), "engine ready") {
            if case .ready = model.engine { return true }; return false
        }
        await services.start()
        await services.start()
        XCTAssertEqual(starts, 1)
        model.open([source])
        await eventually(timeout: .seconds(15), "JPEG frames") { model.document?.phase == .ready }
        XCTAssertNotNil(model.canvasFrame)
        XCTAssertNotNil(model.editedCanvasFrame)
        let frame = try XCTUnwrap(model.editedCanvasFrame?.frame)
        XCTAssertEqual(model.document?.pixelSize?.width, frame.metadata.sourceWidth)
        XCTAssertEqual(model.document?.pixelSize?.height, frame.metadata.sourceHeight)
        XCTAssertEqual(model.document?.pixelSize, PixelSize(width: 1600, height: 2400))
        XCTAssertLessThan(frame.base.height, 2400, "document dimensions must survive preview downsampling")
        model.viewMode = .original
        XCTAssertEqual(model.canvasFrame?.showsOriginal, true)
        XCTAssertEqual(model.editedCanvasFrame?.showsOriginal, false)
        let old = model.document
        let corrupt = root.appendingPathComponent("corrupt.jpg")
        try Data([0xff, 0xd8, 0xff, 0xe0] + [UInt8](repeating: 0, count: 64)).write(to: corrupt)
        model.open([corrupt])
        await eventually(timeout: .seconds(15), "corrupt JPEG failure") { model.alert != nil }
        XCTAssertEqual(model.alert?.code, "decode_failed")
        XCTAssertEqual(model.document, old)
        XCTAssertNotNil(model.canvasFrame)
        // Opening a bad file updates durable history; reopen the good photo
        // before simulating a fresh launch of the model and services.
        model.open([source])
        await eventually(timeout: .seconds(15)) { model.document?.phase == .ready }
        model.closeDocument()
        await settle()
        services.stop()
        services.stop()
        XCTAssertEqual(stops, 1)
        let restoredServices = LiveEditorServices(configuration: config, preferences: preferences)
        defer { restoredServices.stop() }
        let restoredModel = EditorModel(services: restoredServices)
        restoredModel.launch()
        await eventually(timeout: .seconds(15), "remembered JPEG") { restoredModel.document?.phase == .ready }
        XCTAssertEqual(restoredModel.document?.name, source.lastPathComponent)
        XCTAssertNotNil(restoredModel.canvasFrame)
        restoredModel.closeDocument()
        await settle()
    }

    func testContentExtensionMismatchKeepsWorkspaceEmpty() async throws {
        let (root, source, config) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let mismatch = root.appendingPathComponent("photo.png")
        try FileManager.default.copyItem(at: source, to: mismatch)
        let (preferences, suite) = UserDefaults.ephemeral()
        defer { preferences.removePersistentDomain(forName: suite) }
        let services = LiveEditorServices(configuration: config, preferences: preferences)
        defer { services.stop() }
        let model = EditorModel(services: services)
        model.open([mismatch])
        await eventually(timeout: .seconds(15)) { model.alert != nil }
        XCTAssertEqual(model.alert?.code, "input_extension_mismatch")
        XCTAssertEqual(model.workspace, .empty)
    }
}

// Background reads record their count without capturing a main-actor test.
nonisolated private final class FactsReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var count = 0
    private var onMain = false
    func read(_ url: URL) -> CaptureFacts {
        lock.withLock { count += 1; onMain = onMain || Thread.isMainThread }
        // Only the detached reader blocks; the test's main actor remains free.
        _ = release.wait(timeout: .now() + 10)
        return CaptureFacts()
    }
    func finish() { release.signal() }
    var snapshot: (count: Int, onMain: Bool) { lock.withLock { (count, onMain) } }
}

extension LiveEditorServicesTests {
    func testCaptureFactsAreCachedByHandleAndReAdoptionReadsReplacement() async throws {
        let (root, source, config) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ model: String) throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2,
                bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL,
                "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: model]] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try write("Model A")
        let (preferences, suite) = UserDefaults.ephemeral()
        defer { preferences.removePersistentDomain(forName: suite) }
        let services = LiveEditorServices(configuration: config, preferences: preferences)
        defer { services.stop() }
        let photo = try await services.open(source)
        let first = await services.captureFacts(for: photo)
        XCTAssertEqual(first.model, "Model A")
        try write("Model B")
        let second = await services.captureFacts(for: photo)
        XCTAssertEqual(second, first, "Same handle keeps its first facts despite a replaced source")
        await services.close(photo)
        let replacement = try await services.open(source)
        XCTAssertNotEqual(replacement.handle, photo.handle)
        let updated = await services.captureFacts(for: replacement)
        XCTAssertEqual(updated.model, "Model B")
        await services.close(replacement)
    }

    func testConcurrentCaptureFactsReadsShareOneBackgroundTaskAndCacheEmptyResult() async throws {
        let (root, source, config) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let (preferences, suite) = UserDefaults.ephemeral()
        defer { preferences.removePersistentDomain(forName: suite) }
        let counter = FactsReadCounter()
        defer { counter.finish() }
        let services = LiveEditorServices(configuration: config, preferences: preferences,
            readCaptureFacts: { counter.read($0) })
        defer { services.stop() }
        let photo = try await services.open(source)
        var completed = 0
        let tasks = (0..<12).map { _ in Task {
            let result = await services.captureFacts(for: photo)
            completed += 1
            return result
        } }
        await eventually { counter.snapshot.count == 1 }
        await settle()
        XCTAssertEqual(completed, 0, "Concurrent callers are waiting for the same in-flight read")
        counter.finish()
        for task in tasks { let facts = await task.value; XCTAssertEqual(facts, CaptureFacts()) }
        let repeated = await services.captureFacts(for: photo)
        XCTAssertEqual(repeated, CaptureFacts())
        XCTAssertEqual(counter.snapshot.count, 1)
        XCTAssertFalse(counter.snapshot.onMain)
        await services.close(photo)
        let closed = await services.captureFacts(for: photo)
        XCTAssertEqual(closed, CaptureFacts())
        XCTAssertEqual(counter.snapshot.count, 1)
    }
}
