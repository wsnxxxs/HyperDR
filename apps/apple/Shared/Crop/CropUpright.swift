import HyperDRDesign
import HyperDRRecipe

extension RecipeEditor {
    /// The crop pane's Auto for the controls (`GeometryUpright`): the
    /// editor's analysis state and a way to start one.
    var upright: GeometryUpright {
        let analyzing: UprightMode?
        let notice: GeometryUpright.Notice?
        switch uprightStatus {
        case .idle: (analyzing, notice) = (nil, nil)
        case .analyzing(let mode): (analyzing, notice) = (mode, nil)
        case .noLines: (analyzing, notice) = (nil, .noLines)
        case .failed: (analyzing, notice) = (nil, .failed)
        }
        return GeometryUpright(analyzing: analyzing, notice: notice) { [weak self] mode in
            self?.autoUpright(mode)
        }
    }
}
