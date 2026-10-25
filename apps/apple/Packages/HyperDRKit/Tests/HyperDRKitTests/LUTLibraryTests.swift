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
    @Test func aNewLookStartsFromTheSpacesItsNameDeclares() async throws {
        let cases: [(String, LUTSpace, LUTSpace)] = [
            ("SLog3SGamut3.CineToLC-709", .slog3SGamut3Cine, .rec709),
            ("SLog3_SGamut3_to_HLG", .slog3SGamut3, .hlg),
            ("VLog_to_V709_forV35", .vlogVGamut, .rec709),
            ("F-Log2 to WDR BT.709", .flog2FGamut, .rec709),
            ("ARRI_LogC4-to-Gamma24_Rec709-D65", .logC4AWG4, .rec709),
            ("AlexaV3_K1S1_LogC2Video_Rec709_EE", .logC3AWG3, .rec709),
            ("CanonLog3_CinemaGamut_to_BT2100_PQ", .clog3CinemaGamut, .pq),
            ("Rec709 Kodak 2383 D65", .rec709, .rec709),
        ]
        for (name, input, output) in cases {
            let guess = try #require(LUTSpace.guess(fileName: name), "\(name)")
            #expect(guess.input == input && guess.output == output, "\(name)")
        }
        for (name, input) in [("FLog_to_ETERNA_33grid_V.1.00", LUTSpace.flogFGamut),
                              ("FLog2_to_PROVIA_33grid_V.1.00", .flog2FGamut),
                              ("FLog2C_to_ETERNA_33grid_V.1.00", .flog2cFGamutC)] {
            #expect(LUTSpace.guess(fileName: name)?.input == input)
            #expect(LUTSpace.guess(fileName: name)?.output == .rec709)
        }
        #expect(LUTSpace.guess(fileName: "AppleLog_to_Rec2020")?.output == .rec2020)
        #expect(LUTSpace.guess(fileName: "Warm") == nil)
        let env = try LUTEnvironment()
        let entry = try await env.luts.importLUT(env.source("VLog_to_V709.cube"))
        #expect(entry.input == .vlogVGamut && entry.output == .rec709)
        let plain = try await env.luts.importLUT(env.source(data: Data("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n".utf8)))
        #expect(plain.input == .srgb && plain.output == .srgb)
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
        #expect(LUTSpace.allCases.map(\.rawValue).sorted() == ["srgb", "p3", "rec709", "hlg", "pq", "slog3-sgamut3cine", "slog3-sgamut3", "vlog-vgamut", "flog2-fgamut", "logc3-awg3", "logc4-awg4", "clog3-cinemagamut"].sorted())
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

extension LUTLibraryTests {
    @Test func newLogSpacesRoundTripThroughLibraryMetadata() async throws {
        let env = try LUTEnvironment()
        let entry = try await env.luts.importLUT(env.source())
        let updated = try await env.luts.update(entry.id, input: .logC4AWG4, output: .clog3CinemaGamut)
        #expect(updated.input == .logC4AWG4 && updated.output == .clog3CinemaGamut)
        let stored = try #require(await env.luts.entries().first)
        #expect(stored.input == .logC4AWG4 && stored.output == .clog3CinemaGamut)
        let again = try await env.luts.update(entry.id, input: .slog3SGamut3Cine, output: .vlogVGamut)
        #expect(again.input.rawValue == "slog3-sgamut3cine" && again.output.rawValue == "vlog-vgamut")
        for space in [LUTSpace.slog3SGamut3, .flog2FGamut, .logC3AWG3] {
            let data = try JSONEncoder().encode(space)
            #expect(try JSONDecoder().decode(LUTSpace.self, from: data) == space)
            #expect(String(data: data, encoding: .utf8)?.contains(space.rawValue) == true)
        }
        #expect(LUTSpace(rawValue: "slog3-sgamut3cine") == .slog3SGamut3Cine)
    }

    @Test func aByteOrderMarkedCubeKeepsOneIdentityFromLibraryToSession() async throws {
        let env = try LUTEnvironment()
        let marked = Data([0xEF, 0xBB, 0xBF]) + creativeCube
        let entry = try await env.luts.importLUT(env.source("Marked.cube", data: marked))
        let bytes = try await env.luts.cube(entry.id)
        // The editor parses these bytes with `ColorLUT(data:)`, which hashes them as they are.
        #expect(bytes == marked)
        let photo = try await env.photo()
        _ = try await env.luts.apply(entry.id, to: photo.id)
        #expect(try await env.sessions.recipeLUT(entry.contentHash, for: photo.id).contentHash == entry.contentHash)
    }
}
