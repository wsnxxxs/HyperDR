import SwiftUI

/// An inspector slider row (CSS `.field--range`): the title, a readout that is
/// also where an exact value is typed, and the track.
///
/// - The track fills from the spec's origin: from the lower bound, or from
///   the centre for a signed parameter, whose zero is marked.
/// - Drag or click anywhere on the track; a click on the thumb grabs it
///   where it is. Double-click, or Reset to Default in the context menu,
///   returns to the default.
/// - With keyboard navigation on, the track takes focus; ← → ↑ ↓ step it,
///   with Shift ten steps.
/// - The readout shows the formatted value until focused, then the bare
///   number. Return commits and stays, Escape abandons, ↑ ↓ step.
/// - VoiceOver sees a system slider with the formatted value, the
///   increment/decrement actions, and Reset to Default.
///
/// Bind one value per control (S12): the row reads nothing else, so a change
/// redraws only this row. `onEditingChanged` brackets each drag, keyboard
/// step, typed commit and reset, for coalescing undo.
public struct ParameterSlider: View {
    private let title: LocalizedStringKey
    @Binding private var value: Double
    private let spec: ParameterSpec
    private let help: LocalizedStringKey?
    private let onEditingChanged: (Bool) -> Void

    public init(_ title: LocalizedStringKey, value: Binding<Double>, spec: ParameterSpec,
                help: LocalizedStringKey? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.spec = spec
        self.help = help
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: 10) {
                FieldTitle(title: title, help: help)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                ParameterReadout(title: title, value: $value, spec: spec, onEditingChanged: onEditingChanged)
            }
            .frame(minHeight: 22)
            ParameterTrack(title: title, value: $value, spec: spec, onEditingChanged: onEditingChanged)
        }
    }
}

/// The 12 pt title of a field (CSS `.field-title b`); the help text, if any,
/// is its tooltip.
struct FieldTitle: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let text = Text(title)
            .font(.hdr.caption)
            .foregroundStyle(isEnabled ? Color.hdr.ink : Color.hdr.inkDisabled)
            .lineLimit(1)
        if let help { text.help(Text(help)) } else { text }
    }
}

// MARK: - Readout

/// The value field (CSS `.field-value`): 80 × 24, sunken, monospaced,
/// right-aligned.
private struct ParameterReadout: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let spec: ParameterSpec
    let onEditingChanged: (Bool) -> Void

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

    var body: some View {
        TextField(text: Binding(get: { focused ? draft : spec.formatted(value) },
                                set: { new in if new != draft { draft = new; typed = true } }),
                  selection: $selection) { Text(title) }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(.hdr.mono())
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(isEnabled ? Color.hdr.inkStrong : Color.hdr.inkDisabled)
            .padding(.horizontal, 7)
            .frame(width: 80, height: 24)
            .background(focused ? Color.hdr.surfaceCard : Color.hdr.surfaceSunken, in: .rect(cornerRadius: Radius.xs))
            .overlay {
                // Focus: the accent border plus a 1 pt halo (CSS box-shadow 0 0 0 1px).
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(focused ? Color.hdr.focus : hovered && isEnabled ? Color.hdr.lineStrong : Color.hdr.line,
                                  lineWidth: focused ? 2 : 1)
            }
            .focused($focused)
            .focusEffectDisabled()
            .onHover { hovered = $0 }
            .onChange(of: focused) { _, now in now ? beginTyping() : commit() }
            .onChange(of: value) { if focused { beginTyping() } }
            .onSubmit {
                // Commit and stay, with the value as stored, so another number
                // can be typed straight away.
                commit()
                beginTyping()
            }
            .onExitCommand {
                // Escape abandons what was typed and leaves the field.
                typed = false
                focused = false
            }
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let steps = (press.key == .upArrow ? 1 : -1) * (press.modifiers.contains(.shift) ? 10 : 1)
                set(spec.stepped(typed ? spec.parse(draft) ?? value : value, by: steps))
                beginTyping()
                return .handled
            }
            // labelsHidden() drops the label from accessibility too.
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text("design.slider.valueHint", bundle: .module))
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

    private func set(_ new: Double) {
        guard new != value else { return }
        onEditingChanged(true)
        value = new
        onEditingChanged(false)
    }
}

// MARK: - Track

/// The track (CSS `.field input[type="range"]`): a 3 pt line, the fill from
/// the origin, a 13 pt thumb with a halo on hover and while dragging.
private struct ParameterTrack: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let spec: ParameterSpec
    let onEditingChanged: (Bool) -> Void

    @State private var hovered = false
    @State private var grab: CGFloat?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    static let thumb: CGFloat = 13
    static let height: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(width - Self.thumb, 1)
            let x = { (fraction: Double) in Self.thumb / 2 + travel * fraction }
            let fill = spec.fill(for: value)
            let thumbX = x(spec.fraction(of: value))
            let mid = Self.height / 2
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.hdr.controlTrack)
                    .frame(width: width, height: 3)
                    .offset(y: mid - 1.5)
                Rectangle()
                    .fill(isEnabled ? Color.hdr.controlFill : Color.hdr.controlTrack)
                    .frame(width: max(x(fill.upperBound) - x(fill.lowerBound), 0), height: 3)
                    .offset(x: x(fill.lowerBound), y: mid - 1.5)
                if spec.isCentred {
                    // The zero of a signed parameter.
                    Rectangle()
                        .fill(Color.hdr.lineStrong)
                        .frame(width: 1, height: 9)
                        .offset(x: x(spec.fraction(of: spec.origin)) - 0.5, y: mid - 4.5)
                }
                thumb.offset(x: thumbX - Self.thumb / 2, y: mid - Self.thumb / 2)
            }
            .frame(width: width, height: Self.height)
            .contentShape(.rect)
            .gesture(drag(travel: travel, thumbX: thumbX))
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
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            let up = press.key == .rightArrow || press.key == .upArrow
            step((up ? 1 : -1) * (press.modifiers.contains(.shift) ? 10 : 1))
            return .handled
        }
        .contextMenu {
            Button { reset() } label: { Text("design.slider.reset", bundle: .module) }
                .disabled(value == spec.defaultValue)
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { new in set(spec.snapped(new)) }),
                   in: spec.range, step: spec.step) { Text(title) }
                .accessibilityValue(Text(verbatim: spec.formatted(value)))
                .accessibilityAction(named: Text("design.slider.reset", bundle: .module)) { reset() }
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

    private func drag(travel: CGFloat, thumbX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                // Secondary clicks and drags belong to the context menu.
                guard isPrimaryPointerEvent else { return }
                if grab == nil {
                    // On the thumb: keep the pointer where it took hold.
                    // Elsewhere: the thumb jumps to the pointer.
                    let offset = drag.startLocation.x - thumbX
                    grab = abs(offset) <= Self.thumb / 2 + 2 ? offset : 0
                    onEditingChanged(true)
                }
                let fraction = (drag.location.x - (grab ?? 0) - Self.thumb / 2) / travel
                let new = spec.value(atFraction: fraction)
                if new != value { value = new }
            }
            .onEnded { _ in
                // Nothing began (a secondary click): nothing to end.
                guard grab != nil else { return }
                grab = nil
                onEditingChanged(false)
            }
    }

    private func step(_ steps: Int) { set(spec.stepped(value, by: steps)) }

    private func reset() { set(spec.defaultValue) }

    private func set(_ new: Double) {
        guard new != value else { return }
        onEditingChanged(true)
        value = new
        onEditingChanged(false)
    }
}
