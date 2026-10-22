import CoreGraphics
import CoreImage
import Foundation
import HyperDRRecipe
import HyperDRRender
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HyperDREditorCore

/// The real adapter on HyperDRRender, with a small generated photo.
@Suite struct RenderSessionTests {
    private static func tinyPhoto(width: Int = 96, height: Int = 64, type: UTType = .png) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tiny.\(type.preferredFilenameExtension!)")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test(arguments: [UTType.jpeg, .heic, .png])
    func nonRAWRendersReuseTheInitiallyOpenedSource(type: UTType) async throws {
        let url = try Self.tinyPhoto(type: type)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try RenderEngine()
        #expect(await engine.preferredRAWDecoder(url) == nil)
        #expect(await engine.defaultRAWDecoder(url) == nil)
        let session = RenderSession(engine: engine)
        let size = PixelSize(width: 48, height: 32)
        let source = try await session.open(url, previewSize: size)
        #expect(source.rawDecoderVersion == nil)
        let reloads = Counter()
        await session.setBeforeReload { await reloads.add() }
        let request = EditorRenderRequest(sourceID: source.id, recipe: Recipe(inputDomain: source.domain), size: size)
        _ = try await session.render(request)
        #expect(await reloads.count == 0, "The first canvas render must reuse the opened raster")
        // A small look preview must also be accepted before any redevelopment.
        let fresh = try await session.open(url, previewSize: size)
        var preview = EditorRenderRequest(sourceID: fresh.id, recipe: Recipe(inputDomain: fresh.domain),
                                          size: PixelSize(width: 24, height: 16))
        preview.keepsSource = true
        _ = try await session.render(preview)
        #expect(await reloads.count == 0)
        await session.close()
    }

    @MainActor @Test func jpegOriginalAndHDRContentFollowTheRenderedFrames() async throws {
        let url = try Self.tinyPhoto(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let editor = RecipeEditor(renderer: try RenderSession())
        try await editor.open(url)
        await editor.settle()
        #expect(editor.source?.domain == .sdr)
        let on = try #require(editor.frame)
        let original = try #require(editor.originalFrame)
        #expect(on.hasHDRContent)
        #expect(!original.hasHDRContent)
        #expect(RenderEngine.readTexture(original.display.gain).allSatisfy { $0 == 0 })

        var recipe = editor.recipe
        recipe.setValue(.bool(false), for: "hdr.enabled")
        editor.setRecipe(recipe)
        #expect(editor.frame?.hasHDRContent == true, "the pending edit still shows the HDR frame")
        await editor.settle()
        let off = try #require(editor.frame)
        #expect(!off.hasHDRContent)
        #expect(RenderEngine.readTexture(off.display.gain).allSatisfy { $0 == 0 })
        let offBase = RenderEngine.readTexture(off.display.base)
        let originalBase = RenderEngine.readTexture(original.display.base)
        #expect(offBase.count == originalBase.count)
        #expect((zip(offBase, originalBase).map { abs($0 - $1) }.max() ?? 0) < 0.00001)
        #expect(editor.originalFrame?.display.base === original.display.base)

        // Original detail renders use the same SDR recipe as the fitted original.
        let size = try #require(editor.source?.pixelSize)
        let detail = try await editor.render(size: size, region: CGRect(x: 8, y: 8, width: 16, height: 16), original: true)
        #expect(!detail.hasHDRContent)
        #expect(RenderEngine.readTexture(detail.display.gain).allSatisfy { $0 == 0 })

        recipe.setValue(.bool(true), for: "hdr.enabled")
        recipe.setValue(.number(0), for: "hdr.strength")
        editor.setRecipe(recipe)
        await editor.settle()
        #expect(editor.frame?.hasHDRContent == false)
        recipe.setValue(.number(100), for: "hdr.strength")
        editor.setRecipe(recipe)
        await editor.settle()
        #expect(editor.frame?.hasHDRContent == true)
        editor.bypassedGroups = [.hdr]
        await editor.settle()
        #expect(editor.frame?.hasHDRContent == false)
        await editor.close()
    }

    @Test func panoramaDetailsNeverLoadAFullWidthTexture() async throws {
        let session = try RenderSession()
        let url = try Self.tinyPhoto(width:20017,height:32)
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let source = try await session.open(url,previewSize:PixelSize(width:1024,height:1024))
        for x in [8000,16000] {
            let rect = CGRect(x:x,y:4,width:128,height:24)
            let request = EditorRenderRequest(sourceID:source.id,recipe:Recipe(inputDomain:.sdr),size:source.pixelSize,region:rect)
            let detail = try await session.render(request)
            #expect(detail.planes.base.width == 128 && detail.planes.base.height == 24)
            #expect(detail.display.region == rect)
        }
        await session.close()
    }

    @Test func opensRendersARegionAndRefusesStaleRequests() async throws {
        let session = try RenderSession()
        let url = try Self.tinyPhoto()
        let source = try await session.open(url, previewSize: PixelSize(width: 48, height: 48))
        #expect(source.domain == .sdr)
        #expect(source.pixelSize == PixelSize(width: 96, height: 64))

        var recipe = Recipe(inputDomain: .sdr)
        recipe.setValue(.number(0.5), for: "tone.exposure")
        let preview = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: recipe,
                                                                  size: PixelSize(width: 48, height: 32)))
        #expect(preview.display.outputSize == PixelSize(width: 48, height: 32))
        #expect(preview.planes.base.width == 48)

        // A region materializes only its ROI from the lazy full-quality graph.
        let detail = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: recipe,
            size: source.pixelSize, region: CGRect(x: 16, y: 8, width: 32, height: 24)))
        #expect(detail.planes.base.width == 32 && detail.planes.base.height == 24)
        #expect(detail.planes.outputSize == source.pixelSize)

        // AI renders without the model, marked pending.
        var ai = recipe
        ai.setHDRSource(.ai)
        let pending = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: ai,
                                                                  size: PixelSize(width: 48, height: 32)))
        #expect(pending.modelGainPending)
        // R1: with the prediction the same recipe renders with AI gain.
        try await session.predictModelGain(pending.request)
        var withModel = EditorRenderRequest(sourceID: source.id, recipe: ai, size: PixelSize(width: 48, height: 32))
        withModel.usesModelGain = true
        #expect(try await session.render(withModel).modelGainPending == false)

        // Automatic values come with whole renders; bypass is a render option.
        #expect(preview.automaticValues["hdr.range"] != nil)
        var bypassed = EditorRenderRequest(sourceID: source.id, recipe: recipe, size: PixelSize(width: 48, height: 32))
        bypassed.bypassedGroups = [.light]
        #expect(try await session.render(bypassed).request.recipe == recipe)

        let thumbnail = try await session.sdrThumbnail(preview, maximumSize: PixelSize(width: 24, height: 24))
        #expect(thumbnail.width == 24)

        await #expect(throws: EditorRenderingError.staleSource) {
            try await session.render(EditorRenderRequest(sourceID: UUID(), recipe: recipe, size: PixelSize(width: 48, height: 32)))
        }
    }

    /// R22-006: a prediction belongs to the source id it was made on; a new
    /// development renders pending (not an error) until predicted.
    @Test func aNewDevelopmentNeedsItsOwnPrediction() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Tests/HyperDREditorCoreTests → the checkout; `fetch_test_fixtures.py` puts it there.
        let url = (0..<6).reduce(root) { url, _ in url.deletingLastPathComponent() }
            .appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng")
        try #require(FileManager.default.fileExists(atPath: url.path), "Run scripts/fetch_test_fixtures.py")
        let session = try RenderSession()
        let size = PixelSize(width: 64, height: 64)
        let source = try await session.open(url, previewSize: size)
        var recipe = Recipe(inputDomain: source.domain)
        recipe.setHDRSource(.capturedAI)
        func render(_ recipe: Recipe, _ size: PixelSize = size) async throws -> EditorFrame {
            var request = EditorRenderRequest(sourceID: source.id, recipe: recipe, size: size)
            request.usesModelGain = true
            return try await session.render(request)
        }
        try await session.predictModelGain(try await render(recipe).request)
        #expect(try await render(recipe).modelGainPending == false)

        var warmer = recipe
        warmer.setValue(.number(5500), for: "develop.temperature")
        let pending = try await render(warmer)
        #expect(pending.modelGainPending)
        try await session.predictModelGain(pending.request)
        #expect(try await render(warmer).modelGainPending == false)
        // Another preview size shares the development.
        #expect(try await render(warmer, PixelSize(width: 128, height: 128)).modelGainPending == false)
        // Render gives a development loaded again its stable id (5a4ab9f6),
        // so the first one's prediction still applies.
        let back = try await render(recipe)
        #expect(back.modelGainPending == false)
    }

    /// Log look redevelops scene-linear, but AI stays on the Apple-boost photograph.
    @Test func logLookReusesThePrediction() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = (0..<6).reduce(root) { url, _ in url.deletingLastPathComponent() }
            .appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng")
        try #require(FileManager.default.fileExists(atPath: url.path), "Run scripts/fetch_test_fixtures.py")
        let session = try RenderSession()
        let size = PixelSize(width: 64, height: 64)
        let source = try await session.open(url, previewSize: size)
        var recipe = Recipe(inputDomain: source.domain)
        recipe.setHDRSource(.capturedAI)
        func render(_ recipe: Recipe) async throws -> EditorFrame {
            var request = EditorRenderRequest(sourceID: source.id, recipe: recipe, size: size)
            request.usesModelGain = true
            return try await session.render(request)
        }
        try await session.predictModelGain(try await render(recipe).request)
        let apple = try await render(recipe)
        #expect(apple.modelGainPending == false)
        let lut = try ColorLUT(cube: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        await session.installLUT(lut)
        var log = recipe
        log.look = LUTReference(contentHash: lut.contentHash, name: "Identity")
        log.setValue(.string("slog3-sgamut3cine"), for: "look.input")
        log.setValue(.string("rec709"), for: "look.output")
        #expect(try await render(log).modelGainPending == false)
    }

    /// A LUT preview renders small from the open development and never loads
    /// or develops the photo again; a Log look that would is refused.
    @Test func aLookPreviewKeepsTheOpenSource() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = (0..<6).reduce(root) { url, _ in url.deletingLastPathComponent() }
            .appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng")
        try #require(FileManager.default.fileExists(atPath: url.path), "Run scripts/fetch_test_fixtures.py")
        let session = try RenderSession()
        let size = PixelSize(width: 64, height: 64)
        let source = try await session.open(url, previewSize: size)
        let recipe = Recipe(inputDomain: source.domain)
        _ = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: recipe, size: size))
        let reloads = Counter()
        await session.setBeforeReload { await reloads.add() }
        let lut = try ColorLUT(cube: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        await session.installLUT(lut)
        var look = recipe
        look.look = LUTReference(contentHash: lut.contentHash, name: "Identity")
        var preview = EditorRenderRequest(sourceID: source.id, recipe: look, size: PixelSize(width: 24, height: 16))
        preview.keepsSource = true
        let frame = try await session.render(preview)
        #expect(frame.planes.base.width == 24)
        #expect(frame.automaticValues.isEmpty)
        var log = look
        log.setValue(.string("slog3-sgamut3cine"), for: "look.input")
        preview.recipe = log
        await #expect(throws: EditorRenderingError.needsDevelopment) { try await session.render(preview) }
        #expect(await reloads.count == 0)
        // Once the canvas develops Log, the same small request succeeds
        // without reopening the source. Switching back reverses availability.
        _ = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: log, size: size))
        _ = try await session.render(preview)
        #expect(await reloads.count == 1)
        preview.recipe = look
        await #expect(throws: EditorRenderingError.needsDevelopment) { try await session.render(preview) }
        _ = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: recipe, size: size))
        _ = try await session.render(preview)
        #expect(await reloads.count == 2)
    }

    private actor Counter {
        private(set) var count = 0
        func add() { count += 1 }
    }

    /// R23-001: a file replaced after opening is refused as `sourceChanged`.
    @Test func aReplacedFileIsReportedAsChanged() async throws {
        let session = try RenderSession()
        let url = try Self.tinyPhoto()
        let source = try await session.open(url, previewSize: PixelSize(width: 48, height: 48))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: try Self.tinyPhoto(width: 80, height: 64), to: url)
        let region = EditorRenderRequest(sourceID: source.id, recipe: Recipe(inputDomain: .sdr), size: source.pixelSize,
                                         region: CGRect(x: 0, y: 0, width: 16, height: 16))
        // A region loads the file again; a preview renders the source it holds.
        await #expect(throws: EditorRenderingError.sourceChanged) { try await session.render(region) }
        await #expect(throws: EditorRenderingError.sourceChanged) {
            try await session.render(EditorRenderRequest(sourceID: source.id, recipe: Recipe(inputDomain: .sdr),
                                                         size: PixelSize(width: 48, height: 32)))
        }
    }

    /// R22-001: a region render waiting to reload must not write the closed
    /// photo back; it and later renders of that photo find no source.
    @Test func aReloadAcrossCloseWritesNothingBack() async throws {
        let session = try RenderSession()
        let url = try Self.tinyPhoto()
        let source = try await session.open(url, previewSize: PixelSize(width: 48, height: 48))
        let gate = Gate()
        await session.setBeforeReload { await gate.wait() }
        let request = EditorRenderRequest(sourceID: source.id, recipe: Recipe(inputDomain: .sdr), size: source.pixelSize,
                                          region: CGRect(x: 0, y: 0, width: 16, height: 16))
        let stalled = Task { try await session.render(request) }
        await gate.reached()
        await session.close()
        await gate.open()
        await #expect(throws: EditorRenderingError.noSource) { try await stalled.value }
        await #expect(throws: EditorRenderingError.noSource) { try await session.render(request) }
    }
}

/// One waiter, released by the test.
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var arrived = false

    func wait() async {
        arrived = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { waiter = $0 }
    }

    func reached() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

extension RenderSessionTests {
    @MainActor @Test func rawDecoderSurvivesOriginalResetAndLegacyRestore() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng"), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        let editor = RecipeEditor(renderer: RenderSession(engine: engine))
        try await editor.open(url)
        await editor.settle()
        let preferred = await engine.preferredRAWDecoder(url)
        #expect(editor.recipe.rawDecoderVersion == preferred)
        #expect(editor.recipe.original.rawDecoderVersion == preferred)
        #expect(editor.frame?.request.recipe.rawDecoderVersion == preferred)
        #expect(editor.originalFrame?.request.recipe.rawDecoderVersion == preferred)
        #expect(editor.renderFailure == nil)
        editor.resetAll()
        #expect(editor.recipe.rawDecoderVersion == preferred)
        let nineDevelopment = editor.recipe.development
        let legacy = Recipe(inputDomain: .rawEDR)
        #expect(nineDevelopment != legacy.development)
        try await editor.open(url, restoring: legacy)
        await editor.settle()
        #expect(editor.recipe.rawDecoderVersion == nil)
        #expect(editor.frame?.request.recipe.rawDecoderVersion == nil)
        #expect(editor.renderFailure == nil)
        let source = try #require(editor.source)
        let baseline = try await engine.load(url, options: SourceOptions(recipe: legacy, resolution: .preview(maximumSize: PixelSize(width: 64, height: 64)))).rawSettings
        #expect(source.rawDecoderVersion == baseline?.decoderVersion)
        #expect(source.capabilities.contains("CIRAWFilter.isColorNoiseReductionSupported") == baseline?.supportsColorNR)
        await editor.close()
    }
}

extension RenderSessionTests {
    @Test func embeddedPreviewIsBoundedOrientedAndNeverGeneratedWhenAbsent() async throws {
        let url = try Self.tinyPhoto(width: 1600, height: 800, type: .heic)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let absent = try Self.tinyPhoto(width: 320, height: 160, type: .png)
        defer { try? FileManager.default.removeItem(at: absent.deletingLastPathComponent()) }
        #expect(await EmbeddedPreview.load(absent, maximumDimension: 64) == nil)
        #expect(await EmbeddedPreview.load(url, maximumDimension: 64) == nil)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rotated = url.deletingLastPathComponent().appendingPathComponent("embedded.heic")
        let destination = try #require(CGImageDestinationCreateWithURL(rotated as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationSetProperties(destination, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6,
            kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let embedded = try #require(await EmbeddedPreview.read(rotated, maximumDimension: 64))
        let preview = embedded.image
        #expect(embedded.pixelSize == PixelSize(width: 800, height: 1600))
        #expect(preview.contentHeadroom <= 1)
        #expect(max(preview.width, preview.height) <= 64)
        #expect(preview.height > preview.width)
        #expect(await EmbeddedPreview.load(rotated, maximumDimension: 0) == nil)
    }
}

// Explicit local benchmark; normal tests never depend on a user's photo.
extension RenderSessionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HYPERDR_OPEN_BENCHMARK_RAW"] != nil))
    func rawOpeningBenchmark() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HYPERDR_OPEN_BENCHMARK_RAW"]!)
        let decoder = ProcessInfo.processInfo.environment["HYPERDR_OPEN_DECODER"]
        let clock = ContinuousClock()
        for run in 1...2 {
            let started = clock.now
            let engine = try RenderEngine()
            let session = RenderSession(engine: engine)
            let initialized = clock.now
            let preview = await session.openingPreview(url)
            let thumbnail = clock.now
            let restoring = decoder.map { Recipe(inputDomain: .rawEDR, rawDecoderVersion: $0) }
            let source = try await session.open(url, previewSize: PixelSize(width: 1280, height: 1280), restoring: restoring)
            let opened = clock.now
            var recipe = Recipe(inputDomain: source.domain, rawDecoderVersion: source.rawDecoderVersion)
            let size = RecipeEditor.previewSize(source: source.pixelSize, canvasSide: 1280)
            var request = EditorRenderRequest(sourceID: source.id, recipe: recipe, size: size)
            let initialRecipe = recipe
            let initialFrame = try await session.render(request)
            let first = clock.now
            recipe.setHDRSource(.capturedAI)
            request.recipe = recipe
            try await session.predictModelGain(request)
            let predicted = clock.now
            request.usesModelGain = true
            _ = try await session.render(request)
            let finished = clock.now
            print("OPEN_BENCH run=\(run) decoder=\(source.rawDecoderVersion ?? "default") init=\(started.duration(to: initialized)) thumbnail=\(initialized.duration(to: thumbnail)) thumbnailPixels=\(preview?.image.width ?? 0)x\(preview?.image.height ?? 0) native=\(preview?.pixelSize.width ?? 0)x\(preview?.pixelSize.height ?? 0) open=\(thumbnail.duration(to: opened)) firstFrame=\(opened.duration(to: first)) ai=\(first.duration(to: predicted)) aiFrame=\(predicted.duration(to: finished))")
            let referenceSource = try await engine.load(url, options: SourceOptions(recipe: initialRecipe, resolution: .preview(maximumSize: size)))
            let reference = try await engine.render(referenceSource, recipe: initialRecipe, size: size)
            let pixels = RenderEngine.readPixels(initialFrame.planes), expected = RenderEngine.readPixels(reference)
            let baseError = zip(pixels.baseRGBA, expected.baseRGBA).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            let gainError = zip(pixels.gain, expected.gain).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            print("OPEN_REUSE_DIFF base=\(baseError) gain=\(gainError)")
            #expect(baseError == 0 && gainError == 0)
            await session.close()
        }
    }
}

extension RenderSessionTests {
    @Test func aSquareRAWOpenReusesItsExactFittedRaster() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng"), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine(), session = RenderSession(engine: engine)
        let source = try await session.open(url, previewSize: PixelSize(width: 1280, height: 1280))
        let recipe = Recipe(inputDomain: source.domain, rawDecoderVersion: source.rawDecoderVersion)
        let size = RecipeEditor.previewSize(source: source.pixelSize, canvasSide: 1280)
        let reloads = Counter()
        await session.setBeforeReload { await reloads.add() }
        let frame = try await session.render(EditorRenderRequest(sourceID: source.id, recipe: recipe, size: size))
        #expect(await reloads.count == 0)
        // An explicit reopen remains the reference path; identical pixels must
        // be produced when only the maximum preview rectangle changed.
        let reopened = try await engine.load(url, options: SourceOptions(recipe: recipe, resolution: .preview(maximumSize: size)))
        let reference = try await engine.render(reopened, recipe: recipe, size: size)
        #expect(RenderEngine.readPixels(frame.planes).baseRGBA == RenderEngine.readPixels(reference).baseRGBA)
        #expect(RenderEngine.readPixels(frame.planes).gain == RenderEngine.readPixels(reference).gain)
        let changed = Recipe(inputDomain: source.domain, values: ["develop.sharpness": .number(90)], rawDecoderVersion: source.rawDecoderVersion)
        #expect(!reopened.reusesRAWPreview(options: try SourceOptions(recipe: changed, resolution: .preview(maximumSize: size))))
        #expect(!reopened.reusesRAWPreview(options: try SourceOptions(recipe: recipe, resolution: .preview(maximumSize: PixelSize(width: 64, height: 64)))))
        await session.close()
    }
}

extension RenderSessionTests {
    private actor OpenAttempts {
        private(set) var versions: [String] = []
        func add(_ version: String?) { versions.append(version ?? "system-default") }
    }

    private static var fallbackFixtureURL: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng")
    }

    private static var fallbackFixtureSupported: Bool {
        guard let filter = CIRAWFilter(imageURL: fallbackFixtureURL) else { return false }
        return filter.decoderVersion.rawValue == "8.dng"
            && filter.supportedDecoderVersions.contains { $0.rawValue == "9.dng" }
    }

    private func fallbackFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        try FileManager.default.copyItem(at: Self.fallbackFixtureURL, to: url)
        return url
    }

    @MainActor @Test(.enabled(if: Self.fallbackFixtureSupported)) func aNewPhotosDecodeFailureRecordsTheSuccessfulDefaultWithoutReload() async throws {
        let url = try fallbackFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try RenderSession()
        let attempts = OpenAttempts(), reloads = Counter()
        await session.setBeforeOpenLoad { options in
            await attempts.add(options.rawDecoderVersion)
            if options.rawDecoderVersion == "9.dng" { throw RenderError.cannotDecodeSource }
        }
        await session.setBeforeReload { await reloads.add() }
        let editor = RecipeEditor(renderer: session)
        editor.canvasPixelSize = PixelSize(width: 64, height: 64)
        try await editor.open(url)
        await editor.settle()
        #expect(await attempts.versions == ["9.dng", "8.dng"])
        #expect(editor.recipe.rawDecoderVersion == "8.dng")
        #expect(try Recipe.decode(editor.recipe.encoded()).rawDecoderVersion == "8.dng")
        #expect(try editor.exportCapture().recipe.rawDecoderVersion == "8.dng")
        #expect(editor.source?.rawDecoderVersion == "8.dng")
        #expect(editor.source?.rawDecoderFallback == RAWDecoderFallback(requested: "9.dng", used: "8.dng"))
        #expect(editor.frame?.request.recipe.rawDecoderVersion == "8.dng")
        #expect(editor.originalFrame?.request.recipe.rawDecoderVersion == "8.dng")
        #expect(editor.renderFailure == nil)
        #expect(await reloads.count == 0)
        let source = try #require(editor.source)
        var look = EditorRenderRequest(sourceID: source.id, recipe: editor.recipe, size: PixelSize(width: 16, height: 16))
        look.keepsSource = true
        _ = try await session.render(look)
        #expect(await reloads.count == 0)
        // A failed device/camera attempt does not blacklist future photos or
        // change the decoder policy for an explicit subsequent open.
        await session.setBeforeOpenLoad(nil)
        try await editor.open(url)
        await editor.settle()
        #expect(editor.recipe.rawDecoderVersion == "9.dng")
        #expect(editor.source?.rawDecoderFallback == nil)
        await editor.close()
    }

    @Test(.enabled(if: Self.fallbackFixtureSupported), arguments: [false, true])
    func savedRecipesNeverDowngradeTheirDecoder(legacy: Bool) async throws {
        let url = try fallbackFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try RenderSession(), attempts = OpenAttempts()
        await session.setBeforeOpenLoad { options in
            await attempts.add(options.rawDecoderVersion)
            throw RenderError.cannotDecodeSource
        }
        let recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: legacy ? nil : "9.dng")
        await #expect(throws: (any Error).self) {
            try await session.open(url, previewSize: PixelSize(width: 64, height: 64), restoring: recipe)
        }
        #expect(await attempts.versions == [legacy ? "system-default" : "9.dng"])
    }

    @Test(.enabled(if: Self.fallbackFixtureSupported), arguments: ["cancelled", "allocation", "gpu", "changed", "invalid"])
    func unrelatedInitialFailuresNeverDowngradeDecoder(kind: String) async throws {
        let url = try fallbackFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try RenderSession(), attempts = OpenAttempts()
        await session.setBeforeOpenLoad { options in
            await attempts.add(options.rawDecoderVersion)
            switch kind {
            case "cancelled": throw CancellationError()
            case "allocation": throw RenderError.allocationFailed
            case "gpu": throw RenderError.gpu("test")
            case "changed": throw RenderError.sourceChanged
            default: throw RenderError.invalidSize
            }
        }
        await #expect(throws: (any Error).self) {
            try await session.open(url, previewSize: PixelSize(width: 64, height: 64))
        }
        #expect(await attempts.versions == ["9.dng"])
    }

    @Test(.enabled(if: Self.fallbackFixtureSupported)) func aFailedDefaultIsNotRetriedAgain() async throws {
        let url = try fallbackFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try RenderSession(), attempts = OpenAttempts()
        await session.setBeforeOpenLoad { options in
            await attempts.add(options.rawDecoderVersion)
            throw RenderError.cannotDecodeSource
        }
        await #expect(throws: (any Error).self) {
            try await session.open(url, previewSize: PixelSize(width: 64, height: 64))
        }
        #expect(await attempts.versions == ["9.dng", "8.dng"])
    }
}
