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
}
