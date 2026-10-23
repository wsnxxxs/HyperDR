import CoreGraphics
import CoreImage
import Foundation
import HyperDRRecipe
import Metal
import XCTest
@testable import HyperDRRender

final class RAWRepeatabilityTests: XCTestCase {
    func testCanonicalOwnershipKeepsGlobalRowsAndSharedBitmapStorage() async throws {
        let engine = try RenderEngine()
        let facts = try await engine.repeatabilityCanonicalOwnership()
        XCTAssertTrue(facts.matches, "An ROI crossing a canonical cell changed its global pixels")
        XCTAssertTrue(facts.topDown, "Bitmap rows were flipped relative to the public texture contract")
        XCTAssertTrue(facts.shared, "RAW bitmap and Metal must share one aligned float32 allocation")
    }

    func testCanonicalOpacityChecksWholeInnerAndExcludesDiscardedHalo() async throws {
        let engine = try RenderEngine()
        let complete = try await engine.repeatabilityDiscardedHalo()
        XCTAssertEqual(complete, 0)
        do {
            try await engine.repeatabilityMissingOutsideWindow()
            XCTFail("A canonical cell published pixels before its complete inner region was validated")
        } catch RenderError.cannotDecodeSource { }
    }

    func testNativeRAWWriterSlabKeepsSamplingAndFilmHaloBounded() async throws {
        let engine = try RenderEngine()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raw-slab-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source")
        try Data([0]).write(to: file)
        let facts = try await engine.repeatabilityNativeSlab(file)
        XCTAssertTrue(facts.fullSlabs)
        XCTAssertTrue(facts.bounded, "Sampling and film halos exceeded the native texture envelope")
        XCTAssertTrue(facts.fallback, "A fractional or scaled projection used the native integer allowance")
    }

    func testCanonicalReadRejectsNonfiniteAndUnrepresentableBounds() async throws {
        let engine = try RenderEngine()
        let infinite = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        let oversized = infinite.cropped(to: CGRect(x: 0, y: 0, width: Double(UInt32.max) + 4096, height: 2))
        for image in [infinite, oversized] {
            do {
                try await engine.repeatabilityRejectInvalidBounds(image)
                XCTFail("Unbounded RAW grid succeeded")
            } catch RenderError.invalidRegion { }
        }
    }

    func testLossyDNGCanonicalCellsCoverFullPreviewAndPartialLookBaseline() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng"), to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try RenderEngine()
        let selected: String?
        do { selected = try await engine.rawDecoder(file, generation: 9) }
        catch RenderError.unsupportedRAWDecoder { throw XCTSkip("This system does not support RAW decoder 9") }
        let decoder = try XCTUnwrap(selected)
        var options = try SourceOptions(recipe: Recipe(inputDomain: .rawEDR, rawDecoderVersion: decoder))
        let full = try await engine.load(file, options: options)
        let fullTransparent = try await engine.repeatabilityOpaqueCount(full)
        XCTAssertEqual(fullTransparent, 0)
        options.resolution = .preview(maximumSize: PixelSize(width: 320, height: 320))
        let preview = try await engine.load(file, options: options)
        let previewTransparent = try await engine.repeatabilityOpaqueCount(preview)
        XCTAssertEqual(previewTransparent, 0)
        options.sceneLinear = true
        let lazy = try await engine.openExportSource(file, options: options)
        // The last internal decoder column of this fixture previously needed
        // adaptive splitting. A stable cell must cover it without changing shape.
        let region = CGRect(x: 4700, y: 500, width: 257, height: 67)
        let tile = try await engine.materializeExportRegion(lazy, outputSize: lazy.nativeSize, region: region)
        var edit = RenderAdjustments()
        edit.film.stock = .portra400
        edit.film.strength = 0.5
        let baseline = try await engine.repeatabilityBaselineFacts(tile, edit: edit)
        XCTAssertTrue(baseline.sameSize)
        XCTAssertEqual(baseline.transparent, 0)
        XCTAssertTrue(baseline.finite)
    }

    /// Replays the real lazy RAW export with the different row shapes a writer
    /// may request. Set HYPERDR_RAW_REPEATABILITY_SOURCE to the original 61MP
    /// DSC01468.ARW for the local device-case gate; ordinary tests use Sony RAW.
    /// This checks the source and finished planes, before lossy HEVC encoding.
    func testRecordedDecoderRowsAndNativeRegionsStayStable() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let input = ProcessInfo.processInfo.environment["HYPERDR_RAW_REPEATABILITY_SOURCE"]
            .map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raw-repeat-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input." + input.pathExtension)
        try FileManager.default.copyItem(at: input, to: file)
        let engine = try RenderEngine()
        let selected: String?
        if let value = ProcessInfo.processInfo.environment["HYPERDR_RAW_REPEATABILITY_GENERATION"],
           let generation = Int(value) {
            selected = try await engine.rawDecoder(file, generation: generation)
        } else { selected = await engine.defaultRAWDecoder(file) }
        let decoder = try XCTUnwrap(selected)
        let recipe = Recipe(inputDomain: .rawEDR, rawDecoderVersion: decoder)
        let source = try await engine.openExportSource(file, options: SourceOptions(recipe: recipe))
        let size = source.nativeSize
        XCTAssertEqual(source.rawSettings?.decoderVersion, decoder)
        FileHandle.standardOutput.write(Data("RAW_REPEAT native=\(size.width)x\(size.height) decoder=\(decoder)\n".utf8))
        let regions = [CGRect(x: 0, y: 0, width: min(257, size.width), height: min(67, size.height)),
                       CGRect(x: max(0, size.width / 2 - 33), y: max(0, size.height / 2 - 15),
                              width: min(257, size.width / 2), height: min(67, size.height / 2)),
                       CGRect(x: max(0, size.width - 257), y: max(0, size.height - 67),
                              width: min(257, size.width), height: min(67, size.height))]
        var native: [Data] = []
        for region in regions { native.append(try await engine.repeatabilityNativeBytes(source, region: region)) }
        let rows = try await engine.prepareExportRows(source, recipe: recipe,
            request: ExportRenderRequest(photoSize: size, includesGain: true,
                capabilities: .init(supportsThreeChannelGain: false, supportsSignedGain: false,
                                    requiresGainMaximumHeadroom: true)))
        let channels = try XCTUnwrap(rows.report.gain).channelCount
        let baseURL = directory.appendingPathComponent("base.f32"), gainURL = directory.appendingPathComponent("gain.f32")
        XCTAssertTrue(FileManager.default.createFile(atPath: baseURL.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: gainURL.path, contents: nil))
        let base = try FileHandle(forUpdating: baseURL), gain = try FileHandle(forUpdating: gainURL)
        defer { try? base.close(); try? gain.close() }
        for y in stride(from: 0, to: size.height, by: 256) {
            let stripe = try rows.read(y: y, count: min(256, size.height - y))
            try base.write(contentsOf: stripe.baseRGB.withUnsafeBytes { Data($0) })
            try gain.write(contentsOf: stripe.gain.withUnsafeBytes { Data($0) })
        }
        FileHandle.standardOutput.write(Data("RAW_REPEAT reference_rows=256 complete\n".utf8))
        for count in [64, 127, 512] {
            // Reversed replay changes the native decoder's request/cache order.
            for y in Array(stride(from: 0, to: size.height, by: count)).reversed() {
                let stripe = try rows.read(y: y, count: min(count, size.height - y))
                for (handle, values, componentCount, name) in [(base, stripe.baseRGB, 3, "base"),
                                                              (gain, stripe.gain, channels, "gain")] {
                    try handle.seek(toOffset: UInt64(y * size.width * componentCount * MemoryLayout<Float>.stride))
                    let bytes = values.withUnsafeBytes { Data($0) }
                    let expected = try XCTUnwrap(try handle.read(upToCount: bytes.count))
                    XCTAssertTrue(bytes == expected, "\(name) changed at row \(y), request height \(count)")
                }
            }
            FileHandle.standardOutput.write(Data("RAW_REPEAT replay_rows=\(count) reverse complete\n".utf8))
        }
        for index in regions.indices.reversed() {
            let actual = try await engine.repeatabilityNativeBytes(source, region: regions[index])
            XCTAssertTrue(actual == native[index], "Native RAW region \(index) changed after row replay")
        }
    }
}

extension RenderEngine {
    fileprivate func repeatabilityNativeSlab(_ file: URL) throws -> (fullSlabs: Bool, bounded: Bool, fallback: Bool) {
        let size = PixelSize(width: 9504, height: 6336), limit = PreparedExportRows.maximumSourceTileSize
        let analysis = try source(image: CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)), domain: .sdr)
        func lazy(_ bounds: CGRect) throws -> ExportSource {
            let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: bounds)
            let opened = OpenedSource(domain: .rawEDR, image: image, hdr: image, baseSpace: Self.workingColorSpace,
                gain: nil, raw: nil, nativeSize: size, uncroppedSize: PixelSize(width: 12000, height: 8000))
            return ExportSource(id: analysis.id, domain: .rawEDR, nativeSize: size, rawSettings: nil,
                analysisSource: analysis, opened: opened, url: file, revision: try SourceRevision(url: file))
        }
        // A geometry-applied image can have a nonzero integral origin. Its own
        // grid, rather than the sensor dimensions, controls the integer branch.
        let native = try lazy(CGRect(x: 37, y: 71, width: size.width, height: size.height))
        let request = ExportRenderRequest(photoSize: size, capabilities: .init(supportsThreeChannelGain: true))
        var fullSlabs = true, bounded = true
        for halo in [0, 6, 31] {
            let tile = exportTileSize(native, request: request, halo: halo)
            fullSlabs = fullSlabs && tile == PixelSize(width: 4092 - 2 * halo, height: 512 - 2 * halo)
            for origin in [CGPoint.zero, CGPoint(x: 211, y: 333),
                           CGPoint(x: size.width - tile.width, y: size.height - tile.height)] {
                let region = CGRect(origin: origin, size: CGSize(width: tile.width, height: tile.height))
                let source = try materializeExportRegion(native, outputSize: size, region: region, halo: halo)
                bounded = bounded && source.texture.width <= limit.width && source.texture.height <= limit.height
            }
        }
        let fractional = try lazy(CGRect(x: 37.25, y: 71, width: Double(size.width), height: Double(size.height)))
        let mismatched = try lazy(CGRect(x: 37, y: 71, width: size.width - 1, height: size.height))
        let downscaled = ExportRenderRequest(photoSize: PixelSize(width: size.width - 1, height: size.height - 1),
            capabilities: .init(supportsThreeChannelGain: true))
        let fallback = exportTileSize(fractional, request: request).height == 510 &&
            exportTileSize(mismatched, request: request).height == 510 &&
            exportTileSize(native, request: downscaled).height < 512
        return (fullSlabs, bounded, fallback)
    }

    fileprivate func repeatabilityCanonicalOwnership() throws -> (matches: Bool, topDown: Bool, shared: Bool) {
        let size = Self.nativeRAWCellSize
        let bounds = CGRect(x: 37, y: 71, width: size.width + 31, height: size.height + 17)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: bounds.minX, y: bounds.minY),
            "inputPoint1": CIVector(x: bounds.maxX, y: bounds.maxY),
            "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.3),
            "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.7)])!.outputImage!.cropped(to: bounds)
        let whole = Self.readTexture(try rasterizeNativeRAW(gradient, space: Self.workingColorSpace))
        let width = Int(bounds.width), height = Int(bounds.height)
        var matches = true
        for rect in [CGRect(x: bounds.minX, y: bounds.minY, width: 7, height: 5),
                     CGRect(x: bounds.minX + Double(size.width - 3), y: bounds.maxY - Double(size.height + 2), width: 11, height: 7),
                     CGRect(x: bounds.maxX - 13, y: bounds.maxY - 9, width: 13, height: 9)] {
            let values = Self.readTexture(try rasterizeNativeRAW(gradient, region: rect, space: Self.workingColorSpace))
            for y in 0..<Int(rect.height) {
                let at = ((Int(bounds.maxY - rect.maxY) + y) * width + Int(rect.minX - bounds.minX)) * 4
                let count = Int(rect.width) * 4
                if Array(whole[at..<at + count]) != Array(values[y * count..<(y + 1) * count]) { matches = false }
            }
        }
        let bitmap = try rasterizeRAWBitmap(gradient,
            region: CGRect(x: bounds.minX + 5, y: bounds.minY + 7, width: 257, height: 67), space: Self.workingColorSpace)
        let limit = PreparedExportRows.maximumSourceTileSize
        let shared = bitmap.buffer != nil && bitmap.pixelFormat == .rgba32Float &&
            bitmap.bufferBytesPerRow >= bitmap.width * 16 &&
            bitmap.bufferBytesPerRow % device.minimumLinearTextureAlignment(for: .rgba32Float) == 0 &&
            bitmap.buffer!.length <= limit.width * limit.height * 16
        return (matches, whole[width / 2 * 4] > whole[((height - 1) * width + width / 2) * 4], shared)
    }

    fileprivate func repeatabilityDiscardedHalo() throws -> Int {
        let cell = Self.nativeRAWCellSize
        let bounds = CGRect(x: 0, y: 0, width: cell.width + 2, height: cell.height)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: cell.width, height: cell.height))
            .composited(over: CIImage(color: .clear).cropped(to: bounds))
        return try transparentTexels(rasterizeNativeRAW(image,
            region: CGRect(x: 0, y: 0, width: cell.width, height: cell.height), space: Self.workingColorSpace))
    }

    fileprivate func repeatabilityMissingOutsideWindow() throws {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            .composited(over: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8)))
        _ = try rasterizeNativeRAW(image, region: CGRect(x: 0, y: 0, width: 4, height: 4), space: Self.workingColorSpace)
    }

    fileprivate func repeatabilityRejectInvalidBounds(_ image: CIImage) throws {
        _ = try rasterizeNativeRAW(image, region: CGRect(x: 0, y: 0, width: 1, height: 1), space: Self.workingColorSpace)
    }

    fileprivate func repeatabilityOpaqueCount(_ source: RenderSource) throws -> Int {
        try transparentTexels(source.texture)
    }

    fileprivate func repeatabilityBaselineFacts(_ source: RenderSource, edit: RenderAdjustments) throws
        -> (sameSize: Bool, transparent: Int, finite: Bool) {
        let texture = try lookBaseline(source, edit: edit)
        return (texture.width == source.texture.width && texture.height == source.texture.height,
                try transparentTexels(texture), Self.readTexture(texture).allSatisfy(\.isFinite))
    }

    fileprivate func repeatabilityNativeBytes(_ source: ExportSource, region: CGRect) throws -> Data {
        let tile = try materializeExportRegion(source, outputSize: source.nativeSize, region: region)
        return Self.readTexture(tile.texture).withUnsafeBytes { Data($0) }
    }
}
