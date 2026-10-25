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
///   `ModelGainError.deviceUnavailable` or `.notIncluded` (a build without the
///   model, `includesModel`) makes AI unavailable; any other
///   failure is a failed prediction the user can retry.
actor RenderSession: EditorRendering {
    private let engine: RenderEngine
    private struct Opened {
        var editor: EditorSource
        /// The file as opened. `load` of a replaced file quietly opens the new
        /// one, so a reload checks this first (R23-001).
        let revision: FileRevision
        /// The latest loaded variant; all share `id` (source and model identity).
        /// Nil while an export holds the memory (`yieldMemory`): the next
        /// request loads `options` again.
        var source: RenderSource?
        var options: SourceOptions
        /// The primary canvas's development and largest requested tier, independent
        /// of the last scope/original variant that happened to render.
        var previewOptions: SourceOptions
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
    /// Fault injection for the initial load, independent of a platform RAW model.
    private var beforeOpenLoad: (@Sendable (SourceOptions) async throws -> Void)?
    func setBeforeOpenLoad(_ hook: (@Sendable (SourceOptions) async throws -> Void)?) { beforeOpenLoad = hook }


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
        try await mapped { try await openSource(url, previewSize: previewSize, restoring: nil) }
    }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?, restoring: Recipe?) async throws -> EditorSource {
        try await mapped { try await openSource(url, previewSize: previewSize, restoring: restoring) }
    }

    func pickWhiteBalance(_ request: EditorRenderRequest, at point: CGPoint) async throws -> WhiteBalanceSample {
        guard let opened else { throw EditorRenderingError.noSource }
        guard opened.editor.id == request.sourceID else { throw EditorRenderingError.staleSource }
        guard try FileRevision(opened.editor.url) == opened.revision else { throw EditorRenderingError.sourceChanged }
        let options = try SourceOptions(recipe: request.recipe, resolution: .full)
        return try await engine.pickWhiteBalance(opened.editor.url, options: options, point: point,
                                                photoSize: opened.editor.pixelSize, raw: opened.editor.domain == .rawEDR)
    }

    func openingPreview(_ url: URL) async -> EmbeddedPreview.Image? {
        await EmbeddedPreview.read(url)
    }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?, restoring: Recipe?,
              rawDecoderPreference: RAWDecoderPreference,
              progress: @escaping @Sendable (EditorOpeningStage) async -> Void = { _ in }) async throws -> EditorSource {
        try await mapped {
            try await openSource(url, previewSize: previewSize, restoring: restoring,
                                 rawDecoderPreference: rawDecoderPreference, progress: progress)
        }
    }

    private func openSource(_ url: URL, previewSize: HyperDRRender.PixelSize?, restoring: Recipe?,
                            rawDecoderPreference: RAWDecoderPreference = .automatic,
                            progress: @escaping @Sendable (EditorOpeningStage) async -> Void = { _ in }) async throws -> EditorSource {
        generation += 1
        let generation = self.generation
        let resolution: SourceResolution = previewSize.map { .preview(maximumSize: $0) } ?? .full
        await progress(.reading)
        let clock = ContinuousClock()
        let began = clock.now
        var options = try SourceOptions(recipe: restoring ?? Recipe(), resolution: resolution)
        if restoring == nil {
            if let generation = rawDecoderPreference.generation {
                options.rawDecoderVersion = try await engine.rawDecoder(url, generation: generation)
            } else {
                options.rawDecoderVersion = await engine.preferredRAWDecoder(url)
            }
        }
        options.draftRAWPreview = previewSize != nil
        let selected = clock.now
        let revision = try FileRevision(url)
        let loadProgress: @Sendable (SourceLoadPhase) -> Void = { phase in
            if ProcessInfo.processInfo.environment["HYPERDR_OPEN_TIMINGS"] == "1" {
                print("OPEN_PHASE phase=\(phase) elapsed=\(began.duration(to: clock.now))")
            }
            let stage: EditorOpeningStage = switch phase {
            case .loadingDecoder: .loadingDecoder
            case .developing: .developing
            case .preparingAnalysis: .preparingPreview
            }
            Task { await progress(stage) }
        }
        var fallback: RAWDecoderFallback?
        let source: RenderSource
        do {
            try await beforeOpenLoad?(options)
            do {
                source = try await engine.load(url, options: options, preparingAnalysis: true, progress: loadProgress)
            } catch RenderError.cannotDecodeSource where options.draftRAWPreview {
                // A camera may reject reduced development while native works.
                // Keep its selected decoder before considering decoder fallback.
                options.draftRAWPreview = false
                source = try await engine.load(url, options: options, preparingAnalysis: true, progress: loadProgress)
            }
        } catch {
            // A listed decoder can still fail in Apple's camera/system model.
            // Retry only a new photo's preferred 9 after a decode failure, once.
            // Recorded versions, cancellation, memory/GPU errors and changed files
            // retain their original failure semantics.
            guard restoring == nil, rawDecoderPreference == .automatic,
                  case RenderError.cannotDecodeSource = error,
                  let requested = options.rawDecoderVersion,
                  requested.split(separator: ".").first == "9",
                  let version = await engine.fallbackRAWDecoder(url), version != requested else { throw error }
            try Task.checkCancellation()
            guard try FileRevision(url) == revision else { throw RenderError.sourceChanged }
            options.rawDecoderVersion = version
            if ProcessInfo.processInfo.environment["HYPERDR_OPEN_TIMINGS"] == "1" {
                print("OPEN_RAW_DECODER_FALLBACK requested=\(requested) used=\(version)")
            }
            try await beforeOpenLoad?(options)
            source = try await engine.load(url, options: options, preparingAnalysis: true, progress: loadProgress)
            fallback = RAWDecoderFallback(requested: requested, used: version)
            EditorLog.notice("RAW decoder \(requested) could not decode; reopened with \(version)")
        }
        let developed = clock.now
        await progress(.preparingPreview)
        let report = try await engine.sourceReport(source)
        if ProcessInfo.processInfo.environment["HYPERDR_OPEN_TIMINGS"] == "1" {
            print("OPEN_TIMING decoder_selection=\(began.duration(to: selected)) development=\(selected.duration(to: developed)) source_report=\(developed.duration(to: clock.now)) decoder=\(source.rawSettings?.decoderVersion ?? "none")")
        }
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        // The photo's own size: the editor applies the geometry the recipe carries.
        let editor = EditorSource(id: UUID(), url: url, domain: source.domain, pixelSize: source.uncroppedSize,
                                  sourceValues: report.sourceValues,
                                  capabilities: Self.capabilities(report.capabilities),
                                  hasAlpha: source.domain != .rawEDR && Self.hasAlpha(url),
                                  isDraftPreview: source.isDraftRAWPreview,
                                  rawDecoderVersion: source.rawSettings?.decoderVersion, rawDecoderFallback: fallback)
        opened = Opened(editor: editor, revision: revision, source: source, options: options, previewOptions: options)
        EditorLog.notice("Opened \(source.domain) \(source.nativeSize.width)x\(source.nativeSize.height) decoder=\(source.rawSettings?.decoderVersion ?? "none") in \(began.duration(to: clock.now))")
        predictions = [:]
        predictionOrder = []
        return editor
    }

    func refinePreview(sourceID: UUID) async throws -> EditorSource? {
        // Native RAW development is synchronous on its engine. A separate engine
        // leaves the editor's engine free for draft renders while this runs.
        let refiner = try await Task.detached(priority: .utility) { try RenderEngine() }.value
        let generation = self.generation
        while true {
            try Task.checkCancellation()
            try checkCurrent(generation)
            guard let initial = opened, initial.editor.id == sourceID else { throw EditorRenderingError.staleSource }
            guard initial.editor.domain == .rawEDR, initial.previewOptions.draftRAWPreview else { return initial.editor }
            guard initial.source != nil else { return nil }
            var options = initial.previewOptions
            options.draftRAWPreview = false
            guard try FileRevision(initial.editor.url) == initial.revision else { throw EditorRenderingError.sourceChanged }
            let source = try await refiner.load(initial.editor.url, options: options, preparingAnalysis: true)
            let analysis = try await refiner.previewAnalysis(source)
            let report = try await refiner.sourceReport(source)
            try Task.checkCancellation()
            try checkCurrent(generation)
            guard let current = opened else { throw EditorRenderingError.noSource }
            // A development edit meanwhile needs its own native preview. Ordinary
            // edits do not change these options and land on the finished source.
            guard current.source != nil else { return nil } // yielded to export
            guard current.previewOptions == initial.previewOptions else { continue }
            try await engine.installRefinedPreview(source, analysis: analysis, resolution: options.resolution)
            try Task.checkCancellation()
            try checkCurrent(generation)
            guard var latest = opened else { throw EditorRenderingError.noSource }
            guard latest.previewOptions == initial.previewOptions else { continue }
            latest.source = source // drops the draft immediately
            latest.options = options
            latest.previewOptions = options
            latest.editor.sourceValues = report.sourceValues
            latest.editor.isDraftPreview = false
            opened = latest
            return latest.editor
        }
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
        let full = request.region != nil || request.size == recipe.geometry.outputSize(of: opened.editor.pixelSize)
        var sourceOptions = try SourceOptions(recipe: recipe, resolution: full ? .full : .preview(maximumSize: request.size),
                                              options: options)
        sourceOptions.draftRAWPreview = opened.previewOptions.draftRAWPreview && !full
        if opened.editor.domain == .rawEDR, !full, !request.keepsSource {
            let previousSide: Int = switch opened.previewOptions.resolution {
            case .preview(let size): max(size.width, size.height)
            case .full: max(opened.editor.pixelSize.width, opened.editor.pixelSize.height)
            }
            let side = max(previousSide, request.size.width, request.size.height)
            let resolution = SourceResolution.preview(maximumSize: .init(width: side, height: side))
            sourceOptions.resolution = resolution
            opened.previewOptions.resolution = resolution
            if request.isCanvasPreview { opened.previewOptions = sourceOptions }
            self.opened = opened
        }
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
        var reload: SourceOptions?
        if request.keepsSource {
            var kept = sourceOptions
            kept.resolution = opened.options.resolution
            // Only RAW is developed: a film's scene-linear development changes nothing else.
            guard kept == opened.options || opened.editor.domain != .rawEDR else {
                throw EditorRenderingError.needsDevelopment
            }
        } else if sourceOptions != opened.options, opened.source?.reusesRAWPreview(options: sourceOptions) == true {
            guard try FileRevision(opened.editor.url) == opened.revision else { throw EditorRenderingError.sourceChanged }
            opened.options = sourceOptions
            self.opened = opened
        } else if sourceOptions != opened.options {
            reload = sourceOptions
        }
        // An export had the memory: develop the same variant again.
        if reload == nil, opened.source == nil { reload = opened.options }
        if let reload {
            await beforeReload?()
            guard try FileRevision(opened.editor.url) == opened.revision else { throw EditorRenderingError.sourceChanged }
            let source = try await engine.load(opened.editor.url, options: reload, preparingAnalysis: true)
            // Before writing anything back: cancelled, or another photo (or
            // none) opened while this one loaded.
            try Task.checkCancellation()
            try checkCurrent(generation)
            guard var current = self.opened else { throw EditorRenderingError.noSource }
            current.source = source
            current.options = reload
            self.opened = current
            opened = current
        }
        try Task.checkCancellation()
        guard let source = opened.source else { throw EditorRenderingError.noSource }
        // Looked up on the source the request renders from: another
        // development has no prediction yet, and the frame says it is pending.
        let modelGain = request.usesModelGain ? prediction(for: recipe, source: source) : nil
        return Prepared(source: source, lut: lut, modelGain: modelGain, options: options, generation: generation)
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
        let automatic = request.region == nil && !request.keepsSource
            ? try await engine.resolvedAutomatic(source, recipe: request.recipe, lut: prepared.lut,
                                                 modelGain: prepared.modelGain, options: prepared.options,
                                                 includingSet: true)
            : [:]
        try Task.checkCancellation()
        try checkCurrent(prepared.generation)
        return EditorFrame(request: request, planes: planes, display: display, modelGainPending: planes.aiPending,
                           isDraftPreview: source.isDraftRAWPreview, automaticValues: automatic)
    }

    func sdrThumbnail(_ frame: EditorFrame, maximumSize: HyperDRRender.PixelSize) async throws -> CGImage {
        try await engine.sdrThumbnail(frame.planes, maximumSize: maximumSize)
    }

    nonisolated var includesModel: Bool { ModelGain.isIncluded }

    func predictModelGain(_ request: EditorRenderRequest) async throws {
        try await mapped { try await predict(request) }
    }

    private func predict(_ request: EditorRenderRequest) async throws {
        if opened?.source?.isDraftRAWPreview == true {
            _ = try await refinePreview(sourceID: request.sourceID)
        }
        let prepared = try await prepare(request, needsLUT: false)
        let generation = prepared.generation
        // AI belongs to the photograph, not the log look. Both developments
        // share modelSourceID; the new stable id must not force a second prediction.
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
        let key = PredictionKey(source: prepared.source.modelSourceID, model: provider.modelID(for: prepared.source.modelCapture))
        if predictions[key] != nil { return }
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

    /// The prediction for the recipe's model, if it was made for this source.
    private func prediction(for recipe: Recipe, source: RenderSource) -> ModelGainPrediction? {
        guard let provider else { return nil }
        let identity = provider.modelID(for: source.modelCapture)
        guard let prediction = predictions[PredictionKey(source: source.modelSourceID, model: identity)],
              prediction.sourceID == source.modelSourceID, prediction.modelID == identity else { return nil }
        return prediction
    }

    /// The device cannot run the model at all, or this build has none: AI
    /// becomes unavailable. Anything else (a model that fails to load, a failed
    /// prediction) can be retried.
    private static func modelError(_ error: any Error) -> any Error {
        switch error {
        case ModelGainError.deviceUnavailable(let reason): return EditorRenderingError.modelUnavailable(reason)
        case ModelGainError.notIncluded: return EditorRenderingError.modelUnavailable(RecipeEditor.modelNotIncluded)
        case RenderError.metalUnavailable: return EditorRenderingError.modelUnavailable("No Metal device")
        default: return error
        }
    }

    func installLUT(_ lut: ColorLUT) async {
        luts[lut.contentHash] = lut
    }

    func yieldMemory() async {
        if var opened {
            // The previous development's native graph and textures go with it.
            opened.source = nil
            opened.detail = nil
            opened.detailOptions = nil
            self.opened = opened
        }
        await engine.clearCaches()
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
