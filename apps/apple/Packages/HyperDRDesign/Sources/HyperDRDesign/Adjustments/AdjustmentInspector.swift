import HyperDRRecipe
import SwiftUI

/// How the generated controls are drawn.
public enum AdjustmentControlStyle: Sendable {
    /// Mac: `ParameterSlider` with hover, the keyboard and tooltips.
    case pointer
    /// iPad sidebar: `TouchParameterSlider`, 44 pt rows, help behind ⓘ.
    case touch
}

/// The adjustment groups as an inspector column (p7-adjustments §5.1, §5.2):
/// the Mac's right-hand inspector and the iPad's sidebar. Everything in it
/// comes from the declarations through `AdjustmentPanel`.
///
/// - Groups fold; HDR and Light start open, the others folded, and a folded
///   group sums up what was changed in it. A host that passes `expanded`
///   keeps which are open (the Mac keeps them across photos, the crop pane
///   and launches); without it the inspector keeps its own.
/// - HDR's header carries the HDR switch, and its first line says it affects
///   HDR only; turning it off hides the rest of the group.
/// - A group with changes shows ↺, which resets the group. Above the groups,
///   Collapse All (Expand All when every group is folded) and Reset All.
///
/// The recipe is the only state; `onEditingChanged` brackets drags for the
/// host's undo and preview size, with the declaration being edited. A host
/// that names its undo steps passes `onReset` and performs the resets itself
/// ("Reset Light" rather than the name of the one control a reset changed);
/// without it the resets write the binding.
public struct AdjustmentInspector: View {
    @Binding private var recipe: Recipe
    private let panel: AdjustmentPanel
    private let style: AdjustmentControlStyle
    private let onEditingChanged: (ParameterDeclaration, Bool) -> Void
    private let onReset: ((AdjustmentReset) -> Void)?
    private let onLUTLibrary: (() -> Void)?
    private let only: Set<AdjustmentGroupID>?

    /// Which groups are open while the host keeps no record of it.
    @State private var ownExpanded: Set<AdjustmentGroupID>
    private let hostExpanded: Binding<Set<AdjustmentGroupID>>?
    /// The control a note asked to bring into view, until the host has scrolled
    /// to it: the look section switches to the kind that holds it.
    @State private var revealing: String?
    @Environment(\.locale) private var locale
    @Environment(\.revealControl) private var reveal

    /// `only` shows just those groups, all open: the iPad sidebar shows one
    /// tab's groups at a time, as the iPhone's dock does, and keeps Reset All
    /// in the toolbar's More menu instead of above them.
    public init(recipe: Binding<Recipe>, panel: AdjustmentPanel, style: AdjustmentControlStyle = .pointer,
                only: Set<AdjustmentGroupID>? = nil, expanded: Binding<Set<AdjustmentGroupID>>? = nil,
                onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in },
                onReset: ((AdjustmentReset) -> Void)? = nil, onLUTLibrary: (() -> Void)? = nil) {
        _recipe = recipe
        self.panel = panel
        self.style = style
        self.only = only
        self.onEditingChanged = onEditingChanged
        self.onReset = onReset
        self.onLUTLibrary = onLUTLibrary
        _ownExpanded = State(initialValue: only ?? Self.initiallyExpanded)
        hostExpanded = only == nil ? expanded : nil
    }

    /// The groups open the first time: HDR and Light.
    public static let initiallyExpanded: Set<AdjustmentGroupID> = [.hdr, .light]

    private var expanded: Binding<Set<AdjustmentGroupID>> { hostExpanded ?? $ownExpanded }

    private func reset(_ reset: AdjustmentReset) {
        if let onReset { return onReset(reset) }
        switch reset {
        case .group(let group): panel.reset(group: group, in: &recipe)
        case .all: panel.resetAll(in: &recipe)
        }
    }

    public var body: some View {
        let groups = panel.groups(for: recipe).filter { only?.contains($0.group) ?? true }
        VStack(alignment: .leading, spacing: 0) {
            if only == nil { commands(groups) }
            ForEach(groups) { state in
                groupView(state)
            }
        }
        .environment(\.revealControl, reveal.map { host in { id in revealControl(id, host: host) } })
    }

    /// Opens the group the control sits in, then lets the host scroll to it
    /// once the group has laid out.
    private func revealControl(_ id: String, host: @escaping (String) -> Void) {
        if let group = Adjustments.declaration(id)?.group { expanded.wrappedValue.insert(group) }
        revealing = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            host(id)
            revealing = nil
        }
    }

    /// Collapse All (Expand All once every group is folded) and Reset All, on
    /// one line above the groups.
    private func commands(_ groups: [AdjustmentGroupState]) -> some View {
        let anyOpen = groups.contains { expanded.wrappedValue.contains($0.group) }
        let modified = groups.contains(where: \.isModified)
        return HStack(spacing: Space.s3) {
            Button {
                withHDRAnimation {
                    if anyOpen { expanded.wrappedValue.subtract(groups.map(\.group)) }
                    else { expanded.wrappedValue.formUnion(groups.map(\.group)) }
                }
            } label: {
                Label {
                    Text(anyOpen ? "design.adjust.collapseAll" : "design.adjust.expandAll", bundle: .module)
                } icon: {
                    Image(systemName: anyOpen ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
            }
            .buttonStyle(InspectorCommandStyle())
            Spacer(minLength: 0)
            Button { reset(.all) } label: {
                Label {
                    Text("design.adjust.resetAll", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
            .buttonStyle(InspectorCommandStyle(prominent: modified))
            .disabled(!modified)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: style == .touch ? 44 : 30)
    }

    private func controls(_ state: AdjustmentGroupState) -> some View {
        VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s4) {
            if state.affectsHDROnly {
                Text("group.hdrOnly", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.hdr.amber)
            }
            ForEach(state.controls.filter { !AdjustmentSections.isDrawnBySection($0.id) }) { control in
                if AdjustmentPanel.startsCluster(control.id), control.id != state.controls.first?.id {
                    Rectangle().fill(Color.hdr.line).frame(height: 1)
                }
                AdjustmentRow(recipe: $recipe, control: control, panel: panel, style: style,
                              onEditingChanged: onEditingChanged, onLUTLibrary: onLUTLibrary)
            }
            ForEach(state.unsupported, id: \.id) { declaration in
                UnsupportedRow(declaration: declaration, style: style)
            }
        }
    }

    private func groupView(_ state: AdjustmentGroupState) -> some View {
        let expanded = self.expanded
        let isExpanded = Binding(get: { expanded.wrappedValue.contains(state.group) },
                                 set: { if $0 { expanded.wrappedValue.insert(state.group) } else { expanded.wrappedValue.remove(state.group) } })
        return ParameterGroup(AdjustmentText.group(state.group), systemImage: AdjustmentSymbols.group(state.group),
                              summary: isExpanded.wrappedValue ? nil : Text(verbatim: AdjustmentText.summary(state, locale: locale)),
                              isExpanded: isExpanded, collapsible: only == nil) {
            if state.group == .look {
                LookSection(recipe: $recipe, state: state, panel: panel, style: style, revealing: revealing,
                            onEditingChanged: onEditingChanged, onLUTLibrary: onLUTLibrary)
            } else {
                controls(state)
            }
        } accessory: {
            HStack(spacing: Space.s2) {
                if state.isModified {
                    Button { reset(.group(state.group)) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(minWidth: style == .touch ? 44 : 20, minHeight: style == .touch ? 44 : 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .help(Text("group.reset", bundle: .module))
                    .accessibilityLabel(Text("group.reset", bundle: .module))
                }
                if let toggle = state.headerToggle {
                    Toggle(isOn: Binding(get: { toggle.isOn },
                                         set: { panel.set(toggle.id, isOn: $0, in: &recipe) })) {
                        AdjustmentText.label(toggle.declaration)
                    }
                    .labelsHidden()
                    .toggleStyle(.hdrSwitch)
                    .fixedSize()
                }
            }
        }
    }
}

/// A command on the line above the groups: small, quiet until hovered; the
/// prominent one (Reset All with something to reset) in the accent.
private struct InspectorCommandStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        InspectorCommandBody(configuration: configuration, prominent: prominent)
    }
}

private struct InspectorCommandBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .labelStyle(InspectorCommandLabelStyle())
            .font(.system(size: TypeScale.Size.caption, weight: .medium))
            .foregroundStyle(!isEnabled ? Color.hdr.inkDisabled
                             : prominent ? Color.hdr.accent : hovered ? Color.hdr.inkStrong : Color.hdr.inkMuted)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .onHover { hovered = isEnabled && $0 }
    }
}

private struct InspectorCommandLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

/// One generated control: a slider for numbers, a switch, segments or a
/// menu for choices, a menu for references. The iPhone bar uses it for the
/// rows of its settings card.
public struct AdjustmentRow: View {
    @Binding private var recipe: Recipe
    private let control: AdjustmentControl
    private let panel: AdjustmentPanel
    private let style: AdjustmentControlStyle
    private let onEditingChanged: (ParameterDeclaration, Bool) -> Void
    private let onLUTLibrary: (() -> Void)?
    @Environment(\.whiteBalancePicking) private var whiteBalance

    public init(recipe: Binding<Recipe>, control: AdjustmentControl, panel: AdjustmentPanel,
                style: AdjustmentControlStyle,
                onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in },
                onLUTLibrary: (() -> Void)? = nil) {
        _recipe = recipe
        self.control = control
        self.panel = panel
        self.style = style
        self.onEditingChanged = onEditingChanged
        self.onLUTLibrary = onLUTLibrary
    }

    public var body: some View {
        if let section = AdjustmentSections.section(anchoredBy: control.id), section != .curves {
            switch section {
            case .mixer:
                ColorMixerSection(recipe: $recipe, panel: panel, style: style,
                                  showsTitle: !AdjustmentSections.fillsItsGroup(.mixer), onEditingChanged: onEditingChanged)
            case .grading:
                ColorGradingSection(recipe: $recipe, panel: panel, style: style,
                                    showsTitle: !AdjustmentSections.fillsItsGroup(.grading), onEditingChanged: onEditingChanged)
            case .curves:
                EmptyView()
            }
        } else {
            generated
        }
    }

    @ViewBuilder private var generated: some View {
        let declaration = control.declaration
        switch control.kind {
        case .float, .floatOrAuto:
            if let spec = control.spec {
                let value = Binding(get: { control.sliderValue },
                                    set: { panel.set(control.id, sliderValue: $0, in: &recipe) })
                let picking = WhiteBalancePicking.offers(control.id) ? whiteBalance : nil
                VStack(alignment: .leading, spacing: Space.s1) {
                    switch style {
                    case .pointer:
                        ParameterSlider(AdjustmentText.label(declaration), value: value, spec: spec,
                                        help: AdjustmentText.help(declaration),
                                        accessory: picking.map { AnyView(WhiteBalancePickButton($0)) },
                                        onEditingChanged: { onEditingChanged(declaration, $0) })
                    case .touch:
                        TouchParameterSlider(AdjustmentText.label(declaration), value: value, spec: spec,
                                             help: AdjustmentText.help(declaration),
                                             onEditingChanged: { onEditingChanged(declaration, $0) },
                                             onResetGroup: { panel.reset(group: declaration.group, in: &recipe) })
                    }
                    if let notice = picking?.notice { WhiteBalanceNoticeLine(notice) }
                    if control.id == "tone.exposure" { FilmExposureNote(recipe: recipe, panel: panel) }
                    LookExposureAutoNote(control: control)
                }
                .disabled(!control.isAvailable)
            }
        case .bool:
            Toggle(isOn: Binding(get: { control.isOn }, set: { panel.set(control.id, isOn: $0, in: &recipe) })) {
                AdjustmentText.label(declaration)
            }
            .toggleStyle(.hdrSwitch)
            .frame(minHeight: style == .touch ? 44 : nil)
        case .choice:
            AdjustmentChoiceRow(control: control, style: style,
                                selection: Binding(get: { control.selectedOption ?? "" },
                                                   set: { panel.set(control.id, option: $0, in: &recipe) }))
        case .curve:
            // The Mac's inspector draws the curve editor; the iPad's Studio draws its own,
            // and the iPhone's dock has none.
            if style == .pointer {
                ToneCurveSection(recipe: $recipe, control: control, panel: panel, style: style,
                                 onEditingChanged: onEditingChanged)
            }
        case .reference:
            let selection = Binding(get: { control.reference ?? "" },
                                    set: { panel.set(control.id, reference: $0.isEmpty ? nil : $0, in: &recipe) })
            if control.id == Recipe.lookID {
                LookPicker(control: control, panel: panel, style: style, selection: selection, onLibrary: onLUTLibrary)
            } else {
                AdjustmentReferenceRow(control: control, panel: panel, style: style, selection: selection)
            }
        }
    }
}

/// A switch the photo does not offer, where it would be: its name, and in
/// the switch's place why not.
struct UnsupportedRow: View {
    let declaration: ParameterDeclaration
    let style: AdjustmentControlStyle

    var body: some View {
        HStack(spacing: Space.s3) {
            AdjustmentText.label(declaration)
                .foregroundStyle(Color.hdr.inkDisabled)
            Spacer(minLength: Space.s2)
            AdjustmentText.noProfile
                .foregroundStyle(Color.hdr.inkMuted)
        }
        .font(.hdr.caption)
        .frame(minHeight: style == .touch ? 44 : 20)
        .accessibilityElement(children: .combine)
    }
}

/// A choice: segments when it has up to three options (the HDR source),
/// otherwise a menu (LUT spaces). One offered option is a fact, not a choice:
/// for a photo with its own HDR the source is a line of text.
struct AdjustmentChoiceRow: View {
    let control: AdjustmentControl
    let style: AdjustmentControlStyle
    /// The chosen option id.
    let selection: Binding<String>

    var body: some View {
        let declaration = control.declaration
        VStack(alignment: .leading, spacing: Space.s1) {
            if control.options.count == 1, let only = control.options.first {
                AdjustmentText.option(only)
                    .font(.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if control.options.count <= 3 {
                AdjustmentText.label(declaration).font(.hdr.caption)
                ParameterSegmented(AdjustmentText.label(declaration),
                                   selection: selection,
                                   choices: control.options.map {
                                       SegmentedChoice(AdjustmentText.option($0), value: $0.id,
                                                       isEnabled: !control.disabledOptions.contains($0.id))
                                   })
                .frame(minHeight: style == .touch ? 44 : nil)
                if let note = AdjustmentText.note(for: control) {
                    note.font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                }
            } else {
                Picker(selection: selection) {
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
                    AdjustmentText.label(declaration).font(.hdr.caption)
                }
                .pickerStyle(.menu)
                .frame(minHeight: style == .touch ? 44 : nil)
            }
        }
    }
}

/// `look.lut`: the name as a menu (long names, the keyboard) with the
/// library beside it, over a row of tiles: None, then each library LUT on
/// the photo (`AdjustmentContext.lutPreviews`; its colour mark until the
/// preview is in). The chosen tile scrolls into view.
struct LookPicker: View {
    let control: AdjustmentControl
    let panel: AdjustmentPanel
    let style: AdjustmentControlStyle
    /// The chosen LUT hash; empty for none.
    let selection: Binding<String>
    let onLibrary: (() -> Void)?
    @Environment(\.lookPickerShown) private var shown

    var body: some View {
        let side: CGFloat = style == .touch ? 60 : 52
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                AdjustmentReferenceRow(control: control, panel: panel, style: style, selection: selection)
                if let onLibrary {
                    Button(action: onLibrary) {
                        Image(systemName: "swatchpalette")
                            .frame(minWidth: style == .touch ? 44 : 24, minHeight: style == .touch ? 44 : 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .help(Text("design.lut.library", bundle: .module))
                    .accessibilityLabel(Text("design.lut.library", bundle: .module))
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Space.s2) {
                        tile("", name: Text("look.lut.none", bundle: .module), hash: nil, side: side)
                        ForEach(panel.context.luts, id: \.contentHash) { lut in
                            tile(lut.contentHash, name: Text(verbatim: lut.name), hash: lut.contentHash, side: side)
                                .disabled(control.disabledOptions.contains(lut.contentHash))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .onAppear {
                    shown(true)
                    proxy.scrollTo(selection.wrappedValue, anchor: .center)
                }
                .onDisappear { shown(false) }
                .onChange(of: selection.wrappedValue) { _, id in
                    withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func tile(_ id: String, name: Text, hash: String?, side: CGFloat) -> some View {
        let isSelected = selection.wrappedValue == id
        return Button { selection.wrappedValue = id } label: {
            VStack(spacing: 4) {
                LUTThumbnail(image: panel.context.lutPreviews[id], contentHash: hash, side: side, isSelected: isSelected)
                name
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.hdr.inkStrong : Color.hdr.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: side + 8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(id)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A LUT from the library, or a model: a menu of what the context offers.
struct AdjustmentReferenceRow: View {
    let control: AdjustmentControl
    let panel: AdjustmentPanel
    let style: AdjustmentControlStyle
    /// The chosen LUT hash or model id; empty for none.
    let selection: Binding<String>

    var body: some View {
        Picker(selection: selection) {
            if control.id == Recipe.lookID {
                Text("look.lut.none", bundle: .module).tag("")
                ForEach(panel.context.luts, id: \.contentHash) { lut in
                    Text(verbatim: lut.name).tag(lut.contentHash)
                        .disabled(control.disabledOptions.contains(lut.contentHash))
                }
            } else {
                ForEach(panel.context.models) { model in
                    Text(verbatim: model.name).tag(model.id)
                }
            }
        } label: {
            AdjustmentText.label(control.declaration).font(.hdr.caption)
        }
        .pickerStyle(.menu)
        .frame(minHeight: style == .touch ? 44 : nil)
    }
}

extension AdjustmentText {
    /// A line a declaration cannot carry: under the HDR source, what AI does.
    public static func note(for control: AdjustmentControl) -> Text? {
        guard control.id == Recipe.hdrSourceID, let selected = control.selectedOption,
              HDRSource(rawValue: selected)?.usesModel == true else { return nil }
        return Text("hdr.source.aiNote", bundle: .module)
    }
}

/// The look group in the inspector: built-in films or imported LUTs, one at
/// a time, each kind with its own row of looks shown on the photo and the
/// controls that belong to it (the film's strength, exposure and
/// antihalation layer; the LUT's strength and spaces). Then, after a
/// hairline and whichever kind is shown, grain and halation, which work on
/// every photo: with a film, with a LUT or with no look at all.
struct LookSection: View {
    @Binding var recipe: Recipe
    let state: AdjustmentGroupState
    let panel: AdjustmentPanel
    let style: AdjustmentControlStyle
    /// The control a note asked to show: its kind's tab comes forward.
    var revealing: String?
    let onEditingChanged: (ParameterDeclaration, Bool) -> Void
    let onLUTLibrary: (() -> Void)?

    enum Kind: Hashable { case builtIn, imported }

    /// The tab to show when `id` is to be brought into view: a film's control
    /// is under Built-in (a film stays on while its LUT tab is browsed); any
    /// other look control is the LUT's.
    static func kind(revealing id: String?, current: Kind) -> Kind {
        if id == lutExposureID { return .imported }
        guard let id, Adjustments.declaration(id)?.group == .look else { return current }
        return id.hasPrefix(Recipe.filmID) ? .builtIn : current
    }

    /// The kind shown, once chosen; until then the recipe's.
    @State private var chosen: Kind?

    private var kind: Kind { chosen ?? (recipe.look != nil ? .imported : .builtIn) }

    var body: some View {
        let film = state.controls.first { $0.id == Recipe.filmID }
        let lut = state.controls.first { $0.id == Recipe.lookID }
        let filmControls = state.controls.filter { $0.id.hasPrefix(Recipe.filmID) && $0.id != Recipe.filmID }
        let effects = state.controls.filter { Adjustments.isEffect($0.id) }
        // A Log LUT's exposure stands right under the LUT, before its strength and spaces.
        let lutRest = state.controls.filter {
            !$0.id.hasPrefix(Recipe.filmID) && $0.id != Recipe.lookID && !Adjustments.isEffect($0.id)
        }
        let lutControls = lutRest.filter { $0.id == lutExposureID } + lutRest.filter { $0.id != lutExposureID }
        VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s4) {
            ParameterSegmented(Text("look.kind", bundle: .module),
                               selection: Binding(get: { kind }, set: { chosen = $0 }),
                               choices: [SegmentedChoice(Text("look.kind.builtIn", bundle: .module), value: Kind.builtIn),
                                         SegmentedChoice(Text("look.kind.imported", bundle: .module), value: Kind.imported)])
                .frame(minHeight: style == .touch ? 44 : nil)
            switch kind {
            case .builtIn:
                if let film { FilmPicker(recipe: $recipe, control: film, panel: panel, style: style) }
                rows(filmControls)
            case .imported:
                if let lut {
                    AdjustmentRow(recipe: $recipe, control: lut, panel: panel, style: style,
                                  onEditingChanged: onEditingChanged, onLUTLibrary: onLUTLibrary)
                }
                rows(lutControls.filter { !LookSpacesRow.isSpace($0.id) })
                if let spaces = LookSpacesRow.spaces(in: lutControls) {
                    LookSpacesRow(recipe: $recipe, input: spaces.input, output: spaces.output, panel: panel, style: style)
                        .id(LookSpacesRow.inputID)
                }
            }
            if !effects.isEmpty {
                Rectangle().fill(Color.hdr.line).frame(height: 1)
                rows(effects)
            }
        }
        .onChange(of: revealing) { chosen = Self.kind(revealing: revealing, current: kind) }
    }

    private func rows(_ controls: [AdjustmentControl]) -> some View {
        ForEach(controls) { control in
            AdjustmentRow(recipe: $recipe, control: control, panel: panel, style: style,
                          onEditingChanged: onEditingChanged, onLUTLibrary: onLUTLibrary)
                .id(control.id)
        }
    }
}

/// `look.film` as tiles: None, then each stock on the photo (the preview
/// key `film:` + stock; its colour mark until the preview is in). Choosing a
/// stock is `AdjustmentPanel.chooseFilm`; None removes whichever look is on.
struct FilmPicker: View {
    @Binding var recipe: Recipe
    let control: AdjustmentControl
    let panel: AdjustmentPanel
    let style: AdjustmentControlStyle
    @Environment(\.lookPickerShown) private var shown

    var body: some View {
        let side: CGFloat = style == .touch ? 60 : 52
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Space.s2) {
                    tile("none", name: Text("look.lut.none", bundle: .module), preview: "", mark: nil, side: side,
                         isSelected: control.selectedOption == "none" && recipe.look == nil)
                    // Negatives, slides, motion-picture negatives, each after a rule.
                    ForEach(AdjustmentText.optionSections(control).filter { $0.filmFamily != nil }) { section in
                        Capsule()
                            .fill(Color.hdr.line)
                            .frame(width: 1, height: side * 0.6)
                            .padding(.top, side * 0.2)
                            .help(section.title ?? Text(verbatim: ""))
                        ForEach(section.options, id: \.id) { option in
                            tile(option.id, name: AdjustmentText.option(option), preview: "film:" + option.id, mark: option.id,
                                 side: side, isSelected: control.selectedOption == option.id)
                                .disabled(control.disabledOptions.contains(option.id))
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onAppear {
                shown(true)
                proxy.scrollTo(control.selectedOption ?? "none", anchor: .center)
            }
            .onDisappear { shown(false) }
            .onChange(of: control.selectedOption) { _, id in
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id ?? "none", anchor: .center) }
            }
        }
    }

    private func choose(_ stock: String) {
        var edited = recipe
        panel.chooseFilm(stock, in: &edited)
        recipe = edited
    }

    private func tile(_ id: String, name: Text, preview: String, mark: String?, side: CGFloat,
                      isSelected: Bool) -> some View {
        Button { choose(id) } label: {
            VStack(spacing: 4) {
                LUTThumbnail(image: panel.context.lutPreviews[preview], contentHash: mark, side: side, isSelected: isSelected)
                // Two lines, so a stock's name ("Kodak Portra 400") reads whole.
                name
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.hdr.inkStrong : Color.hdr.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: side + 8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(id)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
