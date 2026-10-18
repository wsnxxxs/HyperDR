import Foundation
import HyperDREngine

/// Which parts of a resolved request reach the AI model, and so key its gain
/// cache (batch4 §2.6). Read from the engine, not from the Web's list:
/// `render_model_gain` (modules/app/src/engine_model.cpp) decodes the photo,
/// develops the model base with `render_native_model_base(decoded,
/// clamp_srgb)` and runs `infer_native_model` with the model id and the
/// photo's own capture metadata. Everything else in a request (tone, region,
/// LUT, AI post-adjustments, output format and quality) only acts after the
/// prediction, so changing it reuses the cached gain.
///
/// The photo itself is keyed by the session and its source digest, the
/// engine build by the build fingerprint.
enum ModelGainInputs {
    enum Location: String, Sendable { case settings, command }

    struct Entry: Sendable, Hashable {
        let location: Location
        /// The engine key in the resolved request.
        let key: String
        /// Panel keys that set it.
        let panel: [String]
    }

    static let table: [Entry] = [
        // native_model_request: the selected model.
        Entry(location: .command, key: "model_id", panel: ["modelId"]),
        // Decode: raw.default_gamut, the colour assumed for untagged pixels
        // (decode_cache_variant reads every affects_decoded_pixels setting).
        Entry(location: .settings, key: "color_gamut", panel: ["colorGamut"]),
        // Decode: RAW clipped-highlight handling.
        Entry(location: .settings, key: "highlight_recovery", panel: ["highlightRecovery"]),
        // render_native_model_base. The adapter writes false for SDR
        // encodings, as apply_output_color_options does, so the encoding
        // matters only through this value.
        Entry(location: .settings, key: "clamp_srgb", panel: ["clampSrgb", "encoding"]),
        // Decode size. Kit leaves it out (the engine then uses 2048), so it
        // is constant today; keyed in case a caller ever sets it.
        Entry(location: .settings, key: "preview_max_edge", panel: []),
        // RAW decode resources (raw_decode_resources); Kit rejects these
        // until R1 resolves them from session copies.
        Entry(location: .command, key: "_raw_profile_path", panel: ["rawProfile"]),
        Entry(location: .command, key: "_raw_look_path", panel: ["rawLook"]),
        Entry(location: .command, key: "_lens_profile_path", panel: ["lensProfileName"]),
    ]

    /// The table's values in `request`, as canonical JSON. A missing key is
    /// recorded as null, so "absent" and "set" never collide.
    static func fingerprint(_ request: EngineRequest) throws -> Data {
        var values: [String: JSONValue] = [:]
        for entry in table {
            let source = entry.location == .settings ? request.settings : request.command
            values["\(entry.location.rawValue).\(entry.key)"] = source[entry.key] ?? .null
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(values)
    }
}

/// Identifies one cached model gain: the photo, the engine build and the
/// model inputs. Callers compare keys to learn whether a gain is still valid.
public struct ModelGainKey: Hashable, Sendable {
    let session: SessionID
    let sourceDigest: String
    let buildFingerprint: String
    let inputs: Data

    init(session: PhotoSession, request: EngineRequest, buildFingerprint: String) throws {
        self.session = session.id
        self.sourceDigest = session.sha256
        self.buildFingerprint = buildFingerprint
        do { self.inputs = try ModelGainInputs.fingerprint(request) }
        catch {
            throw HyperDRError(code: "internal_error",
                message: "Unable to encode the model gain inputs: \(error)")
        }
    }
}

/// A computed gain: the engine's `HYPGAIN1` packet.
public struct ModelGainResult: Sendable {
    public let key: ModelGainKey
    public let packet: Data
    public let fromCache: Bool
}
