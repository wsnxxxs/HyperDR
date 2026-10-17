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
        public let reason: String?
    }
    public let schema, version, buildFingerprint: String
    public let codecs: Bool
    /// Model documents retain the native model-list schema without losing keys.
    public let models: JSONValue
    public let encodings: [Encoding]
    public let encoder: Encoder?
    public let memoryBudgetBytes: UInt64
    public let heicTileWorkers: Int
    /// Exact UTF-8 returned by the engine, including the trailing newline.
    public internal(set) var rawJSON = Data()
    private enum CodingKeys: String, CodingKey {
        case schema, version, buildFingerprint, codecs, models, encodings, encoder, memoryBudgetBytes, heicTileWorkers
    }
}

public struct SourceColor: Codable, Sendable {
    public let name, primaries, transfer, source: String
}
public struct ProbeResult: Codable, Sendable {
    public let schema, path: String
    public let width, height, orientation: Int
    public let inputDomain: String
    public let headroom: Double
    public let degraded: Bool
    public let sourceColor: SourceColor
    public internal(set) var rawJSON = Data()
    private enum CodingKeys: String, CodingKey {
        case schema, path, width, height, orientation, inputDomain, headroom, degraded, sourceColor
    }
}
public struct RawMetadata: Codable, Sendable {
    public let make, model, lens: String
    public let focalLength, aperture: Double
    public internal(set) var rawJSON = Data()
    private enum CodingKeys: String, CodingKey { case make, model, lens, focalLength, aperture }
}
public struct ConvertEvent: Codable, Sendable {
    public let phase, path: String
    public let fraction: Double
    public let text: String
}
public struct ReportFile: Codable, Sendable {
    public let input, output: String
    public let success, skipped: Bool
    public let message: String
    public let width, height: Int?
    /// Present for a framed export: `width`/`height` are then the canvas.
    public let frame: ReportFrame?

    public init(input: String, output: String, success: Bool, skipped: Bool,
                message: String, width: Int?, height: Int?, frame: ReportFrame? = nil) {
        self.input = input
        self.output = output
        self.success = success
        self.skipped = skipped
        self.message = message
        self.width = width
        self.height = height
        self.frame = frame
    }
}
public struct ConvertReport: Sendable {
    public let json: Data
    public let files: [ReportFile]

    public init(json: Data, files: [ReportFile]) {
        self.json = json
        self.files = files
    }
}
struct ReportDocument: Decodable { let files: [ReportFile] }
