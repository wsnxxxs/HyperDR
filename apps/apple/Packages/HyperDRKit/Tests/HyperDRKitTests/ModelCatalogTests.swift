import CoreGraphics
import Foundation
import HyperDREngine
import ImageIO
import Testing
@testable import HyperDRKit

private func catalog(runtime: JSONValue = .bool(true), available: JSONValue = .bool(true),
                     defaultID: String = "first") -> ModelCatalog {
    ModelCatalog(document: .object(["runtimeAvailable": runtime, "defaultModelId": .string(defaultID),
        "models": .array([.object(["id": .string("first"), "available": available]),
                          .object(["id": .string("second"), "available": .bool(true)])])]))
}
private func modelCode(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as HyperDRError { return error.code }
    catch { Issue.record("Unexpected error: \(error)"); return nil }
}
private let catalogPhoto = PhotoSession(id: SessionID(rawValue: String(repeating: "a", count: 32)),
    sourceURL: URL(fileURLWithPath: "/tmp/model-photo.png"), displayName: "model-photo.png",
    byteCount: 1, sha256: "digest", format: .png)

@Suite(.timeLimit(.minutes(1))) struct ModelCatalogTests {
    @Test func selectionUsesTheBuildDefaultAndNeverSubstitutesAnotherModel() throws {
        let models = catalog()
        #expect(try models.resolve(nil) == "first")
        #expect(try models.resolve("") == "first")
        #expect(try models.resolveValue(.null) == "first")
        #expect(try models.resolve("second") == "second")
        #expect(modelCode { _ = try models.resolve("third") } == "model_unknown")
        #expect(modelCode { _ = try models.resolveValue(.number(1)) } == "invalid_options")
        let unavailableDefault = catalog(available: .bool(false))
        #expect(unavailableDefault.status.ready)
        #expect(try unavailableDefault.resolve("second") == "second")
        #expect(modelCode { _ = try unavailableDefault.resolve(nil) } == "model_not_ready")
        #expect(modelCode { _ = try catalog(defaultID: "missing").resolve(nil) } == "model_unknown")
    }
    @Test func runtimeAndPerModelFlagsRequireLiteralTrue() throws {
        for runtime in [JSONValue.bool(false), .null, .number(1)] {
            let models = catalog(runtime: runtime)
            #expect(!models.status.ready)
            for id in [nil, "first", "unknown"] {
                #expect(modelCode { _ = try models.resolve(id) } == "model_not_ready")
            }
        }
        for available in [JSONValue.bool(false), .null, .number(1)] {
            #expect(modelCode { _ = try catalog(available: available).resolve("first") } == "model_not_ready")
        }
    }
    @Test func malformedCapabilityDoesNotInventAReadyModel() {
        for document in [JSONValue.null, .object([:]), .object(["models": .array([]), "runtimeAvailable": .bool(true)])] {
            let models = ModelCatalog(document: document)
            #expect(!models.status.ready)
            #expect(modelCode { _ = try models.resolve(nil) } == "model_not_ready")
        }
        let models = ModelCatalog(document: .object(["runtimeAvailable": .bool(true),
            "models": .array([.null, .object(["id": .string("")]),
                              .object(["id": .string("engine-first"), "available": .bool(true), "version": .string("v7")])])]))
        #expect(models.defaultID == "engine-first")
        #expect(models.models.first?.document["version"] == .string("v7"))
    }
    @Test func useModelAndStrengthAreValidatedAndStrengthReplacesManualHdrStrength() throws {
        let resolver = OptionResolver(schema: try Engine.schema(), models: catalog(), maxEdgeCeiling: 2048)
        for flag in [JSONValue.string("true"), .number(1), .null, .array([])] {
            #expect(modelCode { _ = try resolver.resolveExport(EditOptions(["useModel": flag]), session: catalogPhoto) } == "invalid_options")
        }
        for strength in [JSONValue.number(-0.1), .number(1.1), .string("0.5"), .null] {
            #expect(modelCode { _ = try resolver.resolveExport(EditOptions(["modelStrength": strength]), session: catalogPhoto) } == "invalid_options")
        }
        let request = try resolver.resolveExport(EditOptions(["useModel": .bool(true), "modelId": .string("second"),
            "modelStrength": .number(0.65), "hdrStrength": .number(0.1)]), session: catalogPhoto)
        #expect(request.command["model_id"] == .string("second"))
        #expect(request.settings["gain_strength"] == .number(0.65))
        let manual = try resolver.resolveExport(EditOptions(["useModel": .bool(false), "modelId": .number(99)]), session: catalogPhoto)
        #expect(manual.command["model_mode"] == .bool(false))
    }
    @Test func modelPostAdjustmentsReachTheCLIWhileManualDevelopmentFlagsAreOmitted() throws {
        let resolver = OptionResolver(schema: try Engine.schema(), models: catalog(), maxEdgeCeiling: 2048)
        let options = EditOptions(["useModel": .bool(true), "modelStrength": .number(0.65),
            "aiBrightness": .number(0.25), "aiContrast": .number(1.2), "aiShadows": .number(-0.3),
            "aiHighlights": .number(0.4), "aiHdrRange": .number(2.8), "aiExpansionStart": .number(0.55),
            "brightness": .number(0.6), "contrast": .number(1.08), "hdrRange": .number(4)])
        let argv = try Engine.commandLine(resolver.resolveExport(options, session: catalogPhoto))
        for flag in ["--ai-model", "--gain-strength", "--ai-brightness", "--ai-contrast", "--ai-shadows", "--ai-highlights", "--ai-hdr-range", "--ai-expansion-start"] {
            #expect(argv.contains(flag))
        }
        for flag in ["--look", "--contrast", "--vibrance", "--pop", "--headroom-max", "--exposure-bias", "--expansion-start", "--area-coverage", "--exposure", "--headroom"] {
            #expect(!argv.contains(flag))
        }
        let preview = try resolver.resolve(PreviewRequest(session: catalogPhoto.id, options: options, maxEdge: 640), session: catalogPhoto)
        #expect(preview.command["model_id"] == .string("first"))
        #expect(preview.settings["gain_strength"] == .number(0.65))
        let previewArgv = try Engine.commandLine(preview)
        for flag in ["--look", "--contrast", "--vibrance", "--pop", "--headroom-max", "--exposure-bias", "--expansion-start", "--area-coverage", "--exposure", "--headroom"] {
            #expect(!previewArgv.contains(flag))
        }
        var manual = options; manual["useModel"] = .bool(false)
        let manualArgv = try Engine.commandLine(resolver.resolveExport(manual, session: catalogPhoto))
        #expect(!manualArgv.contains("--ai-brightness") && !manualArgv.contains("--ai-contrast"))
        let hlg = try resolver.resolveExport(EditOptions(["encoding": .string("hlg"), "useModel": .bool(true),
            "hdrRange": .number(4), "brightness": .number(0.6)]), session: catalogPhoto)
        let hlgArgv = try Engine.commandLine(hlg)
        let ceiling = try #require(hlgArgv.firstIndex(of: "--ai-hdr-range"))
        #expect(hlgArgv[ceiling + 1] == "-1")
    }
    @Test func modelAndColorOptionsDistinguishPreviewIdentities() throws {
        let resolver = OptionResolver(schema: try Engine.schema(), models: catalog(), maxEdgeCeiling: 2048)
        let values: [[String: JSONValue]] = [[:], ["modelId": .string("second")],
            ["colorGamut": .string("p3")], ["colorGamut": .string("p3"), "clampSrgb": .bool(true)]]
        let keys = try values.map { values in
            var values = values; values["useModel"] = .bool(true)
            let request = PreviewRequest(session: catalogPhoto.id, options: EditOptions(values), maxEdge: 640)
            return try PreviewCacheKey(session: catalogPhoto, request: resolver.resolve(request, session: catalogPhoto), buildFingerprint: "build")
        }
        #expect(Set(keys).count == keys.count)
    }
    @Test func realModelGainPreservesTheEnginesEffectiveIdentityAndPacketHeader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-k4-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("no-exif.png")
        let provider = try #require(CGDataProvider(data: Data(repeating: 128, count: 64 * 48 * 4) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: 64, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); try #require(CGImageDestinationFinalize(destination))
        let kit = try await HyperDRKit(configuration: KitConfiguration(supportDirectory: root.appendingPathComponent("support"), cacheDirectory: root.appendingPathComponent("cache")))
        try #require(kit.models.status.ready)
        let requested = try kit.models.resolve("research-exif-v1")
        let session = try kit.engine.openPreview(source: source)
        var request = EngineRequest(settings: [:]); try request.setCommand("model_id", .string(requested))
        let packet = try await session.modelGain(request)
        try #require(packet.count >= 13)
        #expect(Array(packet.prefix(9)) == Array("HYPGAIN1\n".utf8))
        let size = packet.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 9, as: UInt32.self))) }
        try #require(size > 0 && 13 + size <= packet.count)
        let metadata = try JSONDecoder().decode([String: JSONValue].self, from: packet.subdata(in: 13..<13+size))
        #expect(metadata["schema"] == .string("hyperdr.native-model-gain/v1"))
        #expect(metadata["channels"] == .number(1) && metadata["layout"] == .string("HW"))
        #expect(metadata["sampleType"] == .string("float32-le") && metadata["scale"] == .string("signed-log2-gain"))
        #expect(metadata["requestedModelId"] == .string(requested))
        #expect(metadata["effectiveModelId"] == .string("research-cnn-v1"))
        #expect(metadata["effectiveModelId"] != metadata["requestedModelId"])
        let width = Int(try #require(metadata["width"]?.numberValue))
        let height = Int(try #require(metadata["height"]?.numberValue))
        #expect(packet.count == 13 + size + width * height * 4)
        print("K4 real model gain: requested=\(requested), effective=\(metadata["effectiveModelId"]!), HYPGAIN1 bytes=\(packet.count)")
        session.close()
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).isSubset(of: ["no-exif.png", "support", "cache"]))
    }
}
