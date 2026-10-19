import AppKit
import SwiftUI
import XCTest
import HyperDRDesign
@testable import HyperDR

/// The canvas's view-layer rules: when the divider and legend show, how a
/// hint is announced and counted, press-and-hold, the zoom-in key and the
/// undo commands.
@MainActor final class CanvasWiringTests: XCTestCase {
    // MARK: Divider and legend

    func testDividerShowsOnlyInCompareWithBothFramesAndNoHold() {
        func shows(_ mode: ViewMode = .compare, peeking: Bool = false, reference: Bool = true, edited: Bool = true) -> Bool {
            CanvasAdornments.showsSplit(viewMode: mode, isPeeking: peeking, hasReference: reference, hasEdited: edited)
        }
        XCTAssertTrue(shows())
        XCTAssertFalse(shows(.edited))
        XCTAssertFalse(shows(peeking: true))
        XCTAssertFalse(shows(reference: false))
        XCTAssertFalse(shows(edited: false))
    }

    func testLegendNamesTheMaskAndShowsZebrasOnlyWithoutTheInspector() {
        func rows(mask: String? = nil, hot: Bool = false, cold: Bool = false, inspector: Bool = true,
                  mode: ViewMode = .edited, peeking: Bool = false) -> Int {
            CanvasAdornments.legendRows(maskLabelKey: mask, highlightZebra: hot, shadowZebra: cold,
                                        showsInspector: inspector, viewMode: mode, isPeeking: peeking).count
        }
        XCTAssertEqual(rows(mask: "ctrl.hdrStrength.label"), 1)
        XCTAssertEqual(rows(hot: true, cold: true), 0, "the inspector's own switches are the legend")
        XCTAssertEqual(rows(hot: true, cold: true, inspector: false), 2)
        XCTAssertEqual(rows(mask: "ctrl.hdrStrength.label", hot: true, inspector: false), 2)
        XCTAssertEqual(rows(mask: "ctrl.hdrStrength.label", mode: .original), 0)
        XCTAssertEqual(rows(mask: "ctrl.hdrStrength.label", peeking: true), 0)
        XCTAssertEqual(rows(mask: "ctrl.hdrStrength.label", mode: .compare), 1)
    }

    // MARK: Hints

    func testAHintIsShownTwicePerKeyInARun() {
        let session = ViewerSessionState()
        let hint = CanvasHintState()
        hint.update(key: "canvas.hint.peek", session: session)
        XCTAssertEqual(hint.shown, "canvas.hint.peek")
        hint.reset()
        hint.update(key: "canvas.hint.peek", session: session)
        XCTAssertEqual(hint.shown, "canvas.hint.peek")
        hint.reset()
        hint.update(key: "canvas.hint.peek", session: session)
        XCTAssertNil(hint.shown, "a third showing is over the limit")
        XCTAssertEqual(session.hintCount("canvas.hint.peek"), 2)
        // Another key has its own count.
        hint.update(key: "canvas.hint.pan", session: session)
        XCTAssertEqual(hint.shown, "canvas.hint.pan")
    }

    func testHoldingTheOriginalDoesNotUseUpTheHintOrBringItBack() {
        let session = ViewerSessionState()
        let hint = CanvasHintState()
        hint.update(key: "canvas.hint.peek", session: session)
        hint.dismiss()
        hint.update(key: "canvas.peeking", session: session)
        XCTAssertNil(hint.shown)
        hint.update(key: "canvas.hint.peek", session: session)
        XCTAssertNil(hint.shown, "the same hint after a hold is not announced again")
        XCTAssertEqual(session.hintCount("canvas.hint.peek"), 1)
        XCTAssertEqual(session.hintCount("canvas.peeking"), 0, "the label is not a hint")
    }

    func testLosingTheKeyAndGettingItBackAnnouncesAgain() {
        let session = ViewerSessionState()
        let hint = CanvasHintState()
        hint.update(key: "canvas.hint.peek", session: session)
        hint.update(key: nil, session: session)
        XCTAssertNil(hint.shown)
        hint.update(key: "canvas.hint.split", session: session)
        XCTAssertEqual(hint.shown, "canvas.hint.split")
        hint.dismiss()
        XCTAssertNil(hint.shown)
    }

    // MARK: Press and hold

    private func waitForHold(_ hold: PressAndHold, _ expected: Bool) async {
        await eventually(timeout: .seconds(2), "hold \(expected)") { hold.isHolding == expected }
    }

    func testAPressThatLastsBeginsAHoldAndReleasingEndsIt() async {
        var events: [String] = []
        let hold = PressAndHold(delay: .milliseconds(20), begin: { events.append("begin") }, end: { events.append("end") })
        hold.press(at: CGPoint(x: 10, y: 10))
        hold.drag(to: CGPoint(x: 12, y: 11))   // within 4 pt
        await waitForHold(hold, true)
        hold.drag(to: CGPoint(x: 200, y: 200)) // moving later does not end it
        XCTAssertTrue(hold.isHolding)
        hold.release()
        XCTAssertEqual(events, ["begin", "end"])
        XCTAssertFalse(hold.isHolding)
    }

    func testAPressThatMovesMoreThanFourPointsIsAPanAndNeverHolds() async {
        var events: [String] = []
        let hold = PressAndHold(delay: .milliseconds(30), begin: { events.append("begin") }, end: { events.append("end") })
        hold.press(at: .zero)
        hold.drag(to: CGPoint(x: 3, y: 3.5))   // 4.6 pt away
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(hold.isHolding)
        hold.release()
        XCTAssertEqual(events, [])
    }

    func testAQuickClickNeverHolds() async {
        var began = false
        let hold = PressAndHold(delay: .milliseconds(40), begin: { began = true }, end: {})
        hold.press(at: .zero)
        hold.release()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(began)
    }

    func testTheDefaultDelayIs240Milliseconds() {
        XCTAssertEqual(PressAndHold.delay, .milliseconds(240))
        XCTAssertEqual(PressAndHold.tolerance, 4)
    }

    // MARK: ⌘= (M2-Q)

    private func keyEvent(_ characters: String, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: 24)!
    }

    private func canvas(withPhoto: Bool = true) -> CanvasModel {
        let canvas = CanvasModel()
        if withPhoto {
            canvas.setViewport(CGSize(width: 900, height: 600), backingScale: 2)
            canvas.setImageSize(PixelSize(width: 6000, height: 4000))
        }
        return canvas
    }

    private func context(key: Bool = true, sheet: Bool = false, modal: Bool = false,
                         responder: NSResponder? = nil, menu: NSMenu? = nil) -> ZoomKeyRule.Context {
        ZoomKeyRule.Context(isKeyWindow: key, hasAttachedSheet: sheet, hasModalWindow: modal,
                            firstResponder: responder, mainMenu: menu)
    }

    func testCommandEqualsZoomsInOnce() {
        let canvas = canvas()
        XCTAssertEqual(canvas.zoom, .fit)
        XCTAssertTrue(ZoomKeyRule.handle(keyEvent("=", flags: .command), context: context(), canvas: canvas))
        XCTAssertNotEqual(canvas.zoom, .fit)
    }

    func testOtherModifierCombinationsPassThrough() {
        for flags: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control],
                                              [], [.shift], [.command, .option, .shift]] {
            let canvas = canvas()
            XCTAssertFalse(ZoomKeyRule.handle(keyEvent("=", flags: flags), context: context(), canvas: canvas),
                           "\(flags)")
            XCTAssertEqual(canvas.zoom, .fit)
        }
        XCTAssertFalse(ZoomKeyRule.handle(keyEvent("-", flags: .command), context: context(), canvas: canvas()))
    }

    func testTextFocusSheetsAndModalsAndAnInactiveWindowPassThrough() {
        let field = NSTextField()
        let textView = NSTextView()
        for context in [context(responder: field), context(responder: textView), context(sheet: true),
                        context(modal: true), context(key: false)] {
            let canvas = canvas()
            XCTAssertFalse(ZoomKeyRule.handle(keyEvent("=", flags: .command), context: context, canvas: canvas))
            XCTAssertEqual(canvas.zoom, .fit)
        }
        // Another kind of first responder is fine.
        XCTAssertTrue(ZoomKeyRule.handle(keyEvent("=", flags: .command), context: context(responder: NSView()),
                                         canvas: canvas()))
    }

    func testWithoutAPhotoOrRoomToZoomTheKeyPassesThrough() {
        XCTAssertFalse(ZoomKeyRule.handle(keyEvent("=", flags: .command), context: context(),
                                          canvas: canvas(withPhoto: false)))
        let canvas = canvas()
        while canvas.canZoomIn { canvas.zoomIn() }
        XCTAssertFalse(ZoomKeyRule.handle(keyEvent("=", flags: .command), context: context(), canvas: canvas))
    }

    func testAMenuItemWithTheSameKeyIsLeftToTheMenu() {
        let menu = NSMenu()
        let top = NSMenuItem()
        let sub = NSMenu()
        let item = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "=")
        item.keyEquivalentModifierMask = .command
        sub.addItem(item)
        top.submenu = sub
        menu.addItem(top)
        let canvas = canvas()
        XCTAssertFalse(ZoomKeyRule.handle(keyEvent("=", flags: .command), context: context(menu: menu), canvas: canvas))
        XCTAssertEqual(canvas.zoom, .fit)
        item.isEnabled = false
        XCTAssertTrue(ZoomKeyRule.handle(keyEvent("=", flags: .command), context: context(menu: menu), canvas: canvas),
                      "a disabled item claims nothing")
        // The menu's own Zoom In is ⌘+ (⇧⌘=), which is not this key.
        let plus = NSMenuItem(title: "Zoom In", action: nil, keyEquivalent: "+")
        plus.keyEquivalentModifierMask = .command
        XCTAssertFalse(ZoomKeyRule.menuClaims(keyEvent("=", flags: .command), in: { let m = NSMenu(); m.addItem(plus); return m }()))
    }

    // MARK: Undo routing

    func testUndoGoesToTheTextHistoryForTextAndToTheEditorOtherwise() {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(1))
        let model = EditorModel(services: services)
        let editorOnly = NSView()
        XCTAssertFalse(UndoRouting.canUndo(model: model, responder: editorOnly))
        XCTAssertTrue(UndoRouting.manager(model: model, responder: editorOnly) === model.undoManager)
        let text = NSTextView()
        XCTAssertFalse(UndoRouting.manager(model: model, responder: text) === model.undoManager)
        XCTAssertNil(UndoRouting.manager(model: nil, responder: editorOnly))
        XCTAssertFalse(UndoRouting.canUndo(model: nil, responder: editorOnly))
        XCTAssertEqual(UndoRouting.undoTitle(model: nil, responder: editorOnly), UndoManager().undoMenuItemTitle)
    }

    func testTheMenuTitleNamesTheEditorStep() async {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(1))
        let model = EditorModel(services: services)
        model.open([URL(fileURLWithPath: "/fixtures/a.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        model.adjust("brightness", to: 0.9)
        let title = UndoRouting.undoTitle(model: model, responder: NSView())
        XCTAssertTrue(title.contains(EditorModel.undoActionName("brightness")), title)
        XCTAssertTrue(UndoRouting.canUndo(model: model, responder: NSView()))
        UndoRouting.undo(model: model, responder: NSView())
        XCTAssertTrue(UndoRouting.canRedo(model: model, responder: NSView()))
        // Text keeps its own history: the editor's is not touched.
        let before = model.control("brightness").value
        UndoRouting.redo(model: model, responder: NSTextView())
        XCTAssertEqual(model.control("brightness").value, before)
    }

    func testEmptyTextHistoryDisablesUndoInsteadOfFallingBackToThePhoto() async {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(1))
        let model = EditorModel(services: services)
        model.open([URL(fileURLWithPath: "/fixtures/a.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        model.adjust("brightness", to: 0.9)
        let edited = model.control("brightness").value
        XCTAssertTrue(model.canUndo)

        // A text view with nothing to undo: the commands are off, they do not
        // reach the photo's history, and they name the text's own (empty) one.
        let text = NSTextView()
        XCTAssertFalse(UndoRouting.canUndo(model: model, responder: text))
        XCTAssertFalse(UndoRouting.canRedo(model: model, responder: text))
        UndoRouting.undo(model: model, responder: text)
        XCTAssertEqual(model.control("brightness").value, edited)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(UndoRouting.undoTitle(model: model, responder: text).contains(EditorModel.undoActionName("brightness")))

        // A text field's own history, once it has a step, is what is enabled.
        let history = UndoManager()
        var typed = "a"
        history.registerUndo(withTarget: history) { _ in typed = "" }
        history.setActionName("Typing")
        final class Field: NSTextField {
            var manager: UndoManager?
            override var undoManager: UndoManager? { manager }
        }
        let field = Field()
        field.manager = history
        XCTAssertTrue(UndoRouting.canUndo(model: model, responder: field))
        XCTAssertEqual(UndoRouting.undoTitle(model: model, responder: field), history.undoMenuItemTitle)
        UndoRouting.undo(model: model, responder: field)
        XCTAssertEqual(typed, "")
        XCTAssertEqual(model.control("brightness").value, edited)
    }

    func testMenuStateBumpsWhenAnUndoGroupCloses() {
        let state = UndoMenuState()
        let center = NotificationCenter()
        state.install(center: center)
        let start = state.revision
        center.post(name: .NSUndoManagerDidCloseUndoGroup, object: nil)
        let expectation = expectation(description: "bumped")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertGreaterThan(state.revision, start)
    }

    // MARK: Badge

    func testCompareHasNoBadgeOfItsOwnAndTheLabelSharesTheHDRRule() {
        XCTAssertNil(PhotoBadgeKind(viewMode: .compare, originalAvailable: true, domain: .hdr, gainWeight: 1))
        XCTAssertTrue(PhotoBadgeKind.hasHDR(domain: .hdr, gainWeight: nil))
        XCTAssertTrue(PhotoBadgeKind.hasHDR(domain: .sdr, gainWeight: 0))
        XCTAssertFalse(PhotoBadgeKind.hasHDR(domain: .sdr, gainWeight: nil))
    }

    // MARK: Open commands

    func testTheOpenCommandsFollowTheModelsOpenGate() async {
        let services = FakeEditorServices(openDelay: .seconds(10))
        let model = EditorModel(services: services)
        XCTAssertTrue(model.allowsOpenCommand, "nothing open: Open… is available")
        model.open([URL(fileURLWithPath: "/fixtures/loading.jpg")])
        XCTAssertFalse(model.canOpenDocument)
        XCTAssertFalse(model.allowsOpenCommand, "opening: the menu and toolbar commands are off")
        // The programmatic route (Finder, drop) is not gated by the command rule (Q14).
        model.open([URL(fileURLWithPath: "/fixtures/other.jpg")])
        XCTAssertNotNil(model.document)
        model.closeDocument()
    }

    func testOpenCommandsAreOnOnceThePhotoIsReady() async {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(1))
        let model = EditorModel(services: services)
        model.open([URL(fileURLWithPath: "/fixtures/a.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        XCTAssertTrue(model.allowsOpenCommand)
        model.closeDocument()
    }

    // MARK: Holds from more than one source (M2-V review P3)

    func testReleasingSpaceWhileThePointerStillHoldsKeepsTheOriginal() {
        var events: [String] = []
        let peek = PeekHolds(begin: { events.append("begin") }, end: { events.append("end") })
        peek.hold(.pointer)
        peek.hold(.key)
        peek.release(.key)
        XCTAssertTrue(peek.isHeld)
        XCTAssertEqual(events, ["begin"], "the pointer still holds the original")
        peek.release(.pointer)
        XCTAssertEqual(events, ["begin", "end"])
    }

    func testReleasingThePointerWhileSpaceIsStillHeldKeepsTheOriginal() {
        var events: [String] = []
        let peek = PeekHolds(begin: { events.append("begin") }, end: { events.append("end") })
        peek.hold(.key)
        peek.hold(.pointer)
        peek.hold(.key)             // auto-repeat
        peek.release(.pointer)
        XCTAssertEqual(events, ["begin"])
        peek.release(.key)
        XCTAssertEqual(events, ["begin", "end"])
    }

    func testEscReleasesEverySourceAndALateMouseUpIsHarmless() {
        var events: [String] = []
        let peek = PeekHolds(begin: { events.append("begin") }, end: { events.append("end") })
        peek.hold(.pointer)
        peek.hold(.key)
        peek.releaseAll()
        peek.release(.pointer)      // the mouse goes up after Esc
        peek.release(.key)
        peek.releaseAll()
        XCTAssertEqual(events, ["begin", "end"])
        XCTAssertFalse(peek.isHeld)
    }

    func testAHoldAfterEscBeginsAgain() {
        var events: [String] = []
        let peek = PeekHolds(begin: { events.append("begin") }, end: { events.append("end") })
        peek.hold(.pointer)
        peek.releaseAll()
        peek.hold(.pointer)
        XCTAssertEqual(events, ["begin", "end", "begin"])
    }

    func testThePointerHoldReachesTheModelThroughPeekHoldsAndTheCanvasLeavingLetsGo() async {
        let model = EditorModel.preview(.editingHDRDisplay)
        let peek = PeekHolds(begin: { model.beginPeekOriginal() }, end: { model.endPeekOriginal() })
        let hold = PressAndHold(delay: .milliseconds(10), begin: { peek.hold(.pointer) }, end: { peek.release(.pointer) })
        hold.press(at: .zero)
        await eventually(timeout: .seconds(2), "peeking") { model.isPeekingOriginal }
        // The view goes away with the button down: no mouse-up will come.
        hold.release()
        peek.releaseAll()
        model.endPeekOriginal()
        XCTAssertFalse(model.isPeekingOriginal)
        XCTAssertFalse(hold.isHolding)
        XCTAssertFalse(peek.isHeld)
    }

    func testAPressStillWaitingForItsDelayIsCancelledByTheCanvasLeaving() async {
        var began = false
        let hold = PressAndHold(delay: .milliseconds(40), begin: { began = true }, end: {})
        hold.press(at: .zero)
        hold.release()              // onDisappear
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(began)
    }

    // MARK: Hint and legend (M2-V review P3)

    func testAHintCoveredByTheLegendIsNeitherShownNorCounted() {
        let session = ViewerSessionState()
        let hint = CanvasHintState()
        hint.update(key: "canvas.hint.peek", session: session, covered: true)
        XCTAssertNil(hint.shown)
        XCTAssertEqual(session.hintCount("canvas.hint.peek"), 0)
        hint.update(key: "canvas.hint.peek", session: session)
        XCTAssertNil(hint.shown, "the legend going does not bring back a hint that was never announced")
    }

    func testAShownHintTheLegendReplacesStaysGone() {
        let session = ViewerSessionState()
        let hint = CanvasHintState()
        hint.update(key: "canvas.hint.peek", session: session)
        XCTAssertEqual(hint.shown, "canvas.hint.peek")
        hint.dismiss()              // the legend came: the stage dismisses
        hint.update(key: "canvas.hint.peek", session: session)
        XCTAssertNil(hint.shown, "the legend going within the 4 s does not bring the hint back")
        XCTAssertEqual(session.hintCount("canvas.hint.peek"), 1, "one showing was counted, not two")
    }

    func testASamePhotoNameOpenedOverTheOldFrameAnnouncesTheHintAgain() async {
        let session = ViewerSessionState()
        let hint = CanvasHintState()
        let model = EditorModel.preview(.editingHDRDisplay)
        hint.update(key: model.viewerHintKey, session: session)
        XCTAssertNotNil(hint.shown)
        hint.dismiss()
        // The same key, as when the old frame stays while the new photo opens.
        hint.update(key: model.viewerHintKey, session: session)
        XCTAssertNil(hint.shown)
        hint.photoChanged(key: model.viewerHintKey, session: session)
        XCTAssertEqual(hint.shown, model.viewerHintKey)
    }
}

// MARK: One hint per photo (M2-V review P3-V3)

extension CanvasWiringTests {
    func testTheFirstPhotoClaimsItsHintOnceWhenTheSerialAndKeyChangeTogether() {
        let session = ViewerSessionState()
        let hint = CanvasHintState()
        hint.observe(serial: 0, key: nil, session: session)
        hint.observe(serial: 1, key: "canvas.hint.peek", session: session)
        XCTAssertEqual(hint.shown, "canvas.hint.peek")
        XCTAssertEqual(session.hintCount("canvas.hint.peek"), 1)
        hint.observe(serial: 1, key: "canvas.hint.peek", session: session)
        XCTAssertEqual(session.hintCount("canvas.hint.peek"), 1, "the same observation again claims nothing")
    }

    func testANewKeyOnTheSamePhotoAndANewPhotoWithTheSameKeyEachClaimOnce() {
        let session = ViewerSessionState()
        let hint = CanvasHintState()
        hint.observe(serial: 1, key: "canvas.hint.peek", session: session)
        hint.observe(serial: 1, key: "canvas.hint.pan", session: session)
        XCTAssertEqual(hint.shown, "canvas.hint.pan")
        hint.observe(serial: 2, key: "canvas.hint.pan", session: session)
        XCTAssertEqual(hint.shown, "canvas.hint.pan", "a new photo announces the hint again")
        XCTAssertEqual(session.hintCount("canvas.hint.pan"), 2)
        XCTAssertEqual(session.hintCount("canvas.hint.peek"), 1)
    }

    /// The real view, in a window that is never shown: opening one photo
    /// consumes one showing of its hint, not one per observation.
    func testFirstPhotoConsumesOneHintAppearanceInTheRealStage() async {
        let service = FakeEditorServices(openDelay: .milliseconds(20), previewDelay: .milliseconds(20))
        let model = EditorModel(services: service)
        let session = ViewerSessionState()
        let root = CanvasStage(model: model, window: EditorWindowState())
            .environment(session).frame(width: 600, height: 400)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Never ordered front or activated.
        try? await Task.sleep(for: .milliseconds(100))
        model.open([URL(fileURLWithPath: "/fixtures/hint-integration.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.hintCount("canvas.hint.peek"), 1,
                       "one edited frame consumes one appearance, not one per onChange callback")
        model.closeDocument()
        withExtendedLifetime(window) {}
    }
}
