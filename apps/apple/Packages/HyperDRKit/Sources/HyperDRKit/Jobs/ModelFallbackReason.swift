import Foundation

/// Machine reasons from the engine's model packet/report, never localized prose.
public struct ModelFallbackReason: Equatable, Sendable {
    public enum Code: String, Sendable { case missingCaptureFields, unknown }
    public enum CaptureField: String, CaseIterable, Sendable {
        case iso
        case exposureSeconds = "exposure_seconds"
        case fNumber = "f_number"
        case exposureBiasEV = "exposure_bias_ev"
        case focalLengthMM = "focal_length_mm"
        case focalLength35MM = "focal_length_35mm"
    }
    public let code: Code
    public let missingCaptureFields: [CaptureField]

    /// ncnn_runtime.cpp emits missing_capture_fields:<field>:<field>.
    /// Unknown/malformed reasons carry no raw text into the presentation API.
    public init?(engineReason: String?, isFallback: Bool = false) {
        guard let engineReason, !engineReason.isEmpty else {
            guard isFallback else { return nil }
            code = .unknown; missingCaptureFields = []; return
        }
        let tokens = engineReason.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let fields = tokens.dropFirst().compactMap(CaptureField.init(rawValue:))
        if tokens.first == "missing_capture_fields", !fields.isEmpty, fields.count == tokens.count - 1 {
            code = .missingCaptureFields; missingCaptureFields = fields
        } else { code = .unknown; missingCaptureFields = [] }
    }
}

extension ExportRecord {
    public var modelFallbackReason: ModelFallbackReason? {
        guard let report = (try? JSONSerialization.jsonObject(with: reportJSON)) as? [String: Any],
              let files = report["files"] as? [[String: Any]],
              let file = files.first(where: { $0["success"] as? Bool == true }) else { return nil }
        return ModelFallbackReason(engineReason: file["model_fallback_reason"] as? String,
            isFallback: file["model_inference_mode"] as? String == "pixel_only_fallback")
    }
}
