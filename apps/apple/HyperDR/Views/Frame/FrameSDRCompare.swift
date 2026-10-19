import SwiftUI
import HyperDRDesign

/// The frame sheet's "hold for SDR" (frame-sheet.md §1): while someone holds
/// it, the photograph in the preview is its SDR version; the mat and caption
/// are SDR already and do not change.
///
/// Four sources feed it and all end the same way. The button (the pointer, at
/// once), a press on the preview (the pointer, after 240 ms, `PressAndHold`)
/// and Space (the key) go through one `PeekHolds`, so the last of them to let
/// go brings HDR back. VoiceOver cannot hold anything: its activation
/// switches the comparison and keeps it (`latched`), outside the holds.
/// Esc, the window going inactive, the display turning SDR or the photo
/// changing let go of everything, latched included.
///
/// Pure of SwiftUI and AppKit, so a test drives it with calls and a short
/// hold delay.
@MainActor @Observable final class FrameSDRCompare {
    private(set) var isHeld = false
    private(set) var latched = false
    /// An EDR display is showing the sheet; without one there is nothing to
    /// compare and the button is not shown.
    private(set) var supportsEDR = true
    /// This export has an HDR part; without one the SDR version looks the
    /// same and the button is off.
    private(set) var hasHDR = true

    @ObservationIgnored private var peek: PeekHolds!
    @ObservationIgnored private var hold: PressAndHold!
    @ObservationIgnored private var pressing = false

    init(holdDelay: Duration = PressAndHold.delay) {
        peek = PeekHolds(begin: { [weak self] in self?.isHeld = true }, end: { [weak self] in self?.isHeld = false })
        hold = PressAndHold(delay: holdDelay, begin: { [weak self] in self?.peek.hold(.pointer) },
                            end: { [weak self] in self?.peek.release(.pointer) })
    }

    /// Whether anything can start a comparison.
    var isEnabled: Bool { supportsEDR && hasHDR }
    /// Whether the photograph shows its SDR version.
    var showsSDR: Bool { isEnabled && (isHeld || latched) }

    /// The display and the export decide whether it can work; losing either
    /// ends a comparison that is on.
    func configure(supportsEDR: Bool, hasHDR: Bool) {
        self.supportsEDR = supportsEDR
        self.hasHDR = hasHDR
        if !isEnabled { releaseAll() }
    }

    // The button: down shows, up (or a cancelled press) returns.
    func buttonDown() { if isEnabled { peek.hold(.pointer) } }
    func buttonUp() { peek.release(.pointer) }

    // Space, on the preview or on the button; a repeat changes nothing.
    func spaceDown() { if isEnabled { peek.hold(.key) } }
    func spaceUp() { peek.release(.key) }

    /// A press on the preview, or on its mat or caption: the pointer's start
    /// and where it is now. The first call of a press starts the 240 ms wait.
    func pointerMoved(start: CGPoint, to point: CGPoint) {
        guard isEnabled else { return }
        if !pressing { pressing = true; hold.press(at: start) }
        hold.drag(to: point)
    }

    func pointerEnded() {
        pressing = false
        hold.release()
    }

    /// VoiceOver's activation: switch, and stay.
    func toggleLatched() {
        guard isEnabled else { return }
        latched.toggle()
    }

    /// Esc: ends the comparison and says whether there was one, so the sheet
    /// stays open for exactly that Esc.
    func escape() -> Bool {
        guard showsSDR else { return false }
        releaseAll()
        return true
    }

    /// The preview lost the keyboard: a key-up will not arrive.
    func keyboardLeft() { peek.release(.key) }

    func releaseAll() {
        pressing = false
        hold.release()
        peek.releaseAll()
        latched = false
    }
}

extension EditorModel {
    /// Whether the export being previewed has an HDR part to compare: not
    /// colour-only, a range above zero, and an edit to show.
    var frameCompareHasHDR: Bool {
        hasEditedFrame && workflow != .colorOnly && outputCeilingStops > 0
    }
}

/// "Hold for SDR" at the preview's bottom right. A plain `Button` would turn
/// a hold into a click that stays on; this is a view with a zero-distance
/// drag instead, so down shows and up returns. It is focusable for the
/// keyboard (hold Space) and a switch for VoiceOver.
struct FrameSDRButton: View {
    let compare: FrameSDRCompare
    @FocusState private var focused: Bool
    @State private var focusedByPointer = false

    var body: some View {
        let enabled = compare.isEnabled
        Label("frame.compare.sdr", systemImage: "circle.lefthalf.filled")
            .labelStyle(.titleAndIcon)
            .font(Font.hdr.caption)
            .foregroundStyle(enabled ? Color.hdr.overlayInk : Color.hdr.overlayMuted)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1)
            .background(compare.showsSDR ? Color.hdr.overlayHover : Color.hdr.overlay, in: .rect(cornerRadius: Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(compare.showsSDR ? Color.hdr.overlayLineStrong : Color.hdr.overlayLine)
            }
            .overlay { if focused && !focusedByPointer { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.hdr.overlayInk, lineWidth: 2) } }
            .environment(\.colorScheme, .dark)
            .opacity(enabled ? 1 : 0.6)
            .fixedSize()
            .contentShape(.rect(cornerRadius: Radius.sm))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in focusedByPointer = true; compare.buttonDown() }
                .onEnded { _ in compare.buttonUp() })
            .focusable(enabled)
            .focusEffectDisabled()
            .focused($focused)
            .onChange(of: focused) { _, now in if !now { focusedByPointer = false; compare.keyboardLeft() } }
            .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                if press.phase == .down { compare.spaceDown() } else { compare.spaceUp() }
                return .handled
            }
            .onKeyPress(.escape) { compare.escape() ? .handled : .ignored }
            .help(Text(enabled ? "frame.compare.sdr.help" : "frame.compare.sdr.noHDR"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("frame.compare.sdr.a11y"))
            .accessibilityValue(Text(compare.showsSDR ? "frame.compare.sdr.a11y.on" : "frame.compare.sdr.a11y.off"))
            .accessibilityHint(Text(enabled ? "frame.compare.sdr.a11y.hint" : "frame.compare.sdr.noHDR"))
            .accessibilityAddTraits([.isButton, .isToggle])
            .accessibilityAction { compare.toggleLatched() }
    }
}

/// The label at the top of the card while the photograph shows its SDR
/// version. Held, it says how to go back; kept on by VoiceOver, it does not.
struct FrameSDRLabel: View {
    let compare: FrameSDRCompare

    var body: some View {
        Label(compare.latched ? "frame.compare.sdr.latched" : "frame.compare.sdr.showing", systemImage: "eye")
            .font(Font.hdr.caption)
            .hdrOverlayChip()
            .allowsHitTesting(false)
    }
}

/// Under the preview: what the frame does on this display on the left and
/// "Hold for SDR" on the right. A display without HDR has nothing to compare,
/// so no button there; the note says why.
struct FrameCompareBar: View {
    let display: DisplayState
    let compare: FrameSDRCompare

    static func showsButton(on display: DisplayState) -> Bool { display.supportsEDR }

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.s3) {
            DisplayNote(display: display, showsSDR: compare.showsSDR)
            Spacer(minLength: 0)
            if Self.showsButton(on: display) { FrameSDRButton(compare: compare) }
        }
        .padding(Space.s4)
    }
}
