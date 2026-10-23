import Foundation
import HyperDRRecipe
import HyperDRRender
import Synchronization
import Testing
@testable import HyperDRKit

private final class RecordingReportRows: ExportRowRendering {
    let preparedRows = Mutex<[Int]>([])
    let fake: StripeFake

    init(fake: StripeFake) { self.fake = fake }

    func prepareRows(_ source: HyperDRRender.ExportSource, recipe: Recipe, lut: ColorLUT?,
                     modelGain: ModelGainPrediction?, request: ExportRenderRequest,
                     rows: Int) async throws -> any ExportRowSource {
        preparedRows.withLock { $0.append(rows) }
        return try await fake.prepareRows(source, recipe: recipe, lut: lut,
            modelGain: modelGain, request: request, rows: rows)
    }
}

@Suite(.serialized) struct RecipeExportReportTests {
    @Test func rowReportRecordsBudgetSelectedHeightWithoutChangingIdentity() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var recipe = Recipe()
        recipe.setValue(.bool(false), for: "hdr.enabled")
        recipe.setValue(.number(2), for: "hdr.range")
        // Keep the source tiny. The mat makes two row heights distinguishable
        // in admission while all photo/frame pixels are supplied by the fake.
        let canvas = ExportPixelSize(width: 2048, height: 384)
        let frame = FrameSnapshot(canvasSize: .init(width: canvas.width, height: canvas.height),
            photo: .init(x: 8, y: 8, width: 96, height: 64), paper: .init(repeating: 0.8))
        let snapshot = try env.snapshot(recipe: recipe, frame: frame)
        var request = env.request(.sdrTIFF)
        request.frame = .init(canvas: canvas)
        request.edit = .init(recipe: recipe, peakStops: 2)
        var identities: [ExportKey] = []
        for height in [256, 128] {
            let estimate = ExportMemoryEstimate.estimate(.init(source: request.source,
                photoSize: request.source.pixelSize, canvas: canvas, encoding: .sdrTIFF,
                writer: .inHouse, writesGainMap: false, isFramed: true, baseBitDepth: 16,
                writeRows: height, retainedBytes: 0, allowsRowInput: true, quality: 95))
            let budget = FixedExportMemoryBudget(bytes: estimate.peak + 1)
            let plan = ExportPlanner.plan(request, budget: budget)
            try #require(plan.blockers.isEmpty && plan.memory.usesRowInput)
            try #require(plan.memory.renderRows == height)
            let fake = StripeFake()
            let rowRenderer = RecordingReportRows(fake: fake)
            let service = RecipeExportService(engine: env.engine, renderEngine: env.render,
                renderer: fake, sessions: env.sessions, target: env.target, budget: budget,
                rowRenderer: rowRenderer)
            let result = try await service.export(session: env.session.id, snapshot: snapshot, request: request)
            let report = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
            #expect(result.verified && result.resolved.usesRowInput == true)
            #expect(rowRenderer.preparedRows.withLock { $0 } == [height])
            #expect(report.usesRowInput == true && report.renderRows == height)
            identities.append(try result.resolved.exportKey())
            let resolvedJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.resolved)) as? [String: Any])
            #expect(resolvedJSON["renderRows"] == nil)
        }
        #expect(identities.count == 2 && identities[0] == identities[1])
    }

    @Test func wholeReportOmitsRowHeight() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        var request = env.request(.sdrTIFF)
        request.allowsRowInput = false
        let result = try await env.service().export(session: env.session.id,
            snapshot: env.snapshot(), request: request)
        let report = try JSONDecoder().decode(RecipeExportReport.self, from: result.record.reportJSON)
        #expect(report.writer == .inHouse && report.usesRowInput == false && report.renderRows == nil)
    }

    @Test func olderReportWithoutRowHeightStillDecodes() throws {
        let oldJSON = Data(#"{"schema":"hyperdr.recipe-export/v1","system":{"width":96,"height":64,"bitDepth":16,"orientation":1,"auxiliaryGain":false,"hdrReadable":false,"verifiedHeadroomStops":[]},"stageSeconds":{},"resplitReasons":[],"transparentBackground":"black-sdr","usesRowInput":true}"#.utf8)
        let report = try JSONDecoder().decode(RecipeExportReport.self, from: oldJSON)
        #expect(report.usesRowInput == true && report.renderRows == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(encoded["renderRows"] == nil)
    }
}
