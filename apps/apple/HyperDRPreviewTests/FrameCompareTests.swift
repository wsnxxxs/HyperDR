import XCTest
import SwiftUI
import HyperDRDesign
@_spi(Testing) import HyperDREngine
@testable import HyperDR

/// The frame sheet's "hold for SDR" (frame-sheet.md §1.9 S7): its rules as
/// calls on `FrameSDRCompare`, the composition it asks of the canvas, and
/// pictures of the five states. Nothing here sends a key or a click to the
/// system; the views feed the same calls the tests make.
@MainActor final class FrameCompareTests: XCTestCase {
    private func compare(delay: Duration = .milliseconds(20)) -> FrameSDRCompare { FrameSDRCompare(holdDelay: delay) }

    // MARK: The button

    func testTheButtonShowsOnPressAndReturnsOnRelease() {
        let c = compare()
        XCTAssertFalse(c.showsSDR)
        c.buttonDown()
        XCTAssertTrue(c.showsSDR, "no 240 ms wait for the button")
        c.buttonUp()
        XCTAssertFalse(c.showsSDR)
    }

    /// A click (down and up at once) must not leave the preview on SDR: the
    /// button is a hold, not a switch.
    func testAClickOnTheButtonLeavesHDR() {
        let c = compare()
        c.buttonDown(); c.buttonUp()
        XCTAssertFalse(c.showsSDR)
        XCTAssertFalse(c.latched)
    }

    // MARK: Pressing the preview

    func testAPressOnThePreviewShowsOnlyAfterTheHoldDelay() async {
        let c = compare(delay: .milliseconds(60))
        c.pointerMoved(start: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10))
        XCTAssertFalse(c.showsSDR, "not before the delay")
        await eventually { c.showsSDR }
        // Moving after it has begun does not end it; letting go does.
        c.pointerMoved(start: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 90))
        XCTAssertTrue(c.showsSDR)
        c.pointerEnded()
        XCTAssertFalse(c.showsSDR)
    }

    func testAPressThatMovesMoreThanFourPointsIsNotAHold() async {
        let c = compare(delay: .milliseconds(40))
        c.pointerMoved(start: .zero, to: .zero)
        c.pointerMoved(start: .zero, to: CGPoint(x: 5, y: 0))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(c.showsSDR)
        c.pointerEnded()
        // Within four points it still is one.
        c.pointerMoved(start: .zero, to: .zero)
        c.pointerMoved(start: .zero, to: CGPoint(x: 3, y: 0))
        await eventually { c.showsSDR }
        c.pointerEnded()
    }

    func testReleasingBeforeTheDelayShowsNothing() async {
        let c = compare(delay: .milliseconds(60))
        c.pointerMoved(start: .zero, to: .zero)
        c.pointerEnded()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(c.showsSDR)
    }

    // MARK: Space and several sources

    func testSpaceShowsWhileHeldAndRepeatsChangeNothing() {
        let c = compare()
        c.spaceDown(); c.spaceDown(); c.spaceDown()
        XCTAssertTrue(c.showsSDR)
        c.spaceUp()
        XCTAssertFalse(c.showsSDR, "one key-up ends it however many repeats came")
    }

    func testTheLastSourceToLetGoBringsHDRBack() {
        let c = compare()
        c.buttonDown(); c.spaceDown()
        c.buttonUp()
        XCTAssertTrue(c.showsSDR, "Space still holds")
        c.spaceUp()
        XCTAssertFalse(c.showsSDR)
        c.spaceDown(); c.buttonDown()
        c.spaceUp()
        XCTAssertTrue(c.showsSDR, "the button still holds")
        c.buttonUp()
        XCTAssertFalse(c.showsSDR)
    }

    func testLosingTheKeyboardLetsGoOfSpaceButNotThePointer() {
        let c = compare()
        c.buttonDown(); c.spaceDown()
        c.keyboardLeft()
        XCTAssertTrue(c.showsSDR)
        c.buttonUp()
        XCTAssertFalse(c.showsSDR)
    }

    // MARK: Esc, switching away

    func testEscEndsTheComparisonAndSaysSoOnlyThen() {
        let c = compare()
        XCTAssertFalse(c.escape(), "nothing to end: the sheet may close")
        c.spaceDown(); c.buttonDown()
        XCTAssertTrue(c.escape(), "this Esc is for the comparison")
        XCTAssertFalse(c.showsSDR)
        XCTAssertFalse(c.escape())
        c.toggleLatched()
        XCTAssertTrue(c.escape())
        XCTAssertFalse(c.showsSDR)
        XCTAssertFalse(c.latched)
    }

    func testReleaseAllLetsGoOfEverythingIncludingAPendingPress() async {
        let c = compare(delay: .milliseconds(60))
        c.buttonDown(); c.spaceDown(); c.toggleLatched()
        c.pointerMoved(start: .zero, to: .zero)
        c.releaseAll()
        XCTAssertFalse(c.showsSDR)
        XCTAssertFalse(c.latched)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(c.showsSDR, "the pending press did not start afterwards")
    }

    // MARK: Unavailable

    func testWithoutAnHDRPartNothingStartsAComparison() async {
        let c = compare(delay: .milliseconds(20))
        c.configure(supportsEDR: true, hasHDR: false)
        XCTAssertFalse(c.isEnabled)
        c.buttonDown(); XCTAssertFalse(c.showsSDR)
        c.buttonUp()
        c.spaceDown(); XCTAssertFalse(c.showsSDR)
        c.spaceUp()
        c.pointerMoved(start: .zero, to: .zero)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(c.showsSDR)
        c.pointerEnded()
        c.toggleLatched(); XCTAssertFalse(c.showsSDR); XCTAssertFalse(c.latched)
    }

    func testAnSDRDisplayHasNoButtonAndNoComparison() {
        let sdr = DisplayState(screenName: "", currentHeadroom: 1, potentialHeadroom: 1, gainWeight: nil)
        let hdr = DisplayState(screenName: "", currentHeadroom: 2, potentialHeadroom: 4, gainWeight: 1)
        XCTAssertFalse(FrameCompareBar.showsButton(on: sdr))
        XCTAssertTrue(FrameCompareBar.showsButton(on: hdr))
        let c = compare()
        c.configure(supportsEDR: false, hasHDR: true)
        c.spaceDown(); c.buttonDown()
        XCTAssertFalse(c.showsSDR)
    }

    func testTheDisplayOrTheExportChangingEndsAComparisonThatIsOn() {
        let c = compare()
        c.buttonDown(); c.toggleLatched()
        XCTAssertTrue(c.showsSDR)
        c.configure(supportsEDR: false, hasHDR: true)
        XCTAssertFalse(c.showsSDR)
        XCTAssertFalse(c.latched)
        c.configure(supportsEDR: true, hasHDR: true)
        XCTAssertFalse(c.showsSDR, "coming back does not resume it")
        c.spaceDown()
        c.configure(supportsEDR: true, hasHDR: false)
        XCTAssertFalse(c.showsSDR)
        c.configure(supportsEDR: true, hasHDR: true)
        c.spaceUp()
        XCTAssertFalse(c.showsSDR)
    }

    // MARK: VoiceOver

    func testVoiceOverActivationSwitchesAndKeeps() {
        let c = compare()
        c.toggleLatched()
        XCTAssertTrue(c.showsSDR)
        XCTAssertFalse(c.isHeld)
        c.toggleLatched()
        XCTAssertFalse(c.showsSDR)
        // Latched and then held and released: still on.
        c.toggleLatched(); c.buttonDown(); c.buttonUp()
        XCTAssertTrue(c.showsSDR)
        c.releaseAll()
        XCTAssertFalse(c.showsSDR, "closing the sheet or changing the photo resets it")
    }

    // MARK: The model's side

    private func readyModel() async -> (EditorModel, FakeEditorServices) {
        let services = FakeEditorServices(openDelay: .zero)
        let model = EditorModel(services: services)
        model.open([URL(fileURLWithPath: "/fixtures/a.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready && model.hasEditedFrame }
        return (model, services)
    }

    /// The canvas gets SDR only while comparing, and never from the main
    /// canvas's "Preview as SDR".
    func testTheCompositionIsSDROnlyWhileComparing() async throws {
        let empty = EditorModel(services: FakeEditorServices(openDelay: .zero))
        XCTAssertNil(FramePreviewCanvas.composition(of: empty, showsSDR: false), "no frame, nothing to draw")
        let (model, _) = await readyModel()
        // The main canvas's own switch is not read: the model's composition
        // for the main canvas follows it, the sheet's does not.
        model.previewsAsSDR = true
        XCTAssertEqual(FramePreviewCanvas.composition(of: model, showsSDR: false)?.previewsAsSDR, false)
        let sdr = try XCTUnwrap(FramePreviewCanvas.composition(of: model, showsSDR: true))
        XCTAssertTrue(sdr.previewsAsSDR)
        XCTAssertEqual(sdr.mode, .edited)
        model.closeDocument()
    }

    func testTheExportHasAnHDRPartUnlessColourOnly() async {
        let (model, _) = await readyModel()
        let hdr = model.frameCompareHasHDR
        let encoding = model.exportChoices.encoding
        model.selectEncoding("sdr-tiff")
        XCTAssertFalse(model.frameCompareHasHDR, "colour only has nothing above SDR white")
        model.selectEncoding(encoding)
        XCTAssertEqual(model.frameCompareHasHDR, hdr)
        XCTAssertFalse(EditorModel(services: FakeEditorServices(openDelay: .zero)).frameCompareHasHDR,
                       "nothing open, nothing to compare")
    }

    /// Comparing only changes what is shown, so an export under way does not
    /// take it away.
    func testComparingStaysAvailableWhileAnExportRuns() async {
        let (model, _) = await readyModel()
        let before = model.frameCompareHasHDR
        let c = compare()
        c.configure(supportsEDR: true, hasHDR: before)
        // The lock is not an input: the sheet's settings lock, the comparison does not.
        c.buttonDown()
        XCTAssertEqual(c.showsSDR, before)
        c.buttonUp()
    }

    // MARK: Pictures

    private struct Stage: View {
        let compare: FrameSDRCompare
        let display: DisplayState
        let paper = Color(red: 0.96, green: 0.95, blue: 0.91)

        var body: some View {
            ZStack(alignment: .top) {
                Color.hdr.previewBackdrop
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color(red: 0.26, green: 0.36, blue: 0.62), Color(red: 0.93, green: 0.72, blue: 0.5),
                                            Color(red: 0.2, green: 0.17, blue: 0.2)], startPoint: .top, endPoint: .bottom)
                        .padding(.horizontal, 12).padding(.top, 12)
                    Text(verbatim: "f/8 · 1/250 s · ISO 100").font(.system(size: 8)).foregroundStyle(.gray).frame(height: 34)
                }
                .background(paper)
                .frame(width: 330, height: 260)
                .padding(.top, 24)
                if compare.showsSDR { FrameSDRLabel(compare: compare).padding(.top, 36) }
            }
            .frame(width: 560, height: 360)
            .overlay(alignment: .bottom) { FrameCompareBar(display: display, compare: compare) }
        }
    }

    /// States ①–⑤ of the design, in the four variants; with $HDR_SNAPSHOT_DIR
    /// set they are written to the host's temporary folder as
    /// `framesdr-<state>-<variant>.png`.
    func testStatePictures() throws {
        let hdr = DisplayState(screenName: "", currentHeadroom: 2, potentialHeadroom: 4, gainWeight: 1)
        let sdr = DisplayState(screenName: "", currentHeadroom: 1, potentialHeadroom: 1, gainWeight: nil)
        func make(_ state: String) -> (FrameSDRCompare, DisplayState) {
            let c = compare()
            switch state {
            case "held": c.buttonDown()
            case "latched": c.toggleLatched()
            case "no-hdr": c.configure(supportsEDR: true, hasHDR: false)
            case "sdr-display": c.configure(supportsEDR: false, hasHDR: true)
            default: break
            }
            return (c, state == "sdr-display" ? sdr : hdr)
        }
        let variants: [(String, ColorScheme, String)] = [("light-en", .light, "en"), ("dark-en", .dark, "en"),
                                                         ("light-zh-Hans", .light, "zh-Hans"), ("dark-zh-Hans", .dark, "zh-Hans")]
        let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"].map {
            FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent, isDirectory: true)
        }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var seen: [String: [String: Data]] = [:]
        for state in ["idle", "held", "no-hdr", "sdr-display", "latched"] {
            for (name, scheme, locale) in variants {
                let (c, display) = make(state)
                let root = Stage(compare: c, display: display)
                    .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: locale))
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                seen[name, default: [:]][state] = png
                if let directory { try png.write(to: directory.appendingPathComponent("framesdr-\(state)-\(name).png")) }
            }
        }
        for (name, states) in seen {
            XCTAssertEqual(Set(states.values).count, states.count, "each state looks different: \(name)")
        }
    }
}

// MARK: - The views' side of a hold (R6-FRAME-SDR-1, -2)

/// Mounted views in an offscreen window. Nothing is sent to the system.
@MainActor final class FrameCompareMountedTests: XCTestCase {
    private func mount<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 240, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    /// A press that goes away without `onEnded` ever running -- what a
    /// cancelled gesture does to its `@GestureState` -- lets go.
    private struct Relayed: View {
        let compare: FrameSDRCompare
        let box: PressBox
        var body: some View {
            Color.clear.frame(width: 40, height: 40)
                .modifier(PressRelay(press: box.press, report: compare.buttonPress))
        }
    }
    @MainActor @Observable final class PressBox { var press: FramePress? }

    func testAGestureThatIsCancelledLetsGo() async {
        let compare = FrameSDRCompare()
        let box = PressBox()
        let (window, _) = mount(Relayed(compare: compare, box: box))
        defer { window.close() }
        box.press = FramePress(start: .zero, location: .zero)
        await settle()
        XCTAssertTrue(compare.showsSDR)
        box.press = nil // the state reset; no ended callback
        await settle()
        XCTAssertFalse(compare.showsSDR, "a cancelled press must not leave the preview on SDR")
    }

    private struct MatRelayed: View {
        let compare: FrameSDRCompare
        let box: PressBox
        var body: some View {
            Color.clear.frame(width: 40, height: 40)
                .modifier(PressRelay(press: box.press, report: compare.matPress))
        }
    }

    func testAMatPressThatIsCancelledEndsItsPendingHold() async {
        let compare = FrameSDRCompare(holdDelay: .milliseconds(300))
        let box = PressBox()
        let (window, _) = mount(MatRelayed(compare: compare, box: box))
        defer { window.close() }
        box.press = FramePress(start: .zero, location: .zero)
        await settle()
        XCTAssertFalse(compare.showsSDR, "still waiting out the hold delay")
        box.press = nil
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(compare.showsSDR, "the cancelled press did not start a hold afterwards")
    }

    private struct Switch: View {
        let compare: FrameSDRCompare
        let box: PressBox
        let on: SwitchState
        var body: some View {
            if on.shown {
                Color.clear.frame(width: 40, height: 40)
                    .modifier(PressRelay(press: box.press, report: compare.buttonPress))
            }
        }
    }
    @MainActor @Observable final class SwitchState { var shown = true }

    func testTheViewGoingAwayWhileHeldLetsGo() async {
        let compare = FrameSDRCompare()
        let box = PressBox(), state = SwitchState()
        let (window, _) = mount(Switch(compare: compare, box: box, on: state))
        defer { window.close() }
        box.press = FramePress(start: .zero, location: .zero)
        await settle()
        XCTAssertTrue(compare.showsSDR)
        state.shown = false
        await settle()
        XCTAssertFalse(compare.showsSDR, "the view left with the pointer down")
    }

    func testTheViewGoingAwayKeepsAKeyThatStillHolds() async {
        let compare = FrameSDRCompare()
        let box = PressBox(), state = SwitchState()
        let (window, _) = mount(Switch(compare: compare, box: box, on: state))
        defer { window.close() }
        compare.spaceDown()
        box.press = FramePress(start: .zero, location: .zero)
        await settle()
        state.shown = false
        await settle()
        XCTAssertTrue(compare.showsSDR, "Space is still down")
        compare.buttonUp() // a second release is harmless
        XCTAssertTrue(compare.showsSDR)
        compare.spaceUp()
        XCTAssertFalse(compare.showsSDR)
    }

    // MARK: Disabled for real

    func testWithoutAnHDRPartTheButtonIsDisabledAndWithItEnabled() async {
        let compare = FrameSDRCompare()
        var seen: [Bool] = []
        let (window, _) = mount(FrameSDRButton(compare: compare, resolvedEnabled: { seen.append($0) }))
        defer { window.close() }
        compare.configure(supportsEDR: true, hasHDR: true)
        await settle()
        XCTAssertEqual(seen.last, true)
        compare.configure(supportsEDR: true, hasHDR: false)
        await settle()
        XCTAssertEqual(seen.last, false, "not just dimmed: SwiftUI resolves it disabled, so the accessibility tree and focus follow")
        compare.configure(supportsEDR: true, hasHDR: true)
        await settle()
        XCTAssertEqual(seen.last, true)
    }
}
