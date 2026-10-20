import Foundation
import HyperDREngine
import HyperDRKit
import XCTest
@testable import HyperDR

@MainActor final class ExportReasonTests: XCTestCase {
    func testDestinationVariantComesOnlyFromStructuredSaveMode() {
        let chosen = UserFacingError(HyperDRError(code: "export_folder_unwritable", message: "opaque",
            detail: .object(["save_mode": .string("destination")]), messageDetail: "failure detail"))
        XCTAssertEqual(chosen.variant, "destination")
        XCTAssertEqual(chosen.detail, "failure detail")
        XCTAssertEqual(chosen.messageVariantKey, "err.server.export_folder_unwritable.destination")
        let folder = UserFacingError(HyperDRError(code: "export_folder_unwritable", message: "destination"))
        XCTAssertNil(folder.variant); XCTAssertNil(folder.messageVariantKey)
        let unknown = UserFacingError(HyperDRError(code: "export_folder_unwritable", message: "opaque",
            detail: .object(["save_mode": .string("future")])) )
        XCTAssertNil(unknown.variant)
    }

    func testHistoryCarriesOnlyReasonCodeAndFields() throws {
        func history(_ wire: String) throws -> ExportHistoryItem {
            let report = try JSONSerialization.data(withJSONObject: ["files": [["success": true,
                "input": "photo.jpg", "model_fallback_reason": wire, "model_inference_mode": "pixel_only_fallback"]]])
            let json = try JSONSerialization.data(withJSONObject: ["id": String(repeating: "a", count: 32),
                "name": "photo.tif", "byteCount": 3, "createdAt": 0, "sourceDigest": "fixture", "options": [:],
                "reportJSON": report.base64EncodedString(), "sequence": 1, "key": ["rawValue": "fixture"]])
            return ExportHistoryItem(try JSONDecoder().decode(ExportRecord.self, from: json))
        }
        let known = try history("missing_capture_fields:iso:f_number").version.fallbackReason
        XCTAssertEqual(known?.code, .missingCaptureFields)
        XCTAssertEqual(known?.missingCaptureFields, ["iso", "f_number"])
        let unknown = try history("Missing aperture; used the CNN alone").version.fallbackReason
        XCTAssertEqual(unknown?.code, .unknown); XCTAssertEqual(unknown?.missingCaptureFields, [])
    }
}
