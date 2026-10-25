import HyperDRRecipe
import SwiftUI

/// `look.exposure` (adjust-tools §4.2), spelled as an `id:` argument so the
/// catalogue check does not take it for a string key.
private func parameterID(id: String) -> String { id }
let lutExposureID = parameterID(id: "look.exposure")

extension EnvironmentValues {
    /// Set by a host that can bring a control into view: it opens the group the
    /// control sits in (or the tool that holds it) and scrolls to the row with
    /// that id. Without it the film exposure note under Light's exposure row is
    /// not shown (the iPhone's bar, for now).
    @Entry public var revealControl: ((String) -> Void)?
}

/// The small line under Light's exposure row while a film or a Log LUT with
/// its own exposure is on, saying what exposure the look takes ("Film auto
/// exposure +0.59 · adjust in Style", "LUT auto exposure +1.42 · …", the
/// manual value when it was set by hand). Tapping it brings the look's
/// exposure row into view (adjust-controls F4, adjust-tools §4.2).
public struct FilmExposureNote: View {
    /// The film exposure row's id, also the id its row is scrolled to by.
    public static let rowID = Recipe.filmExposureID
    /// The LUT exposure row's id (a Log LUT's own exposure).
    public static let lutRowID = lutExposureID

    private let recipe: Recipe
    private let panel: AdjustmentPanel
    @Environment(\.revealControl) private var reveal
    @Environment(\.locale) private var locale

    public init(recipe: Recipe, panel: AdjustmentPanel) {
        self.recipe = recipe
        self.panel = panel
    }

    /// The row the note speaks of: the film's exposure while a film is on,
    /// else a LUT's, when its input is Log and the row is shown.
    static func row(recipe: Recipe, panel: AdjustmentPanel) -> (id: String, control: AdjustmentControl, isLUT: Bool)? {
        let controls = panel.group(group: .look, in: recipe)?.controls ?? []
        if let film = controls.first(where: { $0.id == rowID }) { return (rowID, film, false) }
        if let lut = controls.first(where: { $0.id == lutRowID }) { return (lutRowID, lut, true) }
        return nil
    }

    /// The note's words, nil when no look with its own exposure is on or the photo cannot say.
    static func text(recipe: Recipe, panel: AdjustmentPanel, locale: Locale) -> String? {
        guard let row = row(recipe: recipe, panel: panel), let spec = row.control.spec else { return nil }
        let control = row.control
        let number = control.number.map { spec.format.display($0) }
        guard let number else {
            return control.isAutomatic
                ? DesignStrings.string(row.isLUT ? "design.lutNote.autoPending" : "design.filmNote.autoPending", bundle: .module, locale: locale)
                : nil
        }
        let key = row.isLUT ? (control.isAutomatic ? "design.lutNote.auto %@" : "design.lutNote.manual %@")
                            : (control.isAutomatic ? "design.filmNote.auto %@" : "design.filmNote.manual %@")
        return String(format: DesignStrings.string(key, bundle: .module, locale: locale), number)
    }

    public var body: some View {
        if let reveal, let text = Self.text(recipe: recipe, panel: panel, locale: locale),
           let row = Self.row(recipe: recipe, panel: panel) {
            Button { reveal(row.id) } label: {
                Label {
                    Text(verbatim: text)
                } icon: {
                    Image(systemName: "camera.metering.center.weighted")
                }
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(row.isLUT ? "design.lutNote.hint" : "design.filmNote.hint", bundle: .module))
        }
    }
}
