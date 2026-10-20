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
