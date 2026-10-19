import XCTest
import HyperDRKit
@testable import HyperDR

@MainActor final class SavedLocationTests: XCTestCase {
    private func history(displayName: String?) throws -> ExportHistoryItem {
        var saved: [String: Any] = ["fileName":"photo.tif", "savedAt":0,
            "folderLabel":"…/private-parent/Pictures"]
        if let displayName { saved["folderDisplayName"] = displayName }
        let report = Data("{}".utf8)
        let object: [String: Any] = ["id":String(repeating:"a",count:32),
            "name":"photo.tif", "byteCount":3, "createdAt":0, "sourceDigest":"digest",
            "options":["encoding":"sdr-tiff"], "reportJSON":report.base64EncodedString(),
            "sequence":1, "key":["rawValue":"key"], "saved":saved]
        return ExportHistoryItem(try JSONDecoder().decode(ExportRecord.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }
    func testReopeningHistoryUsesSavedDisplayNameAndNeverTheOldPath() throws {
        let location = try XCTUnwrap(history(displayName:"Display name").version.saved)
        XCTAssertEqual(location.folderLabel,"…/Display name")
        XCTAssertFalse(location.folderLabel.contains("private-parent"))
        XCTAssertFalse(location.canReveal)
    }
    func testMissingOrEmptyDisplayNameUsesLocalizedUnknownPosition() throws {
        for name: String? in [nil, ""] {
            let location = try XCTUnwrap(history(displayName:name).version.saved)
            XCTAssertEqual(location.folderLabel,String(localized:"export.location.unknown"))
            XCTAssertFalse(location.folderLabel.contains("Pictures"))
        }
    }
    func testFreshSaveOffersAnOpaqueRevealActionInsteadOfAURL() {
        var calls = 0
        let location = SavedLocation(fileName:"photo.tif",folderLabel:"…/Display name",reveal:{ calls += 1 })
        XCTAssertTrue(location.canReveal)
        XCTAssertEqual(calls,0)
        location.reveal()
        XCTAssertEqual(calls,1)
    }
}
