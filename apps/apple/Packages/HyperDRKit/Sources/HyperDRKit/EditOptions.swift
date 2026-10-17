import Foundation
import HyperDREngine

/// The panel's camelCase option vocabulary. Values cross this layer unchanged;
/// the engine's `command.adapter` decides any quantisation.
public struct EditOptions: Sendable, Hashable, Codable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public init(from decoder: any Decoder) throws {
        values = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }
}

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
