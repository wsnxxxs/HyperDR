import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import HyperDREngine
import ImageIO
import Testing
@testable import HyperDRKit

private let creativeCube = Data("LUT_1D_SIZE 2\n0 0 0\n1 .9 .8\n".utf8)
private final class LUTEnvironment: Sendable {
    let root: URL
    let configuration: KitConfiguration
    let sessions: SessionStore
    let luts: LUTLibrary
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-k4-lut-\(UUID())")
        configuration = KitConfiguration(supportDirectory: root.appendingPathComponent("support"), cacheDirectory: root.appendingPathComponent("cache"))
        sessions = SessionStore(configuration: configuration, formats: try InputFormats(schema: Engine.schema()))
        luts = LUTLibrary(configuration: configuration, sessions: sessions)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func source(_ name: String = "Warm.cube", data: Data = creativeCube) throws -> URL {
        let url = root.appendingPathComponent(name); try data.write(to: url); return url
    }
    func photo(_ name: String = "photo.png") async throws -> PhotoSession {
        let url = try source(name, data: Data([137,80,78,71,13,10,26,10] + [UInt8](repeating: 0, count: 64)))
        return try await sessions.open(url)
    }
    var resolver: SessionLUTResolver { SessionLUTResolver(configuration: configuration) }
    func options(_ entry: LUTEntry) -> EditOptions {
        EditOptions(["lutId": .string(entry.id.rawValue), "lutName": .string(entry.name),
            "lutInput": .string(entry.input.rawValue), "lutOutput": .string(entry.output.rawValue), "lutStrength": .number(0.6)])
    }
    func optionResolver() throws -> OptionResolver {
        OptionResolver(schema: try Engine.schema(), models: ModelCatalog(knownModels: [:], defaultID: "", runtimeAvailable: false),
            maxEdgeCeiling: 2048, sessionLUTs: resolver)
    }
}
private func lutCode(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch let error as HyperDRError { return error.code }
    catch { Issue.record("Unexpected error: \(error)"); return nil }
}

@Suite(.timeLimit(.minutes(1))) struct LUTLibraryTests {
    @Test func importIdentityAndSharedPreviewExportFlagsMatchThePanel() async throws {
        let env = try LUTEnvironment()
        let photo = try await env.photo()
        let entry = try await env.luts.importLUT(env.source(), into: photo.id)
        #expect(entry.id.rawValue == SHA256.hash(data: creativeCube).map { String(format: "%02x", $0) }.joined())
        #expect(entry.name == "Warm.cube")
        let resolver = try env.optionResolver()
        var options = env.options(entry); options["encoding"] = .string("sdr-jpeg")
        let exported = try Engine.commandLine(resolver.resolveExport(options, session: photo))
        let preview = try Engine.commandLine(resolver.resolve(PreviewRequest(session: photo.id, options: options, maxEdge: 640), session: photo))
        for flag in ["--lut", "--lut-input", "--lut-output", "--lut-strength", "--encoding"] {
            let exportIndex = try #require(exported.firstIndex(of: flag))
            let previewIndex = try #require(preview.firstIndex(of: flag))
            #expect(exported[exportIndex + 1] == preview[previewIndex + 1])
        }
        let depth = try #require(exported.firstIndex(of: "--depth"))
        #expect(exported[depth + 1] == "8")
        let other = try await env.photo("other.png")
        #expect(await lutCode { _ = try resolver.resolveExport(env.options(entry), session: other) } == "lut_invalid")
    }
    @Test func reusableLooksKeepSpacesAcrossReimportAndHistorySurvivesRemoval() async throws {
        let env = try LUTEnvironment()
        let photo = try await env.photo()
        let entry = try await env.luts.importLUT(env.source(), into: photo.id)
        _ = try await env.luts.update(entry.id, input: .rec709, output: .srgb)
        let reimport = try await env.luts.importLUT(env.source("New-name.cube"))
        #expect(reimport.input == .rec709 && reimport.name == "Warm.cube")
        #expect(await env.luts.entries().count == 1)
        let other = try await env.photo("other.png")
        let applied = try await env.luts.apply(entry.id, to: other.id)
        #expect(applied.input == .rec709)
        let path = try #require(try env.resolver.resolve(.string(entry.id.rawValue), session: other.id))
        #expect(try Data(contentsOf: path) == creativeCube)
        try await env.luts.remove(entry.id)
        #expect(await env.luts.entries().isEmpty)
        for id in [photo.id, other.id] { #expect(try env.resolver.resolve(.string(entry.id.rawValue), session: id) != nil) }
    }
    @Test func librarySurvivesSessionExpiryAndProcessRecreation() async throws {
        let env = try LUTEnvironment()
        let photo = try await env.photo()
        let entry = try await env.luts.importLUT(env.source(), into: photo.id)
        await env.sessions.close(photo.id)
        #expect(await env.sessions.cleanupExpired(now: Date().addingTimeInterval(1_000_000)) == 1)
        #expect(await lutCode { _ = try await env.luts.apply(entry.id, to: photo.id) } == "session_expired")
        let library = LUTLibrary(configuration: env.configuration, sessions: env.sessions)
        #expect(await library.entries().map(\.id) == [entry.id])
        let other = try await env.photo("new-photo.png")
        _ = try await library.apply(entry.id, to: other.id)
        #expect(try env.resolver.resolve(.string(entry.id.rawValue), session: other.id) != nil)
    }
    @Test func IDsRejectPathInjectionUppercaseAndInvalidJSONRepresentations() throws {
        for raw in ["", "../file", String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                    String(repeating: "a", count: 63), String(repeating: "a", count: 65), "../" + String(repeating: "a", count: 61)] {
            #expect(throws: HyperDRError.self) { _ = try LUTID(rawValue: raw) }
            #expect(throws: HyperDRError.self) { _ = try JSONDecoder().decode(LUTID.self, from: JSONEncoder().encode(raw)) }
        }
        #expect(LUTSpace.allCases.map(\.rawValue).sorted() == ["srgb", "p3", "rec709", "hlg", "pq", "slog3-sgamut3cine"].sorted())
        #expect(LUTSpace(rawValue: "linear") == nil)
    }
    @Test func calibrationInvalidUTF8AndWrongExtensionsAreRejected() async throws {
        let env = try LUTEnvironment()
        for (name, bytes) in [("calibration.cube", Data("3 0 .5 1".utf8)), ("empty.cube", Data()),
                              ("bad.txt", creativeCube), ("bad.cube", creativeCube + Data([0xff])),
                              ("title.cube", Data("TITLE \"LUT_1D_SIZE 2\"\n".utf8))] {
            #expect(await lutCode { _ = try await env.luts.importLUT(env.source(name, data: bytes)) } == "lut_invalid")
        }
        #expect(await env.luts.entries().isEmpty)
        let fifo = env.root.appendingPathComponent("pipe.cube")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(await lutCode { _ = try await env.luts.importLUT(fifo) } == "lut_invalid")
    }
    @Test func cubeParserHandlesBOMWhitespaceAndSplitUTF8WithoutBufferingWholeLines() async throws {
        let env = try LUTEnvironment()
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data("  LUT_3D_SIZE 2\n#".utf8)
            + Data(repeating: 32, count: 65516) + Data("字幕\n0 0 0\n".utf8)
        let entry = try await env.luts.importLUT(env.source("Unicode.CUBE", data: bytes))
        #expect(entry.id.rawValue == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    @Test func readStopsAtExactlySixtyFourMegabytesPlusOneAndLeavesNoPartialAsset() async throws {
        let env = try LUTEnvironment()
        let source = try env.source("oversize.cube")
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(LUTFiles.maximumBytes + 2)); try handle.close()
        let input = Darwin.open(source.path, O_RDONLY)
        defer { Darwin.close(input) }
        #expect(await lutCode { _ = try LUTFiles.digest(input) } == "lut_too_large")
        #expect(lseek(input, 0, SEEK_CUR) == LUTFiles.maximumBytes + 1)
        #expect(await lutCode { _ = try await env.luts.importLUT(source) } == "lut_too_large")
        let library = env.configuration.supportDirectory.appendingPathComponent("lut-library")
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
        let exact = try env.source("exact-limit.cube")
        let exactHandle = try FileHandle(forWritingTo: exact)
        try exactHandle.truncate(atOffset: UInt64(LUTFiles.maximumBytes)); try exactHandle.close()
        _ = try await env.luts.importLUT(exact)
        #expect(await env.luts.entries().count == 1)
    }
    @Test func absentSessionCopiesAndSymlinksAreNeverResolvedAsPrivatePaths() async throws {
        let env = try LUTEnvironment()
        let photo = try await env.photo()
        let entry = try await env.luts.importLUT(env.source(), into: photo.id)
        let path = try #require(try env.resolver.resolve(.string(entry.id.rawValue), session: photo.id))
        try FileManager.default.removeItem(at: path)
        let privatePath = try env.source("outside.cube")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: privatePath)
        #expect(await lutCode { _ = try env.resolver.resolve(.string(entry.id.rawValue), session: photo.id) } == "lut_invalid")
        #expect(await lutCode { _ = try await env.luts.apply(entry.id, to: photo.id) } == "lut_invalid")
        #expect(try Data(contentsOf: privatePath) == creativeCube)
    }
    @Test func privateClientPathsAreRemovedAndSpacesAreStrict() async throws {
        let env = try LUTEnvironment()
        let photo = try await env.photo()
        let resolver = try env.optionResolver()
        let noLUT = try resolver.resolveExport(EditOptions(["_lut_path": .string("/private/evil.cube")]), session: photo)
        #expect(noLUT.command["lut"] == nil)
        let entry = try await env.luts.importLUT(env.source(), into: photo.id)
        var options = env.options(entry)
        options["_lut_path"] = .string("/private/evil.cube")
        let request = try resolver.resolveExport(options, session: photo)
        let argv = try Engine.commandLine(request)
        let index = try #require(argv.firstIndex(of: "--lut"))
        #expect(argv[index + 1].hasSuffix("/\(entry.id).cube"))
        options["lutInput"] = .string("unknown")
        let bad = options
        #expect(await lutCode { _ = try resolver.resolveExport(bad, session: photo) } == "lut_invalid")
    }
    @Test func importedLUTReachesTheRealPreviewAndExportAfterLibraryRemoval() async throws {
        let env = try LUTEnvironment()
        let source = env.root.appendingPathComponent("real.png")
        let provider = try #require(CGDataProvider(data: Data(repeating: 128, count: 64 * 48 * 4) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: 64, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let imageFile = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(imageFile, image, nil); try #require(CGImageDestinationFinalize(imageFile))
        let kit = try await HyperDRKit(configuration: env.configuration)
        let photo = try await kit.sessions.open(source)
        let entry = try await kit.luts.importLUT(env.source(), into: photo.id)
        var options = env.options(entry); options["encoding"] = .string("sdr-jpeg")
        let preview = try await kit.previews.render(PreviewRequest(session: photo.id, options: options, maxEdge: 640))
        #expect(preview.frame.metadata.sourceWidth == 64 && preview.frame.metadata.sourceHeight == 48)
        try await kit.luts.remove(entry.id)
        let ticket = try await kit.jobs.start(session: photo.id, options: options)
        let lutIndex = try #require(ticket.argv.firstIndex(of: "--lut"))
        #expect(ticket.argv[lutIndex + 1].hasSuffix("/\(entry.id).cube"))
        for await event in kit.jobs.events(ticket.job) {
            if case .finished(let summary) = event {
                #expect(summary.failure == nil)
                let record = try #require(summary.result)
                #expect(record.byteCount > 0)
            }
        }
        await kit.previews.detach(photo.id); await kit.sessions.close(photo.id)
    }
}

extension LUTLibraryTests {
    @Test func changedSessionBlobCannotRetainTheOldDigestOrCacheIdentity() async throws {
        let env = try LUTEnvironment()
        let photo = try await env.photo()
        let entry = try await env.luts.importLUT(env.source(), into: photo.id)
        let resolver = try env.optionResolver()
        let before = try resolver.resolveExport(env.options(entry), session: photo)
        let path = try #require(try env.resolver.resolve(.string(entry.id.rawValue), session: photo.id))
        let original = try Data(contentsOf: path)
        // A new inode with the same bytes must be rehashed and accepted.
        try original.write(to: path, options: .atomic)
        let identical = try resolver.resolveExport(env.options(entry), session: photo)
        #expect(try PreviewCacheKey(session: photo, request: before, buildFingerprint: "same")
            == PreviewCacheKey(session: photo, request: identical, buildFingerprint: "same"))
        // Identical content after a timestamp-only change is also accepted.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3)], ofItemAtPath: path.path)
        _ = try resolver.resolveExport(env.options(entry), session: photo)
        let changed = Data("LUT_1D_SIZE 2\n1 0 0\n0 1 0\n".utf8)
        try changed.write(to: path, options: .atomic)
        do {
            _ = try resolver.resolveExport(env.options(entry), session: photo)
            Issue.record("Replaced LUT B was accepted under LUT A's digest and cache key")
        } catch let error as HyperDRError { #expect(error.code == "lut_invalid") }
        // Restore valid bytes in place, then exercise a size/mtime change on
        // that same inode. Resolving once must not bless later corruption.
        try original.write(to: path)
        _ = try resolver.resolveExport(env.options(entry), session: photo)
        try (changed + Data("#changed-size\n".utf8)).write(to: path)
        do {
            _ = try resolver.resolveExport(env.options(entry), session: photo)
            Issue.record("In-place LUT mutation kept a verified identity")
        } catch let error as HyperDRError { #expect(error.code == "lut_invalid") }
        await env.sessions.close(photo.id)
    }
}
