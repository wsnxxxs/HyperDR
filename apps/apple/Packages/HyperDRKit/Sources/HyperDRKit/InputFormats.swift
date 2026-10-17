import Foundation
import HyperDREngine
import UniformTypeIdentifiers

public enum InputFormat: Sendable, Hashable, Codable {
    case raw(String)
    case jpeg
    case png
    case tiff
    case isobmff(String)

    public var isRaw: Bool {
        if case .raw = self { return true }
        return false
    }

    public var displayLabel: String {
        switch self {
        case .raw: "RAW"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .isobmff(let suffix): suffix == ".avif" ? "AVIF" : "HEIC"
        }
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value.hasPrefix("raw:") { self = .raw(String(value.dropFirst(4))); return }
        if value.hasPrefix("isobmff:") { self = .isobmff(String(value.dropFirst(8))); return }
        switch value {
        case "jpeg": self = .jpeg
        case "png": self = .png
        case "tiff": self = .tiff
        default:
            throw HyperDRError(code: "internal_error", message: "Invalid stored input format: \(value)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .raw(let suffix): try container.encode("raw:" + suffix)
        case .jpeg: try container.encode("jpeg")
        case .png: try container.encode("png")
        case .tiff: try container.encode("tiff")
        case .isobmff(let suffix): try container.encode("isobmff:" + suffix)
        }
    }
}

/// Classification derived from the engine schema's `inputs` section.
public struct InputFormats: Sendable {
    private struct SchemaDocument: Decodable { let inputs: SchemaInputs }

    private struct SchemaInputs: Decodable {
        struct Extensions: Decodable {
            let raw: [String]
            let raster: [String: [String]]
        }
        struct Signature: Decodable {
            let offset: Int
            let magic: String
        }
        let extensions: Extensions
        let canonicalExtensions: [String: String]
        let signatures: [String: [Signature]]
        let prefixBytes: Int?
    }

    private struct ParsedSignature: Sendable {
        let offset: Int
        let magic: [UInt8]
    }

    private static let familyOrder = ["jpeg", "png", "tiff", "isobmff"]

    private let rawExtensions: Set<String>
    private let rasterExtensions: [String: Set<String>]
    private let canonicalExtensions: [String: String]
    private let signatures: [String: [ParsedSignature]]
    public let prefixBytes: Int

    public init(schema: SettingsSchema) throws {
        let decoded: SchemaInputs
        do {
            decoded = try JSONDecoder().decode(SchemaDocument.self, from: schema.rawJSON).inputs
        } catch {
            throw HyperDRError(code: "internal_error", message: "Invalid engine input schema: \(error)")
        }
        rawExtensions = Set(decoded.extensions.raw.map { $0.lowercased() })
        rasterExtensions = decoded.extensions.raster.mapValues { Set($0.map { $0.lowercased() }) }
        canonicalExtensions = decoded.canonicalExtensions.mapValues { $0.lowercased() }
        prefixBytes = decoded.prefixBytes ?? 16
        var parsed: [String: [ParsedSignature]] = [:]
        for (family, entries) in decoded.signatures {
            parsed[family] = try entries.map { entry in
                guard let magic = Self.hexBytes(entry.magic) else {
                    throw HyperDRError(code: "internal_error",
                        message: "Invalid \(family) signature in engine schema")
                }
                return ParsedSignature(offset: entry.offset, magic: magic)
            }
        }
        signatures = parsed
    }

    public var contentTypes: [UTType] {
        let extensions = rawExtensions.union(rasterExtensions.values.flatMap { $0 })
        var seen = Set<String>()
        var types: [UTType] = []
        for suffix in extensions.sorted() {
            guard suffix.hasPrefix("."), let type = UTType(filenameExtension: String(suffix.dropFirst())) else { continue }
            if seen.insert(type.identifier).inserted { types.append(type) }
        }
        return types.sorted { $0.identifier < $1.identifier }
    }

    var resultExtensions: Set<String> {
        [".avif", ".heic", ".jpg", ".jpeg", ".tif", ".tiff"]
    }

    public func classify(_ url: URL) throws -> InputFormat {
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension.lowercased()
        if rawExtensions.contains(suffix) { return .raw(suffix) }
        guard !suffix.isEmpty else {
            throw HyperDRError(code: "unsupported_format", message: "The file has no extension")
        }
        let supportedRaster = rasterExtensions.values.contains { $0.contains(suffix) }
        guard supportedRaster else {
            throw HyperDRError(code: "unsupported_format",
                message: "Unsupported image extension: \(suffix)")
        }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            header = try handle.read(upToCount: prefixBytes) ?? Data()
        } catch {
            throw HyperDRError(code: "source_unreadable",
                message: "Unable to read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        if header.isEmpty {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 {
                throw HyperDRError(code: "file_empty", message: "\(url.lastPathComponent) is empty")
            }
            throw HyperDRError(code: "unsupported_format",
                message: "Unrecognized image content in \(url.lastPathComponent)")
        }
        guard let family = detectFamily(header) else {
            throw HyperDRError(code: "unsupported_format",
                message: "Unrecognized image content in \(url.lastPathComponent)")
        }
        let claimed = extensionFormat(suffix)
        if claimed != family {
            let actual = canonicalExtensions[family] ?? suffix
            throw HyperDRError(code: "input_extension_mismatch",
                message: "File content is \(actual); the extension is \(suffix). Rename it to \(actual).")
        }
        switch family {
        case "jpeg": return .jpeg
        case "png": return .png
        case "tiff": return .tiff
        default: return .isobmff(suffix)
        }
    }

    private func extensionFormat(_ suffix: String) -> String? {
        for (family, extensions) in rasterExtensions where extensions.contains(suffix) { return family }
        return nil
    }

    private func detectFamily(_ header: Data) -> String? {
        for family in Self.familyOrder {
            guard let entries = signatures[family] else { continue }
            for entry in entries {
                let end = entry.offset + entry.magic.count
                guard end <= header.count else { continue }
                let start = header.startIndex + entry.offset
                if header[start..<(start + entry.magic.count)].elementsEqual(entry.magic) { return family }
            }
        }
        return nil
    }

    private static func hexBytes(_ value: String) -> [UInt8]? {
        guard value.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
