import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// What the dock shows: one adjustment group, or the export's frame.
enum EditorPane: Hashable {
    case group(AdjustmentGroupID)
    case frame
}

/// One tab of the dock: an adjustment group, or light and colour together.
/// The two are used side by side, so one tab with both rows of rings keeps
/// the tab bar short; the recipe's groups stay as they are.
struct DockGroup: Identifiable {
    /// The groups that share a tab, in display order.
    static let merged: [AdjustmentGroupID] = [.light, .color]

    let states: [AdjustmentGroupState]
    var id: AdjustmentGroupID { states[0].group }
    var isModified: Bool { states.contains { $0.isModified } }
    var isMerged: Bool { states.count > 1 }

    func contains(_ group: AdjustmentGroupID) -> Bool { states.contains { $0.group == group } }

    func isModified(_ group: AdjustmentGroupID) -> Bool {
        states.first { $0.group == group }?.isModified ?? false
    }

    static func tabs(_ groups: [AdjustmentGroupState]) -> [DockGroup] {
        var tabs: [DockGroup] = []
        for state in groups {
            if merged.contains(state.group), let index = tabs.firstIndex(where: { merged.contains($0.id) }) {
                tabs[index] = DockGroup(states: tabs[index].states + [state])
            } else {
                tabs.append(DockGroup(states: [state]))
            }
        }
        return tabs
    }
}

/// The tabs at the foot of the dock (p7-adjustments §5.3): the adjustment
/// groups (light and colour sharing one, `DockGroup`) in one glass capsule and
/// the frame in a capsule of its own, since it shapes the export rather than
/// the photo. Every tab carries its name under the symbol, so none has to be
/// guessed. A dot marks a group with changes and the frame while one is on. Holding a group's tab shows the
/// photo without that group, until it is let go (§5.4).
struct EditorTabs: View {
    let groups: [DockGroup]
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
                    ForEach(groups) { tab in
                        self.tab(.group(tab.id), symbol: AdjustmentSymbols.group(tab.id),
                                 label: tab.isMerged ? Text("ios.adjust.lightColor") : AdjustmentText.group(tab.id),
                                 marked: tab.isModified, mark: tab.id == .hdr ? Color.hdr.amber : Color.hdr.accent,
                                 isCurrent: { if case .group(let group) = $0 { tab.contains(group) } else { false } })
                            .onLongPressGesture(minimumDuration: 0.35) {
                                for state in tab.states { onBypass(state.group, true) }
                            } onPressingChanged: { pressing in
                                if !pressing { for state in tab.states { onBypass(state.group, false) } }
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

    private func tab(_ target: EditorPane, symbol: String, label: Text, marked: Bool, mark: Color,
                     isCurrent: (EditorPane) -> Bool = { _ in false }) -> some View {
        let isCurrent = pane == target || isCurrent(pane)
        return Button {
            // The controls change at once; only the highlight slides.
            pane = target
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: large ? 18 : 16, weight: isCurrent ? .semibold : .regular))
                    .symbolVariant(isCurrent ? .fill : .none)
                label
                    .font(.system(size: large ? 11 : 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            .frame(width: large ? 64 : 58, height: large ? 50 : 46)
            .background {
                if isCurrent {
                    Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "tab", in: selection)
                }
            }
            .overlay(alignment: .topTrailing) {
                if marked {
                    Circle().fill(mark).frame(width: 5, height: 5).padding(large ? 9 : 8)
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
///   visible, their values and the edits. Numbers get a ring and switches
///   a filled circle; other choices and references wait behind "More" at the
///   end of the row. HDR's own switch and its source sit above the row.
/// - The look group's row lists the LUTs instead of rings ("None" first, the
///   library last); the ruler then sets the strength.
/// - Rings: empty at the default, clockwise for positive and anticlockwise for
///   negative; amber for HDR. Double-tap resets, a long press opens the menu.
/// - Tapping the readout types an exact value.
/// - `axis: .vertical` is the standing column on the right in landscape.
struct AdjustmentControls: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    let group: DockGroup
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
        let actual = BarLayout(group)
        let off = actual.isSwitchedOff
        // Switched off, the group's controls stay in place, grey and locked.
        let layout = off ? switchedOnLayout(actual) ?? actual : actual
        let current = layout.rings.first { $0.id == selected[group.id] } ?? layout.rings.first
        let stack = axis == .horizontal ? AnyLayout(VStackLayout(spacing: large ? Space.s3 : Space.s2))
            : AnyLayout(VStackLayout(alignment: .center, spacing: Space.s2))
        stack {
            if actual.power != nil || layout.leadChoice != nil {
                headline(power: actual.power, lead: layout.leadChoice, off: off).padding(.horizontal, Space.s4)
            }
            if off {
                // In the readout's place: what the switch being off means.
                Text("ios.adjust.hdrOff")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(minHeight: 28)
            } else if let current {
                readout(current)
            } else {
                Color.clear.frame(height: 28)
            }
            row(layout, current)
                .locked(off)
            if let current {
                AdjustmentRuler(control: current,
                                write: { panel.set(current.id, number: $0, in: &recipe) },
                                reset: { panel.reset(current.id, in: &recipe) },
                                onEditingChanged: { onEditingChanged(current.declaration, $0) })
                    .id(current.id)
                    .frame(height: large ? 52 : 40)
                    .disabled(!current.isAvailable)
                    .locked(off)
            }
        }
        .animation(.smooth(duration: 0.2), value: off)
        .sensoryFeedback(.impact(weight: .light), trigger: resets)
        .alert(current.map { AdjustmentText.label($0.declaration) } ?? Text(verbatim: ""), isPresented: $typing) {
            if let current { typingActions(current) }
        }
    }

    /// Above the ring row: the group's switch (HDR on or off) in plain sight,
    /// then the HDR source, or what switching it off means.
    private func headline(power: AdjustmentControl?, lead: AdjustmentControl?, off: Bool) -> some View {
        HStack(spacing: Space.s2) {
            if let power {
                PowerSwitch(control: power) { panel.set(power.id, isOn: $0, in: &recipe) }
            }
            if let lead {
                leadChoice(lead).frame(maxWidth: .infinity).locked(off)
            }
        }
        .frame(maxWidth: 420)
    }

    /// The group as it reads with its switch on: the panel hides the
    /// controls of a switched-off group, the dock shows them locked.
    private func switchedOnLayout(_ actual: BarLayout) -> BarLayout? {
        guard let power = actual.power else { return nil }
        var on = recipe
        panel.set(power.id, isOn: true, in: &on)
        let states = group.states.compactMap { panel.group(group: $0.group, in: on) }
        return states.isEmpty ? nil : BarLayout(DockGroup(states: states))
    }

    /// The HDR source: segments, or a line when the photo brings its own HDR.
    /// The film stock: a menu, its names being too long for segments.
    @ViewBuilder private func leadChoice(_ control: AdjustmentControl) -> some View {
        if control.id == Recipe.filmID {
            FilmMenu(control: control) { panel.set(control.id, option: $0, in: &recipe) }
        } else if control.options.count > 1 {
            // No note under it: a line that comes and goes would move the row.
            SourceSegments(control: control) { panel.set(control.id, option: $0, in: &recipe) }
        } else if let only = control.options.first {
            AdjustmentText.option(only)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(minHeight: 36)
        }
    }

    private func row(_ layout: BarLayout, _ current: AdjustmentControl?) -> some View {
        ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Space.s2)) : AnyLayout(VStackLayout(spacing: Space.s1))
            stack {
                if let lut = layout.lut {
                    LUTSwatches(control: lut, luts: panel.context.luts, previews: panel.context.lutPreviews,
                                onLibrary: onLUTLibrary) {
                        panel.set(lut.id, reference: $0, in: &recipe)
                    }
                    // The LUT's and the film's strengths, so the ruler can reach either.
                    if !layout.rings.isEmpty {
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: axis == .horizontal ? 1 : 28, height: axis == .horizontal ? 28 : 1)
                            .padding(axis == .horizontal ? .bottom : .trailing, axis == .horizontal ? 16 : 0)
                        ForEach(layout.rings) { control in
                            ring(control, isCurrent: control.id == current?.id)
                        }
                    }
                } else {
                    ForEach(Array(layout.rings.enumerated()), id: \.element.id) { index, control in
                        // A hairline where light's rings end and colour's begin.
                        if index > 0, layout.rings[index - 1].group != control.group {
                            Capsule()
                                .fill(Color.white.opacity(0.14))
                                .frame(width: axis == .horizontal ? 1 : 28, height: axis == .horizontal ? 28 : 1)
                                .padding(axis == .horizontal ? .bottom : .trailing, axis == .horizontal ? 16 : 0)
                        }
                        ring(control, isCurrent: control.id == current?.id)
                    }
                }
                // Switches read as switches, after the numbers; anything
                // else waits behind "More" at the end of the row.
                ForEach(layout.switches) { control in
                    SwitchRing(control: control, tint: group.id == .hdr ? Color.hdr.amber : Color.hdr.accent) {
                        panel.set(control.id, isOn: $0, in: &recipe)
                    }
                }
                if !layout.more.isEmpty { moreButton(layout.more) }
            }
            .padding(.horizontal, Space.s4)
            .frame(minWidth: axis == .horizontal ? nil : 0)
        }
        .scrollClipDisabled()
        // Centred when the rings fit; otherwise the row opens at its first ring.
        .defaultScrollAnchor(.center, for: .alignment)
        .defaultScrollAnchor(axis == .horizontal ? .leading : .top, for: .initialOffset)
        .frame(maxHeight: axis == .vertical ? .infinity : nil)
    }

    private func moreButton(_ controls: [AdjustmentControl]) -> some View {
        Button { showingOptions = true } label: {
            VStack(spacing: 4) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                Text("ios.adjust.more").font(.system(size: 10)).lineLimit(1)
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
        AdjustmentRing(control: control, isCurrent: isCurrent, tint: group.id == .hdr ? Color.hdr.amber : Color.hdr.accent)
            .onTapGesture(count: 2) {
                panel.reset(control.id, in: &recipe)
                resets += 1
            }
            .onTapGesture {
                withAnimation(.smooth(duration: 0.2)) { selected[group.id] = control.id }
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
                    // The control's own group: on the shared tab, light or colour.
                    if let onReset { onReset(.group(control.group)) } else { panel.reset(group: control.group, in: &recipe) }
                } label: {
                    Label { AdjustmentText.command(.resetGroup) } icon: { Image(systemName: "arrow.counterclockwise") }
                }
                .disabled(!group.isModified(control.group))
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

/// The HDR source as segments in a glass capsule, drawn like the tabs under
/// it: the chosen one lit, the highlight sliding between them. Segments a
/// photo cannot take (AI without a model) stay visible, disabled.
private struct SourceSegments: View {
    let control: AdjustmentControl
    let choose: (String) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(control.options, id: \.id) { option in
                let isCurrent = control.selectedOption == option.id
                Button { choose(option.id) } label: {
                    AdjustmentText.option(option)
                        .font(.footnote.weight(isCurrent ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background {
                            if isCurrent {
                                Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "segment", in: highlight)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(control.disabledOptions.contains(option.id))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .animation(.smooth(duration: 0.25), value: control.selectedOption)
        .sensoryFeedback(.selection, trigger: control.selectedOption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AdjustmentText.label(control.declaration))
    }
}

private extension View {
    /// Grey and out of reach while the group's switch is off.
    func locked(_ locked: Bool) -> some View {
        disabled(locked)
            .allowsHitTesting(!locked)
            .saturation(locked ? 0 : 1)
            .opacity(locked ? 0.35 : 1)
    }
}

/// The group's on/off switch: a glass circle with the power symbol, lit in
/// the group's colour while on.
private struct PowerSwitch: View {
    let control: AdjustmentControl
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!control.isOn) } label: {
            Image(systemName: "power")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(control.isOn ? Color.hdr.amber : Color.secondary)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .sensoryFeedback(.impact(weight: .light), trigger: control.isOn)
        .accessibilityLabel(AdjustmentText.label(control.declaration))
        .accessibilityValue(Text(control.isOn ? "ios.adjust.on" : "ios.adjust.off"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// The look group's film stock, above its row: the chosen stock in a capsule that
/// opens the list.
private struct FilmMenu: View {
    let control: AdjustmentControl
    let choose: (String) -> Void

    var body: some View {
        let selected = control.options.first { $0.id == control.selectedOption } ?? control.options.first
        Menu {
            Picker(selection: Binding(get: { control.selectedOption ?? "" }, set: choose)) {
                ForEach(AdjustmentText.optionSections(control)) { section in
                    Section {
                        ForEach(section.options, id: \.id) { option in
                            AdjustmentText.option(option).tag(option.id)
                        }
                    } header: {
                        section.title
                    }
                }
            } label: {
                AdjustmentText.label(control.declaration)
            }
        } label: {
            HStack(spacing: Space.s2) {
                Image(systemName: "film")
                AdjustmentText.label(control.declaration).foregroundStyle(.secondary)
                Spacer(minLength: Space.s1)
                if let selected { AdjustmentText.option(selected).lineLimit(1) }
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, Space.s3)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AdjustmentText.label(control.declaration))
        .disabled(!control.isAvailable)
    }
}

/// An on/off control in the ring row: its symbol in a circle, filled while on.
private struct SwitchRing: View {
    let control: AdjustmentControl
    let tint: Color
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!control.isOn) } label: {
            VStack(spacing: 4) {
                Image(systemName: AdjustmentSymbols.control(control.declaration))
                    .font(.system(size: 16, weight: control.isOn ? .semibold : .regular))
                    .foregroundStyle(control.isOn ? tint : Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(control.isOn ? tint.opacity(0.18) : .clear))
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 2))
                AdjustmentText.label(control.declaration)
                    .font(.system(size: 10, weight: control.isOn ? .semibold : .regular))
                    .foregroundStyle(control.isOn ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 62)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!control.isAvailable)
        .sensoryFeedback(.selection, trigger: control.isOn)
        .accessibilityValue(Text(control.isOn ? "ios.adjust.on" : "ios.adjust.off"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// How one group's controls split across the bar.
private struct BarLayout {
    /// Numbers, each with a ring and the ruler.
    let rings: [AdjustmentControl]
    /// The HDR source or the film stock, above the ring row (§5.3: the group's most
    /// important choice).
    let leadChoice: AdjustmentControl?
    /// The LUT reference, drawn as swatches in place of the rings.
    let lut: AdjustmentControl?
    /// The group's own switch (HDR on or off), beside the source.
    let power: AdjustmentControl?
    /// The switch is off: the group's other controls are hidden.
    var isSwitchedOff: Bool { power.map { !$0.isOn } ?? false }
    /// Other on/off controls, as switches at the end of the row.
    let switches: [AdjustmentControl]
    /// Everything else (the AI model, the LUT's input and output), behind "More".
    let more: [AdjustmentControl]

    init(_ group: DockGroup) {
        let controls = group.states.flatMap(\.controls)
        rings = controls.filter { $0.spec != nil }
        let others = controls.filter { $0.spec == nil }
        let lead = others.first { $0.id == Recipe.hdrSourceID || $0.id == Recipe.filmID }
        let lut = others.first { $0.id == Recipe.lookID }
        leadChoice = lead
        self.lut = lut
        power = group.states.lazy.compactMap(\.headerToggle).first
        let rest = others.filter { $0.id != lead?.id && $0.id != lut?.id }
        switches = rest.filter { $0.kind == .bool }
        more = rest.filter { $0.kind != .bool }
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
/// Each LUT is shown on the photo (`AdjustmentContext.lutPreviews`), with
/// its colour mark until its preview is in; "None" is the photo without one.
struct LUTSwatches: View {
    let control: AdjustmentControl
    let luts: [LUTReference]
    var previews: [String: CGImage] = [:]
    var onLibrary: () -> Void = {}
    let choose: (String?) -> Void
    @Environment(\.lookPickerShown) private var shown

    var body: some View {
        swatch(id: nil, name: nil, isCurrent: control.reference == nil) { choose(nil) }
            .onAppear { shown(true) }
            .onDisappear { shown(false) }
        ForEach(luts, id: \.contentHash) { lut in
            swatch(id: lut.contentHash, name: lut.name, isCurrent: control.reference == lut.contentHash) {
                choose(lut.contentHash)
            }
            .disabled(control.disabledOptions.contains(lut.contentHash))
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

    private func swatch(id: String?, name: String?, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                LUTThumbnail(image: previews[id ?? LookPreviews.none], contentHash: id, side: 44,
                             isSelected: isCurrent, selection: .white)
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
        .accessibilityLabel(name.map { Text(verbatim: $0) } ?? AdjustmentText.command(.noLUT))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
