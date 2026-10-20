import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// What the dock shows: one adjustment group, or the export's frame.
enum EditorPane: Hashable {
    case group(AdjustmentGroupID)
    case frame
}

/// The tabs at the foot of the dock (p7-adjustments §5.3): the adjustment
/// groups in one glass capsule and the frame in a glass circle of its own,
/// since it shapes the export rather than the photo. A dot marks a group with
/// changes and the frame while one is on. Holding a group's tab shows the
/// photo without that group, until it is let go (§5.4).
struct EditorTabs: View {
    let groups: [AdjustmentGroupState]
    @Binding var pane: EditorPane
    let frameOn: Bool
    var axis: Axis = .horizontal
    var large = false
    var onBypass: (AdjustmentGroupID, Bool) -> Void = { _, _ in }
    @Namespace private var selection

    var body: some View {
        let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Space.s2)) : AnyLayout(VStackLayout(spacing: Space.s2))
        GlassEffectContainer(spacing: Space.s2) {
            stack {
                let inner = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                inner {
                    ForEach(groups) { state in
                        tab(.group(state.group), symbol: AdjustmentSymbols.group(state.group),
                            label: AdjustmentText.group(state.group), marked: state.isModified,
                            mark: state.group == .hdr ? Color.hdr.amber : Color.hdr.accent)
                            .onLongPressGesture(minimumDuration: 0.35) {
                                onBypass(state.group, true)
                            } onPressingChanged: { pressing in
                                if !pressing { onBypass(state.group, false) }
                            }
                    }
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
                tab(.frame, symbol: "photo.artframe", label: Text("ios.frame.title"), marked: frameOn, mark: .white)
                    .padding(4)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .animation(.smooth(duration: 0.25), value: pane)
        .sensoryFeedback(.selection, trigger: pane)
    }

    private func tab(_ target: EditorPane, symbol: String, label: Text, marked: Bool, mark: Color) -> some View {
        let isCurrent = pane == target
        return Button {
            // The controls change at once; only the highlight slides.
            pane = target
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: large ? 18 : 17, weight: isCurrent ? .semibold : .regular))
                    .symbolVariant(isCurrent ? .fill : .none)
                if large { label.font(.system(size: 11, weight: .medium)).lineLimit(1) }
            }
            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            .frame(width: large ? 64 : 46, height: large ? 50 : 40)
            .background {
                if isCurrent {
                    Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "tab", in: selection)
                }
            }
            .overlay(alignment: .topTrailing) {
                if marked {
                    Circle().fill(mark).frame(width: 5, height: 5).padding(large ? 9 : 7)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// One group's controls on the dock (p7-adjustments §5.3): one control at a
/// time. The ring row chooses a control, the ruler sets its value.
///
/// - Everything comes from `AdjustmentPanel`: the groups, which controls are
///   visible, their values and the edits. Numbers get a ring; switches,
///   choices and references go in the options card at the start of the row,
///   except the group's first choice (the HDR source), which sits above it.
/// - The look group's row lists the LUTs instead of rings ("None" first, the
///   library last); the ruler then sets the strength.
/// - Rings: empty at the default, clockwise for positive and anticlockwise for
///   negative; amber for HDR. Double-tap resets, a long press opens the menu.
/// - Tapping the readout types an exact value.
/// - `axis: .vertical` is the standing column on the right in landscape.
struct AdjustmentControls: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    let state: AdjustmentGroupState
    var axis: Axis = .horizontal
    var large = false
    var onEditingChanged: (ParameterDeclaration, Bool) -> Void = { _, _ in }
    /// Performs a group reset itself, so the host's undo names it.
    var onReset: ((AdjustmentReset) -> Void)?
    /// Opens the LUT library, from the end of the look group's row.
    var onLUTLibrary: () -> Void = {}

    /// The chosen control of each group, kept while switching groups.
    @State private var selected: [AdjustmentGroupID: String] = [:]
    @State private var showingOptions = false
    @State private var typing = false
    @State private var draft = ""
    @State private var resets = 0

    var body: some View {
        let layout = BarLayout(state)
        let current = layout.rings.first { $0.id == selected[state.group] } ?? layout.rings.first
        let stack = axis == .horizontal ? AnyLayout(VStackLayout(spacing: large ? Space.s3 : Space.s2))
            : AnyLayout(VStackLayout(alignment: .center, spacing: Space.s2))
        stack {
            if let lead = layout.leadChoice { leadChoice(lead).padding(.horizontal, Space.s4) }
            if let current {
                readout(current)
            } else {
                Color.clear.frame(height: 28)
            }
            row(layout, current)
            if let current {
                AdjustmentRuler(control: current,
                                write: { panel.set(current.id, number: $0, in: &recipe) },
                                reset: { panel.reset(current.id, in: &recipe) },
                                onEditingChanged: { onEditingChanged(current.declaration, $0) })
                    .id(current.id)
                    .frame(height: large ? 52 : 40)
                    .disabled(!current.isAvailable)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: resets)
        .alert(current.map { AdjustmentText.label($0.declaration) } ?? Text(verbatim: ""), isPresented: $typing) {
            if let current { typingActions(current) }
        }
    }

    /// The HDR source above the ring row: segments, or a line when the photo
    /// brings its own HDR.
    @ViewBuilder private func leadChoice(_ control: AdjustmentControl) -> some View {
        if control.options.count > 1 {
            VStack(spacing: Space.s1) {
                // Segments a photo cannot take (AI without a model) stay visible, disabled.
                ParameterSegmented(AdjustmentText.label(control.declaration),
                                   selection: Binding(get: { control.selectedOption ?? "" },
                                                      set: { panel.set(control.id, option: $0, in: &recipe) }),
                                   choices: control.options.map {
                                       SegmentedChoice(AdjustmentText.option($0), value: $0.id,
                                                       isEnabled: !control.disabledOptions.contains($0.id))
                                   })
                    .frame(maxWidth: 420)
                if let note = AdjustmentText.note(for: control) {
                    note.font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                }
            }
        } else if let only = control.options.first {
            AdjustmentText.option(only)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func row(_ layout: BarLayout, _ current: AdjustmentControl?) -> some View {
        ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Space.s2)) : AnyLayout(VStackLayout(spacing: Space.s1))
            stack {
                if !layout.settings.isEmpty { optionsButton(layout.settings) }
                if let lut = layout.lut {
                    LUTSwatches(control: lut, luts: panel.context.luts, onLibrary: onLUTLibrary) {
                        panel.set(lut.id, reference: $0, in: &recipe)
                    }
                } else {
                    ForEach(layout.rings) { control in
                        ring(control, isCurrent: control.id == current?.id)
                    }
                }
            }
            .padding(.horizontal, Space.s4)
            .frame(minWidth: axis == .horizontal ? nil : 0)
        }
        .scrollClipDisabled()
        .defaultScrollAnchor(.center)
        .frame(maxHeight: axis == .vertical ? .infinity : nil)
    }

    private func optionsButton(_ controls: [AdjustmentControl]) -> some View {
        Button { showingOptions = true } label: {
            VStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                Text("ios.adjust.settings").font(.system(size: 10)).lineLimit(1)
            }
            .frame(width: 60)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingOptions) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(controls) { control in
                        AdjustmentRow(recipe: $recipe, control: control, panel: panel, style: .touch)
                    }
                }
                .padding(Space.s4)
            }
            .frame(minWidth: 300, maxHeight: 420)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func ring(_ control: AdjustmentControl, isCurrent: Bool) -> some View {
        AdjustmentRing(control: control, isCurrent: isCurrent, tint: state.group == .hdr ? Color.hdr.amber : Color.hdr.accent)
            .onTapGesture(count: 2) {
                panel.reset(control.id, in: &recipe)
                resets += 1
            }
            .onTapGesture {
                withAnimation(.smooth(duration: 0.2)) { selected[state.group] = control.id }
            }
            .contextMenu {
                Button { panel.reset(control.id, in: &recipe) } label: {
                    Label { AdjustmentText.command(.resetToDefault) } icon: { Image(systemName: "arrow.uturn.backward") }
                }
                .disabled(control.isDefault)
                if control.kind == .floatOrAuto {
                    Button { panel.setAutomatic(control.id, in: &recipe) } label: {
                        Label { AdjustmentText.command(.setAuto) } icon: { Image(systemName: "wand.and.sparkles") }
                    }
                    .disabled(control.isAutomatic)
                }
                Button {
                    if let onReset { onReset(.group(state.group)) } else { panel.reset(group: state.group, in: &recipe) }
                } label: {
                    Label { AdjustmentText.command(.resetGroup) } icon: { Image(systemName: "arrow.counterclockwise") }
                }
                .disabled(!state.isModified)
            }
    }

    private func readout(_ control: AdjustmentControl) -> some View {
        Button {
            draft = control.spec?.editableText(control.sliderValue) ?? ""
            typing = true
        } label: {
            HStack(spacing: Space.s2) {
                AdjustmentText.label(control.declaration)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: control.readout())
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(control.isAutomatic ? Color.secondary : Color.primary)
                    .contentTransition(.numericText())
            }
            .frame(minHeight: 28)
            .padding(.horizontal, Space.s3)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!control.isAvailable)
        .accessibilityHint(Text("ios.adjust.typeHint"))
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
    /// Everything else, behind the options button: the header switch first.
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
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(isCurrent ? 0.28 : 0.14),
                            style: StrokeStyle(lineWidth: 2, dash: control.isAutomatic ? [2.5, 3] : []))
                Circle()
                    .trim(from: 0, to: abs(deviation))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: deviation < 0 ? -1 : 1)
                    .animation(.smooth(duration: 0.15), value: deviation)
                Image(systemName: AdjustmentSymbols.control(control.declaration))
                    .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            }
            .frame(width: 44, height: 44)
            .background(Circle().fill(isCurrent ? Color.white.opacity(0.12) : .clear))
            AdjustmentText.label(control.declaration)
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .frame(width: 62)
        .opacity(control.isAvailable ? 1 : 0.4)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AdjustmentText.label(control.declaration))
        .accessibilityValue(Text(verbatim: control.readout()))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

/// The look group's row: "None", the LUT library, and a tile that opens it.
/// There are no LUT thumbnails yet, so each swatch is a colour from its
/// content hash.
struct LUTSwatches: View {
    let control: AdjustmentControl
    let luts: [LUTReference]
    var onLibrary: () -> Void = {}
    let choose: (String?) -> Void

    var body: some View {
        swatch(name: nil, colour: Color.white.opacity(0.08), isCurrent: control.reference == nil) { choose(nil) }
        ForEach(luts, id: \.contentHash) { lut in
            swatch(name: lut.name, colour: Self.colour(lut.contentHash), isCurrent: control.reference == lut.contentHash) {
                choose(lut.contentHash)
            }
        }
        Button(action: onLibrary) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 16))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                Text("ios.lut.short").font(.system(size: 10)).lineLimit(1)
            }
            .frame(width: 62)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func swatch(name: String?, colour: Color, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(colour.gradient)
                    .overlay {
                        if name == nil { Image(systemName: "nosign").foregroundStyle(.secondary) }
                    }
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(isCurrent ? Color.white : .clear, lineWidth: 2) }
                    .frame(width: 44, height: 44)
                Group {
                    if let name { Text(verbatim: name) } else { AdjustmentText.command(.noLUT) }
                }
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    static func colour(_ hash: String) -> Color {
        let seed = hash.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return Color(hue: Double(seed % 360) / 360, saturation: 0.45, brightness: 0.7)
    }
}
