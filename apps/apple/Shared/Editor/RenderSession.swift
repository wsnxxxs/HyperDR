import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender

/// `EditorRendering` on HyperDRRender's `RenderEngine`: one open photo, the
/// LUTs the recipe can reference, and the AI provider and its predictions.
///
/// - Sources load at the preview size (`SourceResolution.preview`) or, for a
///   region or a full-size render, at full size. Render keeps a full and the
///   latest preview development (R4), so every render just asks `load` for
///   the variant it needs. Bypassed groups are a `RenderOptions` given to the
///   source options and the render alike, so a RAW bypass develops again.
/// - AI (R1): the first prediction loads a `CoreMLModelGainProvider` off the
///   actor; `RenderEngine.predictModelGain` predicts for SDR and RAW, and
///   renders that use it get it as `modelGain`. Predictions are kept by
///   source and model. A provider or prediction that reports
///   `ModelGainError.deviceUnavailable` makes AI unavailable; any other
///   failure is a failed prediction the user can retry.
actor RenderSession: EditorRendering {
    private let engine: RenderEngine
    private struct Opened {
        let editor: EditorSource
        /// The latest loaded variant; all share `id` (source and model identity).
        var source: RenderSource
        var options: SourceOptions
    }
    private var opened: Opened?
    /// Bumped by every open and close: a call that awaited across one of them
    /// writes nothing back.
    private var generation = 0
    /// Tests: runs before a render loads another variant of the source.
    private var beforeReload: (@Sendable () async -> Void)?

    func setBeforeReload(_ hook: (@Sendable () async -> Void)?) { beforeReload = hook }

    private var luts: [String: ColorLUT] = [:]
    private var provider: CoreMLModelGainProvider?
    private struct PredictionKey: Hashable { let source: UUID; let model: String }
    /// By the source's id and the recipe's `hdr.model`; each holds the provider's own model id.
    private var predictions: [PredictionKey: ModelGainPrediction] = [:]

    init(engine: RenderEngine) {
        self.engine = engine
    }

    init() throws {
        self.engine = try RenderEngine()
    }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?) async throws -> EditorSource {
        generation += 1
        let generation = self.generation
        let resolution: SourceResolution = previewSize.map { .preview(maximumSize: $0) } ?? .full
        let options = try SourceOptions(recipe: Recipe(), resolution: resolution)
        let source = try await engine.load(url, options: options)
        let report = try await engine.sourceReport(source)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        let editor = EditorSource(id: UUID(), url: url, domain: source.domain, pixelSize: source.nativeSize,
                                  sourceValues: report.sourceValues,
                                  capabilities: Self.capabilities(report.capabilities))
        opened = Opened(editor: editor, source: source, options: options)
        predictions = [:]
        return editor
    }

    /// What a request renders from: the source variant it needs (loaded on
    /// demand), its LUT, its model gain and its options.
    private struct Prepared {
        let source: RenderSource
        let lut: ColorLUT?
        let modelGain: ModelGainPrediction?
        let options: RenderOptions
        let generation: Int
    }

    private func prepare(_ request: EditorRenderRequest) async throws -> Prepared {
        guard var opened else { throw EditorRenderingError.noSource }
        let generation = self.generation
        guard opened.editor.id == request.sourceID, request.recipe.inputDomain == opened.editor.domain else {
            throw EditorRenderingError.staleSource
        }
        let recipe = request.recipe
        let options = RenderOptions(bypassedGroups: request.bypassedGroups)
        let lut = try recipe.activeLook.map { look -> ColorLUT in
            guard let lut = luts[look.contentHash] else { throw EditorRenderingError.missingLUT(look.contentHash) }
            return lut
        }
        let modelGain = request.usesModelGain ? prediction(for: recipe, source: opened.source) : nil
        let full = request.region != nil || request.size == opened.editor.pixelSize
        let sourceOptions = try SourceOptions(recipe: recipe, resolution: full ? .full : .preview(maximumSize: request.size),
                                              options: options)
        if sourceOptions != opened.options {
            await beforeReload?()
            let source = try await engine.load(opened.editor.url, options: sourceOptions)
            // Before writing anything back: cancelled, or another photo (or
            // none) opened while this one loaded.
            try Task.checkCancellation()
            try checkCurrent(generation)
            opened.source = source
            opened.options = sourceOptions
            self.opened = opened
        }
        try Task.checkCancellation()
        return Prepared(source: opened.source, lut: lut, modelGain: modelGain, options: options, generation: generation)
    }

    func render(_ request: EditorRenderRequest) async throws -> EditorFrame {
        let prepared = try await prepare(request)
        let source = prepared.source
        let planes = try await engine.render(source, recipe: request.recipe, lut: prepared.lut, modelGain: prepared.modelGain,
                                             options: prepared.options, size: request.size, region: request.region)
        let display = try await engine.displayPair(planes, source: source)
        let automatic = request.region == nil
            ? try await engine.resolvedAutomatic(source, recipe: request.recipe, lut: prepared.lut,
                                                 modelGain: prepared.modelGain, options: prepared.options)
            : [:]
        try Task.checkCancellation()
        try checkCurrent(prepared.generation)
        return EditorFrame(request: request, planes: planes, display: display, modelGainPending: planes.aiPending,
                           automaticValues: automatic)
    }

    func effectMask(_ request: EditorRenderRequest, parameterID: String) async throws -> RenderMask {
        let prepared = try await prepare(request)
        let mask = try await engine.effectMask(prepared.source, recipe: request.recipe, parameterID: parameterID,
                                               lut: prepared.lut, modelGain: prepared.modelGain, options: prepared.options,
                                               size: request.size, region: request.region)
        try Task.checkCancellation()
        try checkCurrent(prepared.generation)
        return mask
    }

    func sdrThumbnail(_ frame: EditorFrame, maximumSize: HyperDRRender.PixelSize) async throws -> CGImage {
        try await engine.sdrThumbnail(frame.planes, maximumSize: maximumSize)
    }

    func predictModelGain(modelID: String) async throws {
        guard let opened else { throw EditorRenderingError.noSource }
        let generation = self.generation
        let key = PredictionKey(source: opened.source.id, model: modelID)
        if predictions[key] != nil { return }
        let provider: CoreMLModelGainProvider
        if let loaded = self.provider { provider = loaded } else {
            // Loading the model off the actor keeps renders going meanwhile.
            do {
                provider = try await Task.detached(priority: .userInitiated) { try CoreMLModelGainProvider() }.value
            } catch {
                throw Self.modelError(error)
            }
            if self.provider == nil { self.provider = provider }
        }
        let prediction: ModelGainPrediction
        do { prediction = try await engine.predictModelGain(opened.source, provider: provider) } catch {
            throw Self.modelError(error)
        }
        try Task.checkCancellation()
        try checkCurrent(generation)
        predictions[key] = prediction
    }

    /// The prediction for the recipe's model, if it was made for this source.
    private func prediction(for recipe: Recipe, source: RenderSource) -> ModelGainPrediction? {
        let model = recipe.conditionValue("hdr.model")?.stringValue ?? ""
        guard let prediction = predictions[PredictionKey(source: source.id, model: model)],
              prediction.sourceID == source.id, prediction.modelID == provider?.modelID else { return nil }
        return prediction
    }

    /// The device cannot run the model at all: AI becomes unavailable. Anything
    /// else (a missing model, a failed prediction) can be retried.
    private static func modelError(_ error: any Error) -> any Error {
        switch error {
        case ModelGainError.deviceUnavailable(let reason): return EditorRenderingError.modelUnavailable(reason)
        case RenderError.metalUnavailable: return EditorRenderingError.modelUnavailable("No Metal device")
        default: return error
        }
    }

    func installLUT(_ lut: ColorLUT) async {
        luts[lut.contentHash] = lut
    }

    func close() async {
        generation += 1
        opened = nil
        predictions = [:]
        await engine.clearCaches()
    }

    // MARK: - Helpers

    private func checkCurrent(_ generation: Int) throws {
        guard generation != self.generation else { return }
        throw opened == nil ? EditorRenderingError.noSource : EditorRenderingError.staleSource
    }

    /// Render reports capabilities by parameter id; the controls test the
    /// declaration's capability string (`AdjustmentContext.capabilities`).
    private static func capabilities(_ parameters: Set<String>) -> Set<String> {
        Set(Adjustments.all.compactMap { declaration in
            declaration.capability.flatMap { parameters.contains(declaration.id) ? $0 : nil }
        })
    }
}
