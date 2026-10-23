import CoreImage
import Foundation
import XCTest
import HyperDRRecipe
@testable import HyperDRRender

final class RAWDecoderTests: XCTestCase {
    func testGenerationPolicyPrefersEightEvenWhenSystemDefaultIsNineOrOlder() {
        for suffix in ["", ".dng"] {
            let v = { (n: Int) in String(n) + suffix }
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: [v(7), v(8)], systemDefault: v(7)), v(8))
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: [v(7), v(8), v(9)], systemDefault: v(7)), v(9))
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: [v(9), v(8)], systemDefault: v(9), allowing9: false), v(8))
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: [v(7)], systemDefault: v(7)), v(7))
            XCTAssertNil(RenderEngine.selectRAWDecoder(supported: [v(9)], systemDefault: v(9), allowing9: false))
            XCTAssertNil(RenderEngine.selectRAWDecoder(supported: [v(10)], systemDefault: v(10)))
        }
        XCTAssertNil(RenderEngine.selectRAWDecoder(supported: [CIRAWDecoderVersion.none.rawValue, ""], systemDefault: ""))
    }

    private func fixture(_ name: String = "sony-ilce-7s.ARW") throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let input = root.appendingPathComponent("build/fixtures/" + name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + input.pathExtension)
        try FileManager.default.copyItem(at: input, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func version9(_ url: URL) throws -> String {
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        guard let version = filter.supportedDecoderVersions.first(where: { $0.rawValue.split(separator: ".").first == "9" }) else {
            throw XCTSkip("This system/camera does not support RAW decoder 9")
        }
        return version.rawValue
    }

    func testSelectionLegacyAndUnsupportedVersions() async throws {
        let engine = try RenderEngine()
        for name in ["sony-ilce-7s.ARW", "canon-eos-5d-iii-lossy.dng"] {
            let url = try fixture(name)
            let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
            let preferred = await engine.preferredRAWDecoder(url)
            let expected = filter.supportedDecoderVersions.first { $0.rawValue.split(separator: ".").first == "9" }?.rawValue
                ?? filter.supportedDecoderVersions.first { $0.rawValue.split(separator: ".").first == "8" }?.rawValue
                ?? filter.decoderVersion.rawValue
            XCTAssertEqual(preferred, expected)
            let fallback = await engine.fallbackRAWDecoder(url)
            XCTAssertEqual(fallback, filter.supportedDecoderVersions.first { $0.rawValue.split(separator: ".").first == "8" }?.rawValue
                ?? (filter.decoderVersion.rawValue.split(separator: ".").first == "9" ? nil : filter.decoderVersion.rawValue))
            let legacy = try Recipe.decode(Data("{\"inputDomain\":\"rawEDR\"}".utf8))
            XCTAssertNil(legacy.rawDecoderVersion)
            let opened = try RenderEngine.openRAW(url, options: SourceOptions(recipe: legacy))
            XCTAssertEqual(opened.raw?.decoderVersion, filter.decoderVersion.rawValue)
            var recipe = legacy
            recipe.rawDecoderVersion = preferred
            XCTAssertEqual(try Recipe.decode(recipe.encoded()), recipe)
            let options = try SourceOptions(recipe: recipe)
            XCTAssertEqual(try RenderEngine.openRAW(url, options: options).raw?.decoderVersion, preferred)
            let revision = try SourceRevision(url: url)
            XCTAssertNotEqual(sourceIdentity(url: url, revision: revision, options: options),
                              sourceIdentity(url: url, revision: revision, options: try SourceOptions(recipe: legacy)))
            recipe.rawDecoderVersion = "unsupported-test-version"
            XCTAssertThrowsError(try RenderEngine.openRAW(url, options: SourceOptions(recipe: recipe))) { error in
                guard case RenderError.unsupportedRAWDecoder("unsupported-test-version") = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testDecoder9ColorAndColorNoiseCapability() async throws {
        let url = try fixture("canon-eos-5d-iii-lossy.dng"), version = try version9(url)
        let engine = try RenderEngine()
        let eight = try XCTUnwrap(CIRAWFilter(imageURL: url)?.supportedDecoderVersions.first { $0.rawValue == "8.dng" })
        func options(_ version: String, colorNR: Double? = nil) throws -> SourceOptions {
            var recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: version)
            if let colorNR { recipe.setValue(.number(colorNR), for: "develop.colorNR") }
            return try SourceOptions(recipe: recipe, resolution: .preview(maximumSize: PixelSize(width: 320, height: 320)))
        }
        let old = try await engine.load(url, options: options(eight.rawValue))
        let current = try await engine.load(url, options: options(version))
        let ignored = try await engine.load(url, options: options(version, colorNR: 100))
        XCTAssertNotEqual(old.id, current.id)
        XCTAssertNotEqual(old.modelSourceID, current.modelSourceID)
        var logOptions = try options(version)
        logOptions.sceneLinear = true
        let log = try await engine.load(url, options: logOptions)
        XCTAssertNotEqual(log.id, current.id)
        XCTAssertEqual(log.modelSourceID, current.modelSourceID)
        XCTAssertEqual(log.rawSettings?.decoderVersion, version)
        XCTAssertFalse(try XCTUnwrap(current.rawSettings).supportsColorNR)
        XCTAssertFalse(try XCTUnwrap(current.rawSettings).capabilities.contains("CIRAWFilter.isColorNoiseReductionSupported"))
        let report = try await engine.sourceReport(current)
        XCTAssertFalse(report.capabilities.contains("develop.colorNR"))
        XCTAssertEqual(RenderEngine.readTexture(current.texture), RenderEngine.readTexture(ignored.texture))
        let a = try meansSRGB(old), b = try meansSRGB(current)
        print("RAW_DECODER_MEAN_SRGB 8=\(a) 9=\(b)")
        for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(a[channel] - b[channel]), 5, "Mean sRGB code, channel \(channel)") }
    }

    func testSharedLegacySonyGraphKeepsCanonicalPixels() async throws {
        try await sharedGraph(name: "sony-ilce-7s.ARW", decoder: "7")
    }

    func testSharedLegacyLeicaGraphKeepsCanonicalPixels() async throws {
        try await sharedGraph(name: "leica-c-portrait.RWL", decoder: "7")
    }

    func testSharedRAW9SonyGraphKeepsCanonicalPixels() async throws {
        try await sharedGraph(name: "sony-ilce-7s.ARW", decoder: "9")
    }

    func testSharedRAW8DNGGraphKeepsCanonicalPixels() async throws {
        try await sharedGraph(name: "canon-eos-5d-iii-lossy.dng", decoder: "8.dng")
    }

    func testSharedRAW9DNGGraphKeepsCanonicalPixels() async throws {
        try await sharedGraph(name: "canon-eos-5d-iii-lossy.dng", decoder: "9.dng")
    }

    private func sharedGraph(name: String, decoder: String) async throws {
        let url = try fixture(name)
        guard CIRAWFilter(imageURL: url)?.supportedDecoderVersions.contains(where: { $0.rawValue == decoder }) == true else {
            throw XCTSkip("This system/camera does not support decoder " + decoder)
        }
        for linear in [false, true] {
            var options = try SourceOptions(recipe: Recipe(inputDomain: .rawEDR, rawDecoderVersion: decoder),
                resolution: .preview(maximumSize: PixelSize(width: 1280, height: 1280)))
            options.sceneLinear = linear
            let reference = try RenderEngine(), shared = try RenderEngine()
            let before = try await reference.load(url, options: options)
            let expected = try await reference.fixedAnalysisSource(before)
            let after = try await shared.load(url, options: options, preparingAnalysis: true)
            let actual = try await shared.fixedAnalysisSource(after)
            XCTAssertEqual(RenderEngine.readTexture(before.texture), RenderEngine.readTexture(after.texture))
            XCTAssertEqual(RenderEngine.readTexture(expected.texture), RenderEngine.readTexture(actual.texture))
            XCTAssertEqual(expected.size, actual.size)
            XCTAssertEqual(expected.rawSettings?.scaleFactor, actual.rawSettings?.scaleFactor)
            XCTAssertEqual(before.id, after.id)
            let export = try await reference.openExportSource(url, options: options)
            XCTAssertEqual(RenderEngine.readTexture(export.analysisSource.texture), RenderEngine.readTexture(actual.texture))
            let a = try await reference.analysis(export.analysisSource), b = try await shared.analysis(after)
            XCTAssertEqual(RenderEngine.readTexture(a.cells), RenderEngine.readTexture(b.cells))
            XCTAssertEqual(RenderEngine.readTexture(a.masks), RenderEngine.readTexture(b.masks))
            XCTAssertEqual(RenderEngine.readTexture(a.expansion), RenderEngine.readTexture(b.expansion))
            XCTAssertEqual(a.peaks, b.peaks)
            XCTAssertEqual(a.sourceHeadroom, b.sourceHeadroom)
            var recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: decoder)
            recipe.setValue(.number(0.3), for: "tone.exposure")
            let oldPlanes = try await reference.render(before, recipe: recipe)
            let newPlanes = try await shared.render(after, recipe: recipe)
            XCTAssertEqual(RenderEngine.readTexture(oldPlanes.base), RenderEngine.readTexture(newPlanes.base))
            XCTAssertEqual(RenderEngine.readTexture(oldPlanes.gain), RenderEngine.readTexture(newPlanes.gain))
        }
    }

    private func meansSRGB(_ source: RenderSource) throws -> [Double] {
        let image = try XCTUnwrap(CIImage(mtlTexture: source.texture, options: [.colorSpace: RenderEngine.workingColorSpace]))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        var bytes = [UInt8](repeating: 0, count: source.texture.width * source.texture.height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: source.texture.width * 4, bounds: image.extent,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return (0..<3).map { channel in
            stride(from: channel, to: bytes.count, by: 4).reduce(0.0) { $0 + Double(bytes[$1]) } / Double(bytes.count / 4)
        }
    }

    func testLazyRAWExportKeepsTheRecordedGeometryAndAnalysis() async throws {
        let url = try fixture("canon-eos-5d-iii-lossy.dng"), version = try version9(url)
        for linear in [false, true] {
            var options = SourceOptions(sceneLinear: linear)
            options.rawDecoderVersion = version
            options.geometry = Geometry(angle: 5, quarterTurns: 1,
                crop: CropRect(centreX: 0.03, centreY: -0.02, width: 0.75, height: 0.75))
            let independent = try RenderEngine(), shared = try RenderEngine()
            let coldOpened = try RenderEngine.openRAW(url, options: options)
            var analysisOptions = options
            analysisOptions.resolution = .preview(maximumSize: PixelSize(width: 1024, height: 1024))
            let expected = try await independent.load(url, options: analysisOptions)
            let lazy = try await shared.openExportSource(url, options: options)
            XCTAssertEqual(lazy.id, expected.id)
            XCTAssertEqual(lazy.analysisSource.modelSourceID, expected.modelSourceID)
            XCTAssertEqual(lazy.analysisSource.nativeSize, expected.nativeSize)
            XCTAssertEqual(lazy.analysisSource.rawSettings?.decoderVersion, version)
            XCTAssertEqual(lazy.analysisSource.rawSettings?.scaleFactor, expected.rawSettings?.scaleFactor)
            XCTAssertEqual(RenderEngine.readTexture(lazy.analysisSource.texture).map(\.bitPattern),
                           RenderEngine.readTexture(expected.texture).map(\.bitPattern))
            if linear {
                // Log/film retains the independent load path, whose analysis
                // variant is cached, rather than retaining a warmed full graph.
                var cachedOptions = options
                cachedOptions.resolution = RenderEngine.analysisResolution(native: lazy.nativeSize)
                let cached = try await shared.load(url, options: cachedOptions)
                XCTAssertTrue(cached.texture === lazy.analysisSource.texture)
            }
            // The independent native graph has not developed its analysis grid.
            // Compare its cold ROI with the graph retained after shared analysis.
            let cold = ExportSource(id: expected.id, domain: expected.domain, nativeSize: expected.nativeSize,
                rawSettings: coldOpened.raw, analysisSource: expected, opened: coldOpened,
                url: url, revision: try SourceRevision(url: url))
            let region = CGRect(x: 211, y: 333, width: 257, height: 67)
            let reference = try await independent.materializeExportRegion(cold, outputSize: cold.nativeSize, region: region)
            let actual = try await shared.materializeExportRegion(lazy, outputSize: lazy.nativeSize, region: region)
            XCTAssertEqual(RenderEngine.readTexture(actual.texture).map(\.bitPattern),
                           RenderEngine.readTexture(reference.texture).map(\.bitPattern))
        }
    }

    func testDecoder9NativeRegionsMatchWholeAndRepeat() async throws {
        let url = try fixture("canon-eos-5d-iii-lossy.dng"), version = try version9(url)
        let engine = try RenderEngine()
        let options = try SourceOptions(recipe: Recipe(inputDomain: .rawEDR, rawDecoderVersion: version))
        let opened = try RenderEngine.openRAW(url, options: options)
        let result = try await engine.rawDecoderRegionErrors(opened.image)
        print("RAW_DECODER_ROI max=\(result.roi) repeat=\(result.repeatError)")
        XCTAssertLessThanOrEqual(result.roi, 0.0001)
        XCTAssertEqual(result.repeatError, 0)
    }
}

extension RenderEngine {
    fileprivate func rawDecoderRegionErrors(_ image: CIImage) throws -> (roi: Float, repeatError: Float) {
        let whole = Self.readTexture(try rasterize(image, space: Self.workingColorSpace, opaque: true, raw: true))
        let extent = image.extent.integral, width = Int(extent.width), height = Int(extent.height)
        let regions = [CGRect(x: 0, y: 0, width: 128, height: 128),
                       CGRect(x: width - 300, y: height - 256, width: 300, height: 256),
                       CGRect(x: 0, y: height / 2, width: width, height: 128)]
        var maxError: Float = 0, repeatError: Float = 0
        for rect in regions {
            let crop = image.cropped(to: rect.offsetBy(dx: extent.minX, dy: extent.minY))
            let pixels = Self.readTexture(try rasterize(crop, space: Self.workingColorSpace, opaque: true, raw: true))
            let again = Self.readTexture(try rasterize(crop, space: Self.workingColorSpace, opaque: true, raw: true))
            for y in 0..<Int(rect.height) { for x in 0..<Int(rect.width) { for c in 0..<3 {
                let i = (y * Int(rect.width) + x) * 4 + c
                let j = ((height - Int(rect.maxY) + y) * width + Int(rect.minX) + x) * 4 + c
                maxError = max(maxError, abs(pixels[i] - whole[j]))
                repeatError = max(repeatError, abs(pixels[i] - again[i]))
            } } }
        }
        return (maxError, repeatError)
    }
}
