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
        private var continuation: CheckedContinuation<PhotoDropFiles, Never>?
        private var result: PhotoDropFiles?

        func load() async -> PhotoDropFiles {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ urls: [URL]) { finish(PhotoDropFiles(urls: urls)) }

        func finish(_ result: PhotoDropFiles) {
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: result)
            } else {
                self.result = result
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

        XCTAssertTrue(drop.dropped(model: model, load: { [photo] in PhotoDropFiles(urls: [photo]) }))
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
        XCTAssertTrue(drop.dropped(model: model, load: { [photo] in PhotoDropFiles(urls: [photo]) }))
        XCTAssertEqual(drop.state, .idle)
        check.finish([text])
        try await settle()
        XCTAssertEqual(drop.state, .idle)
        XCTAssertEqual(model.document?.name, "B.jpg")
    }

    func testUnsupportedDragIsShownRefusedAndItsDropIsRefused() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()

        drop.entered(model: model, load: { [text] in PhotoDropFiles(urls: [text]) })
        try await settle()
        XCTAssertEqual(drop.state, .rejects)
        XCTAssertFalse(drop.dropped(model: model, load: { [text] in PhotoDropFiles(urls: [text]) }))
        XCTAssertEqual(drop.state, .idle)
        try await settle()
        XCTAssertNil(model.document)
        XCTAssertNil(model.alert)
    }

    func testOnlyTheLatestDropOpens() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        let slow = PendingLoad()

        drop.entered(model: model, load: { [other] in PhotoDropFiles(urls: [other]) })
        XCTAssertTrue(drop.dropped(model: model, load: slow.load))
        drop.entered(model: model, load: { [photo] in PhotoDropFiles(urls: [photo]) })
        XCTAssertTrue(drop.dropped(model: model, load: { [photo] in PhotoDropFiles(urls: [photo]) }))
        try await settle()
        XCTAssertEqual(model.document?.name, "B.jpg")

        slow.finish([other])                       // the earlier drop's URLs arrive last
        try await settle()
        XCTAssertEqual(model.document?.name, "B.jpg")
    }

    /// No URL could be read: the drag is not refused while it is over the
    /// window (nothing is known about the files), and the drop reports the
    /// first error instead of dropping it.
    func testUnreadableDropReportsItsError() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        let unreadable = CocoaError(.fileReadNoPermission)

        drop.entered(model: model, load: { PhotoDropFiles(firstError: unreadable) })
        try await settle()
        XCTAssertEqual(drop.state, .accepts)
        XCTAssertTrue(drop.dropped(model: model, load: { PhotoDropFiles(firstError: unreadable) }))
        try await settle()
        XCTAssertNil(model.document)
        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.code, UserFacingError.importFailure(unreadable)?.code)
    }

    /// One readable URL is enough: the unreadable ones are skipped, and the
    /// first error is kept only when nothing was read.
    func testReadableURLsWinOverUnreadableOnes() async throws {
        let first = CocoaError(.fileReadNoPermission), second = CocoaError(.fileReadUnknown)
        let mixed = PhotoDropDelegate.collect([.failure(first), .success(photo), .failure(second), .success(other)])
        XCTAssertEqual(mixed.urls, [photo, other])
        XCTAssertEqual(mixed.firstError as? CocoaError, first)
        let failed = PhotoDropDelegate.collect([.failure(first), .failure(second)])
        XCTAssertEqual(failed.urls, [])
        XCTAssertEqual(failed.firstError as? CocoaError, first)
        let none = PhotoDropDelegate.collect([])
        XCTAssertEqual(none.urls, [])
        XCTAssertNil(none.firstError)

        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        drop.entered(model: model, load: { mixed })
        try await settle()
        XCTAssertEqual(drop.state, .accepts)
        XCTAssertTrue(drop.dropped(model: model, load: { mixed }))
        try await settle()
        XCTAssertEqual(model.document?.name, "B.jpg")
        XCTAssertNil(model.alert)
    }

    /// An unreadable item beside unsupported ones may be the photograph: the
    /// drag stays accepted and the drop reports the read error (reviewer-sol,
    /// `testReviewFailedProviderAlongsideUnsupportedURL`).
    func testReadErrorBesideUnsupportedFilesIsReported() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        let unreadable = CocoaError(.fileReadNoPermission)
        let files = PhotoDropDelegate.collect([.failure(unreadable), .success(text)])

        drop.entered(model: model, load: { files })
        try await settle()
        XCTAssertEqual(drop.state, .accepts)
        XCTAssertTrue(drop.dropped(model: model, load: { files }))
        try await settle()
        XCTAssertNil(model.document)
        XCTAssertEqual(model.alert?.code, "source_unreadable")
        XCTAssertEqual(model.alert?.code, UserFacingError.importFailure(unreadable)?.code)
    }

    /// Read in full and unsupported: refused, without an alert.
    func testUnsupportedFilesReadInFullAreRefused() async throws {
        let model = EditorModel(services: FakeEditorServices())
        let drop = PhotoDropCoordinator()
        let files = PhotoDropDelegate.collect([.success(text)])

        drop.entered(model: model, load: { files })
        try await settle()
        XCTAssertEqual(drop.state, .rejects)
        XCTAssertFalse(drop.dropped(model: model, load: { files }))
        try await settle()
        XCTAssertNil(model.alert)
    }

    func testEngineFailureRefusesEveryDrag() async throws {
        let model = EditorModel.preview(.engineFailed)
        let drop = PhotoDropCoordinator()

        drop.entered(model: model, load: { [photo] in PhotoDropFiles(urls: [photo]) })
        XCTAssertEqual(drop.state, .rejects)
        try await settle()
        XCTAssertEqual(drop.state, .rejects)
        XCTAssertFalse(drop.dropped(model: model, load: { [photo] in PhotoDropFiles(urls: [photo]) }))
    }
}
