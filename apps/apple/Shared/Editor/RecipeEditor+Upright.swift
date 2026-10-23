import Foundation
import HyperDRRecipe

/// The crop pane's Auto: finds the photo's straight lines and solves the
/// straightening and perspective that make them upright, as one undo step.
///
/// CONTRACT for the views (stub; the backend fills it in):
/// - `autoUpright(_:)` starts the analysis and returns at once; calling it
///   again while one runs restarts it with the new mode.
/// - `uprightStatus` is `.analyzing` while it runs, then `.idle` once the
///   geometry is applied, or `.noLines` / `.failed` when nothing was applied.
///   Any later geometry edit or leaving the crop pane returns it to `.idle`.
extension RecipeEditor {
    enum UprightStatus: Equatable, Sendable {
        case idle
        case analyzing(UprightMode)
        /// Not enough straight lines to decide; the geometry is unchanged.
        case noLines
        /// The analysis failed (render error); the geometry is unchanged.
        case failed
    }

    func autoUpright(_ mode: UprightMode = .auto) {
        // Stub: implemented by the backend.
    }
}
