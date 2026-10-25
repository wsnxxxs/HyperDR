import Foundation

public struct Capabilities: Codable, Sendable {
    public struct Encoding: Codable, Sendable {
        public let id: String
        public let available: Bool
        public let reason: String
    }
    public struct Encoder: Codable, Sendable {
        public let backend: String
        public let main8, main10: Bool
        public let state: String
        public let reason: String
    }
    public let schema, version, buildFingerprint: String
    public let codecs: Bool
    public let encodings: [Encoding]
    public let encoder: Encoder?
    public let memoryBudgetBytes: UInt64
    /// The limit exports are checked against: the configured budget, or the host's memory less a reserve
    /// when none is configured. Zero means the host could not report it.
    public let effectiveMemoryBudgetBytes: UInt64
    /// LibRaw/DNG converter identity, when the engine reports it (ABI 6+).
    public let rawConverter: String?
    public let heicTileWorkers: Int
    /// Exact UTF-8 returned by the engine, including the trailing newline.
    public internal(set) var rawJSON = Data()
    private enum CodingKeys: String, CodingKey {
        case schema, version, buildFingerprint, codecs, encodings, encoder, memoryBudgetBytes, effectiveMemoryBudgetBytes, heicTileWorkers
        case rawConverter = "raw_converter"
    }
}

public struct SourceColor: Codable, Sendable {
    public let name, primaries, transfer, source: String
}
/// RAW capabilities supplied by the engine, including its cache-key OS build.
public struct RawCapabilities: Codable, Equatable, Sendable {
    public let supported, lensCorrectionSupported: Bool
    public let decoderVersion, osBuild: String

    public init(supported: Bool, lensCorrectionSupported: Bool, decoderVersion: String, osBuild: String) {
        self.supported = supported; self.lensCorrectionSupported = lensCorrectionSupported
        self.decoderVersion = decoderVersion; self.osBuild = osBuild
    }
}
public struct ProbeResult: Codable, Sendable {
    public let schema, path: String
    public let width, height, orientation: Int
    public let inputDomain: String
    public let headroom: Double
    public let raw: RawCapabilities?
    public let degraded: Bool
    public let sourceColor: SourceColor
    public internal(set) var rawJSON = Data()
    private enum CodingKeys: String, CodingKey {
        case schema, path, width, height, orientation, inputDomain, headroom, degraded, sourceColor, raw
    }
}
