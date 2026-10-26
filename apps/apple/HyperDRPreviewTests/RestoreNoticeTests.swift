import SwiftUI
import XCTest
import HyperDRKit
@testable import HyperDR

/// Launch stays empty even when the session store remembers a photo.
/// Notice views also remain covered independently of launch policy.
@MainActor final class RestoreNoticeTests: XCTestCase {
    private let remembered = URL(fileURLWithPath: "/tmp/DSC04127.jpg")

    private func services(_ result: RestoreResult) -> FakeEditorServices {
        let s = FakeEditorServices(openDelay: .zero)
        s.restoreResult = result
        return s
    }

    func testRememberedPhotoDoesNotOpenOrAnnounceItselfAtLaunch() async {
        let s = services(.none)
        s.restoreResult = .restored(s.placeholder(for: remembered))
        let m = EditorModel(services: s)
        m.launch()
        await settle()
        XCTAssertNil(m.document)
        XCTAssertNil(m.photo)
        XCTAssertNil(m.restoreNotice)
        XCTAssertNil(m.canvasNotice)
        XCTAssertNil(m.alert)
    }

    func testAnOrdinaryOpenSaysNothing() async {
        let s = services(.none)
        let m = EditorModel(services: s)
        m.open([remembered])
        await eventually(timeout: .seconds(10)) { m.document?.phase == .ready }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(m.restoreNotice)
    }

    func testAnUnavailableRememberedPhotoDoesNotInterruptLaunch() async {
        for code in ["source_missing", "session_expired", "decode_failed"] {
            let s = services(.unavailable(UserFacingError(code: code), name: "DSC04127.ARW"))
            let m = EditorModel(services: s)
            m.launch()
            await settle()
            XCTAssertNil(m.document)
            XCTAssertNil(m.restoreNotice)
            XCTAssertNil(m.alert)
        }
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

    func testTheMissingNoteWithoutANameIsTheUnnamedSentence() {
        XCTAssertEqual(RestoreMissingNotice.title(name: nil, locale: Locale(identifier: "en")), "Can’t find your last photo")
        XCTAssertEqual(RestoreMissingNotice.title(name: "", locale: Locale(identifier: "en")), "Can’t find your last photo")
    }
}
