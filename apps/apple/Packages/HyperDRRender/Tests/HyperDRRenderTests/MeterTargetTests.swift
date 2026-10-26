import CoreImage
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct MeterTargetTests {
    @Test func onlyRAWCameraPreviewsChooseTheTarget() async throws {
        let engine = try RenderEngine()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try await engine.testMeterTarget(url, domain: .rawEDR, preview: -2) == -2)
        #expect(try await engine.testMeterTarget(url, domain: .rawEDR, preview: nil) == -3)
        #expect(try await engine.testMeterTarget(nil, domain: .rawEDR, preview: -2) == -3)
        #expect(try await engine.testMeterTarget(url, domain: .sdr, preview: -2) == -3)
        #expect(try await engine.testMeterTarget(url, domain: .hdr, preview: -2) == -3)
        #expect(try await engine.testMeterTarget(url, domain: .rawEDR, preview: -2, embedded: true) == -3)
        #expect(try await engine.testMeterTarget(url, domain: .rawEDR, preview: 0) == -3)
        #expect(try await engine.testMeterTarget(url, domain: .rawEDR, preview: .nan) == -3)
        #expect(try await engine.testMeterTarget(url, domain: .rawEDR, preview: -0.5) == -0.5)
    }

    @Test func calibrationChangesDisplayButKeepsSceneLinearInputAndExportOptions() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ARW")
        try FileManager.default.copyItem(at: fixture, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RenderEngine()
        var options = SourceOptions(resolution: .preview(maximumSize: .init(width: 192, height: 192)))
        options.draftRAWPreview = true
        options.rawDecoderVersion = await engine.preferredRAWDecoder(url)
        let source = try await engine.load(url, options: options)
        let bias = try #require(await engine.cameraPreviewExposure(source))
        #expect(bias.isFinite && abs(bias) <= 5)
        options.rawExposureBias = bias
        let calibrated = try await engine.load(url, options: options)
        let target = try #require(RenderEngine.cameraPreviewBrightness(url))
        let measured = try await engine.testMeterBrightness(calibrated)
        #expect(abs(measured - target) < 0.08)

        // This exact scalar is in every reopen, including export and the comparison.
        let recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: options.rawDecoderVersion, rawExposureBias: Double(bias))
        let restored = try Recipe.decode(recipe.encoded())
        let exportOptions = try SourceOptions(recipe: restored)
        #expect(exportOptions.rawExposureBias == bias)
        let display = try await engine.testConfiguredExposure(url, options: exportOptions)
        #expect(display == bias)
        var film = restored
        film.setValue(.string("portra400"), for: Recipe.filmID)
        let filmOptions = try SourceOptions(recipe: film)
        let linear = try await engine.testConfiguredExposure(url, options: filmOptions)
        #expect(linear == 0 && filmOptions.rawExposureBias == bias)
        #expect(source.id == calibrated.id || bias != 0)
    }

    @Test func malformedCalibrationCannotEnterSourceOptions() throws {
        for bias in [Double.nan, .infinity, -5.01, 5.01] {
            #expect(throws: RenderError.self) {
                try SourceOptions(recipe: Recipe(inputDomain: .rawEDR, rawExposureBias: bias))
            }
        }
    }
}

private extension RenderEngine {
    func testMeterTarget(_ url: URL?, domain: InputDomain, preview: Double?, embedded: Bool = false) throws -> Double {
        let image = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        var options = SourceOptions(); options.rawEmbeddedPreview = embedded
        let source = try materialize(OpenedSource(domain: domain, image: image, hdr: image,
            baseSpace: Self.workingColorSpace, gain: nil, raw: nil),
            origin: try url.map { ($0, options, try SourceRevision(url: $0)) })
        return try meterTarget(source, readPreview: { _ in preview }) { -3 }
    }
    func testMeterBrightness(_ source: RenderSource) throws -> Double {
        try meterBrightness(smallMeterSource(source), RenderAdjustments())
    }
    func testConfiguredExposure(_ url: URL, options: SourceOptions) throws -> Float {
        try Self.configuredRAW(url, options: options).0.exposure
    }
}
