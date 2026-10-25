import HyperDRRecipe
import SwiftUI

extension EnvironmentValues {
    /// Set by a host that can bring a control into view: it opens the group the
    /// control sits in (or the tool that holds it) and scrolls to the row with
    /// that id. Without it the film exposure note under Light's exposure row is
    /// not shown (the iPhone's bar, for now).
    @Entry public var revealControl: ((String) -> Void)?
}

/// The small line under Light's exposure row while a film is on, saying what
/// exposure the film takes ("Film auto exposure +0.59 · adjust in Style", the
/// manual value when it was set by hand). Tapping it brings the film exposure
/// row into view (adjust-controls F4).
public struct FilmExposureNote: View {
    /// The film exposure row's id, also the id its row is scrolled to by.
    public static let rowID = Recipe.filmExposureID

    private let recipe: Recipe
    private let panel: AdjustmentPanel
    @Environment(\.revealControl) private var reveal
    @Environment(\.locale) private var locale

    public init(recipe: Recipe, panel: AdjustmentPanel) {
        self.recipe = recipe
        self.panel = panel
    }

    /// The note's words, nil when no film is on or the photo cannot say.
    static func text(recipe: Recipe, panel: AdjustmentPanel, locale: Locale) -> String? {
        guard let control = panel.group(group: .look, in: recipe)?.controls.first(where: { $0.id == rowID }),
              let spec = control.spec else { return nil }
        let number = control.number.map { spec.format.display($0) }
        guard let number else {
            return control.isAutomatic
                ? DesignStrings.string("design.filmNote.autoPending", bundle: .module, locale: locale) : nil
        }
        let format = control.isAutomatic
            ? DesignStrings.string("design.filmNote.auto %@", bundle: .module, locale: locale)
            : DesignStrings.string("design.filmNote.manual %@", bundle: .module, locale: locale)
        return String(format: format, number)
    }

    public var body: some View {
        if let reveal, let text = Self.text(recipe: recipe, panel: panel, locale: locale) {
            Button { reveal(Self.rowID) } label: {
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
            .accessibilityHint(Text("design.filmNote.hint", bundle: .module))
        }
    }
}
