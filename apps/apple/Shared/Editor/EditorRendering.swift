import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender

/// What the editor asks of the renderer (p7-2b §2, §6), so `RecipeEditor` runs
/// on the real `RenderSession` in the apps and on `FakeEditorRendering` in
/// tests and previews. Foundation, Recipe and Render only: no SwiftUI, AppKit
/// or UIKit, and no Kit or engine.
///
/// - One photo at a time: `open` replaces the previous source.
/// - `render` is cancellable: a cancelled call throws `CancellationError` (or
///   returns a result the caller discards), and the editor never shows it.
/// - The model prediction is kept by the renderer for the open photo;
///   requests only say whether to use it (`usesModelGain`).
nonisolated protocol EditorRendering: AnyObject, Sendable {
    /// Opens the photo at a file URL the caller can read (a security scope, if
    /// any, is held by the caller for the duration of the call). The source's
    /// domain decides the new recipe's input domain.
    func open(_ url: URL) async throws -> EditorSource

    /// Renders the open photo. The recipe's input domain must be the source's.
    func render(_ request: EditorRenderRequest) async throws -> EditorFrame

    /// Computes the AI gain for the open photo with the model `modelID`, loading
    /// the model on first use (§9). Predictions are kept by model id: a render
    /// with `usesModelGain` uses the one for its recipe's `hdr.model`, however
    /// the calls for different models finished. Throws
    /// `EditorRenderingError.modelUnavailable` when the model cannot run on
    /// this device at all; any other error is a failed prediction.
    func predictModelGain(modelID: String) async throws

    /// Installs a LUT the recipe can then reference by `contentHash` (`.cube` text).
    func installLUT(_ cube: Data, contentHash: String) async throws

    /// Drops the open photo and its caches.
    func close() async
}

nonisolated enum EditorRenderingError: Error, Equatable, Sendable {
    /// No photo is open.
    case noSource
    /// The model cannot run here (not built in, device unsupported). The
    /// message is a developer-facing English detail.
    case modelUnavailable(String)
    /// The request is for a photo that is no longer open.
    case staleSource
    /// The recipe references a LUT that was never installed.
    case missingLUT(String)
    /// Render does not offer this yet (developer-facing; see p7-2b §6).
    case unsupported(String)
}

/// The open photo, as the editor and the controls need it.
nonisolated struct EditorSource: Equatable, Sendable {
    let id: UUID
    let url: URL
    let domain: HyperDRRecipe.InputDomain
    /// Full-size oriented pixels (RAW: the native size, whatever the preview develops).
    let pixelSize: HyperDRRender.PixelSize
    /// `fromSource` defaults in the declared units: the RAW white balance,
    /// Apple's noise reduction and sharpness (`AdjustmentContext.sourceValues`).
    var sourceValues: [String: Double] = [:]
    /// Capability strings that hold (`ParameterDeclaration.capability`).
    var capabilities: Set<String> = []
}

/// One render of the open photo.
nonisolated struct EditorRenderRequest: Equatable, Sendable {
    /// `EditorSource.id`; a renderer whose open photo is another refuses the request.
    var sourceID: UUID
    var recipe: Recipe
    /// The whole image's output size.
    var size: HyperDRRender.PixelSize
    /// A region of `size` (detail regions); nil renders the whole image.
    var region: CGRect?
    /// Groups temporarily switched off to see their effect (a render option,
    /// never in the recipe, never undone).
    var bypassedGroups: Set<ParameterGroup> = []
    /// Use the prediction `predictModelGain` produced. False while it is
    /// being computed: the photo shows without AI until then (Lead, §14.3).
    var usesModelGain = false
    /// Part of an interactive drag.
    var isInteractive = false
}

/// A finished render.
nonisolated struct EditorFrame: @unchecked Sendable {
    let request: EditorRenderRequest
    let planes: RenderPlanes
    /// What `auto` parameters resolved to, by id, in the declared units
    /// (`AdjustmentContext.automaticValues`). Empty until Render reports them (R7).
    var automaticValues: [String: Double] = [:]

    var size: HyperDRRender.PixelSize { request.size }
}

extension Recipe {
    /// The comparison recipe for "Original": the declared defaults, but the same
    /// RAW development as `self`, because development belongs to the source
    /// (p7-2b §5).
    nonisolated var original: Recipe {
        var original = Recipe(inputDomain: inputDomain)
        for declaration in Adjustments.all where declaration.cost == .redevelop {
            original.setValue(value(for: declaration.id), for: declaration.id)
        }
        return original
    }

    /// The values that need a new development of the source.
    nonisolated var development: [String: ParameterValue] {
        var values: [String: ParameterValue] = [:]
        for declaration in Adjustments.all where declaration.cost == .redevelop {
            values[declaration.id] = value(for: declaration.id)
        }
        return values
    }
}
