import Foundation
import Testing
@testable import HyperDRKit

struct SavedFolderLabelTests {
    @Test func newSavedMarkRoundTripsOnlyTheDirectoryDisplayName() throws {
        let mark = SavedMark(fileName: "photo.tif", folderDisplayName: "Pictures")
        let data = try JSONEncoder().encode(mark)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["folderDisplayName"] as? String == "Pictures")
        #expect(object["folderLabel"] == nil)
        #expect(object["url"] == nil)
        #expect(try JSONDecoder().decode(SavedMark.self, from: data) == mark)
    }
    @Test func missingNewFieldDoesNotRecoverAnOldPathLabel() throws {
        let data = try JSONSerialization.data(withJSONObject: ["fileName":"photo.tif", "folderLabel":"…/private-parent/Pictures", "savedAt":0])
        let mark = try JSONDecoder().decode(SavedMark.self, from: data)
        #expect(mark.folderDisplayName == nil)
        let encoded = String(decoding: try JSONEncoder().encode(mark), as: UTF8.self)
        #expect(!encoded.contains("private-parent"))
        #expect(!encoded.contains("folderLabel"))
    }
}
