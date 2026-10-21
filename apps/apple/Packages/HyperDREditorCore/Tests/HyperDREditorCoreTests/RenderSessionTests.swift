import CoreGraphics
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
        // Render gives a development loaded again its stable id (510e39cc),
        // so the first one's prediction still applies.
        let back = try await render(recipe)
        #expect(back.modelGainPending == false)
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
