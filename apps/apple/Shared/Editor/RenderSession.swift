import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender

/// `EditorRendering` on HyperDRRender's `RenderEngine`: one open photo, the
/// LUTs the recipe can reference, and the AI provider.
///
/// - Sources open at the preview size (`SourceResolution.preview`, R9). A
///   render decodes or develops again only when the development changes or it
///   needs more pixels than the open source has; a region renders from the
///   full-size source. The engine keeps one source, so alternating between a
///   detail region and the preview decodes twice until R4.
/// - Bypassed groups are rendered as reset to their defaults (until R5).
/// - AI: the first prediction loads a `CoreMLModelGainProvider`. Until Render
///   applies a prediction in the graph (R1), an AI source renders as its
///   non-AI counterpart and the frame is marked `modelGainPending`.
actor RenderSession: EditorRendering {
    private let engine: RenderEngine
    private struct Opened {
        let editor: EditorSource
        var source: RenderSource
        var options: SourceOptions
    }
    private var opened: Opened?
    private var luts: [String: ColorLUT] = [:]
    private var provider: CoreMLModelGainProvider?
    /// Predictions for the open photo, by the recipe's model id.
    private var predictions: [String: ModelGainPrediction] = [:]

    init(engine: RenderEngine) {
        self.engine = engine
    }

    init() throws {
        self.engine = try RenderEngine()
    }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?) async throws -> EditorSource {
        let resolution: SourceResolution = previewSize.map { .preview(maximumSize: $0) } ?? .full
        let options = try SourceOptions(recipe: Recipe(), resolution: resolution)
        let source = try await engine.load(url, options: options)
        try Task.checkCancellation()
        let editor = EditorSource(id: UUID(), url: url, domain: source.domain, pixelSize: source.nativeSize,
                                  sourceValues: Self.sourceValues(source.rawSettings),
                                  capabilities: Self.capabilities(source.rawSettings))
        opened = Opened(editor: editor, source: source, options: options)
        predictions = [:]
        return editor
    }

    func render(_ request: EditorRenderRequest) async throws -> EditorFrame {
        guard var opened else { throw EditorRenderingError.noSource }
        guard opened.editor.id == request.sourceID, request.recipe.inputDomain == opened.editor.domain else {
            throw EditorRenderingError.staleSource
        }
        var recipe = request.recipe
        for group in request.bypassedGroups { recipe = recipe.resetting(group) }
        var pending = false
        if recipe.hdrSource.usesModel {
            // R1: the graph cannot take a prediction yet.
            recipe.setHDRSource(recipe.hdrSource == .ai ? .expand : .captured)
            pending = true
        }
        let lut = try recipe.look.map { look -> ColorLUT in
            guard let lut = luts[look.contentHash] else { throw EditorRenderingError.missingLUT(look.contentHash) }
            return lut
        }
        let full = request.region != nil || request.size == opened.editor.pixelSize
        let options = try SourceOptions(recipe: recipe, resolution: full ? .full : .preview(maximumSize: request.size))
        if !Self.covers(opened.options, opened.source, options) {
            opened.source = try await engine.load(opened.editor.url, options: options)
            opened.options = options
            self.opened = opened
        }
        try Task.checkCancellation()
        let planes = try await engine.render(opened.source, recipe: recipe, lut: lut, size: request.size,
                                             region: request.region)
        let display = try await engine.displayPair(planes, source: opened.source)
        try Task.checkCancellation()
        return EditorFrame(request: request, planes: planes, display: display, modelGainPending: pending)
    }

    func sdrThumbnail(_ frame: EditorFrame, maximumSize: HyperDRRender.PixelSize) async throws -> CGImage {
        try await engine.sdrThumbnail(frame.planes, maximumSize: maximumSize)
    }

    func predictModelGain(modelID: String) async throws {
        guard let opened else { throw EditorRenderingError.noSource }
        if predictions[modelID] != nil { return }
        if provider == nil {
            do { provider = try CoreMLModelGainProvider() } catch {
                throw EditorRenderingError.modelUnavailable(String(describing: error))
            }
        }
        guard opened.editor.domain == .sdr else {
            // A RAW prediction needs the SDR base the graph splits off (R1).
            throw EditorRenderingError.unsupported("AI on RAW waits for Render R1")
        }
        let prediction = try await provider!.predict(source: opened.source)
        guard self.opened?.editor.id == opened.editor.id else { throw CancellationError() }
        predictions[modelID] = prediction
    }

    func installLUT(_ lut: ColorLUT) async {
        luts[lut.contentHash] = lut
    }

    func close() async {
        opened = nil
        predictions = [:]
        await engine.clearCaches()
    }

    // MARK: - Helpers

    /// Whether the open source can serve `wanted`: the same development, and
    /// full size or at least as many pixels as asked for.
    private static func covers(_ current: SourceOptions, _ source: RenderSource, _ wanted: SourceOptions) -> Bool {
        var same = wanted
        same.resolution = current.resolution
        guard same == current else { return false }
        switch (current.resolution, wanted.resolution) {
        case (.full, _): return true
        case (.preview, .full): return false
        case (.preview, .preview(let size)):
            return max(source.size.width, source.size.height) >= max(size.width, size.height)
        }
    }

    /// The RAW development's own values in the declared units (R8).
    private static func sourceValues(_ raw: RAWDevelopment?) -> [String: Double] {
        guard let raw else { return [:] }
        var values: [String: Double] = [:]
        for (id, engine) in [("develop.temperature", raw.temperature), ("develop.tint", raw.tint),
                             ("develop.luminanceNR", raw.luminanceNR), ("develop.colorNR", raw.colorNR),
                             ("develop.sharpness", raw.sharpness)] {
            guard let declaration = Adjustments.declaration(id), engine.isFinite else { continue }
            values[id] = declaration.scale == .hundredth ? Double(engine) * 100 : Double(engine)
        }
        return values
    }

    private static func capabilities(_ raw: RAWDevelopment?) -> Set<String> {
        guard let raw else { return [] }
        var capabilities = Set<String>()
        if raw.lensCorrectionSupported { capabilities.insert("CIRAWFilter.isLensCorrectionSupported") }
        if raw.supportsLuminanceNR { capabilities.insert("CIRAWFilter.isLuminanceNoiseReductionSupported") }
        if raw.supportsColorNR { capabilities.insert("CIRAWFilter.isColorNoiseReductionSupported") }
        if raw.supportsSharpness { capabilities.insert("CIRAWFilter.isSharpnessSupported") }
        return capabilities
    }
}
