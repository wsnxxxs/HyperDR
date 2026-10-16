import Foundation
import HyperDREngineCore

public struct HyperDRError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { "\(message) (\(code))" }
}

/// JSON values preserve the schema's mixed default types without C++ interop.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
}

public struct SettingsSchema: Codable, Sendable {
    public struct Setting: Codable, Sendable {
        public let key: String
        public let kind: String
        public let help: String?
        public let choices: [String]?
        public let `default`: JSONValue?
    }
    public let schema: Int
    public let tool: String
    public let settings: [Setting]
    /// The engine's exact UTF-8 stream, including its trailing newline.
    public internal(set) var rawJSON = Data()
    private enum CodingKeys: String, CodingKey { case schema, tool, settings }
}

public enum Engine {
    public static var abiVersion: UInt32 { hyperdr_abi_version() }
    public static var version: String { String(cString: hyperdr_version()) }

    public static func schema() throws -> SettingsSchema {
        let bytes = try jsonResult { hyperdr_schema_json($0, $1) }
        var schema = try JSONDecoder().decode(SettingsSchema.self, from: bytes)
        schema.rawJSON = bytes
        return schema
    }

    public static func curve(settings: [String: JSONValue], samples: Int = 256) throws -> Data {
        guard (2...4096).contains(samples) else {
            throw HyperDRError(code: "invalid_options", message: "Samples must be between 2 and 4096")
        }
        let data = try JSONEncoder().encode(settings)
        return try String(decoding: data, as: UTF8.self).withCString { settings in
            try jsonResult { hyperdr_curve_json(settings, UInt32(samples), $0, $1) }
        }
    }

    private static func jsonResult(_ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                            UnsafeMutablePointer<UnsafeMutablePointer<hyperdr_error>?>) -> Int32) throws -> Data {
        var output: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<hyperdr_error>?
        let status = call(&output, &error)
        defer {
            if let output { hyperdr_string_free(output) }
            if let error { hyperdr_error_free(error) }
        }
        guard status == 0, let output else {
            throw HyperDRError(
                code: error.flatMap { $0.pointee.code }.map { String(cString: $0) } ?? "engine_error",
                message: error.flatMap { $0.pointee.message }.map { String(cString: $0) } ?? "Engine call failed")
        }
        return Data(bytes: output, count: strlen(output))
    }
}
