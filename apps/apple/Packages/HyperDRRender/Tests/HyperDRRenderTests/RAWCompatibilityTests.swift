import CoreGraphics
import CoreImage
import Foundation
import HyperDRRecipe
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HyperDRRender

private final class CompatibilityConverter: RAWCompatibilityConverting, @unchecked Sendable {
    let converterID: String
    let dng: URL?
    let preview: URL?
    let camera: String?
    private let lock = NSLock()
    private(set) var conversions = 0
    private(set) var extractions = 0

    init(converterID: String = "test-libraw/dng-1", dng: URL?, preview: URL?, camera: String? = nil) {
        self.converterID = converterID
        self.dng = dng
        self.preview = preview
        self.camera = camera
    }

    func convertDNG(from source: URL) async throws -> RAWConvertedDNG {
        let count = lock.withLock { conversions += 1; return conversions }
        guard let dng else { throw RenderError.rawUnsupported(camera: camera) }
        return RAWConvertedDNG(url: dng, converterID: converterID, usedCache: count > 1)
    }

    func extractEmbeddedPreview(from source: URL) async throws -> RAWEmbeddedPreview {
        lock.withLock { extractions += 1 }
        guard let preview else { throw RAWCompatibilityError.noPreview }
        return RAWEmbeddedPreview(url: preview, usedCache: true, orientation: 6)
    }
}

final class RAWCompatibilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RenderEngine.registerRAWCompatibilityConverter(nil)
        RenderEngine.forcesRAWCompatibility = false
    }

    override func tearDown() {
        RenderEngine.forcesRAWCompatibility = false
        RenderEngine.registerRAWCompatibilityConverter(nil)
        super.tearDown()
    }

    private func fixture(named name: String = "sony-ilce-7s.ARW") throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let input = root.appendingPathComponent("build/fixtures/" + name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + "." + input.pathExtension)
        try FileManager.default.copyItem(at: input, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func jpeg(width: Int = 8, height: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testForcedConversionRecordsConverterAndReopensIt() async throws {
        let url = try fixture()
        let native = try XCTUnwrap(CIRAWFilter(imageURL: url)?.nativeSize)
        let converter = CompatibilityConverter(dng: url, preview: nil)
        RenderEngine.registerRAWCompatibilityConverter(converter)
        RenderEngine.forcesRAWCompatibility = true
        let resolution = SourceResolution.preview(maximumSize: PixelSize(width: 256, height: 256))
        let source = try await RenderEngine().load(url, options: SourceOptions(resolution: resolution))
        XCTAssertEqual(source.domain, .rawEDR)
        XCTAssertEqual(source.sourceCompatibility, .convertedDNG)
        XCTAssertEqual(source.rawCompatibility, converter.converterID)
        XCTAssertEqual(source.uncroppedSize, PixelSize(width: Int(native.width), height: Int(native.height)))
        XCTAssertEqual(converter.conversions, 1)

        let recipe = Recipe(inputDomain: source.domain, rawDecoderVersion: source.rawSettings?.decoderVersion,
                            rawCompatibility: source.rawCompatibility)
        XCTAssertEqual(try Recipe.decode(recipe.encoded()).rawCompatibility, converter.converterID)
        let reopened = try await RenderEngine().load(url, options: SourceOptions(recipe: recipe, resolution: resolution),
                                                     allowsRAWCompatibilityFallback: false)
        XCTAssertEqual(reopened.id, source.id)
        XCTAssertEqual(reopened.sourceCompatibility, .convertedDNG)
        XCTAssertEqual(converter.conversions, 2)
    }

    func testExplicitDecoderSelectionKeepsConvertedDNG() async throws {
        let url = try fixture()
        let dng = try fixture(named: "canon-eos-5d-iii-lossy.dng")
        let converter = CompatibilityConverter(dng: dng, preview: nil)
        RenderEngine.registerRAWCompatibilityConverter(converter)
        RenderEngine.forcesRAWCompatibility = true
        let selection = try await RenderEngine().rawDecoderSelection(url, generation: 8)
        XCTAssertEqual(selection.version, "8.dng")
        XCTAssertEqual(selection.converterID, converter.converterID)

        var options = SourceOptions(resolution: .preview(maximumSize: PixelSize(width: 128, height: 128)))
        options.rawDecoderVersion = selection.version
        options.rawCompatibility = selection.converterID
        let source = try await RenderEngine().load(url, options: options)
        XCTAssertEqual(source.sourceCompatibility, .convertedDNG)
        XCTAssertEqual(source.rawCompatibility, converter.converterID)
        XCTAssertEqual(source.rawSettings?.decoderVersion, "8.dng")
    }

    func testSystemDecoderProbeReportsGenerations() {
        let generations = RenderEngine.systemRAWDecoderGenerations
        XCTAssertTrue(generations.contains(8), "\(generations)")
        XCTAssertEqual(RenderEngine.systemSupportsRAW9, generations.contains(9))
    }

    func testLibRAWSelectionConvertsACameraTheSystemSupports() async throws {
        let url = try fixture()
        XCTAssertTrue(RenderEngine.systemDevelops(url))
        let dng = try fixture(named: "canon-eos-5d-iii-lossy.dng")
        let converter = CompatibilityConverter(dng: dng, preview: nil)
        RenderEngine.registerRAWCompatibilityConverter(converter)
        let engine = try RenderEngine()
        let selected = try await engine.libRAWDecoderSelection(url)
        let selection = try XCTUnwrap(selected)
        XCTAssertEqual(selection.converterID, converter.converterID)
        let version = try XCTUnwrap(selection.version)
        XCTAssertTrue(version.hasSuffix(".dng"), version)
        let listed = try XCTUnwrap(CIRAWFilter(imageURL: dng)).supportedDecoderVersions.map(\.rawValue)
        XCTAssertEqual(version, listed.contains("9.dng") ? "9.dng" : "8.dng")

        var options = SourceOptions(resolution: .preview(maximumSize: PixelSize(width: 128, height: 128)))
        options.rawDecoderVersion = selection.version
        options.rawCompatibility = selection.converterID
        let source = try await engine.load(url, options: options)
        XCTAssertEqual(source.sourceCompatibility, .convertedDNG)
        XCTAssertEqual(source.rawSettings?.decoderVersion, version)
        let fallback = await engine.fallbackRAWDecoder(url, converterID: converter.converterID)
        XCTAssertEqual(fallback, "8.dng")
    }

    func testLibRAWSelectionLeavesUnreadableCamerasAndDNGOriginalsToTheCaller() async throws {
        let url = try fixture()
        let unreadable = CompatibilityConverter(dng: nil, preview: nil, camera: "Sony ILCE-7S")
        RenderEngine.registerRAWCompatibilityConverter(unreadable)
        let engine = try RenderEngine()
        let none = try await engine.libRAWDecoderSelection(url)
        XCTAssertNil(none)
        XCTAssertEqual(unreadable.extractions, 0)

        let dng = try fixture(named: "canon-eos-5d-iii-lossy.dng")
        let converter = CompatibilityConverter(dng: dng, preview: nil)
        RenderEngine.registerRAWCompatibilityConverter(converter)
        let original = try await engine.libRAWDecoderSelection(dng)
        XCTAssertNil(original?.converterID)
        let preferred = await engine.preferredRAWDecoder(dng)
        XCTAssertEqual(original?.version, preferred)
        XCTAssertEqual(converter.conversions, 0)

        let raster = try jpeg()
        let rasterSelection = try await engine.libRAWDecoderSelection(raster)
        XCTAssertEqual(rasterSelection, RAWDecoderSelection())
    }

    func testNativeDecodeDoesNotInvokeRegisteredConverter() async throws {
        let url = try fixture()
        let converter = CompatibilityConverter(dng: url, preview: nil)
        RenderEngine.registerRAWCompatibilityConverter(converter)
        let source = try await RenderEngine().load(url, options: SourceOptions(
            resolution: .preview(maximumSize: PixelSize(width: 128, height: 128))))
        XCTAssertNil(source.sourceCompatibility)
        XCTAssertEqual(converter.conversions, 0)
    }

    func testEmbeddedPreviewOpensAsSDRAndTerminalFailureNamesCamera() async throws {
        let url = try fixture()
        let preview = try jpeg()
        let converter = CompatibilityConverter(dng: nil, preview: preview, camera: "ILCE-7M5")
        RenderEngine.registerRAWCompatibilityConverter(converter)
        RenderEngine.forcesRAWCompatibility = true
        let source = try await RenderEngine().load(url)
        XCTAssertEqual(source.domain, .sdr)
        XCTAssertEqual(source.sourceCompatibility, .embeddedPreview)
        XCTAssertNil(source.rawCompatibility)
        XCTAssertEqual(source.nativeSize, PixelSize(width: 4, height: 8))
        XCTAssertEqual(source.sourceOptions?.rawEmbeddedPreview, true)

        RenderEngine.registerRAWCompatibilityConverter(CompatibilityConverter(dng: nil, preview: nil, camera: "ILCE-7M5"))
        do {
            _ = try await RenderEngine().load(url)
            XCTFail("A source with no DNG or preview opened")
        } catch RenderError.rawUnsupported(let camera) {
            XCTAssertEqual(camera, "ILCE-7M5")
        }
    }

    func testDeferredEmbeddedPreviewUsesRAWOrientation() throws {
        let preview = try jpeg(width: 5000, height: 3000)
        var options = SourceOptions(kind: .imageIO)
        options.embeddedPreviewOrientation = 6
        let immediate = try RenderEngine.open(preview, options: options, deferred: false)
        let deferred = try RenderEngine.open(preview, options: options, deferred: true)
        XCTAssertEqual(immediate.image.extent.size, CGSize(width: 3000, height: 5000))
        XCTAssertEqual(deferred.image.extent.size, immediate.image.extent.size)
        XCTAssertEqual(deferred.nativeSize, immediate.nativeSize)
    }

    func testRecordedConverterVersionIsRequired() async throws {
        let url = try fixture()
        RenderEngine.registerRAWCompatibilityConverter(CompatibilityConverter(converterID: "new", dng: url, preview: nil))
        let recipe = Recipe(inputDomain: .rawEDR, rawCompatibility: "old")
        do {
            _ = try await RenderEngine().load(url, options: SourceOptions(recipe: recipe),
                                             allowsRAWCompatibilityFallback: false)
            XCTFail("A different converter version was accepted")
        } catch RenderError.unsupportedRAWCompatibility(let id) {
            XCTAssertEqual(id, "old")
        }
    }
}
