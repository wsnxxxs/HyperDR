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
        sessions = SessionStore(configuration: configuration, formats: InputFormats())
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
}
private func lutCode(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch let error as HyperDRError { return error.code }
    catch { Issue.record("Unexpected error: \(error)"); return nil }
}

@Suite(.timeLimit(.minutes(1))) struct LUTLibraryTests {
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
}

extension LUTLibraryTests {

}

@Suite struct LUTCompatibilityTests {
    @Test func onlySLog3InputRequiresRAW() {
        for input in LUTSpace.allCases { for output in LUTSpace.allCases {
            #expect(LUTCompatibility.issue(input: input, output: output, isRAW: true) == nil)
            #expect((LUTCompatibility.issue(input: input, output: output, isRAW: false) == nil)
                    == (input != .slog3SGamut3Cine))
        } }
    }
}
