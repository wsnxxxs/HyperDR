import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// What the dock shows: one adjustment group, the crop, or the export's frame.
enum EditorPane: Hashable {
    case group(AdjustmentGroupID)
    case crop
    case frame
}

/// One tab of the dock: an adjustment group, or light and Adjust (the
/// colour group, which also holds grain and halation) together as Adjust.
/// They are used side by side, so one tab with all their rings keeps the tab
/// bar short; the recipe's groups stay as they are.
///
/// Style holds only the choice of look and its strength: a look changes
/// colour. Grain and halation work on every photo with or without a look,
/// so they sit in the colour group, after saturation. A film's exposure follows its
/// meter (Adjust's exposure moves it) and its antihalation layer stays on.
struct DockGroup: Identifiable {
    /// The groups that share a tab, in display order.
    static let merged: [AdjustmentGroupID] = [.light, .color]
    /// What Style keeps of the look group.
    static let lookControls: Set<String> = [Recipe.filmID, Recipe.lookID, "look.strength", "look.filmStrength"]

    let states: [AdjustmentGroupState]
    var id: AdjustmentGroupID { states[0].group }
    var isMerged: Bool { states.count > 1 }

    /// The controls the tab shows.
    var controls: [AdjustmentControl] {
        let own = states.flatMap(\.controls)
        return id == .look ? own.filter { Self.lookControls.contains($0.id) } : own
    }

    var isModified: Bool {
        if id == .look { return controls.contains { !$0.isDefault } }
        return states.contains { $0.isModified }
    }

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
    /// The photo is cropped, turned, tilted or mirrored.
    var cropOn = false
    let frameOn: Bool
    var axis: Axis = .horizontal
    var large = false
    var onBypass: (AdjustmentGroupID, Bool) -> Void = { _, _ in }
    @Namespace private var selection

    var body: some View {
        let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Space.s3)) : AnyLayout(VStackLayout(spacing: Space.s3))
        let hdr = groups.filter { $0.id == .hdr }
        GlassEffectContainer(spacing: Space.s3) {
            // HDR at the start, the edits that change the photo in the
            // middle, the frame around it at the end.
            stack {
                capsule { ForEach(hdr) { groupTab($0) } }
                capsule {
                    ForEach(groups.filter { $0.id != .hdr }) { groupTab($0) }
                    tab(.crop, symbol: "crop.rotate", label: Text("ios.crop.title"), marked: cropOn, mark: Color.hdr.accent)
                }
                capsule {
                    tab(.frame, symbol: "photo.artframe", label: Text("ios.frame.title"), marked: frameOn, mark: .white)
                }
            }
            .padding(axis == .horizontal ? .horizontal : .vertical, Space.s3)
        }
        .animation(.smooth(duration: 0.25), value: pane)
        .sensoryFeedback(.selection, trigger: pane)
    }

    private func capsule(@ViewBuilder _ content: () -> some View) -> some View {
        let inner = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return inner { content() }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
    }

    private func groupTab(_ tab: DockGroup) -> some View {
        self.tab(.group(tab.id), symbol: tab.isMerged ? "slider.horizontal.3" : AdjustmentSymbols.group(tab.id),
                 label: tab.isMerged ? Text("ios.adjust.tab") : AdjustmentText.group(tab.id),
                 marked: tab.isModified, mark: tab.id == .hdr ? Color.hdr.amber : Color.hdr.accent,
                 isCurrent: { if case .group(let group) = $0 { tab.contains(group) } else { false } })
            .onLongPressGesture(minimumDuration: 0.35) {
                for state in tab.states { onBypass(state.group, true) }
            } onPressingChanged: { pressing in
                if !pressing { for state in tab.states { onBypass(state.group, false) } }
            }
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
/// - The look group chooses its look first: built-in (the film stocks) or
///   imported (the LUT library), as segments above the row; the row lists
///   that kind's looks before its strength ("None" first, the library tile
///   last). One look at a time: choosing a film removes the LUT and the other
///   way round. Its other controls are Adjust's or have none (`DockGroup`).
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
    /// Why AI cannot be chosen, when it cannot: an ⓘ beside the HDR source.
    var aiUnavailable: Text?

    /// The chosen control of each group, kept while switching groups.
    @State private var selected: [AdjustmentGroupID: String] = [:]
    /// The look kind the row shows, once chosen; until then the recipe's.
    @State private var chosenLookKind: LookKind?
    @State private var showingOptions = false
    @State private var typing = false
    @State private var draft = ""
    @State private var resets = 0

    var body: some View {
        let actual = BarLayout(group)
        let off = actual.isSwitchedOff
        // Switched off, the group's controls stay in place, grey and locked.
        let layout = (off ? switchedOnLayout(actual) ?? actual : actual).showing(lookKind)
        let current = layout.rings.first { $0.id == selected[group.id] } ?? layout.rings.first
        let stack = axis == .horizontal ? AnyLayout(VStackLayout(spacing: large ? Space.s3 : Space.s2))
            : AnyLayout(VStackLayout(alignment: .center, spacing: Space.s2))
        stack {
            if actual.power != nil || layout.leadChoice != nil {
                headline(power: actual.power, lead: layout.leadChoice, off: off).padding(.horizontal, Space.s4)
            } else if layout.isLook {
                LookKindSegments(kind: lookKind) { chosenLookKind = $0 }
                    .frame(maxWidth: 420)
                    .padding(.horizontal, Space.s4)
            }
            // With the switch off there is no readout: the switch says so, and
            // the export page says an SDR version is written.
            if !off, let current {
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
            } else if layout.isLook {
                // The ruler's place, so switching the look kind never moves the dock.
                Color.clear.frame(height: large ? 52 : 40)
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
                if lead.id == Recipe.hdrSourceID, let aiUnavailable {
                    InfoButton(text: aiUnavailable)
                }
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
    @ViewBuilder private func leadChoice(_ control: AdjustmentControl) -> some View {
        if control.options.count > 1 {
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
                if layout.isLook {
                    lookSwatches(layout)
                    // The look's strengths, so the ruler can reach them.
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
                // A switch this photo does not offer, where it would be, so
                // it does not read as lost.
                ForEach(layout.unsupported, id: \.id) { declaration in
                    UnsupportedRing(declaration: declaration)
                }
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

    private var lookKind: LookKind { chosenLookKind ?? (recipe.look != nil ? .imported : .builtIn) }

    /// The chosen kind's looks. "None" in either removes whichever look is on.
    @ViewBuilder private func lookSwatches(_ layout: BarLayout) -> some View {
        let removeLook = { panel.set(Recipe.lookID, reference: nil, in: &recipe) }
        switch lookKind {
        case .builtIn:
            if let film = layout.film {
                FilmSwatches(control: film, lookIsImported: recipe.look != nil, previews: panel.context.lutPreviews,
                             removeLook: removeLook) { stock in
                    // One write, one undo step (`AdjustmentPanel.chooseFilm`): the
                    // stock, its exposure back on the meter and its antihalation
                    // layer back on, neither having a control here.
                    var edited = recipe
                    panel.chooseFilm(stock, in: &edited)
                    recipe = edited
                }
            }
        case .imported:
            if let lut = layout.lut {
                LUTSwatches(control: lut, luts: panel.context.luts, previews: panel.context.lutPreviews,
                            filmIsOn: layout.film.map { $0.selectedOption != "none" } ?? false,
                            onLibrary: onLUTLibrary) {
                    if let reference = $0 { panel.set(lut.id, reference: reference, in: &recipe) } else { removeLook() }
                }
            }
        }
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
            // Selects on the first touch: a double-tap first in line would hold
            // every single tap back until it failed.
            .onTapGesture {
                withAnimation(.smooth(duration: 0.2)) { selected[group.id] = control.id }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                panel.reset(control.id, in: &recipe)
                resets += 1
            })
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
                    Label { AdjustmentText.resetGroup(control.group, shared: group.isMerged) } icon: { Image(systemName: "arrow.counterclockwise") }
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

/// An ⓘ in a glass circle that explains something in a popover.
private struct InfoButton: View {
    let text: Text
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .popover(isPresented: $shown) {
            text
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
                .padding(Space.s4)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(text)
    }
}

/// A switch this photo does not offer (lens correction without a lens
/// profile), in its place in the row: greyed, with why under its name.
private struct UnsupportedRing: View {
    let declaration: ParameterDeclaration

    var body: some View {
        // Laid out as the rings beside it, so its circle lines up with
        // theirs; the reason hangs under the name, in the space above the ruler.
        VStack(spacing: 4) {
            Image(systemName: AdjustmentSymbols.control(declaration))
                .font(.system(size: 16))
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 3])))
            AdjustmentText.label(declaration)
                .font(.system(size: 10))
                .lineLimit(1)
                .overlay(alignment: .top) {
                    AdjustmentText.noProfile
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .fixedSize()
                        .offset(y: 14)
                }
        }
        .foregroundStyle(.tertiary)
        .frame(width: 62)
        .accessibilityElement(children: .combine)
    }
}

/// How one group's controls split across the bar.
private struct BarLayout {
    /// Numbers, each with a ring and the ruler.
    private(set) var rings: [AdjustmentControl]
    /// The HDR source, above the ring row (§5.3: the group's most important choice).
    let leadChoice: AdjustmentControl?
    /// The film stock and the LUT reference, drawn as swatches before the rings.
    let film: AdjustmentControl?
    let lut: AdjustmentControl?
    var isLook: Bool { film != nil || lut != nil }
    /// The group's own switch (HDR on or off), beside the source.
    let power: AdjustmentControl?
    /// The switch is off: the group's other controls are hidden.
    var isSwitchedOff: Bool { power.map { !$0.isOn } ?? false }
    /// Other on/off controls, as switches at the end of the row.
    private(set) var switches: [AdjustmentControl]
    /// Everything else (the AI model, the LUT's input and output), behind "More".
    let more: [AdjustmentControl]
    /// Switches the photo does not offer (`AdjustmentGroupState.unsupported`).
    let unsupported: [ParameterDeclaration]

    init(_ group: DockGroup) {
        let controls = group.controls
        rings = controls.filter { $0.spec != nil }
        let others = controls.filter { $0.spec == nil }
        let lead = others.first { $0.id == Recipe.hdrSourceID }
        let film = others.first { $0.id == Recipe.filmID }
        let lut = others.first { $0.id == Recipe.lookID }
        leadChoice = lead
        self.film = film
        self.lut = lut
        power = group.states.lazy.compactMap(\.headerToggle).first
        let rest = others.filter { $0.id != lead?.id && $0.id != film?.id && $0.id != lut?.id }
        switches = rest.filter { $0.kind == .bool }
        // The tone curve is the Mac's and the Studio's; the dock has no editor for it.
        more = rest.filter { $0.kind != .bool && $0.kind != .curve }
        unsupported = group.states.flatMap(\.unsupported)
    }

    /// The look group with only the shown kind's controls: the film's
    /// (`look.film…`) under built-in, the LUT's under imported.
    func showing(_ kind: LookKind) -> BarLayout {
        guard isLook else { return self }
        let belongs = { (control: AdjustmentControl) in control.id.hasPrefix("look.film") == (kind == .builtIn) }
        var layout = self
        layout.rings = rings.filter(belongs)
        layout.switches = switches.filter(belongs)
        return layout
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

/// The look group's imported row: "None", the LUT library, and a tile that
/// opens it. Each LUT is shown on the photo (`AdjustmentContext.lutPreviews`),
/// with its colour mark until its preview is in; "None" is the photo without
/// a look.
struct LUTSwatches: View {
    let control: AdjustmentControl
    let luts: [LUTReference]
    var previews: [String: CGImage] = [:]
    /// A built-in film is the look, so "None" is not.
    var filmIsOn = false
    var onLibrary: () -> Void = {}
    let choose: (String?) -> Void
    @Environment(\.lookPickerShown) private var shown

    var body: some View {
        LookSwatch(image: previews[LookPreviews.none], mark: nil, name: nil,
                   isCurrent: control.reference == nil && !filmIsOn) { choose(nil) }
            .onAppear { shown(true) }
            .onDisappear { shown(false) }
        ForEach(luts, id: \.contentHash) { lut in
            LookSwatch(image: previews[lut.contentHash], mark: lut.contentHash, name: Text(verbatim: lut.name),
                       isCurrent: control.reference == lut.contentHash) {
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
}

/// The look group's built-in row: "None" and the film stocks, each shown on
/// the photo (`LookPreviews.filmKey`) with its colour mark until its preview is in.
private struct FilmSwatches: View {
    let control: AdjustmentControl
    /// An imported LUT is the look, so "None" is not.
    let lookIsImported: Bool
    var previews: [String: CGImage] = [:]
    let removeLook: () -> Void
    let choose: (String) -> Void
    @Environment(\.lookPickerShown) private var shown

    var body: some View {
        LookSwatch(image: previews[LookPreviews.none], mark: nil, name: nil,
                   isCurrent: control.selectedOption == "none" && !lookIsImported, action: removeLook)
            .onAppear { shown(true) }
            .onDisappear { shown(false) }
        // Negatives, slides, motion-picture negatives, each after a rule, as
        // the rings' groups are.
        ForEach(AdjustmentText.optionSections(control).filter { $0.filmFamily != nil }) { section in
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 28)
                .padding(.bottom, 16)
                .accessibilityElement()
                .accessibilityLabel(section.title ?? Text(verbatim: ""))
            ForEach(section.options, id: \.id) { option in
                LookSwatch(image: previews[LookPreviews.filmKey(option.id)], mark: option.id,
                           name: AdjustmentText.option(option), isCurrent: control.selectedOption == option.id) {
                    choose(option.id)
                }
                .disabled(control.disabledOptions.contains(option.id))
            }
        }
    }
}

/// One look in a look row: its preview over its name; no name is "None".
private struct LookSwatch: View {
    let image: CGImage?
    /// The colour mark's seed, shown until the preview is in; nil for "None".
    let mark: String?
    let name: Text?
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                LUTThumbnail(image: image, contentHash: mark, side: 44, isSelected: isCurrent, selection: .white)
                // Two lines, so a stock's name ("Kodak Portra 400") reads whole.
                (name ?? AdjustmentText.command(.noLUT))
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name ?? AdjustmentText.command(.noLUT))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Which kind of look the look group's row shows.
enum LookKind: CaseIterable {
    case builtIn, imported

    var title: LocalizedStringKey {
        switch self {
        case .builtIn: "ios.look.builtIn"
        case .imported: "ios.look.imported"
        }
    }
}

/// Built-in or imported, drawn as the HDR source's segments.
private struct LookKindSegments: View {
    let kind: LookKind
    let choose: (LookKind) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LookKind.allCases, id: \.self) { option in
                let isCurrent = kind == option
                Button { choose(option) } label: {
                    Text(option.title)
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
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .animation(.smooth(duration: 0.25), value: kind)
        .sensoryFeedback(.selection, trigger: kind)
        .accessibilityElement(children: .contain)
    }
}
