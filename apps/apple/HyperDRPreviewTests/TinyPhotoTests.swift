import XCTest
import HyperDREngine
@testable import HyperDR

/// The generated test photo leaves nothing behind (R6-TINY-1).
final class TinyPhotoTests: XCTestCase {
    func testAPhotoIsPrivateAndItsDirectoryGoesWithIt() throws {
        let before = TinyPhoto.leftovers()
        let first = try TinyPhoto(), second = try TinyPhoto()
        XCTAssertNotEqual(first.url.deletingLastPathComponent(), second.url.deletingLastPathComponent(), "never shared")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        first.remove(); first.remove(); second.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.deletingLastPathComponent().path))
        XCTAssertEqual(TinyPhoto.leftovers(), before)
    }

    /// The photo is removed when the test throws, too.
    func testAThrowingUserStillCleansUp() {
        let before = TinyPhoto.leftovers()
        struct Boom: Error {}
        func use() throws { let photo = try TinyPhoto(); defer { photo.remove() }; throw Boom() }
        XCTAssertThrowsError(try use())
        XCTAssertEqual(TinyPhoto.leftovers(), before)
    }

    func testTheEnginePathLeavesNothingBehind() async throws {
        let before = TinyPhoto.leftovers()
        let photo = try TinyPhoto()
        _ = try await Engine().probe(photo.url)
        photo.remove()
        XCTAssertEqual(TinyPhoto.leftovers(), before)
    }
}
