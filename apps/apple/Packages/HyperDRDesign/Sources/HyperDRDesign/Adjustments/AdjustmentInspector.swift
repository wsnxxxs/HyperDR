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
/// host's undo and preview size, with the declaration being edited.
public struct AdjustmentInspector: View {
    @Binding private var recipe: Recipe
    private let panel: AdjustmentPanel
    private let style: AdjustmentControlStyle
    private let onEditingChanged: (ParameterDeclaration, Bool) -> Void

    @State private var expanded: Set<AdjustmentGroupID> = [.hdr, .light]
    @Environment(\.locale) private var locale

    public init(recipe: Binding<Recipe>, panel: AdjustmentPanel, style: AdjustmentControlStyle = .pointer,
                onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in }) {
        _recipe = recipe
        self.panel = panel
        self.style = style
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        let groups = panel.groups(for: recipe)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button { panel.resetAll(in: &recipe) } label: {
                    Text("design.adjust.resetAll", bundle: .module)
                }
                .buttonStyle(.plain)
                .font(.system(size: TypeScale.Size.caption, weight: .medium))
                .foregroundStyle(groups.contains(where: \.isModified) ? Color.hdr.accent : Color.hdr.inkDisabled)
                .disabled(!groups.contains(where: \.isModified))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: style == .touch ? 44 : 32)
            ForEach(groups) { state in
                groupView(state)
            }
        }
    }

    private func groupView(_ state: AdjustmentGroupState) -> some View {
        let isExpanded = Binding(get: { expanded.contains(state.group) },
                                 set: { if $0 { expanded.insert(state.group) } else { expanded.remove(state.group) } })
        return ParameterGroup(AdjustmentText.group(state.group), systemImage: AdjustmentSymbols.group(state.group),
                              summary: isExpanded.wrappedValue ? nil : Text(verbatim: AdjustmentText.summary(state, locale: locale)),
                              isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s4) {
                if state.affectsHDROnly {
                    Text("group.hdrOnly", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.hdr.amber)
                }
                ForEach(state.controls) { control in
                    AdjustmentRow(recipe: $recipe, control: control, panel: panel, style: style,
                                  onEditingChanged: onEditingChanged)
                }
            }
        } accessory: {
            HStack(spacing: Space.s2) {
                if state.isModified {
                    Button { panel.reset(group: state.group, in: &recipe) } label: {
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

    public init(recipe: Binding<Recipe>, control: AdjustmentControl, panel: AdjustmentPanel,
                style: AdjustmentControlStyle,
                onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in }) {
        _recipe = recipe
        self.control = control
        self.panel = panel
        self.style = style
        self.onEditingChanged = onEditingChanged
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
            AdjustmentReferenceRow(control: control, panel: panel, style: style,
                                   selection: Binding(get: { control.reference ?? "" },
                                                      set: { panel.set(control.id, reference: $0.isEmpty ? nil : $0, in: &recipe) }))
        }
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
                    ForEach(control.options, id: \.id) { option in
                        AdjustmentText.option(option).tag(option.id)
                            .disabled(control.disabledOptions.contains(option.id))
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
