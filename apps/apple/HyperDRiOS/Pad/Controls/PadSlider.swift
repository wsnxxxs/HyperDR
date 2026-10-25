import HyperDRDesign
import SwiftUI
import UIKit

/// The Studio panel's slider (ipad-studio §3.4): the whole 44-point row is
/// the control. A bar fills from the parameter's origin to its value, the name
/// on the left and the value on the right, so a column of them reads like a
/// table and every one is a large target for a finger or the Pencil.
///
/// - Dragging is relative: touching never jumps, and the edge of the fill
///   follows the finger across the row. Moving the finger 40 pt above or below
///   halves the speed, 100 pt quarters it (`FineTune`), with a hint above.
///   The pan starts only for a mostly sideways move, so an upward swipe that
///   starts on a slider still scrolls the panel.
/// - Near the default the value holds on it, with a tick of feedback; a mark
///   at the bottom of the row shows the default when the fill starts elsewhere.
/// - Double-tap resets; tapping the value types an exact one (an Auto
///   parameter offers Auto above the keyboard); a long press opens Reset to
///   Default, Set to Auto, the group's reset and the control's help.
/// - Auto reads as a dashed outline and "Auto · 3.0", its fill at what Auto
///   resolves to.
struct PadSlider: View {
    private let title: Text
    @Binding private var value: Double
    private let spec: ParameterSpec
    private let tint: Color
    /// Colours the bar shows in place of its fill, for a control that moves a colour.
    private let gradient: [Color]?
    private let help: Text?
    private let onEditingChanged: (Bool) -> Void
    private let onResetGroup: (() -> Void)?

    @State private var drag: (start: Double, x: CGFloat)?
    @State private var speed = FineTune.full
    @State private var detentHits = 0
    @State private var typing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale

    init(_ title: Text, value: Binding<Double>, spec: ParameterSpec, tint: Color = Color.hdr.accent, gradient: [Color]? = nil, help: Text? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }, onResetGroup: (() -> Void)? = nil) {
        self.title = title
        _value = value
        self.spec = spec
        self.tint = tint
        self.gradient = gradient
        self.help = help
        self.onEditingChanged = onEditingChanged
        self.onResetGroup = onResetGroup
    }

    private var isAutomatic: Bool { spec.isAutomatic(value) }
    private var isChanged: Bool { !isAutomatic && value != spec.defaultValue }
    /// Where the fill and its edge go: the value, or what Auto resolves to.
    private var shown: Double? { isAutomatic ? spec.automatic?.resolved : value }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let shape = RoundedRectangle(cornerRadius: PadMetrics.rowRadius, style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(Color.white.opacity(drag != nil ? 0.12 : 0.06))
                bar(width: width)
                labels
            }
            .clipShape(shape)
            .overlay {
                if isAutomatic {
                    shape.strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .overlay(alignment: .top) { hint }
            .contentShape(.rect)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
            .gesture(HorizontalPan { phase in pan(phase, width: width) })
            .onTapGesture(count: 2) { write(spec.defaultValue) }
            .contextMenu { menu }
        }
        .frame(height: PadMetrics.row)
        .opacity(isEnabled ? 1 : 0.4)
        .sensoryFeedback(.selection, trigger: detentHits)
        .animation(.smooth(duration: 0.15), value: drag != nil)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { isAutomatic ? spec.range.lowerBound : value },
                                  set: { write(isAutomatic ? spec.resumeValue : spec.snapped($0)) }),
                   in: spec.range, step: spec.step) { title }
                .accessibilityValue(Text(verbatim: spec.formatted(value, locale: locale)))
                .accessibilityAction(named: AdjustmentText.command(.resetToDefault)) { write(spec.defaultValue) }
        }
    }

    // MARK: Drawing

    /// The fill from the origin, the origin's notch on a centred bar, the
    /// default's mark, and the value's edge.
    @ViewBuilder private func bar(width: CGFloat) -> some View {
        let x = { (value: Double) in CGFloat(spec.fraction(of: value)) * width }
        if let gradient, !isAutomatic {
            Rectangle()
                .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                .opacity(0.62)
        } else if let shown {
            let fill = spec.fill(for: shown)
            Rectangle()
                .fill(isChanged ? tint.opacity(0.30) : Color.white.opacity(isAutomatic ? 0.06 : 0.10))
                .frame(width: max(0, CGFloat(fill.upperBound - fill.lowerBound) * width))
                .offset(x: CGFloat(fill.lowerBound) * width)
        }
        if spec.isCentred, shown != spec.origin {
            notch.offset(x: x(spec.origin) - 0.5)
        }
        if !spec.isAutomatic(spec.defaultValue), spec.defaultValue != spec.origin {
            Circle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 4, height: 4)
                .offset(x: x(spec.defaultValue) - 2, y: PadMetrics.row / 2 - 5)
        }
        if let shown {
            edge
                .offset(x: min(max(x(shown) - 1.25, 3), width - 5.5))
        }
    }

    /// The value's edge: a mark at the top and the bottom of the row, clear
    /// of the name and the readout; one line top to bottom while dragged.
    private var edge: some View {
        let color = isChanged ? tint : Color.white.opacity(isAutomatic ? 0.4 : 0.6)
        return VStack(spacing: 0) {
            Capsule().fill(color).frame(width: 2.5, height: drag != nil ? PadMetrics.row : 9)
            if drag == nil {
                Spacer(minLength: 0)
                Capsule().fill(color).frame(width: 2.5, height: 9)
            }
        }
        .frame(height: PadMetrics.row)
    }

    /// Two short marks at the origin of a centred bar, top and bottom.
    private var notch: some View {
        VStack(spacing: 0) {
            Rectangle().frame(width: 1, height: 6)
            Spacer(minLength: 0)
            Rectangle().frame(width: 1, height: 6)
        }
        .foregroundStyle(Color.white.opacity(0.28))
        .frame(height: PadMetrics.row)
    }

    private var labels: some View {
        HStack(spacing: Space.s2) {
            title
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Space.s2)
            readout
        }
        .padding(.horizontal, PadMetrics.inset)
    }

    private static let readoutFont = Font.subheadline.weight(.medium).monospacedDigit()

    @ViewBuilder private var readout: some View {
        if typing {
            TextField(text: $draft) { title }
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .multilineTextAlignment(.trailing)
                .font(Self.readoutFont)
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
                .frame(width: 88)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
                .onSubmit(commitTyped)
                .onChange(of: fieldFocused) { _, focused in if !focused { commitTyped() } }
                .toolbar {
                    if let automatic = spec.automatic {
                        ToolbarItemGroup(placement: .keyboard) {
                            Button { write(automatic.value); typing = false } label: { AdjustmentText.command(.auto) }
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
                    .foregroundStyle(isAutomatic ? Color.secondary : isChanged ? tint : Color.primary)
                    .contentTransition(.numericText())
                    .frame(minWidth: 52, minHeight: PadMetrics.row, alignment: .trailing)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("ios.adjust.typeHint"))
        }
    }

    @ViewBuilder private var hint: some View {
        if drag != nil, let hint = speed.hint {
            hint
                .font(.caption2.weight(.medium))
                .padding(.horizontal, Space.s2)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: .capsule)
                .fixedSize()
                .offset(y: -26)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// The control's help heads the menu: the long press is where a touch
    /// screen asks what a control does.
    private var menu: some View {
        Section {
            Button { write(spec.defaultValue) } label: {
                Label { AdjustmentText.command(.resetToDefault) } icon: { Image(systemName: "arrow.uturn.backward") }
            }
            .disabled(value == spec.defaultValue)
            if let automatic = spec.automatic {
                Button { write(automatic.value) } label: {
                    Label { AdjustmentText.command(.setAuto) } icon: { Image(systemName: "wand.and.sparkles") }
                }
                .disabled(isAutomatic)
            }
            if let onResetGroup {
                Button(action: onResetGroup) {
                    Label { AdjustmentText.command(.resetGroup) } icon: { Image(systemName: "arrow.counterclockwise") }
                }
            }
        } header: {
            help ?? title
        }
    }

    // MARK: Dragging

    private func pan(_ phase: HorizontalPan.Phase, width: CGFloat) {
        switch phase {
        case .began(let location):
            guard isEnabled else { return }
            typing = false
            onEditingChanged(true)
            // From Auto the drag starts where Auto resolves to.
            let start = isAutomatic ? (spec.automatic?.resolved ?? spec.resumeValue) : value
            drag = (start, location.x)
            speed = .full
        case .changed(let location):
            guard var anchor = drag else { return }
            // A new speed applies from where the finger is now, not to the whole drag.
            let newSpeed = FineTune(verticalDistance: location.y - PadMetrics.row / 2)
            if newSpeed != speed {
                speed = newSpeed
                anchor = (isAutomatic ? anchor.start : value, location.x)
                drag = anchor
                return
            }
            write(spec.dragged(from: anchor.start, by: Double(location.x - anchor.x),
                               length: Double(max(width, 1)), speed: speed.factor))
        case .ended:
            guard drag != nil else { return }
            drag = nil
            speed = .full
            onEditingChanged(false)
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

/// A one-finger pan that begins only when the finger first moves more across
/// than up or down, so the panel's scroll view keeps vertical swipes. Reports
/// locations in the view's own space.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    enum Phase {
        case began(CGPoint)
        case changed(CGPoint)
        case ended
    }

    let action: (Phase) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began: action(.began(location))
        case .changed: action(.changed(location))
        case .ended, .cancelled, .failed: action(.ended)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
