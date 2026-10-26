import CoreImage
import Foundation
import HyperDRRecipe
import Testing
@testable import HyperDRRender

private func sameBits(_ actual: [Float], _ expected: [Float], _ label: String) {
    #expect(actual.count == expected.count && !actual.isEmpty, "\(label): size")
    let differing = zip(actual, expected).filter { $0.bitPattern != $1.bitPattern }.count
    #expect(differing == 0, "\(label): \(differing) of \(actual.count) values differ")
}

private extension RenderEngine {
    func stagedBaselinePixels(_ source: RenderSource, edit: RenderAdjustments) throws -> [Float] {
        Self.readTexture(try lookBaseline(source, edit: edit))
    }
}

/// A partial RAW scene look's Apple endpoint, staged once for an export, must
/// give the bands exactly what developing it again for each band gives.
@Suite(.serialized) struct StagedLookBaselineTests {
    private let geometry = Geometry(angle: 4, vertical: 17, horizontal: -11, quarterTurns: 1, flipped: true,
        crop: CropRect(centreX: 0.02, centreY: -0.015, width: 0.59, height: 0.41))

    private func fixture() throws -> (directory: URL, file: URL) {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("staged-baseline-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // The DNG offers both 8.dng and 9.dng.
        let file = directory.appendingPathComponent("input.dng")
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/fixtures/canon-eos-5d-iii-lossy.dng"), to: file)
        return (directory, file)
    }

    @Test(arguments: [(8, false), (9, false), (9, true)])
    func stagedBandsMatchReopenedBands(generation: Int, cropped: Bool) async throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selector = try RenderEngine()
        let decoder = try #require(await selector.rawDecoder(file, generation: generation))
        let lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        let film = Recipe(inputDomain: .rawEDR,
            values: ["look.film": .string("portra400"), "look.filmStrength": .number(40), "hdr.range": .number(4)],
            rawDecoderVersion: decoder, geometry: cropped ? geometry : .identity)
        let log = Recipe(inputDomain: .rawEDR, look: LUTReference(contentHash: lut.contentHash, name: "Log"),
            values: ["look.input": .string("slog3-sgamut3cine"), "look.output": .string("rec709"),
                     "look.strength": .number(40), "hdr.range": .number(4)],
            rawDecoderVersion: decoder, geometry: cropped ? geometry : .identity)
        for (name, recipe, recipeLUT) in [("film", film, nil as ColorLUT?), ("log", log, lut)] {
            #expect(recipe.needsLookBaseline)
            let options = try SourceOptions(recipe: recipe)
            let reopening = try RenderEngine(), staging = try RenderEngine()
            let reopened = try await reopening.openExportSource(file, options: options)
            let staged = try await staging.openExportSource(file, options: options, stagingLookBaseline: true)
            #expect(!reopened.stagesLookBaseline && staged.stagesLookBaseline)
            #expect(staged.nativeSize == reopened.nativeSize && staged.rawSettings?.decoderVersion == decoder)
            #expect(staged.id == reopened.id && staged.analysisSource.modelSourceID == reopened.analysisSource.modelSourceID)
            let size = staged.nativeSize
            let edit = try RenderAdjustments(recipe: recipe, lut: recipeLUT)
            let halo = edit.film.sourceHalo(size: size)
            // Corners, and windows across the canonical cell seams (2044 × 256).
            let regions = [CGRect(x: 0, y: 0, width: 53, height: 37),
                CGRect(x: min(2035, size.width - 73), y: min(250, size.height - 39), width: 73, height: 39),
                CGRect(x: min(4080, size.width - 40), y: min(505, size.height - 20), width: 40, height: 20),
                CGRect(x: size.width - 61, y: size.height - 43, width: 61, height: 43)]
            for (index, region) in regions.enumerated() {
                let a = try await reopening.materializeExportRegion(reopened, outputSize: size, region: region, halo: halo)
                let b = try await staging.materializeExportRegion(staged, outputSize: size, region: region, halo: halo)
                let label = "\(name) RAW \(decoder) cropped=\(cropped) region \(index)"
                sameBits(try await staging.stagedBaselinePixels(b, edit: edit),
                         try await reopening.stagedBaselinePixels(a, edit: edit), label + " Apple endpoint")
                let expected = RenderEngine.readPixels(try await reopening.render(a, recipe: recipe, lut: recipeLUT,
                                                                                  size: size, region: region))
                let actual = RenderEngine.readPixels(try await staging.render(b, recipe: recipe, lut: recipeLUT,
                                                                              size: size, region: region))
                sameBits(actual.baseRGBA, expected.baseRGBA, label + " base")
                sameBits(actual.gain, expected.gain, label + " gain")
                var full = recipe
                full.setValue(.number(100), for: recipe.look == nil ? "look.filmStrength" : "look.strength")
                let fullExpected = RenderEngine.readPixels(try await reopening.render(a, recipe: full, lut: recipeLUT,
                    size: size, region: region))
                let fullActual = RenderEngine.readPixels(try await staging.render(b, recipe: full, lut: recipeLUT,
                    size: size, region: region))
                sameBits(fullActual.baseRGBA, fullExpected.baseRGBA, label + " full-strength base")
                sameBits(fullActual.gain, fullExpected.gain, label + " full-strength gain")
            }
            // Finished rows through the export band reader, at native size.
            let request = ExportRenderRequest(photoSize: size, capabilities: .init(supportsThreeChannelGain: true))
            let a = try await reopening.prepareExportRows(reopened, recipe: recipe, lut: recipeLUT, request: request)
            let b = try await staging.prepareExportRows(staged, recipe: recipe, lut: recipeLUT, request: request)
            for y in [0, max(0, size.height / 2 - 40), max(0, size.height - 64)] {
                let count = min(64, size.height - y)
                let expected = try a.read(y: y, count: count), actual = try b.read(y: y, count: count)
                sameBits(actual.baseRGB, expected.baseRGB, "\(name) RAW \(decoder) rows \(y) base")
                sameBits(actual.gain, expected.gain, "\(name) RAW \(decoder) rows \(y) gain")
            }
        }
    }

    @Test func fullStrengthNeedsHDRReferenceAndInactiveZeroDoesNot() throws {
        for strength in [0.0, 100.0] {
            let recipe = Recipe(inputDomain: .rawEDR,
                values: ["look.film": .string("portra400"), "look.filmStrength": .number(strength)])
            #expect(recipe.needsLookBaseline == (strength > 0))
        }
    }
}
