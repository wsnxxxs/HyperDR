import SwiftUI
import XCTest
import HyperDRKit
@testable import HyperDR

/// What the editor says after launch: the photo came back without its
/// adjustments, or it could not be found (parity batch 7 §2).
@MainActor final class RestoreNoticeTests: XCTestCase {
    private let remembered = URL(fileURLWithPath: "/tmp/DSC04127.jpg")

    private func services(_ result: RestoreResult) -> FakeEditorServices {
        let s = FakeEditorServices(openDelay: .zero)
        s.restoreResult = result
        return s
    }

    func testAReopenedPhotoSaysSoOnceItsFirstFrameAndHistoryAreIn() async throws {
        let s = services(.none)
        s.restoreResult = .restored(s.placeholder(for: remembered))
        let m = EditorModel(services: s)
        m.launch()
        await eventually(timeout: .seconds(10)) { m.restoreNotice != nil }
        XCTAssertEqual(m.restoreNotice, .reopened(hasHistory: false))
        XCTAssertEqual(m.canvasNotice, .restored(hasHistory: false))
        XCTAssertEqual(m.document?.phase, .ready)
    }

    func testTheSentenceMentionsExportHistoryOnlyWhenThereIsSome() async throws {
        let s = services(.none)
        s.restoreResult = .restored(s.placeholder(for: remembered))
        let m = EditorModel(services: s)
        let key = try await s.exportKey(s.placeholder(for: remembered), options: EditOptions(), frame: nil)
        s.historyByURL[remembered] = [ExportHistoryItem(
            version: ExportVersion(number: 1, createdAt: Date(), encodingID: "adaptive",
                                   result: ExportResult(export: "v1", fileName: "a.heic", byteCount: 1, pixelSize: PixelSize(width: 1, height: 1))),
            key: key, options: m.exportChoices)]
        m.launch()
        await eventually(timeout: .seconds(10)) { m.restoreNotice != nil }
        XCTAssertEqual(m.restoreNotice, .reopened(hasHistory: true))
    }

    func testTheFirstEditAndDismissalClearTheNotice() async {
        let s = services(.none)
        s.restoreResult = .restored(s.placeholder(for: remembered))
        let m = EditorModel(services: s)
        m.launch()
        await eventually(timeout: .seconds(10)) { m.restoreNotice != nil }
        m.adjustRecipe("tone.exposure", to: 1.2)
        XCTAssertNil(m.restoreNotice)
        let other = EditorModel(services: s)
        other.launch()
        await eventually(timeout: .seconds(10)) { other.restoreNotice != nil }
        other.dismissRestoreNotice()
        XCTAssertNil(other.restoreNotice); XCTAssertNil(other.canvasNotice)
    }

    func testAnOrdinaryOpenSaysNothing() async {
        let s = services(.none)
        let m = EditorModel(services: s)
        m.open([remembered])
        await eventually(timeout: .seconds(10)) { m.document?.phase == .ready }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(m.restoreNotice)
    }

    func testAMissingPhotoIsExplainedInPlaceNotInADialog() async {
        let s = services(.unavailable(UserFacingError(code: "source_missing"), name: "DSC04127.ARW"))
        let m = EditorModel(services: s)
        m.launch()
        await eventually(timeout: .seconds(10)) { m.restoreNotice != nil }
        XCTAssertEqual(m.restoreNotice, .missing(name: "DSC04127.ARW"))
        XCTAssertNil(m.alert); XCTAssertNil(m.canvasNotice)
        m.open([remembered])
        XCTAssertNil(m.restoreNotice, "opening any photo clears it")
    }

    func testOtherRestoreFailuresKeepTheirAlert() async {
        let s = services(.unavailable(UserFacingError(code: "decode_failed"), name: "a.jpg"))
        let m = EditorModel(services: s)
        m.launch()
        await eventually(timeout: .seconds(10)) { m.alert != nil }
        XCTAssertEqual(m.alert?.code, "decode_failed"); XCTAssertNil(m.restoreNotice)
    }

    func testNoPhotoAndNoNoticeWhenNothingWasRemembered() async {
        let m = EditorModel(services: services(.none))
        m.launch()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(m.restoreNotice); XCTAssertNil(m.alert); XCTAssertNil(m.document)
    }

    func testTheSentencesAndTheirAnnouncements() {
        let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")
        XCTAssertEqual(CanvasNotice.restored(hasHistory: false).title(locale: zh), "已重新打开上次的照片")
        XCTAssertTrue(CanvasNotice.restored(hasHistory: true).body(locale: zh).contains("导出记录"))
        XCTAssertFalse(CanvasNotice.restored(hasHistory: false).body(locale: en).contains("Export History"))
        XCTAssertEqual(CanvasNotice.sourceReplaced(name: "a.jpg").body(locale: zh), "已重新读取“a.jpg”，调整从默认开始。")
        XCTAssertEqual(CanvasNotice.restored(hasHistory: false).announcement(locale: en),
                       "Reopened your last photo. Adjustments aren’t kept between launches, so it starts from the default adjustments.")
    }

    // MARK: The views

    private func mount<V: View>(_ view: V, until condition: () -> Bool) async throws {
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "en")).frame(width: 600, height: 200))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let giveUp = Date().addingTimeInterval(condition() ? 0 : 0.3)
        repeat {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        } while !condition() && Date() < giveUp
    }

    func testTheChipIsAnnouncedOnceAndGoesAwayByItself() async throws {
        let (savedLife, savedDeliver) = (CanvasNoticeTiming.lifetime, NoticeAnnouncement.deliver)
        defer { CanvasNoticeTiming.lifetime = savedLife; NoticeAnnouncement.deliver = savedDeliver }
        CanvasNoticeTiming.lifetime = .milliseconds(150)
        var spoken: [(String, Bool)] = []
        NoticeAnnouncement.deliver = { spoken.append(($0, $1)) }
        var dismissed = 0
        try await mount(CanvasNoticeChip(notice: .restored(hasHistory: false)) { dismissed += 1 }) { dismissed > 0 }
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(spoken.first?.1, false, "a plain announcement")
        XCTAssertTrue(spoken.first?.0.hasPrefix("Reopened your last photo.") == true)
    }

    func testTheMissingPhotoIsAnnouncedOnceByTheModelAndNotAgainWhenTheViewIsRebuilt() async throws {
        let saved = NoticeAnnouncement.deliver
        defer { NoticeAnnouncement.deliver = saved }
        var spoken: [(String, Bool)] = []
        NoticeAnnouncement.deliver = { spoken.append(($0, $1)) }
        let s = services(.unavailable(UserFacingError(code: "source_missing"), name: "DSC04127.ARW"))
        let m = EditorModel(services: s)
        m.launch()
        await eventually { m.restoreNotice != nil }
        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(spoken.first?.1, true)
        XCTAssertEqual(spoken.first?.0, RestoreMissingNotice.announcement(name: "DSC04127.ARW", locale: .current))
        for _ in 0..<2 { try await mount(RestoreMissingNotice(name: "DSC04127.ARW") {}) { false } }
        XCTAssertEqual(spoken.count, 1, "showing the note again says nothing more")
    }

    func testTheMissingNoteWithoutANameIsTheUnnamedSentence() {
        XCTAssertEqual(RestoreMissingNotice.title(name: nil, locale: Locale(identifier: "en")), "Can’t find your last photo")
        XCTAssertEqual(RestoreMissingNotice.title(name: "", locale: Locale(identifier: "en")), "Can’t find your last photo")
    }
}
