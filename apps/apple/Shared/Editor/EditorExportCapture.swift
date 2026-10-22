import Foundation
import HyperDRRecipe
import HyperDRRender

/// What an export freezes of the editor (`RecipeEditor.exportCapture`): the
/// photo, its recipe (with its `hdr.model` selection) and the LUT. Hosts turn it into Kit's
/// `RecipeExportSnapshot` with the source revision they captured when the
/// photo was opened (`Shared/Export`).
nonisolated struct EditorExportCapture: Sendable {
    let source: EditorSource
    let recipe: Recipe
    /// The LUT the recipe's look takes effect with, if any.
    let lut: ColorLUT?
    /// What `auto` resolved to in the shown frame, when it shows this recipe.
    let automaticValues: [String: Double]

    /// The exported photo's size: the source after the recipe's geometry.
    var photoSize: HyperDRRender.PixelSize { recipe.geometry.outputSize(of: source.pixelSize) }

    var hdrEnabled: Bool { recipe.conditionValue("hdr.enabled")?.boolValue != false }

    /// The HDR range the edit asks for, in stops: the set value, or what auto
    /// resolved to (3, the automatic ceiling, before any frame has).
    var peakStops: Double {
        recipe.conditionValue("hdr.range")?.numberValue ?? automaticValues["hdr.range"] ?? 3
    }
}
