import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private func makeFormats() throws -> InputFormats {
    try InputFormats(schema: Engine.schema())
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hyperdr-formats-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

private func write(_ name: String, _ bytes: [UInt8], in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

private func errorCode(_ body: () throws -> Void) -> String? {
    do { try body(); return nil }
    catch let error as HyperDRError { return error.code }
    catch { return "other" }
}

private let jpeg = [UInt8](arrayLiteral: 0xff, 0xd8, 0xff, 0xe0) + [UInt8](repeating: 0x20, count: 64)
private let png = [UInt8](arrayLiteral: 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
    + [UInt8](repeating: 0x20, count: 64)
private let tiff = [UInt8](arrayLiteral: 0x49, 0x49, 0x2a, 0x00) + [UInt8](repeating: 0x20, count: 64)
private let heic = [UInt8](arrayLiteral: 0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
                                  0x68, 0x65, 0x69, 0x63) + [UInt8](repeating: 0x20, count: 64)
private let avif = [UInt8](arrayLiteral: 0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
                                  0x61, 0x76, 0x69, 0x66) + [UInt8](repeating: 0x20, count: 64)

@Suite struct InputFormatsTests {
    @Test func classifiesRawByExtensionAndRasterBySignature() throws {
        let formats = try makeFormats()
        try withTemporaryDirectory { directory in
            let cases: [(String, [UInt8], InputFormat)] = [
                ("photo.jpg", jpeg, .jpeg), ("photo.JPEG", jpeg, .jpeg),
                ("photo.png", png, .png), ("photo.tif", tiff, .tiff),
                ("photo.tiff", tiff, .tiff), ("photo.heic", heic, .isobmff(".heic")),
                ("photo.heif", heic, .isobmff(".heif")), ("photo.hif", heic, .isobmff(".hif")),
                ("photo.avif", avif, .isobmff(".avif")),
                ("capture.arw", tiff, .raw(".arw")),
                ("capture.cr3", heic, .raw(".cr3")),
            ]
            for (name, bytes, expected) in cases {
                let url = try write(name, bytes, in: directory)
                #expect(try formats.classify(url) == expected, "\(name)")
            }
            #expect(formats.prefixBytes == 16)
            #expect(formats.contentTypes.contains { $0.identifier == "public.png" })
            #expect(InputFormat.raw(".arw").isRaw)
            #expect(InputFormat.isobmff(".avif").displayLabel == "AVIF")
            #expect(InputFormat.isobmff(".heif").displayLabel == "HEIC")
        }
    }

    @Test func rejectsMismatchUnknownAndUnreadableInputs() throws {
        let formats = try makeFormats()
        try withTemporaryDirectory { directory in
            let disguised = try write("actually-heic.jpg", heic, in: directory)
            #expect(errorCode { _ = try formats.classify(disguised) } == "input_extension_mismatch")
            do { _ = try formats.classify(disguised) }
            catch let error as HyperDRError { #expect(error.message.contains(".heic")) }

            let unsupported = try write("notes.txt", png, in: directory)
            #expect(errorCode { _ = try formats.classify(unsupported) } == "unsupported_format")

            let unknown = try write("unknown.png", [UInt8](repeating: 0x41, count: 64), in: directory)
            #expect(errorCode { _ = try formats.classify(unknown) } == "unsupported_format")

            let empty = try write("empty.png", [], in: directory)
            #expect(errorCode { _ = try formats.classify(empty) } == "file_empty")

            let missing = directory.appendingPathComponent("missing.png")
            #expect(errorCode { _ = try formats.classify(missing) } == "source_unreadable")
        }
    }
}

extension InputFormatsTests {
    @Test func inputVocabularyUsesEverySchemaRawSuffixAndCanonicalRasterExtension() throws {
        let schema = try Engine.schema()
        let formats = try InputFormats(schema: schema)
        let document = try #require(JSONSerialization.jsonObject(with: schema.rawJSON) as? [String: Any])
        let inputs = try #require(document["inputs"] as? [String: Any])
        let extensions = try #require(inputs["extensions"] as? [String: Any])
        let raw = try #require(extensions["raw"] as? [String])
        let raster = try #require(extensions["raster"] as? [String: [String]])
        let canonical = try #require(inputs["canonicalExtensions"] as? [String: String])
        #expect(!raw.isEmpty)
        #expect(formats.prefixBytes == inputs["prefixBytes"] as? Int)
        #expect(formats.prefixBytes >= 16)
        try withTemporaryDirectory { directory in
            for suffix in raw {
                // RAW suffix takes precedence over TIFF/HEIF container magic.
                let file = try write("capture" + suffix.uppercased(), heic, in: directory)
                #expect(try formats.classify(file) == .raw(suffix.lowercased()))
            }
            for (family, aliases) in raster {
                let suffix = try #require(canonical[family])
                #expect(aliases.contains(suffix))
                let header: [UInt8]
                switch family {
                case "jpeg": header = jpeg
                case "png": header = png
                case "tiff": header = tiff
                default: header = heic
                }
                let file = try write("photo" + suffix, Array(header.prefix(formats.prefixBytes)), in: directory)
                _ = try formats.classify(file)
            }
            let bigEndianTIFF = try write("big-endian.tiff", [0x4d, 0x4d, 0x00, 0x2a] + [UInt8](repeating: 0, count: 12), in: directory)
            #expect(try formats.classify(bigEndianTIFF) == .tiff)
        }
    }
}
