import Foundation

/// Canonical settings at the top level, with an optional `command` object.
/// `normalize` adds `command.adapter = "panel-v1"`; preserve it verbatim.
/// Only panel-v1 requests use the Python panel's three-decimal quantization.
/// Untagged canonical requests keep full precision; unknown adapters are rejected
/// by the engine. Normalize and consume with the same library version.
public struct EngineRequest: Sendable, Hashable, Codable {
    public private(set) var settings: [String: JSONValue]
    public private(set) var command: [String: JSONValue]

    /// Creates a canonical request, without panel precision adaptation.
    public init(settings: [String: JSONValue]) {
        self.settings = settings.filter { $0.key != "command" }
        self.command = [:]
    }
    public mutating func setSetting(_ key: String, _ value: JSONValue) {
        // `command` is reserved; use setCommand to preserve adapter provenance.
        guard key != "command" else { return }
        settings[key] = value
    }
    public mutating func setCommand(_ key: String, _ value: JSONValue?) throws {
        guard key != "adapter" else {
            throw HyperDRError(code: "invalid_options", message: "command.adapter cannot be modified")
        }
        command[key] = value
    }
    public var adapter: String? {
        if case .string(let value) = command["adapter"] { return value }
        return nil
    }
    public init(from decoder: any Decoder) throws {
        var object = try [String: JSONValue](from: decoder)
        if let value = object.removeValue(forKey: "command") {
            guard case .object(let command) = value else {
                throw HyperDRError(code: "invalid_options", message: "command must be an object")
            }
            self.command = command
        } else { command = [:] }
        settings = object
    }
    public func encode(to encoder: any Encoder) throws {
        var object = settings
        if !command.isEmpty { object["command"] = .object(command) }
        try object.encode(to: encoder)
    }
}
