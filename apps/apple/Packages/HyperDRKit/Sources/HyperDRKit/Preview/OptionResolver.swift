import Foundation
import HyperDREngine

/// Translates the panel vocabulary into a canonical engine preview request.
/// Resource-library resolution (LUT/DCP/lens) is intentionally added by K4/K5;
/// until then a non-empty resource selection fails rather than being silently
/// dropped.
struct OptionResolver: Sendable {
    private static let fallbackHighlightChoices = ["blend", "reconstruct", "clip", "unclip"]

    let schema: SettingsSchema
    let knownModels: [String: Bool]
    /// False when the build's model table could not be read at all: every
    /// request is then `model_not_ready` (Python checks the runtime first and
    /// only then looks the id up).
    let modelsAvailable: Bool
    let maxEdgeCeiling: Int
    let defaultModelID: String

    init(schema: SettingsSchema, knownModels: [String: Bool], modelsAvailable: Bool = true,
         maxEdgeCeiling: Int, defaultModelID: String = "research-cnn-v1") {
        self.schema = schema
        self.knownModels = knownModels
        self.modelsAvailable = modelsAvailable
        self.maxEdgeCeiling = maxEdgeCeiling
        self.defaultModelID = defaultModelID
    }

    func resolve(_ request: PreviewRequest, session: PhotoSession) throws -> EngineRequest {
        var options = request.options.values
        if options["external_gain"] != nil || options["external_gain_report"] != nil {
            throw HyperDRError(code: "invalid_options",
                message: "Preview requests cannot supply external gain paths")
        }
        // Private routing keys are server-derived, never client-controlled.
        options = options.filter { !$0.key.hasPrefix("_") }

        let recovery = try highlightRecovery(options.removeValue(forKey: "highlightRecovery"))
        let useModel = try boolean(options.removeValue(forKey: "useModel"), name: "useModel", default: false)
        let modelStrength = try modelStrength(options.removeValue(forKey: "modelStrength"))
        let requestedModel = options.removeValue(forKey: "modelId")
        if useModel {
            guard modelsAvailable else {
                throw HyperDRError(code: "model_not_ready",
                    message: "The native model runtime is not available")
            }
            let id: String
            if let requestedModel {
                guard case .string(let value) = requestedModel else {
                    throw HyperDRError(code: "invalid_options", message: "modelId must be a string")
                }
                // api.py treats an omitted or empty id as the build default;
                // substituting a different explicit id would be wrong.
                id = value.isEmpty ? defaultModelID : value
            } else {
                id = defaultModelID
            }
            guard let available = knownModels[id] else {
                throw HyperDRError(code: "model_unknown", message: "Unknown model: \(id)")
            }
            guard available else {
                throw HyperDRError(code: "model_not_ready", message: "Model is not available: \(id)")
            }
            options["_model_mode"] = .bool(true)
            options["_model_id"] = .string(id)
            options["hdrStrength"] = .number(modelStrength)
        }

        if let value = options["lutId"], value != .string("") {
            throw HyperDRError(code: "invalid_options",
                message: "LUT resolution is not available in this build")
        }
        if let value = options["rawProfile"], value != .string("") {
            throw HyperDRError(code: "invalid_options",
                message: "RAW profile resolution is not available in this build")
        }
        if let value = options["rawLook"], value != .string("") {
            throw HyperDRError(code: "invalid_options",
                message: "RAW look resolution is not available in this build")
        }
        if let value = options["lensProfileName"], value != .string("") {
            throw HyperDRError(code: "invalid_options",
                message: "Lens profile resolution is not available in this build")
        }
        options.removeValue(forKey: "lutId")
        options.removeValue(forKey: "lutName")
        options.removeValue(forKey: "rawProfile")
        options.removeValue(forKey: "rawProfileName")
        options.removeValue(forKey: "rawLook")
        options.removeValue(forKey: "rawLookName")
        options.removeValue(forKey: "lensProfileName")
        options.removeValue(forKey: "lensCorrection")
        options["highlightRecovery"] = .string(recovery)

        // Detail requests always render at the ceiling; Python's _preview
        // forces MAX_EDGE for regions regardless of the normal preview tier.
        let edge = request.region == nil
            ? max(320, min(max(320, maxEdgeCeiling), request.maxEdge))
            : max(320, maxEdgeCeiling)
        let normalized = try Engine.normalize(options)
        var resolved = normalized
        resolved.setSetting("preview_max_edge", .number(Double(edge)))
        try resolved.setCommand("input", .string(session.sourceURL.path))
        try resolved.setCommand("output", .string(""))
        try resolved.setCommand("report", .string(""))
        if let region = request.region {
            guard region.left >= 0, region.top >= 0,
                  (1...2048).contains(region.width), (1...2048).contains(region.height) else {
                throw HyperDRError(code: "invalid_options",
                    message: "Preview region must be positive and at most 2048 pixels per side")
            }
            let object: [String: JSONValue] = [
                "left": .number(Double(region.left)), "top": .number(Double(region.top)),
                "width": .number(Double(region.width)), "height": .number(Double(region.height)),
                "center": .bool(region.center),
            ]
            try resolved.setCommand("region", .object(object))
        }
        return resolved
    }

    private func highlightRecovery(_ value: JSONValue?) throws -> String {
        let choices = schema.settings.first { $0.key == "highlight_recovery" }?.choices
            ?? Self.fallbackHighlightChoices
        guard let value else { return "blend" }
        guard case .string(let recovery) = value else {
            throw HyperDRError(code: "invalid_options",
                message: "Unknown highlight recovery mode")
        }
        // api.py uses `or`, so a restored empty value falls back to blend.
        if recovery.isEmpty { return "blend" }
        guard choices.contains(recovery) else {
            throw HyperDRError(code: "invalid_options",
                message: "Unknown highlight recovery mode")
        }
        return recovery
    }

    private func boolean(_ value: JSONValue?, name: String, default fallback: Bool) throws -> Bool {
        guard let value else { return fallback }
        guard case .bool(let flag) = value else {
            throw HyperDRError(code: "invalid_options", message: "\(name) must be a boolean")
        }
        return flag
    }

    private func modelStrength(_ value: JSONValue?) throws -> Double {
        guard let value else { return 1 }
        guard case .number(let strength) = value, strength.isFinite,
              (0...1).contains(strength) else {
            throw HyperDRError(code: "invalid_options",
                message: "modelStrength must be a number in [0, 1]")
        }
        return strength
    }
}
