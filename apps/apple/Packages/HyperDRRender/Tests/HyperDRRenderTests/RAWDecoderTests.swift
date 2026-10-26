import CoreImage
import Foundation
import ImageIO
import Metal
import XCTest
import HyperDRRecipe
@testable import HyperDRRender

final class RAWDecoderTests: XCTestCase {
    func testGenerationPolicyPrefersNewestSupportedAndRetriesEight() {
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

    func testCameraDecoderWinsRegardlessOfDNGEnumerationOrder() {
        // Actual Q3/macOS 15.5 order: generic 8.dng precedes camera-specific 8.
        let q3 = ["6.dng", "7.dng", "7", "8.dng", "8"]
        XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: q3, systemDefault: "8"), "8")
        for versions in [["8.dng", "8", "9.dng", "9"], ["9", "9.dng", "8", "8.dng"]] {
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: versions, systemDefault: "8"), "9")
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: versions, systemDefault: "9", allowing9: false), "8")
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: versions, generation: 8), "8")
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: versions, generation: 9), "9")
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: versions, systemDefault: "8", prefersDNG: true), "9.dng")
            XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: versions, generation: 8, prefersDNG: true), "8.dng")
        }
        XCTAssertEqual(RenderEngine.selectRAWDecoder(supported: ["7.dng", "8.dng"], systemDefault: "7.dng"), "8.dng")
    }

    func testInvalidNativeDimensionsAreDecodeFailuresInsteadOfGeometryTraps() throws {
        XCTAssertEqual(try RenderEngine.rawNativeSize(CGSize(width: 7008, height: 4672), rotated: false),
                       PixelSize(width: 7008, height: 4672))
        XCTAssertEqual(try RenderEngine.rawNativeSize(CGSize(width: 7008, height: 4672), rotated: true),
                       PixelSize(width: 4672, height: 7008))
        let invalid = [
            CGSize.zero,
            CGSize(width: 0, height: 4672),
            CGSize(width: 7008, height: 0),
            CGSize(width: 0.5, height: 12),
            CGSize(width: -1, height: 12),
            CGSize(width: Double.nan, height: 12),
            CGSize(width: 12, height: Double.infinity),
            CGSize(width: Double(UInt32.max) + 1, height: 12),
        ]
        for native in invalid {
            for rotated in [false, true] {
                XCTAssertThrowsError(try RenderEngine.rawNativeSize(native, rotated: rotated)) { error in
                    guard case RenderError.cannotDecodeSource = error else {
                        return XCTFail("Unexpected error for \(native): \(error)")
                    }
                }
            }
        }
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

    func testExplicitGenerationRequiresSupportAndKeepsDNGVariant() async throws {
        let engine = try RenderEngine()
        for name in ["sony-ilce-7s.ARW", "canon-eos-5d-iii-lossy.dng"] {
            let url = try fixture(name)
            let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
            for generation in [8, 9] {
                let version = String(generation)
                let supported = filter.supportedDecoderVersions.map(\.rawValue)
                let expected = [version, version + ".dng"].first { supported.contains($0) }
                do {
                    let actual = try await engine.rawDecoder(url, generation: generation)
                    XCTAssertNotNil(expected, "Unsupported generation succeeded")
                    XCTAssertEqual(actual, expected)
                } catch RenderError.unsupportedRAWDecoder(let actual) {
                    XCTAssertNil(expected)
                    XCTAssertEqual(actual, version)
                }
            }
            do {
                _ = try await engine.rawDecoder(url, generation: 999)
                XCTFail("Unsupported generation succeeded")
            } catch RenderError.unsupportedRAWDecoder(let version) {
                XCTAssertEqual(version, "999")
            }
        }
    }

    func testExplicitGenerationReturnsNilForRaster() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let pixel = Data([64, 128, 192, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: pixel as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let engine = try RenderEngine()
        let version = try await engine.rawDecoder(url, generation: 9)
        XCTAssertNil(version)
    }

    func testSelectionLegacyAndUnsupportedVersions() async throws {
        let engine = try RenderEngine()
        for name in ["sony-ilce-7s.ARW", "canon-eos-5d-iii-lossy.dng"] {
            let url = try fixture(name)
            let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
            let preferred = await engine.preferredRAWDecoder(url)
            let supported = filter.supportedDecoderVersions.map(\.rawValue)
            let expected = ["9", "9.dng", "8", "8.dng"].first { supported.contains($0) }
                ?? filter.decoderVersion.rawValue
            XCTAssertEqual(preferred, expected)
            let fallback = await engine.fallbackRAWDecoder(url)
            XCTAssertEqual(fallback, ["8", "8.dng"].first { supported.contains($0) }
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
            assertPixelsClose(before.texture, after.texture)
            assertPixelsClose(expected.texture, actual.texture)
            XCTAssertEqual(expected.size, actual.size)
            XCTAssertEqual(expected.rawSettings?.scaleFactor, actual.rawSettings?.scaleFactor)
            XCTAssertEqual(before.id, after.id)
            let export = try await reference.openExportSource(url, options: options)
            assertPixelsClose(export.analysisSource.texture, actual.texture)
            let a = try await reference.analysis(export.analysisSource), b = try await shared.analysis(after)
            assertPixelsClose(a.cells, b.cells)
            assertPixelsClose(a.masks, b.masks)
            assertPixelsClose(a.expansion, b.expansion)
            XCTAssertEqual(a.peaks, b.peaks)
            XCTAssertEqual(a.sourceHeadroom, b.sourceHeadroom)
            var recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: decoder)
            recipe.setValue(.number(0.3), for: "tone.exposure")
            let oldPlanes = try await reference.render(before, recipe: recipe)
            let newPlanes = try await shared.render(after, recipe: recipe)
            assertPixelsClose(oldPlanes.base, newPlanes.base, tolerance: 0.000002)
            assertPixelsClose(oldPlanes.gain, newPlanes.gain)
            // The existing one-code contract remains stricter than a generic
            // float epsilon: check the SDR endpoint's actual P3 transfer at 16 bit.
            let oldBase = RenderEngine.readTexture(oldPlanes.base), newBase = RenderEngine.readTexture(newPlanes.base)
            func code(_ linear: Float) -> Int {
                let value = min(1, max(0, Double(linear)))
                let encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
                return Int((encoded * 65535).rounded())
            }
            let codeError = zip(oldBase, newBase).enumerated().filter { $0.offset % 4 != 3 }
                .reduce(0) { max($0, abs(code($1.element.0) - code($1.element.1))) }
            XCTAssertLessThanOrEqual(codeError, 1)
        }
    }

    /// Shared native cells change the area sum's grouping at cell boundaries,
    /// without changing their decoded pixels. Compare the grids with a tolerance.
    private func assertPixelsClose(_ a: any MTLTexture, _ b: any MTLTexture, tolerance: Float = 0.00001,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let first = RenderEngine.readTexture(a), second = RenderEngine.readTexture(b)
        XCTAssertEqual(first.count, second.count, file: file, line: line)
        let worst = zip(first, second).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        XCTAssertLessThanOrEqual(worst, tolerance, file: file, line: line)
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
