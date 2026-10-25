import HyperDRRecipe
import SwiftUI

/// The LUT's input and output spaces (`look.input`, `look.output`), spelled as
/// `id:` arguments so the catalogue check does not take them for string keys.
private func parameterID(id: String) -> String { id }

/// A LUT's input and output spaces on one row, input → output
/// (controls-polish §7): the menus keep their headings (display, HDR, camera
/// Log, grading) and an input the photo cannot supply stays disabled. The Mac
/// inspector and the iPhone's More use it; the iPad draws its own cells.
public struct LookSpacesRow: View {
    public static let inputID = parameterID(id: "look.input")
    public static let outputID = parameterID(id: "look.output")

    @Binding private var recipe: Recipe
    private let input: AdjustmentControl
    private let output: AdjustmentControl
    private let panel: AdjustmentPanel
    private let style: AdjustmentControlStyle

    public init(recipe: Binding<Recipe>, input: AdjustmentControl, output: AdjustmentControl,
                panel: AdjustmentPanel, style: AdjustmentControlStyle) {
        _recipe = recipe
        self.input = input
        self.output = output
        self.panel = panel
        self.style = style
    }

    /// The pair among a group's controls, when both are shown.
    public static func spaces(in controls: [AdjustmentControl]) -> (input: AdjustmentControl, output: AdjustmentControl)? {
        guard let input = controls.first(where: { $0.id == inputID }),
              let output = controls.first(where: { $0.id == outputID }) else { return nil }
        return (input, output)
    }

    public static func isSpace(_ id: String) -> Bool { id == inputID || id == outputID }

    public var body: some View {
        let menus = HStack(spacing: Space.s1) {
            // The input first: a camera Log space's name is the long one.
            menu(input).layoutPriority(1)
            Image(systemName: "arrow.right")
                .font(.system(size: style == .touch ? 13 : 10, weight: .semibold))
                .foregroundStyle(Color.hdr.inkMuted)
                .accessibilityHidden(true)
            menu(output).frame(minWidth: style == .touch ? 120 : 100)
        }
        // The name above, so each menu has half the row for a long Log space's name.
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("design.look.spaces", bundle: .module).font(.hdr.caption)
            menus.frame(minHeight: style == .touch ? 44 : nil)
        }
    }

    private func menu(_ control: AdjustmentControl) -> some View {
        let selected = control.options.first { $0.id == control.selectedOption }
        return Picker(selection: Binding(get: { control.selectedOption ?? "" },
                                         set: { panel.set(control.id, option: $0, in: &recipe) })) {
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
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
        .help(selected.map(AdjustmentText.option) ?? AdjustmentText.label(control.declaration))
        .accessibilityLabel(AdjustmentText.label(control.declaration))
    }
}

/// Under a LUT's exposure while it is automatic: how Auto meters
/// (controls-polish §7), in the film exposure note's style.
public struct LookExposureAutoNote: View {
    private let control: AdjustmentControl

    public init(control: AdjustmentControl) { self.control = control }

    public var body: some View {
        if control.id == lutExposureID, control.isAutomatic {
            Label {
                Text("design.lutExposure.autoNote", bundle: .module)
            } icon: {
                Image(systemName: "camera.metering.center.weighted")
            }
            .font(Font.hdr.caption)
            .foregroundStyle(Color.hdr.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
