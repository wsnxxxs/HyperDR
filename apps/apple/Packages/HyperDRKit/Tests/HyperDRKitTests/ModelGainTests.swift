import CoreGraphics
import Foundation
import HyperDREngine
import ImageIO
import Testing
@testable import HyperDRKit

/// Counts gain computations; the packet names the computation.
private actor CountingGainRenderer: PreviewRenderSession {
    private(set) var requests: [EngineRequest] = []
    private let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }

    func renderFrame(_ request: EngineRequest) async throws -> PreviewFrame {
        throw HyperDRError(code: "internal_error", message: "not used")
    }

    func modelGain(_ request: EngineRequest) async throws -> Data {
        requests.append(request)
        try await Task.sleep(for: delay)
        return Data("gain-\(requests.count)".utf8)
    }

    func close() async {}
}

private func photo(_ url: URL = URL(fileURLWithPath: "/tmp/gain.png"), format: InputFormat = .png,
                   digest: String = "gain-digest") -> PhotoSession {
    PhotoSession(id: SessionID(rawValue: String(repeating: "d", count: 32)), sourceURL: url,
        displayName: url.lastPathComponent, byteCount: 1, sha256: digest, format: format)
}

private func service(_ photo: PhotoSession, cacheEntries: Int = 2, cacheBytes: Int = 4 << 20,
                     factory: @escaping @Sendable (PhotoSession) throws -> any PreviewRenderSession)
    throws -> PreviewService {
    PreviewService(schema: try Engine.schema(), buildFingerprint: "test-build",
        knownModels: ["research-cnn-v1": true, "research-exif-v1": true], previewMaxEdge: 2048,
        previewTimeout: .seconds(5), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
        cacheEntries: cacheEntries, cacheBytes: cacheBytes,
        sessionProvider: { _ in photo }, rendererFactory: factory)
}

private let base = EditDefaults.initial(encoding: "adaptive", sourceDomain: nil, unadjusted: nil)

private func changed(_ key: String, _ value: JSONValue, from options: EditOptions = base) -> EditOptions {
    var options = options
    options[key] = value
    return options
}

/// Panel options that never reach the model, with a non-default value each.
private let outsideTheTable: [(String, JSONValue)] = [
    ("encoding", .string("pq")), ("encoding", .string("hlg")), ("hevcPreset", .string("medium")),
    ("outputGamut", .string("p3")), ("sourceDomain", .string("scene-referred")),
    ("brightness", .number(-1)), ("hdrStrength", .number(0.9)), ("hdrRange", .number(1.5)),
    ("expansionStart", .number(0.5)), ("areaCoverage", .number(0.3)),
    ("lutStrength", .number(0.5)), ("lutInput", .string("p3")), ("lutOutput", .string("rec709")),
    ("modelStrength", .number(0.3)), ("aiBrightness", .number(0.5)), ("aiContrast", .number(1.2)),
    ("aiShadows", .number(-0.5)), ("aiHighlights", .number(0.5)), ("aiHdrRange", .number(2)),
    ("aiExpansionStart", .number(0.4)), ("contrast", .number(1.2)), ("vibrance", .number(0.3)),
    ("quality", .number(70)), ("useModel", .bool(false)),
]

/// Panel options the table keys, with a value that must invalidate the gain.
private let insideTheTable: [(String, JSONValue)] = [
    ("modelId", .string("research-exif-v1")), ("colorGamut", .string("p3")),
    ("highlightRecovery", .string("clip")), ("clampSrgb", .bool(true)),
]

/// An 8-bit PNG with no colour chunk, so the engine assumes `colorGamut`.
private func untaggedPNG(at url: URL) throws {
    let width = 96, height = 64
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            pixels[index] = UInt8(x * 255 / width)
            pixels[index + 1] = UInt8(y * 255 / height)
            pixels[index + 2] = UInt8((x * 7 + y * 3) % 256)
        }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    // ImageIO tags the file sRGB; drop every chunk but the image itself.
    let png = encoded as Data
    var stripped = png.prefix(8)
    var offset = 8
    while offset + 12 <= png.count {
        let length = png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
        if ["IHDR", "IDAT", "IEND"].contains(type) { stripped += png[offset..<offset + 12 + length] }
        offset += 12 + length
    }
    try stripped.write(to: url)
}

@Suite struct ModelGainTests {
    /// Every option the editor writes is classified: keyed by the table, or
    /// shown not to reach the model. A new option fails until it is.
    @Test func everyEditOptionIsClassified() {
        let tablePanel = Set(ModelGainInputs.table.flatMap(\.panel))
        let outside = Set(outsideTheTable.map(\.0))
        #expect(tablePanel.isDisjoint(with: outside.subtracting(["encoding"])))
        #expect(Set(insideTheTable.map(\.0)).isSubset(of: tablePanel))
        // Resource selections the resolver resolves or strips; none reaches
        // the model (a LUT acts after the prediction).
        let resources: Set = ["lutId", "lutName", "rawProfileName", "rawLookName", "lensCorrection"]
        let written = Set(base.values.keys)
            .union(["highlightRecovery", "contrast", "vibrance", "quality", "useModel", "sourceDomain"])
        let classified = tablePanel.union(outside).union(resources)
        #expect(written.subtracting(classified).isEmpty, "unclassified: \(written.subtracting(classified))")
    }

    /// Changing an option outside the table reuses the cached gain; changing
    /// any option in it computes a new one.
    @Test func theKeyTableDecidesWhenTheGainIsReused() async throws {
        let renderer = CountingGainRenderer()
        let photo = photo()
        let service = try service(photo) { _ in renderer }
        try await service.attach(photo)
        let first = try await service.modelGain(session: photo.id, options: base)
        #expect(!first.fromCache)
        for (key, value) in outsideTheTable {
            let result = try await service.modelGain(session: photo.id, options: changed(key, value))
            #expect(result.fromCache && result.key == first.key && result.packet == first.packet, "\(key)")
        }
        #expect(await renderer.requests.count == 1)
        for (index, (key, value)) in insideTheTable.enumerated() {
            let options = changed(key, value)
            let expectedKey = try await service.modelGainKey(session: photo.id, options: options)
            #expect(expectedKey != first.key, "\(key)")
            let result = try await service.modelGain(session: photo.id, options: options)
            #expect(!result.fromCache && result.key == expectedKey, "\(key)")
            #expect(result.packet == Data("gain-\(index + 2)".utf8), "\(key)")
        }
        // Clamping is off for SDR output whatever the switch says, so it
        // does not invalidate there.
        let sdr = changed("encoding", .string("sdr-jpeg"))
        #expect(try await service.modelGainKey(session: photo.id, options: sdr) ==
                service.modelGainKey(session: photo.id, options: changed("clampSrgb", .bool(true), from: sdr)))
        // Back to the first options: still cached.
        #expect(try await service.modelGain(session: photo.id, options: base).fromCache)
        let requests = await renderer.requests
        #expect(requests.allSatisfy { $0.command["model_mode"] == .bool(true) })
        #expect(requests.allSatisfy { $0.settings["preview_max_edge"] == nil })
        await service.detach(photo.id)
    }

    @Test func theSourceAndTheBuildArePartOfTheKey() throws {
        let resolver = OptionResolver(schema: try Engine.schema(), knownModels: ["research-cnn-v1": true],
                                      maxEdgeCeiling: 2048)
        let original = photo()
        let request = try resolver.resolveModelGain(base, session: original)
        let key = try ModelGainKey(session: original, request: request, buildFingerprint: "a")
        #expect(try key != ModelGainKey(session: original, request: request, buildFingerprint: "b"))
        let replaced = photo(digest: "other")
        #expect(try key != ModelGainKey(session: replaced, request: request, buildFingerprint: "a"))
    }

    /// Slider frames must not push the gain out of the shared cache; only the
    /// byte budget can.
    @Test func framesDoNotEvictTheGain() async throws {
        let cache = PreviewCache<String, Int>(entries: 2, bytes: 100)
        await cache.put(0, bytes: 10, for: "gain", counted: false)
        for index in 1...5 { await cache.put(index, bytes: 10, for: "frame\(index)") }
        #expect(await cache.get("gain") == 0)
        #expect(await cache.get("frame5") == 5)
        #expect(await cache.get("frame4") == 4)
        #expect(await cache.get("frame3") == nil)
        await cache.put(9, bytes: 90, for: "large")
        #expect(await cache.get("gain") == nil, "the byte budget still applies")
        #expect(await cache.totalBytes <= 100)
    }

    @Test func concurrentRequestsShareOneComputationAndDetachClearsTheGain() async throws {
        let renderer = CountingGainRenderer(delay: .milliseconds(100))
        let photo = photo()
        let service = try service(photo) { _ in renderer }
        try await service.attach(photo)
        async let a = service.modelGain(session: photo.id, options: base)
        async let b = service.modelGain(session: photo.id, options: changed("brightness", .number(1)))
        let (first, second) = try await (a, b)
        #expect(first.packet == second.packet)
        #expect(await renderer.requests.count == 1)
        await service.detach(photo.id)
        try await service.attach(photo)
        #expect(try await !service.modelGain(session: photo.id, options: base).fromCache)
        await service.detach(photo.id)
    }

    /// The real engine: options outside the table leave the packet
    /// byte-identical; colour options in it change the packet.
    @Test func theEngineReadsOnlyTheTable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-m2k-gain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("untagged.png")
        try untaggedPNG(at: source)
        let engine = try await Engine()
        let resolver = OptionResolver(schema: try Engine.schema(),
            knownModels: ["research-cnn-v1": true, "research-exif-v1": true], maxEdgeCeiling: 2048)
        let photo = photo(source)
        // A fresh engine session per call, so no engine-side cache answers.
        func packet(_ options: EditOptions) async throws -> Data {
            let session = try engine.openPreview(source: source)
            defer { session.close() }
            return try await session.modelGain(resolver.resolveModelGain(options, session: photo))
        }
        let reference = try await packet(base)
        #expect(Array(reference.prefix(9)) == Array("HYPGAIN1\n".utf8))
        for (key, value) in outsideTheTable {
            #expect(try await packet(changed(key, value)) == reference, "\(key) changed the model gain")
        }
        let wide = changed("colorGamut", .string("p3"))
        let widePacket = try await packet(wide)
        #expect(widePacket != reference, "colorGamut must reach the model")
        #expect(try await packet(changed("clampSrgb", .bool(true), from: wide)) != widePacket,
                "clampSrgb must reach the model")

        // Through the service: the same bytes, computed once.
        let service = try service(photo) { photo in try engine.openPreview(source: photo.sourceURL) }
        try await service.attach(photo)
        let computed = try await service.modelGain(session: photo.id, options: base)
        #expect(computed.packet == reference && !computed.fromCache)
        #expect(try await service.modelGain(session: photo.id, options: changed("brightness", .number(-1))).fromCache)
        await service.detach(photo.id)
    }
}
