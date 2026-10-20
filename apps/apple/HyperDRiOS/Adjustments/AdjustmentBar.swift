import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// The iPhone adjustment bar (p7-adjustments §5.3), and its larger form under
/// the canvas of a narrow iPad window (§5.2). One control at a time: the group
/// tabs choose a group, the ring row a control, the ruler sets its value.
///
/// - Everything comes from `AdjustmentPanel`: the groups, which controls are
///   visible, their values and the edits. Numbers get a ring; switches,
///   choices and references go in the settings card at the start of the row,
///   except the group's first choice (the HDR source), which sits above it.
/// - The look group's row lists the LUTs instead of rings ("None" first); the
///   ruler then sets the strength.
/// - Rings: empty at the default, clockwise for positive and anticlockwise for
///   negative; amber for HDR. Double-tap resets, a long press opens the menu.
/// - Tapping the readout types an exact value.
/// - `axis: .vertical` is the landscape form on the right of the canvas.
struct AdjustmentBar: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    var axis: Axis = .horizontal
    /// The narrow iPad's version: group tabs with names, a taller control area.
    var large = false
    var onEditingChanged: (ParameterDeclaration, Bool) -> Void = { _, _ in }

    @State private var group: AdjustmentGroupID = .light
    @State private var selected: String?
    @State private var showingSettings = false
    @State private var typing = false
    @State private var draft = ""
    @State private var resets = 0

    var body: some View {
        let groups = panel.groups(for: recipe)
        let state = groups.first { $0.group == group } ?? groups.first
        let layout = state.map(BarLayout.init)
        let current = layout.flatMap { layout in layout.rings.first { $0.id == selected } ?? layout.rings.first }
        Group {
            if axis == .horizontal {
                VStack(spacing: large ? Space.s3 : Space.s2) {
                    tabs(groups)
                    if let state, let layout { controlArea(state, layout, current) }
                }
            } else {
                HStack(alignment: .top, spacing: Space.s2) {
                    if let state, let layout { controlArea(state, layout, current) }
                    tabs(groups)
                }
            }
        }
        .padding(.vertical, Space.s2)
        .padding(.horizontal, Space.s2)
        .background(.ultraThinMaterial)
        .sensoryFeedback(.impact(weight: .light), trigger: resets)
        .alert(current.map { AdjustmentText.label($0.declaration) } ?? Text(verbatim: ""), isPresented: $typing) {
            if let current { typingActions(current) }
        }
    }

    // MARK: Group tabs

    private func tabs(_ groups: [AdjustmentGroupState]) -> some View {
        let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Space.s1)) : AnyLayout(VStackLayout(spacing: Space.s1))
        return stack {
            ForEach(groups) { state in
                let isCurrent = state.group == group
                Button {
                    group = state.group
                    selected = nil
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: AdjustmentSymbols.group(state.group))
                            .font(.system(size: 17))
                        if large || axis == .horizontal {
                            AdjustmentText.group(state.group)
                                .font(.system(size: large ? 12 : 10, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .frame(minWidth: 52, minHeight: 44)
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .overlay(alignment: .topTrailing) {
                        if state.isModified {
                            Circle().fill(state.group == .hdr ? Color.hdr.amber : Color.hdr.accent).frame(width: 5, height: 5)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controlArea(_ state: AdjustmentGroupState, _ layout: BarLayout, _ current: AdjustmentControl?) -> some View {
        VStack(spacing: Space.s2) {
            if let lead = layout.leadChoice { leadChoice(lead) }
            row(state, layout, current)
            if let current {
                readout(current)
                AdjustmentRuler(control: current,
                                write: { panel.set(current.id, number: $0, in: &recipe) },
                                reset: { panel.reset(current.id, in: &recipe) },
                                onEditingChanged: { onEditingChanged(current.declaration, $0) })
                    .id(current.id)
                    .frame(height: large ? 56 : 44)
                    .disabled(!current.isAvailable)
            }
        }
        .frame(maxWidth: axis == .vertical ? 220 : .infinity)
        .frame(minHeight: large ? 220 : nil, alignment: .top)
    }

    /// The HDR source above the ring row: segments, or a line when the photo
    /// brings its own HDR.
    @ViewBuilder private func leadChoice(_ control: AdjustmentControl) -> some View {
        if control.options.count > 1 {
            ParameterSegmented(AdjustmentText.label(control.declaration),
                               selection: Binding(get: { control.selectedOption ?? "" },
                                                  set: { panel.set(control.id, option: $0, in: &recipe) }),
                               choices: control.options.map {
                                   SegmentedChoice(AdjustmentText.option($0), value: $0.id,
                                                   isEnabled: !control.disabledOptions.contains($0.id))
                               })
            if let note = AdjustmentText.note(for: control) {
                note.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        } else if let only = control.options.first {
            AdjustmentText.option(only)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func row(_ state: AdjustmentGroupState, _ layout: BarLayout, _ current: AdjustmentControl?) -> some View {
        ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Space.s3)) : AnyLayout(VStackLayout(spacing: Space.s2))
            stack {
                if !layout.settings.isEmpty { settingsButton(layout.settings) }
                if let lut = layout.lut {
                    LUTSwatches(control: lut, luts: panel.context.luts) { panel.set(lut.id, reference: $0, in: &recipe) }
                } else {
                    ForEach(layout.rings) { control in
                        ring(control, state: state, isCurrent: control.id == current?.id)
                    }
                }
            }
            .padding(.horizontal, Space.s2)
        }
        .frame(maxHeight: axis == .vertical ? 260 : nil)
    }

    private func settingsButton(_ controls: [AdjustmentControl]) -> some View {
        Button { showingSettings = true } label: {
            VStack(spacing: 2) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                Text("ios.adjust.settings").font(.system(size: 10)).lineLimit(1)
            }
            .frame(minWidth: 56)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSettings) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(controls) { control in
                        AdjustmentRow(recipe: $recipe, control: control, panel: panel, style: .touch)
                    }
                    // Values the card's own rows reveal (a LUT's strength) stay on the ruler.
                }
                .padding(Space.s4)
            }
            .frame(minWidth: 300, maxHeight: 420)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func ring(_ control: AdjustmentControl, state: AdjustmentGroupState, isCurrent: Bool) -> some View {
        AdjustmentRing(control: control, isCurrent: isCurrent, tint: state.group == .hdr ? Color.hdr.amber : Color.hdr.accent)
            .onTapGesture(count: 2) {
                panel.reset(control.id, in: &recipe)
                resets += 1
            }
            .onTapGesture { selected = control.id }
            .contextMenu {
                Button { panel.reset(control.id, in: &recipe) } label: { AdjustmentText.command(.resetToDefault) }
                    .disabled(control.isDefault)
                if control.kind == .floatOrAuto {
                    Button { panel.setAutomatic(control.id, in: &recipe) } label: { AdjustmentText.command(.setAuto) }
                        .disabled(control.isAutomatic)
                }
                Button { panel.reset(group: state.group, in: &recipe) } label: { AdjustmentText.command(.resetGroup) }
                    .disabled(!state.isModified)
            }
    }

    private func readout(_ control: AdjustmentControl) -> some View {
        HStack(spacing: Space.s2) {
            AdjustmentText.label(control.declaration).font(.system(size: 13, weight: .medium))
            Button {
                draft = control.spec?.editableText(control.sliderValue) ?? ""
                typing = true
            } label: {
                Text(verbatim: control.readout())
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(control.isAutomatic ? Color.secondary : Color.primary)
                    .frame(minHeight: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!control.isAvailable)
            .accessibilityHint(Text("ios.adjust.typeHint"))
        }
    }

    @ViewBuilder private func typingActions(_ control: AdjustmentControl) -> some View {
        TextField(text: $draft) { AdjustmentText.label(control.declaration) }
            .keyboardType(.numbersAndPunctuation)
        if control.kind == .floatOrAuto {
            Button { panel.setAutomatic(control.id, in: &recipe) } label: { AdjustmentText.command(.auto) }
        }
        Button(role: .cancel) {} label: { Text("ios.adjust.cancel") }
        Button {
            if let value = control.spec?.parse(draft) { panel.set(control.id, sliderValue: value, in: &recipe) }
        } label: {
            Text("ios.adjust.apply")
        }
    }
}

/// How one group's controls split across the bar.
private struct BarLayout {
    /// Numbers, each with a ring and the ruler.
    let rings: [AdjustmentControl]
    /// The HDR source, above the ring row (§5.3: the group's most important choice).
    let leadChoice: AdjustmentControl?
    /// The LUT reference, drawn as swatches in place of the rings.
    let lut: AdjustmentControl?
    /// Everything else, behind the settings button: the header switch first.
    let settings: [AdjustmentControl]

    init(_ state: AdjustmentGroupState) {
        rings = state.controls.filter { $0.spec != nil }
        let others = state.controls.filter { $0.spec == nil }
        let lead = others.first { $0.id == Recipe.hdrSourceID }
        let lut = others.first { $0.id == Recipe.lookID }
        leadChoice = lead
        self.lut = lut
        settings = (state.headerToggle.map { [$0] } ?? [])
            + others.filter { $0.id != lead?.id && $0.id != lut?.id }
    }
}

/// A control's icon in a ring that shows how far it is from its default.
struct AdjustmentRing: View {
    let control: AdjustmentControl
    let isCurrent: Bool
    let tint: Color

    var body: some View {
        let deviation = control.deviation
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18),
                            style: StrokeStyle(lineWidth: 2.5, dash: control.isAutomatic ? [3, 3] : []))
                Circle()
                    .trim(from: 0, to: abs(deviation))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: deviation < 0 ? -1 : 1)
                Image(systemName: AdjustmentSymbols.control(control.declaration))
                    .font(.system(size: 16))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            }
            .frame(width: 44, height: 44)
            .background(Circle().fill(isCurrent ? Color.white.opacity(0.12) : .clear))
            AdjustmentText.label(control.declaration)
                .font(.system(size: 10))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .frame(width: 64)
        .opacity(control.isAvailable ? 1 : 0.4)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AdjustmentText.label(control.declaration))
        .accessibilityValue(Text(verbatim: control.readout()))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

/// The look group's row: "None" and the LUT library. There are no LUT
/// thumbnails yet, so each swatch is a colour from its content hash.
struct LUTSwatches: View {
    let control: AdjustmentControl
    let luts: [LUTReference]
    let choose: (String?) -> Void

    var body: some View {
        swatch(name: nil, colour: Color.white.opacity(0.08), isCurrent: control.reference == nil) { choose(nil) }
        ForEach(luts, id: \.contentHash) { lut in
            swatch(name: lut.name, colour: Self.colour(lut.contentHash), isCurrent: control.reference == lut.contentHash) {
                choose(lut.contentHash)
            }
        }
    }

    private func swatch(name: String?, colour: Color, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colour)
                    .overlay {
                        if name == nil { Image(systemName: "circle.slash").foregroundStyle(.secondary) }
                    }
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(isCurrent ? Color.hdr.accent : .clear, lineWidth: 2) }
                    .frame(width: 44, height: 44)
                Group {
                    if let name { Text(verbatim: name) } else { AdjustmentText.command(.noLUT) }
                }
                .font(.system(size: 10))
                .lineLimit(1)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    static func colour(_ hash: String) -> Color {
        let seed = hash.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return Color(hue: Double(seed % 360) / 360, saturation: 0.45, brightness: 0.7)
    }
}
