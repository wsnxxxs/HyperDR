import Foundation
import HyperDRRecipe
import HyperDRRender

/// Prepared once; package may synchronously request any band more than once.
/// Implementations must freeze source/recipe/model and never accumulate a canvas.
public protocol ExportRowSource: Sendable {
    var report: ExportRenderReport { get }
    func read(y: Int, count: Int) throws -> ExportStripe
}

/// Separate from the legacy whole-output push API so Fakes state their capability.
public protocol ExportRowRendering: Sendable {
    func prepareRows(_ source: HyperDRRender.ExportSource, recipe: Recipe, lut: ColorLUT?,
                     modelGain: ModelGainPrediction?, request: ExportRenderRequest,
                     rows: Int) async throws -> any ExportRowSource
}
