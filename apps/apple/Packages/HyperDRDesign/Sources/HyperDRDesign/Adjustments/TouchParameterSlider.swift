import SwiftUI

/// The touch version of `ParameterSlider` for the iPad sidebar (p7-adjustments
/// §5.2, §5.4): a title row over a 22 pt thumb's track, together at least
/// 44 pt tall, and no hover. A value moved off its default reads in the
/// accent, so a tab's changes can be found at a glance.
///
/// - Dragging moves the value by the finger's travel; moving the finger 40 pt
///   above or below the track halves the speed, 100 pt quarters it, with a
///   hint above the track while that lasts. Touching the track away from the
///   thumb first jumps there.
/// - Near the default the value stops on it (2 pt), with a selection haptic
///   when it gets there.
/// - Tapping the readout types an exact value; an Auto parameter offers Auto
///   above the keyboard.
/// - Double-tap resets; a long press on the title opens Reset to Default, Set
///   to Auto and, when given, the group's reset.
public struct TouchParameterSlider: View {
    private let title: Text
    @Binding private var value: Double
    private let spec: ParameterSpec
    private let help: Text?
    private let onEditingChanged: (Bool) -> Void
    private let onResetGroup: (() -> Void)?

    @State private var dragStart: (value: Double, x: CGFloat)?
    @State private var speed = FineTune.full
    @State private var detentHits = 0
    @State private var typing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale

    static let thumb: CGFloat = 22
    /// The title row; with the track below it the row is well over 44 pt.
    static let rowHeight: CGFloat = 34

    public init(_ title: Text, value: Binding<Double>, spec: ParameterSpec, help: Text? = nil,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }, onResetGroup: (() -> Void)? = nil) {
        self.title = title
        _value = value
        self.spec = spec
        self.help = help
        self.onEditingChanged = onEditingChanged
        self.onResetGroup = onResetGroup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                title.font(.hdr.control).foregroundStyle(isEnabled ? Color.hdr.ink : Color.hdr.inkDisabled)
                if let help { InfoButton(help: help) }
                Spacer(minLength: 0)
                readout
            }
            .frame(minHeight: Self.rowHeight)
            .contentShape(.rect)
            .contextMenu { menu }
            track
        }
        .padding(.bottom, Space.s1)
        .sensoryFeedback(.selection, trigger: detentHits)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { spec.isAutomatic(value) ? spec.range.lowerBound : value },
                                  set: { write(spec.isAutomatic(value) ? spec.resumeValue : spec.snapped($0)) }),
                   in: spec.range, step: spec.step) { title }
                .accessibilityValue(Text(verbatim: spec.formatted(value, locale: locale)))
                .accessibilityAction(named: Text("design.slider.reset", bundle: .module)) { write(spec.defaultValue) }
        }
    }

    private static let readoutFont = Font.system(size: TypeScale.Size.control, weight: .medium).monospacedDigit()

    @ViewBuilder private var readout: some View {
        if typing {
            TextField(text: $draft) { title }
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .multilineTextAlignment(.trailing)
                .font(Self.readoutFont)
                .frame(width: 96)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onSubmit(commitTyped)
                .onChange(of: fieldFocused) { _, focused in if !focused { commitTyped() } }
                .toolbar {
                    if let automatic = spec.automatic {
                        ToolbarItemGroup(placement: .keyboard) {
                            Button { write(automatic.value); typing = false } label: {
                                Text("design.slider.auto", bundle: .module)
                            }
                            Spacer()
                        }
                    }
                }
        } else {
            Button {
                draft = spec.editableText(value)
                typing = true
            } label: {
                Text(verbatim: spec.formatted(value, locale: locale))
                    .font(Self.readoutFont)
                    .foregroundStyle(spec.isAutomatic(value) ? Color.hdr.inkMuted
                                     : value != spec.defaultValue ? Color.hdr.accent : Color.hdr.inkStrong)
                    .frame(minWidth: 64, minHeight: 44, alignment: .trailing)
                    .padding(.vertical, -5)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("design.slider.valueHint", bundle: .module))
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(width - Self.thumb, 1)
            let x = { (fraction: Double) in Self.thumb / 2 + travel * fraction }
            let isAuto = spec.isAutomatic(value)
            let fill = spec.fill(for: value)
            let mid = Self.thumb / 2
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.hdr.controlTrack)
                    .frame(width: width, height: 4)
                    .offset(y: mid - 2)
                if !isAuto {
                    Rectangle()
                        .fill(isEnabled ? Color.hdr.controlFill : Color.hdr.controlTrack)
                        .frame(width: max(x(fill.upperBound) - x(fill.lowerBound), 0), height: 4)
                        .offset(x: x(fill.lowerBound), y: mid - 2)
                    if let defaultFraction = defaultFraction {
                        Rectangle()
                            .fill(Color.hdr.lineStrong)
                            .frame(width: 1, height: 10)
                            .offset(x: x(defaultFraction) - 0.5, y: mid - 5)
                    }
                    Circle()
                        .fill(isEnabled ? Color.hdr.controlThumb : Color.hdr.inkDisabled)
                        .overlay { Circle().strokeBorder(Color.hdr.controlRing) }
                        .frame(width: Self.thumb, height: Self.thumb)
                        .offset(x: x(spec.fraction(of: value)) - Self.thumb / 2)
                }
            }
            .overlay(alignment: .top) {
                if dragStart != nil, let hint = speed.hint {
                    hint
                        .font(.hdr.caption)
                        .padding(.horizontal, Space.s2)
                        .padding(.vertical, 2)
                        .background(Color.hdr.surfaceCard, in: .capsule)
                        .offset(y: -28)
                        .fixedSize()
                }
            }
            .frame(width: width, height: Self.thumb)
            .contentShape(.rect)
            .gesture(drag(travel: travel, thumbX: x(spec.fraction(of: value)), isAuto: isAuto))
            .simultaneousGesture(TapGesture(count: 2).onEnded { write(spec.defaultValue) })
        }
        .frame(height: Self.thumb)
    }

    /// The default's position, marked when it is not the fill's origin.
    private var defaultFraction: Double? {
        guard !spec.isAutomatic(spec.defaultValue), spec.defaultValue != spec.origin else { return nil }
        return spec.fraction(of: spec.defaultValue)
    }

    private func drag(travel: CGFloat, thumbX: CGFloat, isAuto: Bool) -> some Gesture {
        // Not from the first point: in the sidebar's scroll view, a swipe that
        // starts on a track and goes mostly up or down is a scroll.
        DragGesture(minimumDistance: 6)
            .onChanged { drag in
                if dragStart == nil {
                    guard abs(drag.translation.width) >= abs(drag.translation.height) else { return }
                    onEditingChanged(true)
                    // Away from the thumb (or from Auto) the value first jumps under the finger.
                    let onThumb = !isAuto && abs(drag.startLocation.x - thumbX) <= Self.thumb
                    let start = onThumb ? value : spec.value(atFraction: (drag.startLocation.x - Self.thumb / 2) / travel)
                    dragStart = (start, drag.startLocation.x)
                }
                guard let anchor = dragStart else { return }
                // A new speed applies from where the finger is now, not to the whole drag.
                let newSpeed = FineTune(verticalDistance: drag.location.y - Self.thumb / 2)
                if newSpeed != speed {
                    speed = newSpeed
                    dragStart = (value, drag.location.x)
                    return
                }
                write(spec.dragged(from: anchor.value, by: Double(drag.location.x - anchor.x),
                                   length: Double(travel), speed: speed.factor))
            }
            .onEnded { _ in
                guard dragStart != nil else { return }
                dragStart = nil
                speed = .full
                onEditingChanged(false)
            }
    }

    @ViewBuilder private var menu: some View {
        Button { write(spec.defaultValue) } label: { Text("design.slider.reset", bundle: .module) }
            .disabled(value == spec.defaultValue)
        if let automatic = spec.automatic {
            Button { write(automatic.value) } label: { Text("design.slider.setAuto", bundle: .module) }
                .disabled(spec.isAutomatic(value))
        }
        if let onResetGroup {
            Button(action: onResetGroup) { Text("group.reset", bundle: .module) }
        }
    }

    private func commitTyped() {
        guard typing else { return }
        typing = false
        if let new = spec.parse(draft) { write(new) }
    }

    private func write(_ new: Double) {
        guard new != value else { return }
        if !spec.isAutomatic(spec.defaultValue), new == spec.defaultValue { detentHits += 1 }
        value = new
    }
}

extension FineTune {
    /// What the slowed-down speed is called while a drag lasts; nil at full speed.
    public var hint: Text? {
        switch self {
        case .full: return nil
        case .half: return Text("design.adjust.fineTune.half", bundle: .module)
        case .quarter: return Text("design.adjust.fineTune.quarter", bundle: .module)
        }
    }
}

/// The ⓘ after a control's title on touch screens: the help in a small popover
/// instead of a tooltip (p7-adjustments §5.2).
struct InfoButton: View {
    let help: Text
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Color.hdr.inkMuted)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .popover(isPresented: $showing) {
            help.font(.hdr.caption).padding(Space.s4).frame(maxWidth: 280).presentationCompactAdaptation(.popover)
        }
    }
}
