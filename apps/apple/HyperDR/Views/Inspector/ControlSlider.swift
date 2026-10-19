import SwiftUI
import HyperDRDesign

/// One continuous control of the editor as a `ParameterSlider`: the title,
/// help, range, step, format and Auto state come from the control's own
/// description, the value from its `ControlValue` and every write goes to the
/// model. The row reads only its own control (S12), so dragging one slider
/// redraws one row.
struct ControlSlider: View {
    let model: EditorModel
    let key: String

    @Environment(\.locale) private var locale

    var body: some View {
        let control = model.control(key)
        if control.isVisible {
            ParameterSlider(
                LocalizedStringKey(control.spec.labelKey),
                value: Binding(get: { control.value }, set: { model.adjust(key, to: $0) }),
                spec: ParameterSpecFactory.spec(for: control, locale: locale),
                help: control.spec.helpKey.map { LocalizedStringKey($0) },
                mask: mask(for: control),
                readoutHelp: ParameterSpecFactory.ceiling(of: control).map {
                    Text("adjust.rangeCeiling \($0.formatted(.number.precision(.fractionLength(1)).locale(locale)))")
                },
                onEditingChanged: { editing in
                    if editing { model.beginAdjusting(key) } else { model.endAdjusting(key) }
                },
                onReset: { model.resetControl(key) })
            .disabled(!control.isEnabled)
        }
    }

    /// A control with a mask asks the model for it while the pointer or the
    /// keyboard is on the row, and gives it back only if it is still its own:
    /// the next row may already have taken it.
    private func mask(for control: ControlValue) -> ParameterMaskLink? {
        guard control.spec.hasMask else { return nil }
        return ParameterMaskLink(isShowing: model.maskKey == key) { showing in
            if showing { model.showMask(for: key) } else if model.maskKey == key { model.hideMask() }
        }
    }
}

/// How a control's description becomes the design package's `ParameterSpec`.
enum ParameterSpecFactory {
    /// `locale` is the one the readout is written in.
    static func spec(for control: ControlValue, locale: Locale) -> ParameterSpec {
        let description = control.spec
        let effective = control.range
        // Auto is a state of its own below the range, not a position on it.
        let range = description.allowsAuto ? max(0, effective.lowerBound)...effective.upperBound : effective
        let origin: Double? = description.format == .ev || description.format == .signed ? 0 : nil
        return ParameterSpec(range: range, step: description.step, defaultValue: control.defaultValue,
                             origin: origin, format: format(description.format, locale: locale),
                             automatic: description.allowsAuto ? ParameterAutomatic() : nil)
    }

    /// The effective upper end of the range, when the output format holds it
    /// below the control's own (the "limit for this format" tooltip).
    static func ceiling(of control: ControlValue) -> Double? {
        control.range.upperBound < control.spec.range.upperBound - 1e-9 ? control.range.upperBound : nil
    }

    static func format(_ format: ControlFormat, locale: Locale) -> ParameterFormat {
        switch format {
        case .ev: .signed(fractionDigits: 2, suffix: "EV")
        case .signed: .signed(fractionDigits: 2)
        case .percent, .percentOrAuto: .percent
        case .fixed2: .number(fractionDigits: 2)
        case .integer: .number(fractionDigits: 0)
        case .stops1, .stopsOrAuto1:
            ParameterFormat { value in
                AppStrings.format("unit.stops %@", locale: locale,
                                  value.formatted(.number.precision(.fractionLength(1)).locale(locale)))
            }
        }
    }
}
