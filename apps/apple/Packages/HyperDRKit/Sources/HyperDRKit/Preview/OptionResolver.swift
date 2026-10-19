import Foundation
import HyperDREngine

/// Shared panel vocabulary for preview and export. K4 resources are resolved
/// only from immutable session copies; private client paths are discarded.
struct OptionResolver: Sendable {

    let schema: SettingsSchema
    let models: ModelCatalog
    let sessionLUTs: SessionLUTResolver?
    let maxEdgeCeiling: Int

    init(schema: SettingsSchema, knownModels: [String: Bool], modelsAvailable: Bool = true,
         maxEdgeCeiling: Int, defaultModelID: String = "research-cnn-v1") {
        self.init(schema: schema, models: ModelCatalog(knownModels: knownModels,
            defaultID: defaultModelID, runtimeAvailable: modelsAvailable), maxEdgeCeiling: maxEdgeCeiling)
    }

    init(schema: SettingsSchema, models: ModelCatalog, maxEdgeCeiling: Int,
         sessionLUTs: SessionLUTResolver? = nil) {
        self.schema = schema; self.models = models
        self.maxEdgeCeiling = maxEdgeCeiling; self.sessionLUTs = sessionLUTs
    }

    func resolve(_ request: PreviewRequest, session: PhotoSession) throws -> EngineRequest {
        try resolve(request, session: session, preview: true)
    }

    func resolveExport(_ options: EditOptions, session: PhotoSession) throws -> EngineRequest {
        try resolve(PreviewRequest(session: session.id, options: options, maxEdge: maxEdgeCeiling), session: session, preview: false)
    }

    /// The request for `PreviewService.modelGain`: the edit with the model
    /// turned on, at the engine's own model decode size (no preview edge).
    func resolveModelGain(_ options: EditOptions, session: PhotoSession) throws -> EngineRequest {
        var values = options.values
        values["useModel"] = .bool(true)
        return try resolve(PreviewRequest(session: session.id, options: EditOptions(values),
            maxEdge: maxEdgeCeiling), session: session, preview: false)
    }

    private func resolve(_ request: PreviewRequest, session: PhotoSession, preview: Bool) throws -> EngineRequest {
        var options = request.options.values
        guard options["frame"] == nil else {
            throw HyperDRError(code: "invalid_options", message: "Frames must be supplied separately")
        }
        if options["external_gain"] != nil || options["external_gain_report"] != nil {
            throw HyperDRError(code: "invalid_options",
                message: "Preview requests cannot supply external gain paths")
        }
        // Private routing keys are server-derived, never client-controlled.
        options = options.filter { !$0.key.hasPrefix("_") }

        let useModel = try boolean(options.removeValue(forKey: "useModel"), name: "useModel", default: false)
        let modelStrength = try modelStrength(options.removeValue(forKey: "modelStrength"))
        let requestedModel = options.removeValue(forKey: "modelId")
        if useModel {
            let id = try models.resolveValue(requestedModel)
            options["_model_mode"] = .bool(true)
            options["_model_id"] = .string(id)
            options["hdrStrength"] = .number(modelStrength)
        }

        if let value = options["lutId"], value != .string(""), value != .null {
            guard case .string(let raw) = value else { throw LUTFiles.invalid("Invalid LUT identifier") }
            _ = try LUTID(rawValue: raw)
            guard let sessionLUTs, let path = try sessionLUTs.resolve(value, session: session.id) else {
                throw LUTFiles.invalid()
            }
            options["_lut_path"] = .string(path.path)
            for key in ["lutInput", "lutOutput"] {
                if let space = options[key] {
                    guard case .string(let name) = space, LUTSpace(rawValue: name) != nil else {
                        throw LUTFiles.invalid("Unknown LUT color space")
                    }
                }
            }
        }
        options.removeValue(forKey: "lutId")
        options.removeValue(forKey: "lutName")
        options.removeValue(forKey: "lensCorrection")

        // Detail requests always render at the ceiling; Python's _preview
        // forces MAX_EDGE for regions regardless of the normal preview tier.
        let edge = request.region == nil
            ? max(320, min(max(320, maxEdgeCeiling), request.maxEdge))
            : max(320, maxEdgeCeiling)
        let normalized = try Engine.normalize(options)
        var resolved = normalized
        if preview { resolved.setSetting("preview_max_edge", .number(Double(edge))) }
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
