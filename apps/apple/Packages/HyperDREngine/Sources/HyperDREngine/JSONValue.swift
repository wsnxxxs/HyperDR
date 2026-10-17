import Foundation

/// JSON values preserve the schema's mixed default types without C++ interop.
public enum JSONValue: Codable, Hashable, Sendable {
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

