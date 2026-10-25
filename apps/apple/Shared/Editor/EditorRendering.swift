import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender

/// Loading progress; `.rendering` covers the first edited frame after the source opens.
nonisolated enum EditorOpeningStage: String, Equatable, Sendable {
    case reading, loadingDecoder, developing, preparingPreview, rendering
    var order: Int {
        switch self {
        case .reading: 0
        case .loadingDecoder: 1
        case .developing: 2
        case .preparingPreview: 3
        case .rendering: 4
        }
    }
}

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
    /// domain decides the new recipe's input domain. `previewSize` bounds the
    /// first decode or development (nil: full size); later renders decode
    /// again only when they need more pixels or another development.
    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?) async throws -> EditorSource
    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?, restoring: Recipe?) async throws -> EditorSource
    /// `rawDecoderPreference` applies only without a restored recipe; forced
    /// generations must fail if unavailable, and never retry another generation.
    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?, restoring: Recipe?,
              rawDecoderPreference: RAWDecoderPreference,
              progress: @escaping @Sendable (EditorOpeningStage) async -> Void) async throws -> EditorSource
    func openingPreview(_ url: URL) async -> EmbeddedPreview.Image?
    /// Replaces an editable RAW draft with native-area preview pixels, preserving source identity.
    func refinePreview(sourceID: UUID) async throws -> EditorSource?


    /// Renders the open photo, with the display pair the canvas draws. The
    /// recipe's input domain must be the source's. A region renders from the
    /// full-size source.
    func render(_ request: EditorRenderRequest) async throws -> EditorFrame

    func pickWhiteBalance(_ request: EditorRenderRequest, at point: CGPoint) async throws -> WhiteBalanceSample

    /// An SDR thumbnail (Display P3) of a frame's base: export summaries, frames.
    func sdrThumbnail(_ frame: EditorFrame, maximumSize: HyperDRRender.PixelSize) async throws -> CGImage

    /// Computes the AI gain with the recipe's `hdr.model` for the source the
    /// request renders from (its RAW development and bypass), loading the
    /// model on first use (§9). Predictions are kept by that source and model:
    /// a render with `usesModelGain` gets the one for the source it renders
    /// from, or none (`modelGainPending`) when that development has none.
    /// Throws `EditorRenderingError.modelUnavailable` when the model cannot
    /// run on this device at all; any other error is a failed prediction.
    func predictModelGain(_ request: EditorRenderRequest) async throws

    /// Whether this build includes the AI model. Without it (an open-source
    /// build) AI is unavailable from the start and only the analytic
    /// expansion is offered; nothing is loaded to find out.
    var includesModel: Bool { get }

    /// Installs a LUT the recipe can then reference by its `contentHash`.
    func installLUT(_ lut: ColorLUT) async

    /// Drops the open photo and its caches.
    func close() async

    /// Gives up what the open photo holds besides the photo itself (its
    /// preview development, full-size details and the renderer's caches)
    /// while an export develops the photo. The next render develops it again
    /// with the same settings; predictions are kept.
    func yieldMemory() async
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
    /// A `keepsSource` request needs a development the open source does not have.
    case needsDevelopment
    /// The file changed on disk after it was opened (Render's R23-001): the
    /// photo has to be opened again.
    case sourceChanged
    /// Render does not offer this yet (developer-facing; see p7-2b §6).
    case unsupported(String)
}

/// A new photo's preferred decoder failed before it opened. The successful
/// version is recorded in the recipe; hosts may explain the downgrade.
nonisolated struct RAWDecoderFallback: Equatable, Sendable {
    let requested: String
    let used: String
}

/// The open photo, as the editor and the controls need it.
nonisolated struct EditorSource: Equatable, Sendable {
    let id: UUID
    let url: URL
    let domain: HyperDRRecipe.InputDomain
    /// Full-size oriented pixels (RAW: the native size, whatever the preview develops).
    let pixelSize: HyperDRRender.PixelSize
    /// The photo's own values in the declared units (`SourceReport`): the RAW
    /// white balance, Apple's noise reduction and sharpness, which the
    /// `fromSource` defaults show (`AdjustmentContext.sourceValues`), and
    /// facts such as the source's own headroom in `hdr.range` (not the
    /// output range: that is `EditorFrame.automaticValues`).
    var sourceValues: [String: Double] = [:]
    /// Capability strings that hold (`ParameterDeclaration.capability`).
    var capabilities: Set<String> = []
    /// The file carries transparency, which an export fills (Kit's
    /// `ExportSource.hasAlpha`).
    var hasAlpha = false
    var isDraftPreview = false
    var rawDecoderVersion: String? = nil
    var rawDecoderFallback: RAWDecoderFallback? = nil
}

/// One render of the open photo.
nonisolated struct EditorRenderRequest: Equatable, Sendable {
    /// `EditorSource.id`; a renderer whose open photo is another refuses the request.
    var sourceID: UUID
    var recipe: Recipe
    /// The whole image's output size.
    var size: HyperDRRender.PixelSize
    /// A region of `size` in whole pixels, origin top left (detail regions);
    /// nil renders the whole image.
    var region: CGRect?
    /// Groups temporarily switched off to see their effect (a render option,
    /// never in the recipe, never undone).
    var bypassedGroups: Set<ParameterGroup> = []
    /// Use the prediction `predictModelGain` produced for this development.
    /// False while it is being computed: the photo shows without AI until then
    /// (Lead, §14.3).
    var usesModelGain = false
    /// Part of an interactive drag.
    var isInteractive = false
    /// A small render (a LUT preview) from the source the preview has open,
    /// at any size: it never loads or develops the photo again. One whose
    /// recipe needs another development (a Log look on a RAW) throws
    /// `EditorRenderingError.needsDevelopment`. No automatic values.
    var keepsSource = false
    /// The primary edited canvas sets its RAW development/refinement target.
    /// Scopes, original comparisons and thumbnails only sample the current tier.
    var isCanvasPreview = false

    /// Whether the two render the same picture of the same photo, whatever
    /// their size, region or pacing: a detail belongs to a frame
    /// only while this holds.
    func rendersSame(as other: EditorRenderRequest) -> Bool {
        sourceID == other.sourceID && recipe == other.recipe && bypassedGroups == other.bypassedGroups
            && usesModelGain == other.usesModelGain
    }
}

/// A finished render.
nonisolated struct EditorFrame: @unchecked Sendable {
    let request: EditorRenderRequest
    /// The pair export and thumbnails read; never adapted to a display.
    let planes: RenderPlanes
    /// The same render normalized for the canvas (R3): linear P3 base, log2 gain.
    let display: DisplayGainPair
    /// The recipe asks for AI gain but this frame has none yet, because the
    /// prediction is not ready (`RenderPlanes.aiPending`).
    var modelGainPending = false
    var isDraftPreview = false
    /// What `auto` parameters resolve to, by id, in the declared units
    /// (`AdjustmentContext.automaticValues`; `hdr.range` in stops), also for
    /// parameters the recipe sets: the ruler marks it as their default.
    /// Whole-image renders only; a region's is empty.
    var automaticValues: [String: Double] = [:]

    var size: HyperDRRender.PixelSize { request.size }

    /// Whether this rendered frame carries extended range, independent of
    /// the current recipe controls and the screen's available HDR headroom.
    var hasHDRContent: Bool { max(display.baseHeadroom, display.alternateHeadroom) > 0 }
}

extension Recipe {
    /// The comparison recipe retains the source's range and the same RAW
    /// development. An SDR original must not acquire the default HDR expansion.
    nonisolated var original: Recipe {
        // The same crop, so the two line up.
        var original = Recipe(inputDomain: inputDomain, rawDecoderVersion: rawDecoderVersion, geometry: geometry)
        if inputDomain == .sdr { original.setValue(.bool(false), for: "hdr.enabled") }
        for declaration in Adjustments.all where declaration.cost == .redevelop {
            original.setValue(value(for: declaration.id), for: declaration.id)
        }
        return original
    }

    /// The LUT reference when it takes effect: enabled with a strength above
    /// zero. Otherwise the reference stays in the recipe but the renderer gets
    /// no LUT and needs none installed.
    nonisolated var activeLook: LUTReference? {
        guard let look, conditionValue("look.enabled")?.boolValue != false,
              conditionValue("look.strength")?.numberValue != 0 else { return nil }
        return look
    }

    /// The values that need a new development of the source.
    nonisolated var development: [String: ParameterValue] {
        var values: [String: ParameterValue] = [:]
        values["raw.decoderVersion"] = rawDecoderVersion.map(ParameterValue.string)
        for declaration in Adjustments.all where declaration.cost == .redevelop {
            values[declaration.id] = value(for: declaration.id)
        }
        return values
    }
}

// Test renderers without decoder graphs may keep their existing open implementation.
extension EditorRendering {
    nonisolated var includesModel: Bool { true }

    func openingPreview(_ url: URL) async -> EmbeddedPreview.Image? { nil }

    func yieldMemory() async {}

    func pickWhiteBalance(_ request: EditorRenderRequest, at point: CGPoint) async throws -> WhiteBalanceSample {
        throw EditorRenderingError.unsupported("White balance sampling")
    }

    func refinePreview(sourceID: UUID) async throws -> EditorSource? { nil }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?, restoring: Recipe?,
              rawDecoderPreference: RAWDecoderPreference,
              progress: @escaping @Sendable (EditorOpeningStage) async -> Void) async throws -> EditorSource {
        await progress(.reading)
        return try await open(url, previewSize: previewSize, restoring: restoring)
    }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?, restoring: Recipe?) async throws -> EditorSource {
        try await open(url, previewSize: previewSize)
    }
}
