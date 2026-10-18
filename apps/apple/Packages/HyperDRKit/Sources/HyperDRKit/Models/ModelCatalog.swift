import Foundation
import HyperDREngine

public struct ModelEntry: Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let available: Bool
    /// Preserve the engine's version, capture requirements and fallback facts.
    public let document: [String: JSONValue]
}
public struct ModelStatus: Sendable, Hashable {
    public let ready: Bool
    public let runtimeAvailable: Bool
}

/// A snapshot of this engine build. Selection never substitutes another model;
/// only inference may report a different effectiveModelId in its own metadata.
public struct ModelCatalog: Sendable {
    public let models: [ModelEntry]
    public let defaultID: String
    public let status: ModelStatus

    public init(capabilities: Capabilities) { self.init(document: capabilities.models) }

    init(document: JSONValue) {
        guard case .object(let root) = document,
              case .array(let entries) = root["models"] else {
            models = []; defaultID = ""; status = ModelStatus(ready: false, runtimeAvailable: false)
            return
        }
        models = entries.compactMap { value in
            guard case .object(let entry) = value,
                  case .string(let id) = entry["id"], !id.isEmpty else { return nil }
            return ModelEntry(id: id, displayName: entry["displayName"]?.stringValue ?? id,
                available: entry["available"] == .bool(true), document: entry)
        }
        let declared = root["defaultModelId"]?.stringValue ?? ""
        defaultID = declared.isEmpty ? models.first?.id ?? "" : declared
        let runtime = root["runtimeAvailable"] == .bool(true) && !models.isEmpty
        status = ModelStatus(ready: runtime && models.contains(where: \.available), runtimeAvailable: runtime)
    }

    init(knownModels: [String: Bool], defaultID: String, runtimeAvailable: Bool) {
        self.init(document: .object([
            "runtimeAvailable": .bool(runtimeAvailable), "defaultModelId": .string(defaultID),
            "models": .array(knownModels.sorted { $0.key < $1.key }.map {
                .object(["id": .string($0.key), "available": .bool($0.value)])
            })
        ]))
    }

    public func resolve(_ requested: String?) throws -> String {
        try resolveValue(requested.map(JSONValue.string))
    }

    func resolveValue(_ requested: JSONValue?) throws -> String {
        guard status.runtimeAvailable else {
            throw HyperDRError(code: "model_not_ready", message: "The native model runtime is not available")
        }
        let id: String
        if requested == nil || requested == .null || requested == .string("") { id = defaultID }
        else if case .string(let value) = requested { id = value }
        else { throw HyperDRError(code: "invalid_options", message: "modelId must be a string") }
        guard let entry = models.first(where: { $0.id == id }) else {
            throw HyperDRError(code: "model_unknown", message: "Unknown model: \(id)")
        }
        guard entry.available else {
            throw HyperDRError(code: "model_not_ready", message: "Model is not available: \(id)")
        }
        return id
    }
}
