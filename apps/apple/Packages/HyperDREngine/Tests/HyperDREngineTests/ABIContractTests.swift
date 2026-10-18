import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import HyperDREngine

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../../..", isDirectory: true).standardized

private final class Fixture {
    let directory: URL
    let source: URL
    init(width: Int = 128, height: Int = 96) throws {
        directory = repository.appendingPathComponent("build-batch3/E2/fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source.png")
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 13 + y * 3) % 256)
                pixels[i + 1] = UInt8((x + y * 7) % 256)
                pixels[i + 2] = UInt8((x * 3 + y * 17) % 256)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

private func cli(_ arguments: [String]) async throws -> Data {
    try await EngineExecutor.run { _ in
        let process = Process()
        process.executableURL = repository.appendingPathComponent("build-apple/HyperDR")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0, "\(String(decoding: diagnostic, as: UTF8.self))")
        return bytes
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ConvertEvent] = []
    private var onDecode: (@Sendable () -> Void)?
    func append(_ event: ConvertEvent) {
        #expect(!Thread.isMainThread)
        let notify = lock.withLock {
            values.append(event)
            if event.phase == "decode" { let notify = onDecode; onDecode = nil; return notify }
            return nil as (@Sendable () -> Void)?
        }
        notify?()
    }
    var phases: [String] { lock.withLock { values.map(\.phase) } }
    func decodeStarted() async {
        await withCheckedContinuation { continuation in
            let complete = lock.withLock {
                if values.contains(where: { $0.phase == "decode" }) { return true }
                onDecode = { continuation.resume() }
                return false
            }
            if complete { continuation.resume() }
        }
    }
}

@Suite(.serialized) struct ABIContractTests {
    @Test func allPanelGoldensAndAdapterProvenance() throws {
        struct Golden: Decodable {
            let options: [String: JSONValue]
            let settings: [String: JSONValue]?
            let argv: [String]?
            let error: String?
        }
        let goldens = try JSONDecoder().decode([Golden].self, from:
            Data(contentsOf: repository.appendingPathComponent("tests/capi/golden/edit_options.json")))
        #expect(goldens.count == 41)
        for golden in goldens {
            if golden.error != nil {
                do { _ = try Engine.normalize(golden.options); Issue.record("Expected invalid_options") }
                catch let error as HyperDRError { #expect(error.code == "invalid_options") }
                continue
            }
            var request = try Engine.normalize(golden.options)
            #expect(request.settings == golden.settings)
            #expect(request.adapter == "panel-v1")
            #expect(try Engine.commandLine(request) == golden.argv)
            for key in ["input", "output", "region"] {
                try request.setCommand(key, .string("changed"))
                #expect(request.adapter == "panel-v1")
                try request.setCommand(key, nil)
                #expect(request.adapter == "panel-v1")
            }
            #expect(throws: HyperDRError.self) { try request.setCommand("adapter", nil) }
            let roundTrip = try JSONDecoder().decode(EngineRequest.self, from: JSONEncoder().encode(request))
            #expect(roundTrip == request)
        }
    }

    @Test func canonicalPrecisionAndPanelPrecision() async throws {
        let settings: [String: JSONValue] = ["contrast": .number(1.123456)]
        let canonical = EngineRequest(settings: settings)
        #expect(canonical.adapter == nil)
        let bytes = try Engine.curve(settings: settings, samples: 33)
        #expect(bytes == (try await cli(["curve", "--contrast", "1.123456", "--samples", "33"])))
        var panel = try Engine.normalize(["contrast": .number(1.123456)])
        // This is the same canonical value but tagged for panel adaptation.
        panel.setSetting("contrast", .number(1.123456))
        var panelDocument = panel.settings
        panelDocument["command"] = .object(panel.command)
        let adapted = try Engine.curve(settings: panelDocument, samples: 33)
        #expect(adapted != bytes)
        let object = try #require(JSONSerialization.jsonObject(with: adapted) as? [String: Any])
        #expect((object["contrast"] as? Double) == 1.123)
        #expect(canonical.settings["contrast"] == .number(1.123456))
    }

    @Test func inspectionContractsAndRawBytes() async throws {
        let fixture = try Fixture()
        let engine = try await Engine()
        let capabilities = try await engine.capabilities()
        #expect(capabilities.schema == "hyperdr.capabilities/v1")
        #expect(capabilities.version == Engine.version)
        #expect(capabilities.codecs)
        #expect(capabilities.encodings.count == 8)
        let decoded = try JSONDecoder().decode(Capabilities.self, from: capabilities.rawJSON)
        #expect(decoded.buildFingerprint == capabilities.buildFingerprint)
        #expect(capabilities.rawJSON.last == 10)
        let probe = try await engine.probe(fixture.source)
        #expect(probe.width == 128 && probe.height == 96)
        #expect(probe.rawJSON == (try await cli(["probe", fixture.source.path, "--json"])))
        let raw = repository.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
        #expect(FileManager.default.fileExists(atPath: raw.path), "Run scripts/fetch_test_fixtures.py first")
        let metadata = try await engine.rawMetadata(raw)
        #expect(metadata.rawJSON == (try await cli(["raw-metadata", raw.path])))
        #expect(!metadata.make.isEmpty && !metadata.model.isEmpty)
        // V4 adds the capabilities CLI. Until then, verify future encoder fields decode.
        var object = try #require(JSONSerialization.jsonObject(with: capabilities.rawJSON) as? [String: Any])
        object["encoder"] = ["backend": "videotoolbox", "main8": true, "main10": false,
                             "state": "ready", "reason": ""]
        let future = try JSONDecoder().decode(Capabilities.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(future.encoder?.main8 == true && future.encoder?.main10 == false)
    }

    @Test func framePlanesMatchPacketAndMetalUsesSamePointers() async throws {
        let fixture = try Fixture()
        let engine = try await Engine()
        let session = try engine.openPreview(source: fixture.source)
        let device = try #require(MTLCreateSystemDefaultDevice())
        for compact in [true, false] {
            var request = EngineRequest(settings: ["preview_max_edge": .number(64), "contrast": .number(1.123456)])
            try request.setCommand("compact", .bool(compact))
            let frame = try await session.renderFrame(request)
            let packet = try await session.renderPacket(request)
            #expect(String(decoding: packet.prefix(8), as: UTF8.self) == (compact ? "HYPREV2\n" : "HYPREV1\n"))
            let length = packet.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))) }
            #expect(frame.metadataJSON == packet.subdata(in: 12..<(12 + length)))
            let base = frame.base.withUnsafeBytes { Data($0) }
            let gain = frame.gain.withUnsafeBytes { Data($0) }
            #expect(packet.suffix(from: 12 + length) == base + gain)
            #expect(frame.metadata.sourceWidth == 128 && frame.metadata.sourceHeight == 96)
            #expect(frame.isCompact == compact)
            #expect(frame.base.allocationBytes % Int(getpagesize()) == 0)
            let buffers = try frame.metalBuffers(device: device)
            frame.base.withUnsafeBytes { #expect(UnsafeRawPointer(buffers.base.contents()) == $0.baseAddress) }
            frame.gain.withUnsafeBytes { #expect(UnsafeRawPointer(buffers.gain.contents()) == $0.baseAddress) }
            if compact { #expect(frame.metadata.baseHeadroom != nil && frame.metadata.alternateHeadroom != nil) }
        }
        var modelRequest = EngineRequest(settings: [:])
        try modelRequest.setCommand("model_id", .string("research-cnn-v1"))
        let gain = try await session.modelGain(modelRequest)
        #expect(gain == (try await cli(["model-gain", fixture.source.path, "--ai-model", "research-cnn-v1"])))
    }

    private final class WeakStorageBox {
        weak var value: FrameStorage?
    }

    /// Encodes work referring to both zero-copy buffers, drops every Swift owner,
    /// and keeps the GPU blocked until the caller releases the event. The command
    /// buffer and its buffers live only in this function, so returning proves
    /// that dropping the last command buffer also releases native frame storage.
    private func renderThroughBlockingGPU(_ session: PreviewSession, device: any MTLDevice,
                                          queue: any MTLCommandQueue,
                                          event: any MTLSharedEvent) async throws -> WeakStorageBox {
        let box = WeakStorageBox()
        let command = try #require(queue.makeCommandBuffer()) // retained references are mandatory
        command.encodeWaitForEvent(event, value: 1)
        var frame: PreviewFrame? = try await session.renderFrame(EngineRequest(settings: [:]))
        box.value = frame?.storage
        try autoreleasepool {
            let frameBuffers = try #require(frame).metalBuffers(device: device)
            let destination = try #require(device.makeBuffer(length: max(frameBuffers.base.length, frameBuffers.gain.length)))
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: frameBuffers.base, sourceOffset: 0, to: destination, destinationOffset: 0, size: frameBuffers.base.length)
            blit.copy(from: frameBuffers.gain, sourceOffset: 0, to: destination, destinationOffset: 0, size: frameBuffers.gain.length)
            blit.endEncoding()
        }
        frame = nil
        #expect(box.value != nil)
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
            #expect(box.value != nil) // GPU is held by the unsignalled event
            event.signaledValue = 1
        }
        #expect(command.status == .completed)
        return box
    }

    @Test func nativeFrameLivesThroughGPUCompletion() async throws {
        let fixture = try Fixture()
        let engine = try await Engine()
        let session = try engine.openPreview(source: fixture.source)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let event = try #require(device.makeSharedEvent())
        let box = try await renderThroughBlockingGPU(session, device: device, queue: queue, event: event)
        for _ in 0..<100 where box.value != nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(box.value == nil)
    }

    @Test func nativeStorageReleasesAfterLastOwner() async throws {
        let fixture = try Fixture()
        let session = try await Engine().openPreview(source: fixture.source) // session outlives engine
        let device = try #require(MTLCreateSystemDefaultDevice())
        var frame: PreviewFrame? = try await session.renderFrame(EngineRequest(settings: [:]))
        weak let storage = frame?.storage
        var base: (any MTLBuffer)?
        var gain: (any MTLBuffer)?
        try autoreleasepool {
            let buffers = try #require(frame).metalBuffers(device: device)
            base = buffers.base; gain = buffers.gain
        }
        frame = nil
        #expect(storage != nil)
        base = nil
        #expect(storage != nil)
        #expect(gain != nil)
        gain = nil
        #expect(storage == nil)
        #expect(base == nil)
    }

    @Test func busyAndActiveRenderCancellation() async throws {
        let fixture = try Fixture(width: 2600, height: 2000)
        let engine = try await Engine()
        let session = try engine.openPreview(source: fixture.source)
        let request = EngineRequest(settings: ["preview_max_edge": .number(2048)])
        let task = Task { try await session.renderFrame(request) }
        // Wait for the first call to hold the session's reservation. Starting a
        // second call before that would let either task win the race.
        for _ in 0..<1000 where !session.isReserved { await Task.yield() }
        #expect(session.isReserved)
        do { _ = try await session.renderFrame(request); Issue.record("Expected busy") }
        catch let error as HyperDRError { #expect(error.code == "busy") }
        // `isReserved` proves the wrapper holds the session, not that the native
        // decoder has entered. The large source plus this delay makes the decode
        // likely in flight, but it is not a synchronization proof; the C ABI
        // contract test covers native-active cancellation directly. This test
        // covers the Swift cancellation bridge and keeps the reservation alive.
        try await Task.sleep(for: .milliseconds(10))
        #expect(session.isReserved)
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancelled render") }
        catch let error as HyperDRError { #expect(error.code == "cancelled") }
        #expect(start.duration(to: .now) < .milliseconds(200))
        _ = try await session.renderFrame(EngineRequest(settings: ["preview_max_edge": .number(32)]))
    }

    @Test func frameFileExportDecodesSchema12Geometry() async throws {
        let fixture = try Fixture()
        let spec: [String: JSONValue] = ["margins": .number(0.05), "caption": .number(0.1)]
        let layout = try Engine.frameLayout(frame: spec, photoWidth: 128, photoHeight: 96)
        let path = fixture.directory.appendingPathComponent("frame with spaces.json")
        try JSONEncoder().encode(spec).write(to: path)
        var request = try Engine.normalize(["input": .string(fixture.source.path),
            "output": .string(fixture.directory.appendingPathComponent("export").path),
            "report": .string(fixture.directory.appendingPathComponent("report.json").path),
            "encoding": .string("sdr-jpeg")])
        try request.setCommand("frame", .string(path.path))
        let argv = try Engine.commandLine(request)
        let index = try #require(argv.firstIndex(of: "--frame"))
        #expect(argv[index + 1] == path.path)
        #expect(request.adapter == "panel-v1")
        let engine = try await Engine()
        let report = try await engine.convert(request)
        let file = try #require(report.files.first)
        #expect(file.success)
        let frame = try #require(file.frame)
        #expect(frame.width == layout.width && frame.height == layout.height)
        #expect(frame.photo == layout.photo)
        let document = try #require(JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        #expect(document["schema"] as? Int == 12)
    }

    @Test func frameVariantSurvivesLayoutAndSchema12Export() async throws {
        let fixture = try Fixture(width: 400, height: 100)
        let spec: [String: JSONValue] = ["margins": .number(0.05),
            "variants": .object(["wide": .object(["minRatio": .number(2.5),
                "reference": .string("long"), "caption": .number(0.06)])])]
        let layout = try Engine.frameLayout(frame: spec, photoWidth: 400, photoHeight: 100)
        #expect(layout.variant == "wide")
        let plain = try Engine.frameLayout(frame: spec, photoWidth: 250, photoHeight: 100)
        #expect(plain.variant == nil)
        var request = EngineRequest(settings: ["encoding": .string("sdr-tiff")])
        try request.setCommand("frame", .object(spec))
        try request.setCommand("input", .string(fixture.source.path))
        try request.setCommand("output", .string(fixture.directory.appendingPathComponent("export").path))
        let engine = try await Engine()
        let report = try await engine.convert(request)
        let file = try #require(report.files.first)
        #expect(file.success)
        let frame = try #require(file.frame)
        #expect(frame.variant == "wide" && frame.photo == layout.photo)
        #expect(frame.width == layout.width && frame.height == layout.height)
    }

    @Test func exportBytesProgressAndActiveCancellation() async throws {
        let fixture = try Fixture()
        let engine = try await Engine()
        for encoding in ["avif-pq", "avif-hlg"] {
            let output = fixture.directory.appendingPathComponent("abi-\(encoding)")
            let reference = fixture.directory.appendingPathComponent("cli-\(encoding)")
            var request = EngineRequest(settings: ["encoding": .string(encoding), "contrast": .number(1.123456)])
            try request.setCommand("input", .string(fixture.source.path))
            try request.setCommand("output", .string(output.path))
            let events = Events()
            let report = try await engine.convert(request, events: { events.append($0) })
            #expect(report.files.count == 1 && report.files[0].success)
            _ = try await cli(["convert", fixture.source.path, "--encoding", encoding, "--contrast", "1.123456", "--output", reference.path])
            let file = try #require(report.files.first)
            let expected = reference.appendingPathComponent(URL(fileURLWithPath: file.output).lastPathComponent)
            #expect(try Data(contentsOf: URL(fileURLWithPath: file.output)) == Data(contentsOf: expected))
            #expect(events.phases.first == "decode" && events.phases.last == "complete")
        }
        let large = try Fixture(width: 2600, height: 2000)
        var request = EngineRequest(settings: ["encoding": .string("sdr-jpeg")])
        try request.setCommand("input", .string(large.source.path))
        try request.setCommand("output", .string(large.directory.appendingPathComponent("cancelled").path))
        let events = Events()
        let finalRequest = request
        let task = Task { try await engine.convert(finalRequest, events: { events.append($0) }) }
        await events.decodeStarted()
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancelled export") }
        catch let error as HyperDRError { #expect(error.code == "cancelled") }
        #expect(start.duration(to: .now) < .milliseconds(200))
    }

    @Test @MainActor func synchronousAPIsRunOnMainThread() async throws {
        MainActor.preconditionIsolated()
        #expect(Engine.abiVersion == 1)
        #expect(!Engine.version.isEmpty)
        #expect(!(try Engine.schema()).settings.isEmpty)
        let curve = try Engine.curve(settings: ["contrast": .number(1.123456)], samples: 33)
        let panel = try Engine.normalize([
            "input": .string("image.png"), "output": .string("exports"),
            "report": .string("report.json"), "encoding": .string("sdr-jpeg"),
            "contrast": .number(1.123456)])
        #expect(panel.adapter == "panel-v1")
        #expect(!(try Engine.commandLine(panel)).isEmpty)
        #expect(!curve.isEmpty)
        let fixture = try Fixture()
        let engine = try await Engine()
        let session = try engine.openPreview(source: fixture.source)
        withExtendedLifetime(session) { }
    }

    @Test func rawFixtureRunsOnEngineQueue() async throws {
        let raw = repository.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
        #expect(FileManager.default.fileExists(atPath: raw.path), "Run scripts/fetch_test_fixtures.py first")
        let engine = try await Engine()
        let probe = try await engine.probe(raw)
        #expect(probe.rawJSON == (try await cli(["probe", raw.path, "--json"])))
        let metadata = try await engine.rawMetadata(raw)
        #expect(!metadata.make.isEmpty && !metadata.model.isEmpty)
        let session = try engine.openPreview(source: raw)
        var request = EngineRequest(settings: ["preview_max_edge": .number(64)])
        try request.setCommand("compact", .bool(true))
        let frame = try await session.renderFrame(request)
        #expect(frame.metadata.sourceWidth == probe.width)
        #expect(frame.metadata.sourceHeight == probe.height)
        #expect(frame.base.width <= 64 && frame.base.height <= 64)
        var gainRequest = EngineRequest(settings: [:])
        try gainRequest.setCommand("model_id", .string("research-cnn-v1"))
        let gain = try await session.modelGain(gainRequest)
        #expect(String(decoding: gain.prefix(8), as: UTF8.self) == "HYPGAIN1")
    }

    @Test func errorsAndLazyOpen() async throws {
        let fixture = try Fixture()
        let engine = try await Engine()
        let corrupt = fixture.directory.appendingPathComponent("corrupt.jpg")
        try Data([0xff, 0xd8, 0, 0]).write(to: corrupt)
        let session = try engine.openPreview(source: corrupt) // opening never reads the file
        do { _ = try await session.renderFrame(EngineRequest(settings: [:])); Issue.record("Expected decode_failed") }
        catch let error as HyperDRError { #expect(error.code == "decode_failed") }
        let good = try engine.openPreview(source: fixture.source)
        do { _ = try await good.renderFrame(EngineRequest(settings: ["unknown": .bool(true)])); Issue.record("Expected invalid_options") }
        catch let error as HyperDRError { #expect(error.code == "invalid_options") }
        do { _ = try await Engine(configuration: .init(heicTileWorkers: 5)); Issue.record("Expected invalid_options") }
        catch let error as HyperDRError { #expect(error.code == "invalid_options") }
    }
}
