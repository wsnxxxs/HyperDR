import Foundation
import Testing
@testable import HyperDRKit

struct ModelFallbackReasonTests {
    @Test func engineFieldIdentifiersBecomeStructuredValues() throws {
        let reason = try #require(ModelFallbackReason(engineReason:
            "missing_capture_fields:iso:exposure_seconds:f_number:exposure_bias_ev:focal_length_mm:focal_length_35mm"))
        #expect(reason.code == .missingCaptureFields)
        #expect(reason.missingCaptureFields == ModelFallbackReason.CaptureField.allCases)
        #expect(ModelFallbackReason(engineReason: "missing_capture_fields:f_number")?.missingCaptureFields == [.fNumber])
    }
    @Test func absentAndUnknownReasonsNeverReturnEngineProse() {
        #expect(ModelFallbackReason(engineReason: nil) == nil)
        #expect(ModelFallbackReason(engineReason: "") == nil)
        #expect(ModelFallbackReason(engineReason: nil, isFallback: true)?.code == .unknown)
        for wire in ["future_reason", "Missing aperture; used the CNN alone", "missing_capture_fields", "missing_capture_fields:", "missing_capture_fields:iso:future_field"] {
            let reason = ModelFallbackReason(engineReason: wire)
            #expect(reason?.code == .unknown)
            #expect(reason?.missingCaptureFields == [])
        }
    }
    @Test func reportUsesSuccessfulFilesAndPreservesUnknownFallbackAsGeneric() throws {
        func record(_ files: [[String: Any]]) throws -> ExportRecord {
            ExportRecord(id: ExportID(rawValue: String(repeating: "a", count: 32)), name: "photo.tif", byteCount: 3,
                createdAt: Date(timeIntervalSince1970: 0), sourceDigest: "fixture", options: [:],
                reportJSON: try JSONSerialization.data(withJSONObject: ["files": files]), sequence: 1,
                key: ExportKey(rawValue: "fixture"), frame: nil)
        }
        let known = try record([["success": false, "model_fallback_reason": "ignore"],
            ["success": true, "model_fallback_reason": "missing_capture_fields:f_number"]])
        #expect(known.modelFallbackReason?.code == .missingCaptureFields)
        #expect(known.modelFallbackReason?.missingCaptureFields == [.fNumber])
        #expect(try record([["success": true, "model_inference_mode": "pixel_only_fallback"]]).modelFallbackReason?.code == .unknown)
        #expect(try record([["success": true]]).modelFallbackReason == nil)
    }
}
