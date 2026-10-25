import SwiftUI

/// A request to show where a control acts on the photograph: the mask mark
/// after its title, and the callback that asks the model for the mask.
public struct ParameterMaskLink {
    /// Whether this control's mask is on the canvas now (the model's state).
    public var isShowing: Bool
    /// `true` when the first of hover, focus and drag takes hold, `false`
    /// when the last lets go.
    public var onChange: (Bool) -> Void

    public init(isShowing: Bool, onChange: @escaping (Bool) -> Void) {
        self.isShowing = isShowing
        self.onChange = onChange
    }
}

/// An inspector slider row (CSS `.field--range`): the title, a readout that is
/// also where an exact value is typed, and the track.
///
/// - The track fills from the spec's origin: from the lower bound, or from
///   the centre for a signed parameter, whose zero is marked.
/// - Drag or click anywhere on the track; a click on the thumb grabs it
///   where it is. Double-click, or Reset to Default in the context menu,
///   returns to the default (`onReset`, when given, does it instead of a
///   write of `spec.defaultValue`: only the model knows a HDR photo's own).
/// - With keyboard navigation on, the track takes focus; ← → ↑ ↓ step it,
///   with Shift ten steps.
/// - The readout shows the formatted value until focused, then the bare
///   number. Return commits and stays, Escape abandons, ↑ ↓ step.
/// - A spec with an `automatic` state shows it as the word "Auto" and a
///   dashed track with a hollow ring where Auto lands, when known, so the
///   track reads as one to drag (on iPad above all). Elsewhere a small Auto button sits by the
///   readout; clearing the readout or typing "auto" also returns to it, and
///   a click, drag, key or typed number leaves it.
/// - With a `mask`, a small mark follows the title, and hovering the row,
///   focusing the readout or dragging asks for the mask on the photograph.
/// - VoiceOver sees a system slider with the formatted value, the
///   increment/decrement actions, Reset to Default and, when the control
///   has one, Set to Auto. The control's `help` is the slider's hint: the
///   tooltip is all the pointer gets, and VoiceOver users never see it.
///
/// Bind one value per control (S12): the row reads nothing else, so a change
/// redraws only this row. With the M2 contract (batch 3 §3.4), the value is
/// the key's `ControlValue`, writes go to `adjust(key, to:)`, and
/// `onEditingChanged` maps to `beginAdjusting` / `endAdjusting`.
///
/// `onEditingChanged` brackets a pointer drag and a held arrow key: each is
/// one undo step and previews at the draft size until it ends. A key's
/// bracket opens at its first key-down, stays open through the auto-repeat
/// and closes at key-up (or when focus leaves, the control is disabled or
/// removed), so holding Right Arrow from 0.60 to 0.75 is one step; a single
/// press is a bracket of its own. A typed value and a reset are single
/// writes outside any bracket, one undo step each, and render at full size
/// at once. A drag that ends where it began still brackets; the model
/// records no step for an unchanged value.
public struct ParameterSlider: View {
    private let title: Text
    @Binding private var value: Double
    private let spec: ParameterSpec
    private let help: Text?
    private let mask: ParameterMaskLink?
    private let onReset: (() -> Void)?
    private let readoutHelp: Text?
    private let accessory: AnyView?
    private let onEditingChanged: (Bool) -> Void

    @State private var maskHold = MaskHold()
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: LocalizedStringKey, value: Binding<Double>, spec: ParameterSpec,
                help: LocalizedStringKey? = nil, mask: ParameterMaskLink? = nil, readoutHelp: Text? = nil,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }, onReset: (() -> Void)? = nil) {
        self.init(Text(title), value: value, spec: spec, help: help.map { Text($0) }, mask: mask,
                  readoutHelp: readoutHelp, onEditingChanged: onEditingChanged, onReset: onReset)
    }

    /// A row whose title and help are already `Text`s: from this package's
    /// catalogue, as the generated adjustment controls are. An `accessory`
    /// (the white balance eyedropper) sits between the title and the readout.
    public init(_ title: Text, value: Binding<Double>, spec: ParameterSpec,
                help: Text? = nil, mask: ParameterMaskLink? = nil, readoutHelp: Text? = nil,
                accessory: AnyView? = nil,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }, onReset: (() -> Void)? = nil) {
        self.accessory = accessory
        self.title = title
        _value = value
        self.spec = spec
        self.help = help
        self.mask = mask
        self.onReset = onReset
        self.readoutHelp = readoutHelp
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: 10) {
                FieldTitle(title: title, help: help, mask: mask)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let accessory { accessory }
                if let automatic = spec.automatic, !spec.isAutomatic(value) {
                    AutoButton { if value != automatic.value { value = automatic.value } }
                }
                ParameterReadout(title: title, value: $value, spec: spec, help: readoutHelp,
                                 onEditingChanged: onEditingChanged) { focused in
                    hold(.focus, focused)
                }
            }
            .frame(minHeight: 22)
            ParameterTrack(title: title, value: $value, spec: spec, help: help, onReset: onReset) { editing in
                hold(.drag, editing)
                onEditingChanged(editing)
            }
        }
        .onHover { hold(.hover, $0 && isEnabled) }
        .onChange(of: isEnabled) { if !isEnabled { release() } }
        .onDisappear { release() }
    }

    private func hold(_ source: MaskHold.Source, _ on: Bool) {
        guard let mask else { return }
        maskHold.set(source, on, notify: mask.onChange)
    }

    private func release() {
        guard let mask else { return }
        maskHold.releaseAll(notify: mask.onChange)
    }
}

/// The 12 pt title of a field (CSS `.field-title b`); the help text, if any,
/// is its tooltip. A control with a mask carries a small mark after it.
struct FieldTitle: View {
    let title: Text
    let help: Text?
    var mask: ParameterMaskLink?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 5) {
            let text = title
                .font(.hdr.caption)
                .foregroundStyle(isEnabled ? Color.hdr.ink : Color.hdr.inkDisabled)
                .lineLimit(1)
            if let help { text.help(help) } else { text }
            if let mask {
                Image(systemName: "square.dashed")
                    .font(.system(size: 10))
                    .foregroundStyle(!isEnabled ? Color.hdr.inkDisabled : mask.isShowing ? Color.hdr.maskTint : Color.hdr.inkMuted)
                    .help(Text("design.slider.maskHint", bundle: .module))
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The small "Auto" button left of the readout (20 pt high, outlined) that
/// returns a parameter to its Auto state.
private struct AutoButton: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text("design.slider.auto", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(!isEnabled ? Color.hdr.inkDisabled : hovered ? Color.hdr.inkStrong : Color.hdr.inkMuted)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .overlay { RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Color.hdr.line) }
                .contentShape(.rect(cornerRadius: Radius.xs))
        }
        .buttonStyle(.plain)
        .onHover { hovered = isEnabled && $0 }
        .hdrAnimation(Motion.fast, value: hovered)
        .help(Text("design.slider.setAuto", bundle: .module))
        .accessibilityLabel(Text("design.slider.setAuto", bundle: .module))
    }
}

// MARK: - Readout

/// The value field (CSS `.field-value`): 80 × 24, system face with tabular
/// digits (`Font.hdr.readout`), right-aligned. It is drawn as a text field
/// (a card-coloured well with a visible border, the I-beam pointer and a
/// tooltip that says to click and type), so it reads as somewhere to type an
/// exact value, not as a label; hovering darkens the border to the accent and
/// focusing adds the 2 pt focus ring. In the Auto state it says "Auto" and,
/// once focused, is empty with "Auto" as its placeholder.
private struct ParameterReadout: View {
    let title: Text
    @Binding var value: Double
    let spec: ParameterSpec
    let help: Text?
    let onEditingChanged: (Bool) -> Void
    let onFocusChange: (Bool) -> Void

    @State private var keys = ArrowKeyEditing()
    @FocusState private var focused: Bool
    @State private var draft = ""
    /// Whether `draft` holds something typed. Only typed text is committed.
    /// The slider can move while the field keeps focus (a click on the track
    /// does not take it); the draft then follows the value, and anything
    /// typed but not committed gives way to the newer change.
    @State private var typed = false
    @State private var selection: TextSelection?
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale

    var body: some View {
        let isAuto = spec.isAutomatic(value)
        field(isAuto: isAuto)
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(.hdr.readout)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(!isEnabled ? Color.hdr.inkDisabled : isAuto && !focused ? Color.hdr.inkMuted : Color.hdr.inkStrong)
            .padding(.horizontal, 7)
            .frame(width: 80, height: 24)
            .background(isEnabled ? Color.hdr.surfaceCard : Color.hdr.surfaceSunken, in: .rect(cornerRadius: Radius.xs))
            .overlay {
                // Resting: a visible border, so the box reads as an input.
                // Hover: the accent at half strength. Focus: the accent plus
                // a 1 pt halo (CSS box-shadow 0 0 0 1px).
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(border, lineWidth: focused ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: Radius.xs))
            #if os(macOS)
            .pointerStyle(isEnabled ? .horizontalText : .default)
            #endif
            .hdrAnimation(Motion.fast, value: hovered)
            .focused($focused)
            .focusEffectDisabled()
            .onHover { hovered = $0 }
            .help(help ?? Text("design.slider.readoutHelp", bundle: .module))
            .onChange(of: focused) { _, now in
                now ? beginTyping() : commit()
                if !now { keys.finish(onEditingChanged) }
                onFocusChange(now)
            }
            .onChange(of: isEnabled) { if !isEnabled { keys.finish(onEditingChanged) } }
            .onDisappear { keys.finish(onEditingChanged) }
            .onChange(of: value) { if focused { beginTyping() } }
            .onSubmit {
                // Commit and stay, with the value as stored, so another number
                // can be typed straight away.
                commit()
                beginTyping()
            }
            #if os(macOS)
            .onExitCommand {
                // Escape abandons what was typed and leaves the field.
                typed = false
                focused = false
            }
            #endif
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat, .up]) { press in
                keys.perform(ArrowKeyInput(press), verticalOnly: true, notify: onEditingChanged) { steps in
                    set(spec.stepped(typed ? spec.parse(draft) ?? value : value, by: steps))
                    beginTyping()
                }
                return .handled
            }
            // labelsHidden() drops the label from accessibility too.
            .accessibilityLabel(title)
            .accessibilityHint(Text("design.slider.valueHint", bundle: .module))
    }

    private var border: Color {
        if !isEnabled { return Color.hdr.line }
        if focused { return Color.hdr.focus }
        return hovered ? Color.hdr.focus.opacity(0.55) : Color.hdr.lineStrong
    }

    @ViewBuilder private func field(isAuto: Bool) -> some View {
        let text = Binding(get: { focused ? draft : spec.formatted(value, locale: locale) },
                           set: { new in if new != draft { draft = new; typed = true } })
        if spec.automatic != nil {
            TextField(text: text, selection: $selection,
                      prompt: Text("design.slider.auto", bundle: .module).foregroundStyle(Color.hdr.inkDisabled)) { title }
        } else {
            TextField(text: text, selection: $selection) { title }
        }
    }

    private func beginTyping() {
        draft = spec.editableText(value)
        typed = false
        selection = TextSelection(range: draft.startIndex..<draft.endIndex)
    }

    private func commit() {
        guard typed else { return }
        typed = false
        if let new = spec.parse(draft) { set(new) }
    }

    /// A single write outside any drag: one undo step of its own.
    private func set(_ new: Double) {
        if new != value { value = new }
    }
}

/// `.accessibilityHint` for a hint that may not be there.
private struct OptionalHint: ViewModifier {
    let text: Text?

    func body(content: Content) -> some View {
        if let text { content.accessibilityHint(text) } else { content }
    }
}

// MARK: - Track

/// The track (CSS `.field input[type="range"]`): a 3 pt line, the fill from
/// the origin, a 13 pt thumb with a halo on hover and while dragging. In the
/// Auto state it is a dashed line with no fill and a hollow ring for a thumb
/// at the value Auto resolves to.
private struct ParameterTrack: View {
    let title: Text
    @Binding var value: Double
    let spec: ParameterSpec
    /// What the parameter does: the title's tooltip for the pointer, and the
    /// slider's hint for VoiceOver (J-08).
    let help: Text?
    let onReset: (() -> Void)?
    let onEditingChanged: (Bool) -> Void

    @State private var hovered = false
    @State private var grab: CGFloat?
    @State private var bracket = EditingBracket()
    /// Open from the first key-down of an arrow to its key-up.
    @State private var keys = ArrowKeyEditing()
    /// True while the pointer gesture is live; the system resets it to false
    /// when the gesture is cancelled as well as when it ends.
    @GestureState private var live = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale
    @Environment(\.sliderTrackGradient) private var gradient

    static let thumb: CGFloat = 13
    static let height: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(width - Self.thumb, 1)
            let x = { (fraction: Double) in Self.thumb / 2 + travel * fraction }
            let isAuto = spec.isAutomatic(value)
            let fill = spec.fill(for: value)
            let thumbX = x(spec.fraction(of: value))
            let mid = Self.height / 2
            ZStack(alignment: .topLeading) {
                if isAuto {
                    // Not a position but a state: a dashed line, nothing on it.
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: mid))
                        path.addLine(to: CGPoint(x: width, y: mid))
                    }
                    .stroke(Color.hdr.controlTrack, style: StrokeStyle(lineWidth: 3, lineCap: .butt, dash: [4, 4]))
                    if let resolved = spec.automatic?.resolved, spec.range.contains(resolved) {
                        Circle()
                            .strokeBorder(isEnabled ? Color.hdr.controlThumb : Color.hdr.inkDisabled, lineWidth: 1.5)
                            .frame(width: Self.thumb, height: Self.thumb)
                            .offset(x: x(spec.fraction(of: resolved)) - Self.thumb / 2, y: mid - Self.thumb / 2)
                    }
                } else {
                    if let gradient {
                        GradientTrack(stops: gradient, height: 5)
                            .frame(width: width)
                            .offset(y: mid - 2.5)
                            .opacity(isEnabled ? 1 : 0.4)
                    } else {
                        Capsule()
                            .fill(Color.hdr.controlTrack)
                            .frame(width: width, height: 3)
                            .offset(y: mid - 1.5)
                        Rectangle()
                            .fill(isEnabled ? Color.hdr.controlFill : Color.hdr.controlTrack)
                            .frame(width: max(x(fill.upperBound) - x(fill.lowerBound), 0), height: 3)
                            .offset(x: x(fill.lowerBound), y: mid - 1.5)
                    }
                    if spec.isCentred {
                        // The zero of a signed parameter.
                        Rectangle()
                            .fill(Color.hdr.lineStrong)
                            .frame(width: 1, height: 9)
                            .offset(x: x(spec.fraction(of: spec.origin)) - 0.5, y: mid - 4.5)
                    }
                    thumb.offset(x: thumbX - Self.thumb / 2, y: mid - Self.thumb / 2)
                }
            }
            .frame(width: width, height: Self.height)
            .contentShape(.rect)
            .gesture(drag(travel: travel, thumbX: thumbX, isAuto: isAuto))
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        }
        .frame(height: Self.height)
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.hdr.focus, lineWidth: 2)
                    .padding(-3)
            }
        }
        .onHover { hovered = $0 }
        .hdrAnimation(Motion.fast, value: hovered)
        // Like a system slider: keyboard focus only with keyboard navigation
        // on, never from a click.
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat, .up]) { press in
            keys.perform(ArrowKeyInput(press), verticalOnly: false, notify: onEditingChanged, apply: step)
            return .handled
        }
        .onChange(of: live) { if !live { finishDrag() } }
        .onChange(of: focused) { if !focused { keys.finish(onEditingChanged) } }
        .onChange(of: isEnabled) { if !isEnabled { finishDrag(); keys.finish(onEditingChanged) } }
        .onDisappear { finishDrag(); keys.finish(onEditingChanged) }
        .contextMenu {
            Button { reset() } label: { Text("design.slider.reset", bundle: .module) }
                .disabled(value == spec.defaultValue)
            if let automatic = spec.automatic {
                Button { set(automatic.value) } label: { Text("design.slider.setAuto", bundle: .module) }
                    .disabled(spec.isAutomatic(value))
            }
        }
        .accessibilityRepresentation {
            // From Auto a step lands on the resume value, as a key press does.
            Slider(value: Binding(get: { spec.isAutomatic(value) ? spec.range.lowerBound : value },
                                  set: { new in set(spec.isAutomatic(value) ? spec.resumeValue : spec.snapped(new)) }),
                   in: spec.range, step: spec.step) { title }
                .accessibilityValue(Text(verbatim: spec.formatted(value, locale: locale)))
                .modifier(OptionalHint(text: help))
                .accessibilityAction(named: Text("design.slider.reset", bundle: .module)) { reset() }
                .accessibilityActions {
                    if let automatic = spec.automatic {
                        Button { set(automatic.value) } label: { Text("design.slider.setAuto", bundle: .module) }
                    }
                }
        }
    }

    private var thumb: some View {
        let halo: CGFloat = grab != nil ? 5 : hovered && isEnabled ? 4 : 0
        return Circle()
            .fill(isEnabled ? Color.hdr.controlThumb : Color.hdr.inkDisabled)
            .overlay { Circle().strokeBorder(Color.hdr.controlRing) }
            .frame(width: Self.thumb, height: Self.thumb)
            .background {
                Circle().fill(Color.hdr.controlTrack).padding(-halo)
            }
    }

    private func drag(travel: CGFloat, thumbX: CGFloat, isAuto: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                // Secondary clicks and drags belong to the context menu.
                guard isPrimaryPointerEvent else { return }
                if grab == nil {
                    // On the thumb: keep the pointer where it took hold.
                    // Elsewhere: the thumb jumps to the pointer.
                    let offset = drag.startLocation.x - thumbX
                    grab = !isAuto && abs(offset) <= Self.thumb / 2 + 2 ? offset : 0
                    bracket.begin(onEditingChanged)
                }
                let fraction = (drag.location.x - (grab ?? 0) - Self.thumb / 2) / travel
                let new = spec.value(atFraction: fraction)
                if new != value { value = new }
            }
            .updating($live) { _, state, _ in state = true }
            .onEnded { _ in finishDrag() }
    }

    /// Ends the drag if one is open: normal end, cancelled gesture, control
    /// removed or disabled. Idempotent.
    private func finishDrag() {
        grab = nil
        bracket.finish(onEditingChanged)
    }

    private func step(_ steps: Int) { set(spec.stepped(value, by: steps)) }

    private func reset() {
        if let onReset { onReset() } else { set(spec.defaultValue) }
    }

    /// A single write outside any drag: one undo step of its own.
    private func set(_ new: Double) {
        if new != value { value = new }
    }
}
