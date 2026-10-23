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
/// - Groups collapse; HDR and Light start open, the others closed, and a
///   collapsed group sums up what was changed in it.
/// - HDR's header carries "Affects HDR only" and the HDR switch; turning it
///   off hides the rest of the group.
/// - A group with changes shows ↺, which resets the group; Reset All sits at
///   the top.
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

    @State private var expanded: Set<AdjustmentGroupID>
    @Environment(\.locale) private var locale

    /// `only` shows just those groups, all open: the iPad sidebar shows one
    /// tab's groups at a time, as the iPhone's dock does, and keeps Reset All
    /// in the toolbar's More menu instead of above them.
    public init(recipe: Binding<Recipe>, panel: AdjustmentPanel, style: AdjustmentControlStyle = .pointer,
                only: Set<AdjustmentGroupID>? = nil,
                onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in },
                onReset: ((AdjustmentReset) -> Void)? = nil, onLUTLibrary: (() -> Void)? = nil) {
        _recipe = recipe
        self.panel = panel
        self.style = style
        self.only = only
        self.onEditingChanged = onEditingChanged
        self.onReset = onReset
        self.onLUTLibrary = onLUTLibrary
        _expanded = State(initialValue: only ?? [.hdr, .light])
    }

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
            if only == nil { resetAll(groups) }
            ForEach(groups) { state in
                groupView(state)
            }
        }
    }

    private func resetAll(_ groups: [AdjustmentGroupState]) -> some View {
        HStack {
            Spacer()
            Button { reset(.all) } label: {
                Text("design.adjust.resetAll", bundle: .module)
            }
            .buttonStyle(.plain)
            .font(.system(size: TypeScale.Size.caption, weight: .medium))
            .foregroundStyle(groups.contains(where: \.isModified) ? Color.hdr.accent : Color.hdr.inkDisabled)
            .disabled(!groups.contains(where: \.isModified))
        }
        .padding(.horizontal, 20)
        .frame(minHeight: style == .touch ? 44 : 32)
    }

    private func controls(_ state: AdjustmentGroupState) -> some View {
        VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s4) {
            if state.affectsHDROnly {
                Text("group.hdrOnly", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.hdr.amber)
            }
            ForEach(state.controls) { control in
                AdjustmentRow(recipe: $recipe, control: control, panel: panel, style: style,
                              onEditingChanged: onEditingChanged, onLUTLibrary: onLUTLibrary)
            }
            ForEach(state.unsupported, id: \.id) { declaration in
                UnsupportedRow(declaration: declaration, style: style)
            }
        }
    }

    private func groupView(_ state: AdjustmentGroupState) -> some View {
        let isExpanded = Binding(get: { expanded.contains(state.group) },
                                 set: { if $0 { expanded.insert(state.group) } else { expanded.remove(state.group) } })
        return ParameterGroup(AdjustmentText.group(state.group), systemImage: AdjustmentSymbols.group(state.group),
                              summary: isExpanded.wrappedValue ? nil : Text(verbatim: AdjustmentText.summary(state, locale: locale)),
                              isExpanded: isExpanded) {
            if state.group == .look {
                LookSection(recipe: $recipe, state: state, panel: panel, style: style,
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
            .padding(.trailing, state.isModified || state.headerToggle != nil ? 20 : 0)
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
        let declaration = control.declaration
        switch control.kind {
        case .float, .floatOrAuto:
            if let spec = control.spec {
                let value = Binding(get: { control.sliderValue },
                                    set: { panel.set(control.id, sliderValue: $0, in: &recipe) })
                Group {
                    switch style {
                    case .pointer:
                        ParameterSlider(AdjustmentText.label(declaration), value: value, spec: spec,
                                        help: AdjustmentText.help(declaration),
                                        onEditingChanged: { onEditingChanged(declaration, $0) })
                    case .touch:
                        TouchParameterSlider(AdjustmentText.label(declaration), value: value, spec: spec,
                                             help: AdjustmentText.help(declaration),
                                             onEditingChanged: { onEditingChanged(declaration, $0) },
                                             onResetGroup: { panel.reset(group: declaration.group, in: &recipe) })
                    }
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
/// controls that belong to it (the film's strength, exposure, grain and
/// halation; the LUT's strength and spaces).
struct LookSection: View {
    @Binding var recipe: Recipe
    let state: AdjustmentGroupState
    let panel: AdjustmentPanel
    let style: AdjustmentControlStyle
    let onEditingChanged: (ParameterDeclaration, Bool) -> Void
    let onLUTLibrary: (() -> Void)?

    enum Kind: Hashable { case builtIn, imported }

    /// The kind shown, once chosen; until then the recipe's.
    @State private var chosen: Kind?

    private var kind: Kind { chosen ?? (recipe.look != nil ? .imported : .builtIn) }

    var body: some View {
        let film = state.controls.first { $0.id == Recipe.filmID }
        let lut = state.controls.first { $0.id == Recipe.lookID }
        let filmControls = state.controls.filter { $0.id.hasPrefix(Recipe.filmID) && $0.id != Recipe.filmID }
        let lutControls = state.controls.filter { !$0.id.hasPrefix(Recipe.filmID) && $0.id != Recipe.lookID }
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
                rows(lutControls)
            }
        }
    }

    private func rows(_ controls: [AdjustmentControl]) -> some View {
        ForEach(controls) { control in
            AdjustmentRow(recipe: $recipe, control: control, panel: panel, style: style,
                          onEditingChanged: onEditingChanged, onLUTLibrary: onLUTLibrary)
        }
    }
}

/// `look.film` as tiles: None, then each stock on the photo (the preview
/// key `film:` + stock; its colour mark until the preview is in). Choosing a
/// stock puts its exposure back on the meter and its antihalation layer back
/// on, in the same undo step; None removes whichever look is on.
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
                    ForEach(control.options.filter { $0.id != "none" }, id: \.id) { option in
                        tile(option.id, name: AdjustmentText.option(option), preview: "film:" + option.id, mark: option.id,
                             side: side, isSelected: control.selectedOption == option.id)
                            .disabled(control.disabledOptions.contains(option.id))
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
        if stock == "none" {
            panel.set(control.id, option: "none", in: &edited)
            panel.set(Recipe.lookID, reference: nil, in: &edited)
        } else {
            panel.set(control.id, option: stock, in: &edited)
            panel.setAutomatic(Recipe.filmExposureID, in: &edited)
            panel.reset(Recipe.filmAntihalationID, in: &edited)
        }
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
