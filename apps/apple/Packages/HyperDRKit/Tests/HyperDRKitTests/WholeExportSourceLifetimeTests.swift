import CoreImage
import Foundation
import HyperDREngine
import HyperDRRecipe
import Metal
import Testing
@testable import HyperDRRender
@testable import HyperDRKit

private final class WeakWholeSource: @unchecked Sendable {
    private let lock = NSLock()
    private weak var texture: (any MTLTexture)?
    private weak var image: CIImage?
    private var observed = false
    private var encodingState: (texture: Bool, image: Bool)?
    func observe(_ source: RenderSource) {
        lock.withLock { texture = source.texture; image = source.hdrImage; observed = true }
    }
    func encoding() { lock.withLock { encodingState = (texture != nil, image != nil) } }
    func snapshot() -> (observed: Bool, texture: Bool, image: Bool, encodingTexture: Bool?, encodingImage: Bool?) {
        lock.withLock { (observed, texture != nil, image != nil, encodingState?.texture, encodingState?.image) }
    }
}

private struct WeakWholeRenderer: ExportStripeRendering {
    let sourceOwner: WeakWholeSource
    var fake = StripeFake()
    func renderExportStripes(_ source: RenderSource, recipe: Recipe, lut: ColorLUT?,
                             modelGain: ModelGainPrediction?, request: ExportRenderRequest, rows: Int,
                             prepare: @Sendable (ExportRenderReport) throws -> Void,
                             consume: @Sendable (ExportStripe) throws -> Void) async throws -> ExportRenderReport {
        sourceOwner.observe(source)
        return try await fake.renderExportStripes(source, recipe: recipe, lut: lut, modelGain: modelGain,
            request: request, rows: rows, prepare: prepare, consume: consume)
    }
}

@Suite(.serialized) struct WholeExportSourceLifetimeTests {
    private func service(_ env: RecipeExportEnvironment, source: WeakWholeSource,
                         fake: StripeFake = StripeFake()) -> RecipeExportService {
        .init(engine: env.engine, renderEngine: env.render,
            renderer: WeakWholeRenderer(sourceOwner: source, fake: fake), sessions: env.sessions,
            target: env.target, budget: FixedExportMemoryBudget(bytes: 1_000_000_000), rowRenderer: env.render)
    }
    private func request(_ env: RecipeExportEnvironment, allowsRowInput: Bool = false,
                         encoding: ExportEncoding = .sdrTIFF) -> ExportPlanRequest {
        var result = env.request(encoding)
        result.allowsRowInput = allowsRowInput
        return result
    }

    @Test(arguments: [false, true]) func sourceIsReleasedBeforeWholePackaging(allowsRowInput: Bool) async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let source = WeakWholeSource(), exporter = service(env, source: source)
        let result = try await exporter.export(session: env.session.id, snapshot: env.snapshot(),
            request: request(env, allowsRowInput: allowsRowInput, encoding: .adaptive),
            progress: { event in if event.stage == .encoding { source.encoding() } })
        let state = source.snapshot()
        #expect(result.verified && result.resolved.usesRowInput == false)
        let report = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
        #expect(report.writer == .imageIO && report.usesRowInput == false && report.renderRows == nil)
        #expect(state.observed && state.encodingTexture == false && state.encodingImage == false)
        #expect(!state.texture && !state.image)
    }

    @Test func sourceMutationAfterWholeRenderStillBlocksPublication() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let source = WeakWholeSource()
        let url = env.session.sourceURL
        let exporter = service(env, source: source, fake: StripeFake(afterStripe: {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        }))
        await #expect(throws: RecipeExportError.sourceChanged) {
            _ = try await exporter.export(session: env.session.id, snapshot: env.snapshot(), request: request(env))
        }
        #expect(await env.sessions.exports(for: env.session.id).isEmpty)
        let state = source.snapshot()
        #expect(state.observed && !state.texture && !state.image)
    }

    @Test func cancellationAtWholeEncodingReleasesSourceAndAdmission() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let source = WeakWholeSource(), exporter = service(env, source: source)
        let snapshot = try env.snapshot(), request = request(env)
        let task = Task {
            try await exporter.export(session: env.session.id, snapshot: snapshot, request: request,
                progress: { event in
                    if event.stage == .encoding {
                        source.encoding()
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
        }
        do { _ = try await task.value; Issue.record("Cancelled whole export succeeded") }
        catch is CancellationError {}
        catch let error as HyperDRError { #expect(error.code == "cancelled") }
        let state = source.snapshot()
        #expect(state.observed && state.encodingTexture == false && state.encodingImage == false)
        #expect(!state.texture && !state.image)
        #expect(await env.sessions.exports(for: env.session.id).isEmpty)
        _ = try await exporter.export(session: env.session.id, snapshot: snapshot, request: request)
        #expect(await env.sessions.exports(for: env.session.id).count == 1)
    }
}
