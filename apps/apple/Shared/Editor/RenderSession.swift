import CoreGraphics
import Foundation
import ImageIO
import HyperDRRecipe
import HyperDRRender

/// `EditorRendering` on HyperDRRender's `RenderEngine`: one open photo, the
/// LUTs the recipe can reference, and the AI provider and its predictions.
///
/// - Preview sources load at the canvas tier. Detail requests keep a lazy
///   system graph and materialize only the requested ROI and sampling halo,
///   on Mac, iPhone and iPad alike. Bypassed groups are a `RenderOptions` given to the
///   source options and the render alike, so a RAW bypass develops again.
/// - AI (R1): the first prediction loads a `CoreMLModelGainProvider` off the
///   actor; `RenderEngine.predictModelGain` predicts for SDR and RAW, and
///   renders that use it get it as `modelGain`. A prediction belongs to the
///   `RenderSource.id` it was made on, which a new RAW development changes
///   (preview and full size share it): renders look it up after loading
///   their source, and without one they come back `aiPending`. The latest
///   `predictionLimit` are kept, by source id and model. A provider or prediction that reports
///   `ModelGainError.deviceUnavailable` makes AI unavailable; any other
///   failure is a failed prediction the user can retry.
actor RenderSession: EditorRendering {
    private let engine: RenderEngine
    private struct Opened {
        let editor: EditorSource
        /// The file as opened. `load` of a replaced file quietly opens the new
        /// one, so a reload checks this first (R23-001).
        let revision: FileRevision
        /// The latest loaded variant; all share `id` (source and model identity).
        var source: RenderSource
        var options: SourceOptions
        var detail: ExportSource?
        var detailOptions: SourceOptions?
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
    /// Oldest first.
    private var predictionOrder: [PredictionKey] = []
    static let predictionLimit = RecipeEditor.predictionLimit

    init(engine: RenderEngine) {
        self.engine = engine
    }

    init() throws {
        self.engine = try RenderEngine()
    }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?) async throws -> EditorSource {
        try await mapped { try await openSource(url, previewSize: previewSize) }
    }

    private func openSource(_ url: URL, previewSize: HyperDRRender.PixelSize?) async throws -> EditorSource {
        generation += 1
        let generation = self.generation
        let resolution: SourceResolution = previewSize.map { .preview(maximumSize: $0) } ?? .full
        let options = try SourceOptions(recipe: Recipe(), resolution: resolution)
        let revision = try FileRevision(url)
        let source = try await engine.load(url, options: options)
        let report = try await engine.sourceReport(source)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        let editor = EditorSource(id: UUID(), url: url, domain: source.domain, pixelSize: source.nativeSize,
                                  sourceValues: report.sourceValues,
                                  capabilities: Self.capabilities(report.capabilities),
                                  hasAlpha: source.domain != .rawEDR && Self.hasAlpha(url))
        opened = Opened(editor: editor, revision: revision, source: source, options: options)
        predictions = [:]
        predictionOrder = []
        return editor
    }

    /// Whether the file's first image has an alpha channel, from its
    /// properties alone (no decoding).
    nonisolated static func hasAlpha(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
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

    private func prepare(_ request: EditorRenderRequest, needsLUT: Bool = true) async throws -> Prepared {
        guard var opened else { throw EditorRenderingError.noSource }
        let generation = self.generation
        guard opened.editor.id == request.sourceID, request.recipe.inputDomain == opened.editor.domain else {
            throw EditorRenderingError.staleSource
        }
        let recipe = request.recipe
        let options = RenderOptions(bypassedGroups: request.bypassedGroups)
        let lut = try recipe.activeLook.flatMap { look -> ColorLUT? in
            guard needsLUT else { return nil }
            guard let lut = luts[look.contentHash] else { throw EditorRenderingError.missingLUT(look.contentHash) }
            return lut
        }
        let full = request.region != nil || request.size == opened.editor.pixelSize
        let sourceOptions = try SourceOptions(recipe: recipe, resolution: full ? .full : .preview(maximumSize: request.size),
                                              options: options)
        if let region = request.region {
            await beforeReload?()
            guard try FileRevision(opened.editor.url) == opened.revision else { throw EditorRenderingError.sourceChanged }
            try checkCurrent(generation)
            if opened.detail == nil || opened.detailOptions != sourceOptions {
                // Release the previous RAW development before opening another;
                // retaining both native decoder graphs doubles the input cache.
                opened.detail = nil
                opened.detailOptions = nil
                self.opened = opened
                opened.detail = try await engine.openExportSource(opened.editor.url, options: sourceOptions)
                opened.detailOptions = sourceOptions
            }
            // The film's scatter reads a few pixels beyond the region.
            let halo = try RenderAdjustments(recipe: recipe, lut: lut, options: options).film.sourceHalo(size: request.size)
            let tile = try await engine.materializeExportRegion(opened.detail!, outputSize: request.size, region: region, halo: halo)
            try Task.checkCancellation()
            try checkCurrent(generation)
            self.opened = opened
            return Prepared(source: tile, lut: lut,
                            modelGain: request.usesModelGain ? prediction(for: recipe, source: tile) : nil,
                            options: options, generation: generation)
        }
        if sourceOptions != opened.options {
            await beforeReload?()
            guard try FileRevision(opened.editor.url) == opened.revision else { throw EditorRenderingError.sourceChanged }
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
        // Looked up on the source the request renders from: another
        // development has no prediction yet, and the frame says it is pending.
        let modelGain = request.usesModelGain ? prediction(for: recipe, source: opened.source) : nil
        return Prepared(source: opened.source, lut: lut, modelGain: modelGain, options: options, generation: generation)
    }

    func render(_ request: EditorRenderRequest) async throws -> EditorFrame {
        try await mapped { try await renderFrame(request) }
    }

    private func renderFrame(_ request: EditorRenderRequest) async throws -> EditorFrame {
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

    func sdrThumbnail(_ frame: EditorFrame, maximumSize: HyperDRRender.PixelSize) async throws -> CGImage {
        try await engine.sdrThumbnail(frame.planes, maximumSize: maximumSize)
    }

    func predictModelGain(_ request: EditorRenderRequest) async throws {
        try await mapped { try await predict(request) }
    }

    private func predict(_ request: EditorRenderRequest) async throws {
        let prepared = try await prepare(request, needsLUT: false)
        let generation = prepared.generation
        // AI belongs to the photograph, not the log look. Both developments
        // share modelSourceID; the new stable id must not force a second prediction.
        let key = PredictionKey(source: prepared.source.modelSourceID, model: Self.modelID(request.recipe))
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
        do { prediction = try await engine.predictModelGain(prepared.source, provider: provider) } catch {
            throw Self.modelError(error)
        }
        try Task.checkCancellation()
        try checkCurrent(generation)
        predictions[key] = prediction
        predictionOrder.removeAll { $0 == key }
        predictionOrder.append(key)
        if predictionOrder.count > Self.predictionLimit { predictions[predictionOrder.removeFirst()] = nil }
    }

    private static func modelID(_ recipe: Recipe) -> String { recipe.conditionValue("hdr.model")?.stringValue ?? "" }

    /// The prediction for the recipe's model, if it was made for this source.
    private func prediction(for recipe: Recipe, source: RenderSource) -> ModelGainPrediction? {
        guard let prediction = predictions[PredictionKey(source: source.modelSourceID, model: Self.modelID(recipe))],
              prediction.sourceID == source.modelSourceID, prediction.modelID == provider?.modelID else { return nil }
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
        predictionOrder = []
        await engine.clearCaches()
    }

    // MARK: - Helpers

    /// Size and modification date, as Render's own source revision.
    private struct FileRevision: Equatable {
        let size: Int?
        let modified: Date?

        init(_ url: URL) throws {
            var url = url
            url.removeAllCachedResourceValues()
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size = values.fileSize
            modified = values.contentModificationDate
        }
    }

    /// R23-001: Render refuses a file that changed since it was opened.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch RenderError.sourceChanged { throw EditorRenderingError.sourceChanged }
    }

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
