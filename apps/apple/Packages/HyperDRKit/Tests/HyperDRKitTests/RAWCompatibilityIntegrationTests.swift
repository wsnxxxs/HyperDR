import CoreImage
import Foundation
import HyperDREngine
import HyperDRRecipe
import XCTest
@testable import HyperDRRender
@testable import HyperDRKit

/// Real LibRaw + CIRAWFilter integration. Kept in XCTest so the process-wide
/// converter/force flags cannot race Kit's parallel Swift Testing suites.
final class RAWCompatibilityIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RenderEngine.forcesRAWCompatibility = false
        RenderEngine.registerRAWCompatibilityConverter(nil)
    }

    override func tearDown() {
        RenderEngine.forcesRAWCompatibility = false
        RenderEngine.registerRAWCompatibilityConverter(nil)
        super.tearDown()
    }

    private func fixture() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
    }

    func testForcedConversionOpensCachesAndExports() async throws {
        try await exercise(fixture())
    }

    /// LibRaw chosen in Settings: a camera Apple develops is still converted
    /// by the real LibRaw, without the debug force flag.
    func testLibRAWChoiceConvertsASupportedCamera() async throws {
        let url = fixture()
        XCTAssertTrue(RenderEngine.systemDevelops(url))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raw-compat-libraw-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KitConfiguration(supportDirectory: root.appendingPathComponent("support"),
                                             cacheDirectory: root.appendingPathComponent("cache"))
        let engine = try await Engine(configuration: .init(cacheDirectory: configuration.cacheDirectory))
        RenderEngine.registerRAWCompatibilityConverter(RAWCompatibilityConverter(engine: engine, configuration: configuration))
        let render = try RenderEngine()
        let selected = try await render.libRAWDecoderSelection(url)
        let selection = try XCTUnwrap(selected)
        XCTAssertEqual(selection.converterID, Engine.rawConverterID)
        let version = try XCTUnwrap(selection.version)
        XCTAssertEqual(version, RenderEngine.systemSupportsRAW9 ? "9.dng" : "8.dng")
        var options = SourceOptions(resolution: .preview(maximumSize: PixelSize(width: 512, height: 512)))
        options.rawDecoderVersion = version
        options.rawCompatibility = selection.converterID
        let source = try await render.load(url, options: options)
        XCTAssertEqual(source.domain, .rawEDR)
        XCTAssertEqual(source.sourceCompatibility, .convertedDNG)
        XCTAssertEqual(source.rawSettings?.decoderVersion, version)
    }

    /// Opt-in hands-on run against the user's A7 V file; normal test runs never
    /// depend on personal photos. HYPERDR_OPEN_TIMINGS adds stage attribution.
    func testA7VForcedConversionOpensAndExports() async throws {
        guard let path = ProcessInfo.processInfo.environment["HYPERDR_RAW_COMPAT_SAMPLE"] else {
            throw XCTSkip("Set HYPERDR_RAW_COMPAT_SAMPLE to the A7 V RAW")
        }
        try await exercise(URL(fileURLWithPath: path), requiresModel2Capture: true)
    }

    private func exercise(_ url: URL, requiresModel2Capture: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raw-compat-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KitConfiguration(supportDirectory: root.appendingPathComponent("support"),
                                             cacheDirectory: root.appendingPathComponent("cache"))
        let engine = try await Engine(configuration: .init(cacheDirectory: configuration.cacheDirectory))
        let converter = RAWCompatibilityConverter(engine: engine, configuration: configuration)
        RenderEngine.registerRAWCompatibilityConverter(converter)
        RenderEngine.forcesRAWCompatibility = true

        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        let rotated = filter.orientation.rawValue >= 5
        let native = filter.nativeSize
        let expected = PixelSize(width: Int(rotated ? native.height : native.width),
                                 height: Int(rotated ? native.width : native.height))
        let clock = ContinuousClock()
        let openBegan = clock.now
        let resolution = SourceResolution.preview(maximumSize: PixelSize(width: 1024, height: 1024))
        let source = try await RenderEngine().load(url, options: SourceOptions(resolution: resolution))
        let openElapsed = openBegan.duration(to: clock.now)
        XCTAssertEqual(source.domain, .rawEDR)
        XCTAssertEqual(source.sourceCompatibility, .convertedDNG)
        XCTAssertEqual(source.rawCompatibility, Engine.rawConverterID)
        XCTAssertEqual(source.uncroppedSize, expected)

        let recipe = Recipe(inputDomain: source.domain, rawDecoderVersion: source.rawSettings?.decoderVersion,
                            rawCompatibility: source.rawCompatibility,
                            rawEmbeddedPreview: source.sourceCompatibility == .embeddedPreview)
        let cacheBegan = clock.now
        let reopened = try await RenderEngine().load(url, options: SourceOptions(recipe: recipe, resolution: resolution),
                                                     allowsRAWCompatibilityFallback: false)
        let cacheOpenElapsed = cacheBegan.duration(to: clock.now)
        XCTAssertEqual(reopened.id, source.id)
        let cached = try await converter.convertDNG(from: url)
        XCTAssertTrue(cached.usedCache)
        XCTAssertEqual(cached.converterID, Engine.rawConverterID)
        if requiresModel2Capture {
            let dngSource = try XCTUnwrap(CGImageSourceCreateWithURL(cached.url as CFURL, nil))
            let dngProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(dngSource, 0, nil) as? [String: Any])
            XCTAssertTrue(ModelGainCapture(properties: dngProperties).isUsable)
            XCTAssertTrue(reopened.modelCapture.isUsable)
        }

        var exportRecipe = recipe
        exportRecipe.setValue(.bool(false), for: "hdr.enabled")
        let sessions = SessionStore(configuration: configuration, formats: InputFormats())
        let photo = try await sessions.open(url)
        let snapshot = RecipeExportSnapshot(recipe: exportRecipe, source: try .init(session: photo))
        let size = ExportPixelSize(width: expected.width, height: expected.height)
        let request = ExportPlanRequest(choice: .custom(.init(encoding: .sdrJPEG, gamut: .p3, quality: 90)),
            source: ExportSource(domain: .rawEDR, pixelSize: size, sensorSize: size),
            edit: .init(hdrEnabled: false, peakStops: 0))
        let exportRender = try RenderEngine()
        let service = RecipeExportService(engine: engine, renderEngine: exportRender, renderer: exportRender,
            sessions: sessions, target: ExportTarget(configuration: configuration, sessions: sessions),
            budget: FixedExportMemoryBudget(bytes: 8_000_000_000))
        let exportBegan = clock.now
        let result = try await service.export(session: photo.id, snapshot: snapshot, request: request)
        let exportElapsed = exportBegan.duration(to: clock.now)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.size, size)
        XCTAssertEqual(result.resolved.snapshot.recipe.rawCompatibility, Engine.rawConverterID)
        XCTAssertFalse(result.resolved.snapshot.recipe.rawEmbeddedPreview)
        print("RAW_COMPAT_TIMINGS photo=\(url.lastPathComponent) native=\(expected.width)x\(expected.height) open=\(openElapsed) cachedOpen=\(cacheOpenElapsed) export=\(exportElapsed)")
    }
}
