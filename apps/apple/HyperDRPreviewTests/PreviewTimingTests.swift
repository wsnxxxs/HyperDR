import XCTest
@_spi(Testing) import HyperDREngine
import HyperDRKit
import Metal
import Synchronization
@testable import HyperDR

@MainActor final class PreviewTimingTests: XCTestCase {
    func testTaskLocalRequestTraceReachesTheRealFrameAndItsMetalBuffers() async throws {
        let engine = try await Engine()
        let bundle = previewFixtureBundle()
        let url = try XCTUnwrap(bundle.url(forResource:"photo", withExtension:"jpg", subdirectory:"Fixtures")
            ?? bundle.url(forResource:"photo", withExtension:"jpg"))
        let session = try engine.openPreview(source: url)
        defer { session.close() }
        let trace = PreviewTrace(recording: true)
        let frame = try await PreviewTrace.$current.withValue(trace) {
            try await session.renderFrame(EngineRequest(settings:["preview_max_edge":.number(64)]))
        }
        XCTAssertTrue(frame.trace === trace)
        let renderer = try makePreviewRenderer()
        let buffers = try frame.metalBuffers(device: renderer.device)
        XCTAssertGreaterThan(buffers.base.length, 0)
        XCTAssertGreaterThan(buffers.gain.length, 0)
    }

    func testSchedulerAndLiveSubmitPumpPreserveTheSameRequestTrace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-trace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = previewFixtureBundle()
        let url = try XCTUnwrap(bundle.url(forResource:"photo", withExtension:"jpg", subdirectory:"Fixtures")
            ?? bundle.url(forResource:"photo", withExtension:"jpg"))
        let (preferences, suite) = UserDefaults.ephemeral()
        defer { preferences.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input.jpg")
        try FileManager.default.copyItem(at: url, to: source)
        let services = LiveEditorServices(configuration: KitConfiguration(supportDirectory:root.appendingPathComponent("support"),
            cacheDirectory:root.appendingPathComponent("cache")), preferences: preferences)
        defer { services.stop() }
        let model = EditorModel(services: services)
        await eventually(timeout: .seconds(15)) { if case .ready = model.engine { return true }; return false }
        model.open([source])
        await eventually(timeout: .seconds(15)) { model.document?.phase == .ready }
        model.adjust("brightness", to: 0.5)
        let trace = try XCTUnwrap(model.lastJob?.trace)
        await eventually(timeout: .seconds(15)) { model.currentEditedFrame?.trace === trace }
        let first = try XCTUnwrap(model.currentEditedFrame)
        model.adjust("brightness", to: 0.6)
        let middle = try XCTUnwrap(model.lastJob?.trace)
        await eventually(timeout: .seconds(15)) { model.editedPresentationTrace === middle }
        model.adjust("brightness", to: 0.5)
        let cached = try XCTUnwrap(model.lastJob?.trace)
        await eventually(timeout: .seconds(15)) { model.editedPresentationTrace === cached }
        XCTAssertTrue(model.currentEditedFrame === first, "The pixel cache is still reused")
        XCTAssertTrue(model.canvasComposition?.presentationTrace === cached, "A cache hit must time this request, not the first render")
        XCTAssertTrue(first.trace === trace, "Publication must not mutate immutable pixel provenance")
        XCTAssertFalse(cached.hasPresented, "Offscreen service completion is not a presentation")
        model.viewMode = .compare
        model.canvas.setViewport(CGSize(width: 16, height: 16), backingScale: 1)
        model.canvas.previewPixelSize = CGSize(width: 1, height: 1)
        model.canvas.referencePixelSize = CGSize(width: 1, height: 1)
        model.scheduleDetails()
        await model.detailTask?.value
        XCTAssertNotNil(model.originalDetailTrace)
        XCTAssertNotNil(model.editedDetailTrace)
        XCTAssertTrue(model.canvasComposition?.originalDetailTrace === model.originalDetailTrace)
        XCTAssertTrue(model.canvasComposition?.editedDetailTrace === model.editedDetailTrace)
        model.invalidateDetails()
        XCTAssertNil(model.originalDetailTrace)
        XCTAssertNil(model.editedDetailTrace)
        model.closeDocument()
    }

    func testCachedOriginalAndBothDetailLayersEncodeWithPublicationTraces() async throws {
        let engine = try await Engine()
        let bundle = previewFixtureBundle()
        let url = try XCTUnwrap(bundle.url(forResource: "photo", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "photo", withExtension: "jpg"))
        let session = try engine.openPreview(source: url)
        defer { session.close() }
        let staleEvents = Mutex<[String]>([])
        let stale = PreviewTrace(onRecord: { stage, event in staleEvents.withLock { $0.append(stage + ":" + event) } })
        let frame = try await PreviewTrace.$current.withValue(stale) {
            try await session.renderFrame(EngineRequest(settings: ["preview_max_edge": .number(32), "headroom": .number(2)]))
        }
        var request = EngineRequest(settings: ["preview_max_edge": .number(32), "headroom": .number(2)])
        try request.setCommand("region", .object(["left": .number(4), "top": .number(4),
            "width": .number(16), "height": .number(12)]))
        let detail = try await PreviewTrace.$current.withValue(stale) { try await session.renderFrame(request) }
        let renderer = try makePreviewRenderer()
        let compositor = try CanvasCompositor(device: renderer.device, queue: renderer.queue, library: renderer.library)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let transform = CanvasTransform(imageSize: CGSize(width: frame.base.width, height: frame.base.height), viewport: CGSize(width: 16, height: 16))
        func encode(_ composition: CanvasComposition) async throws {
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try compositor.encode(composition, transform: transform, target: target, command: command)
            command.commit()
            await eventually(timeout: .seconds(10)) { command.status == .completed }
        }
        try await encode(CanvasComposition(original: frame, edited: frame, presentationTrace: stale))
        staleEvents.withLock { $0.removeAll() }
        let events = Mutex<[String]>([])
        let publication = PreviewTrace(onRecord: { stage, event in events.withLock { $0.append(stage + ":" + event) } })
        try await encode(CanvasComposition(original: frame, edited: frame, mode: .original, presentationTrace: publication))
        XCTAssertTrue(events.withLock { $0.contains("metalBuffers:begin") && $0.contains("pass1_encode:begin") })
        XCTAssertTrue(staleEvents.withLock { $0.isEmpty })

        let originalEvents = Mutex<[String]>([]), editedEvents = Mutex<[String]>([])
        let original = PreviewTrace(onRecord: { stage, event in originalEvents.withLock { $0.append(stage + ":" + event) } })
        let edited = PreviewTrace(onRecord: { stage, event in editedEvents.withLock { $0.append(stage + ":" + event) } })
        var content = CanvasComposition(original: frame, edited: frame, originalDetail: detail, editedDetail: detail,
            mode: .compare, presentationTrace: publication, originalDetailTrace: original, editedDetailTrace: edited)
        try await encode(content)
        for log in [originalEvents.withLock({ $0 }), editedEvents.withLock({ $0 })] {
            XCTAssertTrue(log.contains("metalBuffers:begin") && log.contains("pass1_encode:begin"))
        }
        XCTAssertTrue(staleEvents.withLock { $0.isEmpty })
        XCTAssertEqual(content.presentedTraces.map(\.token), [publication, original, edited].map(\.token))
        // Headroom-only rebuilds must use the same publication ownership too.
        originalEvents.withLock { $0.removeAll() }; editedEvents.withLock { $0.removeAll() }
        content.headroom = 2
        try await encode(content)
        XCTAssertTrue(originalEvents.withLock { $0.contains("pass1_encode:begin") })
        XCTAssertTrue(editedEvents.withLock { $0.contains("pass1_encode:begin") })
        content.mode = .original
        XCTAssertEqual(content.presentedTraces.map(\.token), [publication, original].map(\.token))
        XCTAssertFalse(publication.hasPresented)
        XCTAssertFalse(original.hasPresented)
        XCTAssertFalse(edited.hasPresented)
        XCTAssertTrue(frame.trace === stale)
    }

    func testGPUCounterCalibrationCompletesInTheSameCommandBuffer() async throws {
        let renderer = try makePreviewRenderer()
        guard renderer.device.supportsCounterSampling(.atStageBoundary),
              renderer.device.counterSets?.contains(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) == true else {
            throw XCTSkip("GPU timestamp counter set unavailable")
        }
        let sampled = Mutex<(UInt64, UInt64)?>(nil)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(PreviewGPUTiming.encoder(device: renderer.device, command: command,
            trace: PreviewTrace(recording: true), enabled: true, onInterval: { begin, end in sampled.withLock { $0 = (begin, end) } }))
        let values = [Float](repeating: 0.5, count: 16*16*3)
        let base = try XCTUnwrap(renderer.device.makeBuffer(bytes: values, length: values.count*4))
        let planes = FramePlanes(base: base, baseRowBytes: 16*12, gain: base, gainRowBytes: 16*12,
            gainChannels: 3, width: 16, height: 16, gainWidth: 16, gainHeight: 16)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false)
        descriptor.usage = .shaderWrite
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let pipeline = try await renderer.device.makeComputePipelineState(function: XCTUnwrap(renderer.library.makeFunction(name: "reconstructFrame")))
        var params = ReconstructParams(planes: planes, original: false)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(base, offset: 0, index: 0); encoder.setBuffer(base, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ReconstructParams>.stride, index: 2)
        encoder.setTexture(texture, index: 0)
        encoder.dispatchThreads(MTLSize(width:16,height:16,depth:1), threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding()
        command.commit()
        await eventually(timeout: .seconds(3)) { sampled.withLock { $0 != nil } }
        let result = try XCTUnwrap(sampled.withLock { $0 })
        XCTAssertGreaterThan(result.0, 0)
        XCTAssertGreaterThanOrEqual(result.1, result.0)
        XCTAssertEqual(command.status, .completed)
    }
}
