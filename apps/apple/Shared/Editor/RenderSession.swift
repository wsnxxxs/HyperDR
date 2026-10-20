import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender

/// `EditorRendering` on HyperDRRender's `RenderEngine`: one open photo, the
/// LUTs the recipe can reference, and (with R1) the AI prediction.
///
/// Built against the P7-0 Render on the main line, which has the source
/// nodes but no adjustment graph yet: the recipe is validated and the photo
/// is rendered as opened. When p7-render (R2, R3, R9) and p7-coreml (R1) are
/// in, `render` hands the recipe to `render(_:recipe:lut:size:)`, regions to
/// the region render, `SourceOptions(recipe:rawResolution:)` decides when a
/// development change opens the source again, and `predictModelGain` loads a
/// `CoreMLModelGainProvider` on first use.
actor RenderSession: EditorRendering {
    private let engine: RenderEngine
    private var opened: (source: RenderSource, editor: EditorSource)?
    private var luts: [String: Data] = [:]

    init(engine: RenderEngine) {
        self.engine = engine
    }

    init() throws {
        self.engine = try RenderEngine()
    }

    func open(_ url: URL) async throws -> EditorSource {
        let source = try await engine.load(url)
        var capabilities = Set<String>()
        if source.rawSettings?.lensCorrectionSupported == true {
            capabilities.insert("CIRAWFilter.isLensCorrectionSupported")
        }
        let editor = EditorSource(id: source.id, url: url, domain: source.domain, pixelSize: source.size,
                                  capabilities: capabilities)
        opened = (source, editor)
        return editor
    }

    func render(_ request: EditorRenderRequest) async throws -> EditorFrame {
        guard let opened else { throw EditorRenderingError.noSource }
        guard opened.editor.id == request.sourceID, request.recipe.inputDomain == opened.source.domain else {
            throw EditorRenderingError.staleSource
        }
        if let look = request.recipe.look, luts[look.contentHash] == nil {
            throw EditorRenderingError.missingLUT(look.contentHash)
        }
        guard request.region == nil else {
            throw EditorRenderingError.unsupported("Region rendering waits for Render R2")
        }
        try Task.checkCancellation()
        let planes = try await engine.render(opened.source, size: request.size)
        try Task.checkCancellation()
        return EditorFrame(request: request, planes: planes)
    }

    func predictModelGain(modelID: String) async throws {
        guard opened != nil else { throw EditorRenderingError.noSource }
        throw EditorRenderingError.modelUnavailable("The Core ML gain provider is not in this build yet (R1)")
    }

    func installLUT(_ cube: Data, contentHash: String) async throws {
        luts[contentHash] = cube
    }

    func close() async {
        opened = nil
        await engine.clearCaches()
    }
}
