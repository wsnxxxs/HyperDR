import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// One adjustment group's controls in the Studio panel (HDR, light, colour,
/// detail), generated from `AdjustmentPanel` like every other host: numbers
/// as `PadSlider`s, switches as switch rows, small choices as segments and
/// the rest as menus, in declared order.
///
/// - HDR's source leads, across the panel, with what AI does under it; when
///   the device cannot run the model, a line says so.
/// - With HDR switched off its controls stay in place, grey and locked, under
///   a line saying what off means, so turning it back on never moves them.
/// - A switch the photo does not offer (lens correction without a profile)
///   stays where it would be, unavailable, with why.
struct PadGroupControls: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    let group: AdjustmentGroupID
    var columns = 1
    var onEditingChanged: (ParameterDeclaration, Bool) -> Void = { _, _ in }
    var onReset: (AdjustmentReset) -> Void = { _ in }
    /// Why AI cannot be chosen, when it cannot.
    var aiUnavailable: Text?
    /// The white balance eyedropper, when the host offers one.
    @Environment(\.whiteBalancePicking) private var whiteBalance

    var body: some View {
        let actual = panel.group(group: group, in: recipe)
        let off = actual?.isSwitchedOff ?? false
        if let state = off ? switchedOn() ?? actual : actual {
            let lead = state.controls.first { $0.id == Recipe.hdrSourceID }
            let rows = state.controls.filter { $0.id != lead?.id && $0.kind != .curve }
            let curves = state.controls.filter { $0.kind == .curve }
            VStack(alignment: .leading, spacing: 12) {
                if let lead {
                    VStack(alignment: .leading, spacing: PadMetrics.rowSpacing) {
                        source(lead)
                        if let aiUnavailable { PadNote(text: aiUnavailable, symbol: "exclamationmark.circle") }
                    }
                    .disabled(off)
                }
                PadRows(columns: columns) {
                    ForEach(rows) { control in
                        row(control)
                    }
                    ForEach(state.unsupported, id: \.id) { declaration in
                        PadUnsupportedRow(declaration: declaration)
                    }
                }
                .disabled(off)
                // The tone curve's plot takes the panel's width, below the rows.
                ForEach(curves) { control in
                    ToneCurveSection(recipe: $recipe, control: control, panel: panel, style: .touch,
                                     onEditingChanged: onEditingChanged)
                        .disabled(off)
                }
            }
            .saturation(off ? 0 : 1)
            .animation(.smooth(duration: 0.2), value: off)
        }
    }

    private var tint: Color { group == .hdr ? Color.hdr.amber : Color.hdr.accent }

    /// The group as it reads with its switch on: the panel hides the
    /// controls of a switched-off group; the Studio shows them locked.
    private func switchedOn() -> AdjustmentGroupState? {
        guard let power = panel.group(group: group, in: recipe)?.headerToggle else { return nil }
        var on = recipe
        panel.set(power.id, isOn: true, in: &on)
        return panel.group(group: group, in: on)
    }

    /// HDR's source: segments, or a line when the photo brings its own HDR.
    @ViewBuilder private func source(_ control: AdjustmentControl) -> some View {
        if control.options.count > 1 {
            PadSegments(options: control.options.map {
                PadSegments.Option(value: $0.id, label: AdjustmentText.option($0),
                                   isEnabled: !control.disabledOptions.contains($0.id))
            }, selection: control.selectedOption ?? "", tint: Color.hdr.amber) {
                panel.set(control.id, option: $0, in: &recipe)
            }
            .accessibilityLabel(AdjustmentText.label(control.declaration))
        } else if let only = control.options.first {
            PadNote(text: AdjustmentText.option(only), symbol: "sun.max")
        }
    }

    @ViewBuilder private func row(_ control: AdjustmentControl) -> some View {
        let declaration = control.declaration
        switch control.kind {
        case .float, .floatOrAuto:
            if let spec = control.spec {
                let slider = PadSlider(AdjustmentText.label(declaration),
                                       value: Binding(get: { control.sliderValue },
                                                      set: { panel.set(control.id, sliderValue: $0, in: &recipe) }),
                                       spec: spec, tint: tint, help: AdjustmentText.help(declaration),
                                       onEditingChanged: { onEditingChanged(declaration, $0) },
                                       onResetGroup: control.group == group ? { onReset(.group(control.group)) } : nil)
                    .disabled(!control.isAvailable)
                if WhiteBalancePicking.offers(control.id), let whiteBalance {
                    // The eyedropper stands beside the temperature bar, a finger's size.
                    VStack(alignment: .leading, spacing: Space.s1) {
                        HStack(spacing: Space.s2) {
                            slider
                            WhiteBalancePickButton(whiteBalance, size: PadMetrics.row)
                                .disabled(!control.isAvailable)
                        }
                        if let notice = whiteBalance.notice {
                            WhiteBalanceNoticeLine(notice).padding(.horizontal, 4)
                        }
                    }
                } else if control.id == "tone.exposure" {
                    // A film on takes its own exposure; the note says which, and leads to it.
                    VStack(alignment: .leading, spacing: Space.s1) {
                        slider
                        FilmExposureNote(recipe: recipe, panel: panel).padding(.horizontal, 4)
                    }
                } else {
                    slider
                }
            }
        case .bool:
            PadToggleRow(title: AdjustmentText.label(declaration),
                         isOn: Binding(get: { control.isOn }, set: { panel.set(control.id, isOn: $0, in: &recipe) }),
                         symbol: AdjustmentSymbols.control(declaration),
                         tint: group == .hdr ? Color.hdr.amber : Color.hdr.accentFill)
                .disabled(!control.isAvailable)
        case .choice:
            PadChoiceRow(control: control) { panel.set(control.id, option: $0, in: &recipe) }
        case .curve:
            EmptyView()
        case .reference:
            PadMenuRow(title: AdjustmentText.label(declaration),
                       value: Text(verbatim: panel.context.models.first { $0.id == control.reference }?.name ?? "")) {
                Picker(selection: Binding(get: { control.reference ?? "" },
                                          set: { panel.set(control.id, reference: $0.isEmpty ? nil : $0, in: &recipe) })) {
                    ForEach(panel.context.models) { model in
                        Text(verbatim: model.name).tag(model.id)
                    }
                } label: {
                    AdjustmentText.label(declaration)
                }
            }
        }
    }
}

/// A choice as a menu row, its options under their headings (the LUT spaces
/// as display, HDR and camera Log spaces).
struct PadChoiceRow: View {
    let control: AdjustmentControl
    let choose: (String) -> Void

    var body: some View {
        let selected = control.options.first { $0.id == control.selectedOption }
        PadMenuRow(title: AdjustmentText.label(control.declaration),
                   value: selected.map(AdjustmentText.option) ?? Text(verbatim: "")) {
            Picker(selection: Binding(get: { control.selectedOption ?? "" }, set: { choose($0) })) {
                ForEach(AdjustmentText.optionSections(control)) { section in
                    Section {
                        ForEach(section.options, id: \.id) { option in
                            AdjustmentText.option(option).tag(option.id)
                                .disabled(control.disabledOptions.contains(option.id))
                        }
                    } header: {
                        section.title
                    }
                }
            } label: {
                AdjustmentText.label(control.declaration)
            }
        }
    }
}

/// A switch this photo does not offer, where it would be: its name, and in
/// the switch's place why not.
struct PadUnsupportedRow: View {
    let declaration: ParameterDeclaration

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: AdjustmentSymbols.control(declaration))
                .font(.subheadline)
                .frame(width: 20)
            AdjustmentText.label(declaration).font(.subheadline).lineLimit(1)
            Spacer(minLength: Space.s2)
            AdjustmentText.noProfile.font(.footnote).lineLimit(1)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, PadMetrics.inset)
        .frame(height: PadMetrics.row)
        .overlay {
            RoundedRectangle(cornerRadius: PadMetrics.rowRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .accessibilityElement(children: .combine)
    }
}
