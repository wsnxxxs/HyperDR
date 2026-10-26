import CoreImage
import Foundation
import HyperDRRecipe
import HyperDRRender
import Testing
@testable import HyperDREditorCore

/// LibRaw chosen for new photos, on the real RenderSession. The converter
/// stands in for Kit's: it hands back a fixture DNG as the conversion.
@Suite(.serialized) struct LibRAWOpeningTests {
    private final class Converter: RAWCompatibilityConverting, @unchecked Sendable {
        let converterID = "test-libraw/dng-1"
        let dng: URL?
        private let lock = NSLock()
        private var count = 0
        var conversions: Int { lock.withLock { count } }

        init(dng: URL?) { self.dng = dng }

        func convertDNG(from source: URL) async throws -> RAWConvertedDNG {
            let previous = lock.withLock { count += 1; return count - 1 }
            guard let dng else { throw RenderError.rawUnsupported(camera: "Test Camera") }
            return RAWConvertedDNG(url: dng, converterID: converterID, usedCache: previous > 0)
        }

        func extractEmbeddedPreview(from source: URL) async throws -> RAWEmbeddedPreview {
            throw RAWCompatibilityError.noPreview
        }
    }

    private actor OpenAttempts {
        private(set) var versions: [String] = []
        func add(_ version: String?) { versions.append(version ?? "system-default") }
    }

    private static var fixtures: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("build/fixtures")
    }

    /// The camera must be one Apple develops, and the DNG must offer 8 and 9.
    private static var supported: Bool {
        guard CIRAWFilter(imageURL: fixtures.appendingPathComponent("sony-ilce-7s.ARW")) != nil,
              let dng = CIRAWFilter(imageURL: fixtures.appendingPathComponent("canon-eos-5d-iii-lossy.dng")) else { return false }
        let versions = dng.supportedDecoderVersions.map(\.rawValue)
        return versions.contains("8.dng") && versions.contains("9.dng")
    }

    private func copy(_ name: String) throws -> URL {
        let input = Self.fixtures.appendingPathComponent(name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + input.pathExtension)
        try FileManager.default.copyItem(at: input, to: url)
        return url
    }

    private func register(dng: URL?) -> Converter {
        let converter = Converter(dng: dng)
        RenderEngine.registerRAWCompatibilityConverter(converter)
        return converter
    }

    @MainActor @Test(.enabled(if: Self.supported))
    func aSupportedCameraIsConvertedRecordedAndReopenedThroughLibRaw() async throws {
        let url = try copy("sony-ilce-7s.ARW"), dng = try copy("canon-eos-5d-iii-lossy.dng")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: dng) }
        let converter = register(dng: dng)
        defer { RenderEngine.registerRAWCompatibilityConverter(nil) }
        let editor = RecipeEditor(renderer: try RenderSession())
        editor.canvasPixelSize = PixelSize(width: 64, height: 64)
        try await editor.open(url, rawDecoderPreference: .libRAW)
        await editor.settle()
        #expect(editor.sourceCompatibility == .convertedDNG)
        #expect(editor.source?.rawCompatibilityByChoice == true)
        #expect(editor.source?.rawDecoderFallback == nil)
        #expect(editor.recipe.rawCompatibility == converter.converterID)
        #expect(editor.recipe.rawDecoderVersion == "9.dng")
        #expect(try editor.exportCapture().recipe.rawCompatibility == converter.converterID)
        #expect(editor.renderFailure == nil)

        // A saved LibRaw edit reopens through LibRaw whatever the setting.
        let saved = editor.recipe
        try await editor.open(url, restoring: saved, rawDecoderPreference: .raw8)
        await editor.settle()
        #expect(editor.sourceCompatibility == .convertedDNG)
        #expect(editor.recipe.rawCompatibility == converter.converterID)
        #expect(editor.recipe.rawDecoderVersion == "9.dng")

        // The same camera under Automatic stays native.
        try await editor.open(url, rawDecoderPreference: .automatic)
        await editor.settle()
        #expect(editor.sourceCompatibility == nil)
        #expect(editor.recipe.rawCompatibility == nil)
        await editor.close()
    }

    @Test(.enabled(if: Self.supported))
    func libRawsNineFallsBackToEightOnTheSameConversion() async throws {
        let url = try copy("sony-ilce-7s.ARW"), dng = try copy("canon-eos-5d-iii-lossy.dng")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: dng) }
        let converter = register(dng: dng)
        defer { RenderEngine.registerRAWCompatibilityConverter(nil) }
        let session = try RenderSession(), attempts = OpenAttempts()
        await session.setBeforeOpenLoad { options in
            await attempts.add(options.rawDecoderVersion)
            if options.rawDecoderVersion == "9.dng" { throw RenderError.cannotDecodeSource }
        }
        let source = try await session.open(url, previewSize: PixelSize(width: 64, height: 64), restoring: nil,
                                            rawDecoderPreference: .libRAW)
        #expect(await attempts.versions == ["9.dng", "8.dng"])
        #expect(source.rawDecoderVersion == "8.dng")
        #expect(source.rawCompatibility == converter.converterID)
        #expect(source.rawDecoderFallback == RAWDecoderFallback(requested: "9.dng", used: "8.dng"))
        await session.close()
    }

    @Test(.enabled(if: Self.supported))
    func aCameraLibRawCannotReadOpensWithAppleAndSaysSo() async throws {
        let url = try copy("sony-ilce-7s.ARW")
        defer { try? FileManager.default.removeItem(at: url) }
        let converter = register(dng: nil)
        defer { RenderEngine.registerRAWCompatibilityConverter(nil) }
        let session = try RenderSession()
        let source = try await session.open(url, previewSize: PixelSize(width: 64, height: 64), restoring: nil,
                                            rawDecoderPreference: .libRAW)
        #expect(source.sourceCompatibility == nil)
        #expect(source.rawCompatibility == nil)
        #expect(!source.rawCompatibilityByChoice)
        let version = try #require(source.rawDecoderVersion)
        #expect(source.rawDecoderFallback == RAWDecoderFallback(requested: RAWDecoderFallback.libRAW, used: version))
        #expect(converter.conversions == 1)
        await session.close()
    }

    @Test(.enabled(if: Self.supported))
    func aDNGOriginalIsNotConvertedAgain() async throws {
        let dng = try copy("canon-eos-5d-iii-lossy.dng"), other = try copy("canon-eos-5d-iii-lossy.dng")
        defer { try? FileManager.default.removeItem(at: dng); try? FileManager.default.removeItem(at: other) }
        let converter = register(dng: other)
        defer { RenderEngine.registerRAWCompatibilityConverter(nil) }
        let session = try RenderSession()
        let source = try await session.open(dng, previewSize: PixelSize(width: 64, height: 64), restoring: nil,
                                            rawDecoderPreference: .libRAW)
        #expect(source.sourceCompatibility == nil)
        #expect(source.rawDecoderVersion == "9.dng")
        #expect(source.rawDecoderFallback == nil)
        #expect(converter.conversions == 0)
        await session.close()
    }
}
