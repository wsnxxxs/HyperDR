import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// The Style tool (ipad-studio §3.4): built-in films or imported LUTs, one
/// kind at a time; each look as a tile of this photo with it applied, so the
/// choice is made by eye; then that kind's controls. One look at a time:
/// choosing a film removes the LUT and the other way round (the recipe sees
/// to it), and "None" removes whichever is on.
///
/// - Films: choosing one puts its exposure back on the meter and its
///   antihalation layer back on, in the same undo step, as on the iPhone and
///   the Mac. Its strength, exposure and antihalation layer follow the grid;
///   grain and halation are the Adjust tool's, for every photo.
/// - LUTs: the library's LUTs, then a tile that opens the library; the LUT's
///   strength and its input and output spaces follow the grid.
struct PadLookTool: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    var columns = 1
    var onEditingChanged: (ParameterDeclaration, Bool) -> Void = { _, _ in }
    var onReset: (AdjustmentReset) -> Void = { _ in }
    var onLibrary: () -> Void = {}

    /// The kind the grid shows, once chosen; until then the recipe's.
    @State private var chosenKind: LookKind?
    @Environment(\.lookPickerShown) private var shown

    private var kind: LookKind { chosenKind ?? (recipe.look != nil ? .imported : .builtIn) }

    var body: some View {
        if let state = panel.group(group: .look, in: recipe) {
            let film = state.controls.first { $0.id == Recipe.filmID }
            let lut = state.controls.first { $0.id == Recipe.lookID }
            let filmControls = state.controls.filter { $0.id.hasPrefix(Recipe.filmID) && $0.id != Recipe.filmID }
            let lutControls = state.controls.filter { !$0.id.hasPrefix(Recipe.filmID) && $0.id != Recipe.lookID }
            VStack(alignment: .leading, spacing: 12) {
                PadSegments(options: LookKind.allCases.map { PadSegments.Option(value: $0, label: Text($0.title)) },
                            selection: kind) { chosenKind = $0 }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: columns > 1 ? 92 : 84), spacing: 10)],
                          alignment: .leading, spacing: 12) {
                    switch kind {
                    case .builtIn:
                        if let film { films(film) }
                    case .imported:
                        if let lut { luts(lut) }
                    }
                }
                .onAppear { shown(true) }
                .onDisappear { shown(false) }
                let controls = kind == .builtIn ? filmControls : lutControls
                if !controls.isEmpty {
                    PadRows(columns: columns) {
                        ForEach(controls) { control in
                            row(control)
                        }
                    }
                }
            }
        }
    }

    // MARK: Looks

    @ViewBuilder private func films(_ control: AdjustmentControl) -> some View {
        let previews = panel.context.lutPreviews
        LookTile(image: previews[LookPreviews.none], mark: nil, name: AdjustmentText.command(.noLUT),
                 isCurrent: control.selectedOption == "none" && recipe.look == nil, action: removeLook)
        ForEach(control.options.filter { $0.id != "none" }, id: \.id) { option in
            LookTile(image: previews[LookPreviews.filmKey(option.id)], mark: option.id, name: AdjustmentText.option(option),
                     isCurrent: control.selectedOption == option.id) {
                // One write, one undo step (`AdjustmentPanel.chooseFilm`).
                var edited = recipe
                panel.chooseFilm(option.id, in: &edited)
                recipe = edited
            }
            .disabled(control.disabledOptions.contains(option.id))
        }
    }

    @ViewBuilder private func luts(_ control: AdjustmentControl) -> some View {
        let previews = panel.context.lutPreviews
        let filmIsOn = panel.group(group: .look, in: recipe)?.controls
            .first { $0.id == Recipe.filmID }.map { $0.selectedOption != "none" } ?? false
        LookTile(image: previews[LookPreviews.none], mark: nil, name: AdjustmentText.command(.noLUT),
                 isCurrent: control.reference == nil && !filmIsOn, action: removeLook)
        ForEach(panel.context.luts, id: \.contentHash) { lut in
            LookTile(image: previews[lut.contentHash], mark: lut.contentHash, name: Text(verbatim: lut.name),
                     isCurrent: control.reference == lut.contentHash) {
                panel.set(control.id, reference: lut.contentHash, in: &recipe)
            }
            .disabled(control.disabledOptions.contains(lut.contentHash))
        }
        Button(action: onLibrary) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { Image(systemName: "plus").font(.title3).foregroundStyle(.secondary) }
                Text("ios.lut.short")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    private func removeLook() {
        panel.set(Recipe.lookID, reference: nil, in: &recipe)
    }

    // MARK: Controls

    @ViewBuilder private func row(_ control: AdjustmentControl) -> some View {
        let declaration = control.declaration
        switch control.kind {
        case .float, .floatOrAuto:
            if let spec = control.spec {
                PadSlider(AdjustmentText.label(declaration),
                          value: Binding(get: { control.sliderValue },
                                         set: { panel.set(control.id, sliderValue: $0, in: &recipe) }),
                          spec: spec, help: AdjustmentText.help(declaration),
                          onEditingChanged: { onEditingChanged(declaration, $0) },
                          onResetGroup: { onReset(.group(.look)) })
                    .disabled(!control.isAvailable)
            }
        case .bool:
            PadToggleRow(title: AdjustmentText.label(declaration),
                         isOn: Binding(get: { control.isOn }, set: { panel.set(control.id, isOn: $0, in: &recipe) }),
                         symbol: AdjustmentSymbols.control(declaration))
        case .choice:
            PadChoiceRow(control: control) { panel.set(control.id, option: $0, in: &recipe) }
        case .curve:
            EmptyView()
        case .reference:
            EmptyView()
        }
    }
}

/// One look in the Style grid: the photo with it, its name under it; the
/// chosen one ringed and ticked. Without a preview yet, its colour mark.
private struct LookTile: View {
    let image: CGImage?
    /// The colour mark's seed until the preview is in; nil for "None".
    let mark: String?
    let name: Text
    let isCurrent: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else if let mark {
                            Rectangle().fill(LUTThumbnail.colour(mark).gradient)
                        } else {
                            Rectangle().fill(Color.white.opacity(0.06))
                            Image(systemName: "nosign").foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(isCurrent ? Color.white : Color.white.opacity(0.1), lineWidth: isCurrent ? 2.5 : 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.black, Color.white)
                                .padding(6)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.smooth(duration: 0.2), value: image != nil)
                name
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.smooth(duration: 0.2), value: isCurrent)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
