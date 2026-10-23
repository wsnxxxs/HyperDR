import CoreImage
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRRender

private struct LogGeometryRows: Sendable {
    let size: PixelSize
    let base, gain: [Float]
    let metadata: ExportGainMetadata

    var hdr: [Float] {
        base.indices.map { index in
            let pixel = index / 3, channel = index % 3
            let value = gain[pixel * metadata.channelCount + (metadata.channelCount == 1 ? 0 : channel)]
            return (base[index] + metadata.baseOffset[channel]) * exp2(value) - metadata.alternateOffset[channel]
        }
    }
}

private struct LogGeometryCapture: Sendable {
    let preview: PlanePixels
    let nativeRegions: [PlanePixels]
    let rows: LogGeometryRows
}

private final class LogGeometryStripes: @unchecked Sendable {
    private let lock = NSLock()
    private var baseStorage: [Float] = [], gainStorage: [Float] = []
    func append(_ stripe: ExportStripe) {
        lock.withLock { baseStorage += stripe.baseRGB; gainStorage += stripe.gain }
    }
    var base: [Float] { lock.withLock { baseStorage } }
    var gain: [Float] { lock.withLock { gainStorage } }
}

private func logGeometryClose(_ actual: [Float], _ expected: [Float], tolerance: Float, label: String) {
    #expect(actual.count == expected.count && !actual.isEmpty, "\(label): invalid output size")
    #expect(actual.allSatisfy(\.isFinite) && expected.allSatisfy(\.isFinite), "\(label): nonfinite output")
    let error = zip(actual, expected).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
    #expect(error <= tolerance, "\(label): maximum error \(error)")
}

private func logGeometryHDR(_ pixels: PlanePixels) -> [Float] {
    var result: [Float] = []
    for y in 0..<pixels.size.height { for x in 0..<pixels.size.width {
        let gainX = min(pixels.gainSize.width - 1, x * pixels.gainSize.width / pixels.size.width)
        let gainY = min(pixels.gainSize.height - 1, y * pixels.gainSize.height / pixels.size.height)
        for channel in 0..<3 {
            let gain = pixels.gain[(gainY * pixels.gainSize.width + gainX) * pixels.gainChannelCount
                + (pixels.gainChannelCount == 1 ? 0 : channel)]
            result.append(pixels.baseRGBA[(y * pixels.size.width + x) * 4 + channel] * exp2(gain))
        }
    } }
    return result
}

private func logGeometryPixels(_ planes: RenderPlanes) throws -> PlanePixels {
    let hasZeroOffsetLogGain: Bool
    if case .log2 = planes.encoding { hasZeroOffsetLogGain = true }
    else { hasZeroOffsetLogGain = false }
    try #require(hasZeroOffsetLogGain, "The RAW linear-light oracle requires zero-offset .log2 gain")
    return RenderEngine.readPixels(planes)
}

private func logGeometryClose(_ actual: PlanePixels, _ expected: PlanePixels, label: String) {
    #expect(actual.size == expected.size)
    logGeometryClose(actual.baseRGBA, expected.baseRGBA, tolerance: 1.0 / 1023, label: label + " SDR")
    logGeometryClose(logGeometryHDR(actual), logGeometryHDR(expected), tolerance: 4.0 / 1023, label: label + " HDR")
}

/// The same independent-endpoint oracle as LookPipelineTests: mix completed
/// renditions in linear light, never interpolate encoded Log values or gains.
private func logGeometryMix(_ actual: PlanePixels, neutral: PlanePixels, styled: PlanePixels, label: String) {
    let expectedBase = zip(neutral.baseRGBA, styled.baseRGBA).map { $0 + ($1 - $0) * 0.4 }
    let expectedHDR = zip(logGeometryHDR(neutral), logGeometryHDR(styled)).map { $0 + ($1 - $0) * 0.4 }
    logGeometryClose(actual.baseRGBA, expectedBase, tolerance: 1e-5, label: label + " SDR mix")
    logGeometryClose(logGeometryHDR(actual), expectedHDR, tolerance: 1e-4, label: label + " HDR mix")
}

private extension RenderEngine {
    func logGeometrySourcePixels(_ source: RenderSource) -> [Float] { Self.readTexture(source.texture) }
    func logGeometryBaselinePixels(_ source: RenderSource, edit: RenderAdjustments) throws -> [Float] {
        Self.readTexture(try lookBaseline(source, edit: edit))
    }
}

@Suite(.serialized) struct RAWLogGeometryRegressionTests {
    private let geometry = Geometry(angle: 4, vertical: 17, horizontal: -11, quarterTurns: 1, flipped: true,
        crop: CropRect(centreX: 0.02, centreY: -0.015, width: 0.59, height: 0.41))

    @Test(arguments: [8, 9])
    func partialLogKeepsItsRecordedDecoderAndGlobalGeometry(generation: Int) async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raw-log-geometry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // This real DNG advertises both 8.dng and 9.dng. The older Sony fixture
        // used by general Log tests only offers older camera-specific decoders.
        let file = directory.appendingPathComponent("input.dng")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng"), to: file)
        let selector = try RenderEngine()
        let decoder = try #require(await selector.rawDecoder(file, generation: generation))
        let lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        func recipe(_ strength: Double) -> Recipe {
            Recipe(inputDomain: .rawEDR, look: LUTReference(contentHash: lut.contentHash, name: "Log geometry"),
                values: ["look.input": .string("slog3-sgamut3cine"), "look.output": .string("rec709"),
                         "look.strength": .number(strength), "hdr.range": .number(4)],
                rawDecoderVersion: decoder, geometry: geometry)
        }
        let neutral = try await capture(file, recipe: recipe(0), lut: lut)
        let styled = try await capture(file, recipe: recipe(100), lut: lut)
        let partial = try await capture(file, recipe: recipe(40), lut: lut)
        logGeometryMix(partial.preview, neutral: neutral.preview, styled: styled.preview, label: "geometry preview")
        for index in neutral.nativeRegions.indices {
            logGeometryMix(partial.nativeRegions[index], neutral: neutral.nativeRegions[index],
                styled: styled.nativeRegions[index], label: "geometry native region \(index)")
        }
        logGeometryClose(partial.rows.base, zip(neutral.rows.base, styled.rows.base).map { $0 + ($1 - $0) * 0.4 },
            tolerance: 1e-5, label: "geometry finished-row SDR mix")
        logGeometryClose(partial.rows.hdr, zip(neutral.rows.hdr, styled.rows.hdr).map { $0 + ($1 - $0) * 0.4 },
            tolerance: 1e-4, label: "geometry finished-row HDR mix")
        #expect(zip(neutral.preview.baseRGBA, styled.preview.baseRGBA).contains { abs($0 - $1) > 0.001 },
                "The Log endpoint must actually change this photo")
        print("RAW_LOG_GEOMETRY requested=\(generation) recorded=\(decoder) preview_nativeROI_finishedRows=complete")
    }

    private func capture(_ file: URL, recipe: Recipe, lut: ColorLUT) async throws -> LogGeometryCapture {
        let engine = try RenderEngine()
        let decoder = try #require(recipe.rawDecoderVersion)
        #expect(try Recipe.decode(recipe.encoded()).rawDecoderVersion == decoder)
        let options = try SourceOptions(recipe: recipe)
        let full = try await engine.load(file, options: options)
        let size = full.nativeSize
        #expect(full.rawSettings?.decoderVersion == decoder && full.size == size)
        print("RAW_LOG_GEOMETRY_CAPTURE decoder=\(decoder) strength=\(recipe.conditionValue("look.strength")?.numberValue ?? -1) native=\(size.width)x\(size.height)")
        let regions = [CGRect(x: 0, y: 0, width: 53, height: 37),
            CGRect(x: min(2035, size.width - 73), y: 253, width: 73, height: 39),
            CGRect(x: size.width - 61, y: size.height - 43, width: 61, height: 43)]
        var native: [PlanePixels] = []
        for region in regions {
            native.append(try logGeometryPixels(try await engine.render(full, recipe: recipe, lut: lut, region: region)))
        }
        let lazy = try await engine.openExportSource(file, options: options)
        #expect(lazy.nativeSize == size && lazy.rawSettings?.decoderVersion == decoder)
        let edit = try RenderAdjustments(recipe: recipe, lut: lut)
        var neutral = recipe
        neutral.look = nil
        let appleEngine = try RenderEngine()
        let appleLazy = recipe.needsLookBaseline
            ? try await appleEngine.openExportSource(file, options: SourceOptions(recipe: neutral)) : nil
        for (index, region) in regions.enumerated() {
            let tile = try await engine.materializeExportRegion(lazy, outputSize: size, region: region)
            #expect(tile.rawSettings?.decoderVersion == decoder)
            let actual = try logGeometryPixels(try await engine.render(tile, recipe: recipe, lut: lut, size: size, region: region))
            logGeometryClose(actual, native[index], label: "full/lazy geometry region \(index)")
            if let appleLazy {
                let apple = try await appleEngine.materializeExportRegion(appleLazy, outputSize: size, region: region)
                #expect(apple.rawSettings?.decoderVersion == decoder)
                logGeometryClose(try await engine.logGeometryBaselinePixels(tile, edit: edit),
                    await appleEngine.logGeometrySourcePixels(apple), tolerance: 1e-5, label: "independent Apple ROI baseline")
            }
        }
        let bound = SourceResolution.preview(maximumSize: PixelSize(width: 96, height: 96))
        let previewSource = try await engine.load(file, options: SourceOptions(recipe: recipe, resolution: bound))
        #expect(previewSource.nativeSize == size && previewSource.size.width < size.width)
        #expect(previewSource.rawSettings?.decoderVersion == decoder)
        let preview = try logGeometryPixels(try await engine.render(previewSource, recipe: recipe, lut: lut))
        if recipe.needsLookBaseline {
            let apple = try await appleEngine.load(file, options: SourceOptions(recipe: neutral, resolution: bound))
            #expect(apple.rawSettings?.decoderVersion == decoder && apple.size == previewSource.size)
            logGeometryClose(try await engine.logGeometryBaselinePixels(previewSource, edit: edit),
                await appleEngine.logGeometrySourcePixels(apple), tolerance: 1e-5, label: "independent Apple preview baseline")
        } else if recipe.conditionValue("look.strength")?.numberValue == 0 {
            let apple = try await appleEngine.load(file, options: SourceOptions(recipe: neutral, resolution: bound))
            logGeometryClose(preview, try logGeometryPixels(try await appleEngine.render(apple, recipe: neutral)),
                label: "zero Log equals no look")
        }

        // Both branches render onto the same output grid. Preview's area filter
        // is not compared with applying a nonlinear Log look before downsampling.
        let output = PixelSize(width: 129, height: 111)
        let request = ExportRenderRequest(photoSize: output, capabilities: .init(supportsThreeChannelGain: true))
        let reference = LogGeometryStripes()
        let report = try await engine.renderExportStripes(full, recipe: recipe, lut: lut, request: request,
            rows: 17, prepare: { _ in }, consume: { reference.append($0) })
        let prepared = try await engine.prepareExportRows(lazy, recipe: recipe, lut: lut, request: request)
        let all = try prepared.read(y: 0, count: output.height)
        let metadata = try #require(prepared.report.gain)
        #expect(metadata.channelCount == report.gain?.channelCount)
        logGeometryClose(all.baseRGB, reference.base, tolerance: 1.0 / 1023, label: "full/lazy finished SDR")
        logGeometryClose(all.gain, reference.gain, tolerance: 4.0 / 1023, label: "full/lazy finished gain")
        if recipe.needsLookBaseline {
            for count in [17, 31, 64] {
                for y in Array(stride(from: 0, to: output.height, by: count)).reversed() {
                    let stripe = try prepared.read(y: y, count: min(count, output.height - y))
                    let last = y + stripe.rect.height
                    logGeometryClose(stripe.baseRGB, Array(all.baseRGB[(y * output.width * 3)..<(last * output.width * 3)]),
                        tolerance: 1.0 / 1023, label: "reversed geometry rows SDR")
                    logGeometryClose(stripe.gain,
                        Array(all.gain[(y * output.width * metadata.channelCount)..<(last * output.width * metadata.channelCount)]),
                        tolerance: 4.0 / 1023, label: "reversed geometry rows gain")
                }
            }
        }
        return LogGeometryCapture(preview: preview, nativeRegions: native,
            rows: LogGeometryRows(size: output, base: all.baseRGB, gain: all.gain, metadata: metadata))
    }
}
