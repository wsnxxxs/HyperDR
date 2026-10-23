import CoreGraphics
import CoreImage
import Foundation
import HyperDRRecipe
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HyperDRRender

enum FilmFileKind: String, CaseIterable, Sendable {
    case jpeg, pqTIFF
    var domain: InputDomain { self == .jpeg ? .sdr : .hdr }
}

/// A TinyPhoto-style real file in a private directory. The PQ TIFF has no gain
/// map, so it exercises the single-layer HDR branch rather than the dual shortcut.
private struct FilmTinyPhoto {
    let directory: URL
    let url: URL

    init(_ kind: FilmFileKind) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperdr-film-file-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent(kind == .jpeg ? "input.jpg" : "input.tiff")
        do {
            let width = 96, height = 64
            let image: CGImage
            if kind == .jpeg {
                let bytes = Data((0..<(width * height)).flatMap { i -> [UInt8] in
                    [UInt8(30 + (i % width) * 180 / width),
                     UInt8(25 + (i / width) * 160 / height), UInt8(50 + (i / 7 % 2) * 100), 255]
                })
                image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent))
            } else {
                // Encoded PQ samples include highlights above SDR white. ImageIO
                // must retain that transfer function and classify this as HDR.
                let samples = (0..<(width * height)).flatMap { i -> [UInt16] in
                    let x = Double(i % width) / Double(width), y = Double(i / width) / Double(height)
                    return [UInt16((0.55 + 0.25 * x) * 65535), UInt16((0.50 + 0.22 * y) * 65535),
                            UInt16((0.58 + 0.12 * Double(i / 7 % 2)) * 65535), 65535]
                }
                let data = samples.withUnsafeBytes { Data($0) }
                image = try #require(CGImage(width: width, height: height, bitsPerComponent: 16,
                    bitsPerPixel: 64, bytesPerRow: width * 8, space: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!,
                    bitmapInfo: [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)],
                    provider: CGDataProvider(data: data as CFData)!, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent))
            }
            let type = kind == .jpeg ? UTType.jpeg : .tiff
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
                type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class FilmFileStripes: @unchecked Sendable {
    private let lock = NSLock()
    private var baseStorage: [Float] = [], gainStorage: [Float] = []
    func append(_ stripe: ExportStripe) {
        lock.withLock { baseStorage += stripe.baseRGB; gainStorage += stripe.gain }
    }
    var base: [Float] { lock.withLock { baseStorage } }
    var gain: [Float] { lock.withLock { gainStorage } }
}

private func fileFilmRecipe(_ domain: InputDomain, strength: Double) -> Recipe {
    Recipe(inputDomain: domain, values: ["look.film": .string("portra400"),
        "look.filmStrength": .number(strength), "look.filmGrain": .number(0),
        "look.filmHalation": .number(0), "look.filmExposure": .number(0)])
}

private func fileFilmClose(_ actual: [Float], _ expected: [Float], label: String, scale: Float = 1) {
    #expect(!actual.isEmpty && actual.count == expected.count, "\(label): invalid output shape")
    #expect(actual.allSatisfy(\.isFinite) && expected.allSatisfy(\.isFinite), "\(label): nonfinite output")
    let error = zip(actual, expected).reduce(Float(0)) { max($0, abs($1.0 - $1.1) * scale) }
    #expect(error <= 1.0 / 1023, "\(label): changed by \(error)")
}

private func fileFilmClose(_ actual: PlanePixels, _ expected: PlanePixels, label: String) {
    #expect(actual.size == expected.size && actual.gainChannelCount == expected.gainChannelCount)
    fileFilmClose(actual.baseRGBA, expected.baseRGBA, label: label + " base")
    fileFilmClose(actual.gain, expected.gain, label: label + " gain", scale: 0.25)
}

private struct FilmBaselinePixels: Sendable {
    let values: [Float]
    let reusedInput: Bool
}

private extension RenderEngine {
    func fileFilmBaseline(_ source: RenderSource, edit: RenderAdjustments) throws -> FilmBaselinePixels {
        let texture = try lookBaseline(source, edit: edit)
        return FilmBaselinePixels(values: Self.readTexture(texture), reusedInput: texture === source.texture)
    }

    func fileFilmSourcePixels(_ source: RenderSource) -> [Float] { Self.readTexture(source.texture) }
}

@Suite(.serialized) struct FilmFileBaselineTests {
    @Test(arguments: FilmFileKind.allCases, [0.0, 40, 100])
    func fileBackedFilmRendersFullPreviewROIAndExport(kind: FilmFileKind, strength: Double) async throws {
        try await exerciseFile(kind: kind, strength: strength, manualSceneLinear: false)
    }

    @Test(arguments: FilmFileKind.allCases)
    func aManualSceneLinearFlagDoesNotReopenRasterFilesAsRAW(kind: FilmFileKind) async throws {
        try await exerciseFile(kind: kind, strength: 40, manualSceneLinear: true)
    }

    private func exerciseFile(kind: FilmFileKind, strength: Double, manualSceneLinear: Bool) async throws {
        let photo = try FilmTinyPhoto(kind)
        defer { photo.remove() }
        let recipe = fileFilmRecipe(kind.domain, strength: strength)
        #expect(!recipe.needsLookBaseline)
        var options = try SourceOptions(recipe: recipe)
        if manualSceneLinear { options.sceneLinear = true }
        let engine = try RenderEngine(), referenceEngine = try RenderEngine()
        let full = try await engine.load(photo.url, options: options)
        let reference = try await referenceEngine.load(photo.url)
        #expect(full.domain == kind.domain && full.rawSettings == nil && full.authoredGainMap == nil)
        if kind == .pqTIFF {
            #expect(await engine.fileFilmSourcePixels(full).contains { $0 > 1 })
        }
        // The reference imports the display rendition before any film is chosen.
        // File-backed film must grade those same pixels at every strength.
        let whole = RenderEngine.readPixels(try await engine.render(full, recipe: recipe))
        let expected = RenderEngine.readPixels(try await referenceEngine.render(reference, recipe: recipe))
        fileFilmClose(whole, expected, label: "\(kind) strength \(strength) full")
        if strength == 0 {
            let neutral = RenderEngine.readPixels(try await referenceEngine.render(reference, recipe: Recipe(inputDomain: kind.domain)))
            fileFilmClose(whole, neutral, label: "zero film endpoint")
        } else {
            let neutral = RenderEngine.readPixels(try await referenceEngine.render(reference, recipe: Recipe(inputDomain: kind.domain)))
            #expect(zip(whole.baseRGBA, neutral.baseRGBA).contains { abs($0 - $1) > 0.001 },
                    "Film disappeared instead of rendering the selected strength")
        }
        options.resolution = .preview(maximumSize: PixelSize(width: 43, height: 31))
        let preview = try await engine.load(photo.url, options: options)
        let previewReference = try await referenceEngine.load(photo.url, options: SourceOptions(resolution: options.resolution))
        #expect(preview.size.width < full.size.width && preview.size.height < full.size.height)
        fileFilmClose(RenderEngine.readPixels(try await engine.render(preview, recipe: recipe)),
            RenderEngine.readPixels(try await referenceEngine.render(previewReference, recipe: recipe)), label: "file preview")

        let lazyEngine = try RenderEngine()
        let lazy = try await lazyEngine.openExportSource(photo.url, options: options)
        #expect(lazy.domain == kind.domain && lazy.rawSettings == nil && lazy.opened.gain == nil)
        let region = CGRect(x: 19, y: 13, width: 41, height: 27)
        let edit = try RenderAdjustments(recipe: recipe)
        let tile = try await lazyEngine.materializeExportRegion(lazy, outputSize: lazy.nativeSize, region: region,
            halo: edit.film.sourceHalo(size: lazy.nativeSize))
        fileFilmClose(RenderEngine.readPixels(try await lazyEngine.render(tile, recipe: recipe, size: lazy.nativeSize, region: region)),
            RenderEngine.readPixels(try await referenceEngine.render(reference, recipe: recipe, size: lazy.nativeSize, region: region)),
            label: "file lazy ROI")

        let request = ExportRenderRequest(photoSize: lazy.nativeSize, capabilities: .init(supportsThreeChannelGain: true))
        let prepared = try await lazyEngine.prepareExportRows(lazy, recipe: recipe, request: request)
        let written = FilmFileStripes()
        let report = try await referenceEngine.renderExportStripes(reference, recipe: recipe, request: request,
            rows: 13, prepare: { _ in }, consume: { written.append($0) })
        let rows = try prepared.read(y: 0, count: lazy.nativeSize.height)
        #expect(prepared.report.gain?.channelCount == report.gain?.channelCount)
        fileFilmClose(rows.baseRGB, written.base, label: "file prepared/export base")
        fileFilmClose(rows.gain, written.gain, label: "file prepared/export gain", scale: 0.25)
        let tail = try prepared.read(y: 37, count: 17)
        fileFilmClose(tail.baseRGB, Array(rows.baseRGB[(37 * 96 * 3)..<(54 * 96 * 3)]), label: "file row replay base")
        let channels = try #require(prepared.report.gain?.channelCount)
        fileFilmClose(tail.gain, Array(rows.gain[(37 * 96 * channels)..<(54 * 96 * channels)]), label: "file row replay gain", scale: 0.25)
        print("FILM_FILE kind=\(kind.rawValue) strength=\(strength) manualLinear=\(manualSceneLinear) full_preview_ROI_export=complete")
    }

    @Test func aPartialRAWFilmStillDevelopsItsGeometryMatchedAppleBaseline() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-film-raw-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input.ARW")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW"), to: file)
        let engine = try RenderEngine(), appleEngine = try RenderEngine()
        let version = try #require(await engine.defaultRAWDecoder(file))
        var recipe = fileFilmRecipe(.rawEDR, strength: 40)
        recipe = Recipe(inputDomain: .rawEDR, values: recipe.values, rawDecoderVersion: version,
            geometry: Geometry(angle: 3, quarterTurns: 1,
                crop: CropRect(centreX: 0.02, centreY: -0.03, width: 0.8, height: 0.8)))
        #expect(recipe.needsLookBaseline)
        let edit = try RenderAdjustments(recipe: recipe)
        let bound = SourceResolution.preview(maximumSize: PixelSize(width: 63, height: 47))
        var options = try SourceOptions(recipe: recipe, resolution: bound)
        #expect(options.sceneLinear)
        let scene = try await engine.load(file, options: options)
        let baseline = try await engine.fileFilmBaseline(scene, edit: edit)
        options.sceneLinear = false
        let apple = try await appleEngine.load(file, options: options)
        let display = await appleEngine.fileFilmSourcePixels(apple)
        #expect(!baseline.reusedInput)
        #expect(scene.rawSettings?.decoderVersion == version && apple.rawSettings?.decoderVersion == version)
        fileFilmClose(baseline.values, display, label: "RAW partial preview Apple endpoint")
        let sceneValues = await engine.fileFilmSourcePixels(scene)
        #expect(zip(baseline.values, sceneValues).contains { abs($0 - $1) > 0.001 },
                "RAW partial film lost its distinct Apple display endpoint")
        for strength in [0.0, 100] {
            let endpoint = fileFilmRecipe(.rawEDR, strength: strength)
            #expect(!endpoint.needsLookBaseline)
            #expect(try await engine.fileFilmBaseline(scene, edit: RenderAdjustments(recipe: endpoint)).reusedInput)
        }
        options.sceneLinear = true
        let lazy = try await engine.openExportSource(file, options: options)
        options.sceneLinear = false
        let appleLazy = try await appleEngine.openExportSource(file, options: options)
        let region = CGRect(x: lazy.nativeSize.width / 2 - 7, y: lazy.nativeSize.height / 2 - 5, width: 23, height: 17)
        let tile = try await engine.materializeExportRegion(lazy, outputSize: lazy.nativeSize, region: region)
        let appleTile = try await appleEngine.materializeExportRegion(appleLazy, outputSize: appleLazy.nativeSize, region: region)
        let roiBaseline = try await engine.fileFilmBaseline(tile, edit: edit)
        #expect(!roiBaseline.reusedInput)
        fileFilmClose(roiBaseline.values, await appleEngine.fileFilmSourcePixels(appleTile), label: "RAW partial geometry/ROI Apple endpoint")
    }
}
