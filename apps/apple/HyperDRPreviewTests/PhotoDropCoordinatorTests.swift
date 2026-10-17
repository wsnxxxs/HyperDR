import XCTest
@testable import HyperDR

/// Drag sessions on the canvas: a URL check that finishes late must not
/// change the state of a later drag (F2 review, PhotoDrop interleaving).
@MainActor final class PhotoDropCoordinatorTests: XCTestCase {
    private let photo = URL(fileURLWithPath: "/fixtures/B.jpg")
    private let other = URL(fileURLWithPath: "/fixtures/C.ARW")
    private let text = URL(fileURLWithPath: "/fixtures/A.txt")

    /// A drag's URL reading, finished by the test when it chooses.
    @MainActor private final class PendingLoad {
        private var continuation: CheckedContinuation<[URL], Never>?
        private var result: [URL]?

        func load() async -> [URL] {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ urls: [URL]) {
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: urls)
            } else {
                result = urls
            }
        }
    }

    /// Lets tasks resumed by `finish` run to completion.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(30))
    }

    func testLateRejectionFromAnEarlierDragDoesNotRefuseTheCurrentDrag() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        let a = PendingLoad(), b = PendingLoad()

        drop.entered(model: model, load: a.load)   // unsupported A, still reading
        drop.exited()
        drop.entered(model: model, load: b.load)   // valid B
        b.finish([photo])
        try await settle()
        XCTAssertEqual(drop.state, .accepts)

        a.finish([text])                           // A's check completes late
        try await settle()
        XCTAssertEqual(drop.state, .accepts)

        XCTAssertTrue(drop.dropped(model: model, load: { [photo] in [photo] }))
        try await settle()
        XCTAssertEqual(model.document?.name, "B.jpg")
    }

    func testLateCheckFromAnEarlierDragDoesNotOverrideAPendingDrag() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        let a = PendingLoad(), b = PendingLoad()

        drop.entered(model: model, load: a.load)
        drop.exited()
        drop.entered(model: model, load: b.load)
        a.finish([text])                           // A finishes while B is still reading
        try await settle()
        XCTAssertEqual(drop.state, .accepts)
        b.finish([text])
        try await settle()
        XCTAssertEqual(drop.state, .rejects)
    }

    func testCheckFinishingAfterTheDropDoesNotPublish() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        let check = PendingLoad()

        drop.entered(model: model, load: check.load)
        XCTAssertTrue(drop.dropped(model: model, load: { [photo] in [photo] }))
        XCTAssertEqual(drop.state, .idle)
        check.finish([text])
        try await settle()
        XCTAssertEqual(drop.state, .idle)
        XCTAssertEqual(model.document?.name, "B.jpg")
    }

    func testUnsupportedDragIsShownRefusedAndItsDropIsRefused() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()

        drop.entered(model: model, load: { [text] in [text] })
        try await settle()
        XCTAssertEqual(drop.state, .rejects)
        XCTAssertFalse(drop.dropped(model: model, load: { [text] in [text] }))
        XCTAssertEqual(drop.state, .idle)
        try await settle()
        XCTAssertNil(model.document)
        XCTAssertNil(model.alert)
    }

    func testOnlyTheLatestDropOpens() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        let slow = PendingLoad()

        drop.entered(model: model, load: { [other] in [other] })
        XCTAssertTrue(drop.dropped(model: model, load: slow.load))
        drop.entered(model: model, load: { [photo] in [photo] })
        XCTAssertTrue(drop.dropped(model: model, load: { [photo] in [photo] }))
        try await settle()
        XCTAssertEqual(model.document?.name, "B.jpg")

        slow.finish([other])                       // the earlier drop's URLs arrive last
        try await settle()
        XCTAssertEqual(model.document?.name, "B.jpg")
    }

    func testEngineFailureRefusesEveryDrag() async throws {
        let model = EditorModel.preview(.engineFailed)
        let drop = PhotoDropCoordinator()

        drop.entered(model: model, load: { [photo] in [photo] })
        XCTAssertEqual(drop.state, .rejects)
        try await settle()
        XCTAssertEqual(drop.state, .rejects)
        XCTAssertFalse(drop.dropped(model: model, load: { [photo] in [photo] }))
    }
}
