import SwiftUI
import Testing
@testable import HyperDRDesign

@MainActor struct LUTLibraryRowTests {
    @Test func theSizeIsOnePieceSoItNeverWrapsAlone() {
        #expect(LUTLibraryRow.unbreakable("38 kB") == "38\u{00A0}kB")
        #expect(LUTLibraryRow.unbreakable("1.2 MB") == "1.2\u{00A0}MB")
        #expect(LUTLibraryRow.unbreakable("940 kB") != "940 kB")
    }
}
