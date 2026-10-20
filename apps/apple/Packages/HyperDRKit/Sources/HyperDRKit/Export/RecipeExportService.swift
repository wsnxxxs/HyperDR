import Foundation
import os
import HyperDREngine
import HyperDRRecipe
import HyperDRRender

public struct RecipeExportReport: Sendable, Codable {
    public let schema: String
    /// Unmodified hyperdr.package/v1 bytes, absent only for ordinary SDR HEIC.
    public let packageJSON: Data?
    public let firstReaderJSON: Data?
    public let system: SystemExportVerification
    public let stageSeconds: [String: Double]
    public let resplitReasons: [String]
    public let transparentBackground: String
}

/// One operation at a time. Dedicated RenderEngine caches can be discarded
/// without disturbing the editor. The caller's Task owns cancellation.
public actor RecipeExportService: RecipeExportServicing {
    public typealias Prediction = @Sendable (RenderSource, String) async throws -> ModelGainPrediction
    private let engine: Engine
    private let renderEngine: RenderEngine
    private let renderer: any ExportStripeRendering
    private let sessions: SessionStore
    private let target: ExportTarget
    private let budget: any ExportMemoryBudget
    private let prediction: Prediction
    private var busy = false

    public init(engine: Engine, renderEngine: RenderEngine, renderer: any ExportStripeRendering,
                sessions: SessionStore, target: ExportTarget,
                budget: any ExportMemoryBudget = SystemExportMemoryBudget(), prediction: Prediction? = nil) {
        self.engine = engine; self.renderEngine = renderEngine; self.renderer = renderer
        self.sessions = sessions; self.target = target; self.budget = budget
        self.prediction = prediction ?? { source, modelID in
            let provider = try CoreMLModelGainProvider(device: await renderEngine.device)
            guard provider.modelID == modelID else { throw RecipeExportError.missingModel }
            return try await renderEngine.predictModelGain(source, provider: provider)
        }
    }

    public func export(session: SessionID, snapshot: RecipeExportSnapshot,
                       request: ExportPlanRequest, lut: ColorLUT? = nil, destination: URL? = nil,
                       progress: @escaping @Sendable (RecipeExportProgress) -> Void = { _ in }) async throws -> RecipeExportResult {
        guard !busy else { throw RecipeExportError.busy }
        busy = true
        defer { busy = false }
        var pending: ExportID?
        var published = false
        var timings: [String: Double] = [:]
        var stage = RecipeExportStage.preparing
        var stageStart = Date()
        func emit(_ next: RecipeExportStage) {
            timings[stage.rawValue, default: 0] += Date().timeIntervalSince(stageStart)
            stage = next; stageStart = Date(); progress(.init(stage: next))
        }
        progress(.init(stage: .preparing))
        do {
            try Task.checkCancellation()
            guard snapshot.version == RecipeExportSnapshot.currentVersion,
                  snapshot.recipe.version == Recipe.currentVersion,
                  snapshot.recipe.inputDomain == request.source.domain,
                  request.source.pixelSize.width <= 1_048_576, request.source.pixelSize.height <= 1_048_576,
                  request.source.pixelSize.width <= (1 << 34) / request.source.pixelSize.height else { throw RecipeExportError.invalidSnapshot }
            if let sensor = request.source.sensorSize {
                guard sensor.width <= 1_048_576, sensor.height <= 1_048_576,
                      sensor.width <= (1 << 34) / sensor.height else { throw RecipeExportError.invalidSnapshot }
            }
            let (photo, lease) = try await sessions.exportSource(session)
            defer { lease.stop() }
            try validateRevision(photo, snapshot: snapshot)
            var actualRequest = request
            // Recipe is authoritative for the SDR switch. The selection cannot
            // turn processing back on or turn the recipe into legacy options.
            actualRequest.edit.hdrEnabled = snapshot.recipe.conditionValue("hdr.enabled")?.boolValue ?? true
            if let frame = snapshot.frame {
                guard frame.width > 0, frame.height > 0, frame.width <= 1_048_576, frame.height <= 1_048_576,
                      frame.width <= (1 << 34) / frame.height else { throw RecipeExportError.invalidSnapshot }
                actualRequest.frame = ExportFrameFacts(canvas: .init(width: frame.width, height: frame.height))
            } else { actualRequest.frame = ExportFrameFacts() }
            var plan = ExportPlanner.plan(actualRequest, budget: budget)
            // Photos authorization gates library delivery, never file generation.
            let blockers = plan.blockers.filter { $0.code != "photos_permission_denied" }
            guard blockers.isEmpty else { throw RecipeExportError.planBlocked(blockers.map(\.code)) }
            let ext = fileExtension(plan.encoding)
            let destinationLease: SecurityScopeLease?
            if let destination { destinationLease = try await target.leaseDestination(destination, expectedExtension: ext) }
            else { destinationLease = nil }
            defer { destinationLease?.stop() }
            try await checkMemory(plan, residentBytes: 0, sourcePixels: request.source.pixelSize.pixels)
            await renderEngine.clearCaches()
            var frozenLUT = lut
            if let hash = snapshot.lutContentHash {
                // Require the durable session resource, even if the UI still has
                // a parsed table. History must survive library deletion.
                let retained = try await sessions.recipeLUT(hash, for: session)
                guard frozenLUT == nil || frozenLUT?.contentHash == retained.contentHash,
                      retained.contentHash == hash else { throw RecipeExportError.missingLUT }
                frozenLUT = retained
                actualRequest.resources.lutValueCount = retained.values.count
            } else if frozenLUT != nil { throw RecipeExportError.invalidSnapshot }
            let adjustments = try RenderAdjustments(recipe: snapshot.recipe, lut: frozenLUT)
            let frozenFrame = try await sessions.resolveFrame(snapshot.frame, for: session)
            actualRequest.resources.frameOverlayBytes = frozenFrame?.caption?.png.count ?? 0
            if let caption = frozenFrame?.caption {
                actualRequest.resources.frameOverlayPixels = caption.rect.width * caption.rect.height
            }
            plan = ExportPlanner.plan(actualRequest, budget: budget)
            let retainedCPUBytes = (frozenLUT?.values.count ?? 0) * 16 + (frozenFrame?.caption?.png.count ?? 0)
            try await checkMemory(plan, residentBytes: retainedCPUBytes, sourcePixels: request.source.pixelSize.pixels)
            if let frame = frozenFrame {
                guard frame.photo.width == plan.photoSize.width, frame.photo.height == plan.photoSize.height else {
                    throw RecipeExportError.invalidSnapshot
                }
            }
            emit(.developing)
            let source = try await renderEngine.load(photo.sourceURL,
                options: SourceOptions(recipe: snapshot.recipe, resolution: .full))
            guard source.domain == snapshot.recipe.inputDomain,
                  source.nativeSize.width == request.source.pixelSize.width,
                  source.nativeSize.height == request.source.pixelSize.height else { throw RecipeExportError.sourceChanged }
            var model: ModelGainPrediction?
            if adjustments.hdr.enabled && [.ai, .capturedAI].contains(snapshot.recipe.hdrSource) {
                emit(.model)
                guard let modelID = snapshot.modelID else { throw RecipeExportError.missingModel }
                model = try await prediction(source, modelID)
                guard model?.sourceID == source.id, model?.modelID == modelID else { throw RecipeExportError.missingModel }
            }
            try Task.checkCancellation()
            // UI readouts can precede prediction and are only estimates. Resolve
            // the frozen Recipe with the actual model before imposing a ceiling.
            let automatic = try await renderEngine.resolvedAutomatic(source, recipe: snapshot.recipe,
                                                                      lut: frozenLUT, modelGain: model)
            guard let naturalRange = adjustments.hdr.range.map(Double.init) ?? automatic["hdr.range"],
                  naturalRange.isFinite, naturalRange >= 0 else { throw RecipeExportError.invalidSnapshot }
            actualRequest.edit.peakStops = naturalRange
            plan = ExportPlanner.plan(actualRequest, budget: budget)
            let resolvedBlockers = plan.blockers.filter { $0.code != "photos_permission_denied" }
            guard resolvedBlockers.isEmpty else { throw RecipeExportError.planBlocked(resolvedBlockers.map(\.code)) }
            let resident = retainedCPUBytes + (model.map { $0.gain.width * $0.gain.height * 4 } ?? 0)
                + request.source.pixelSize.pixels * (source.domain == .dual ? 48 : 16)
                + (source.domain == .rawEDR ? (request.source.sensorSize ?? request.source.pixelSize).pixels * 16 : 0)
            try await checkMemory(plan, residentBytes: resident, sourcePixels: request.source.pixelSize.pixels)
            let prepared = try await sessions.prepareRecipeExport(session, snapshot: snapshot)
            pending = prepared.id
            let file = prepared.directory.appendingPathComponent("result." + ext)
            let caps = plan.writer.capabilities(encoding: plan.encoding, bitDepth: plan.baseBitDepth,
                                                gainChannels: plan.gainMap.channels)
            let renderRequest = ExportRenderRequest(
                photoSize: .init(width: plan.photoSize.width, height: plan.photoSize.height),
                ceilingStops: plan.peakStops.map(Float.init), gamut: renderGamut(plan.gamut),
                includesGain: plan.gainMap.writesGainMap || plan.encoding.isBT2100,
                capabilities: .init(supportsThreeChannelGain: caps.supportsThreeChannelGain,
                                    supportsSignedGain: caps.supportsSignedGain,
                                    requiresGainMaximumHeadroom: caps.requiresGainMaximumHeadroom),
                frame: frozenFrame)
            let owner = PackagePlaneCollector(width: plan.size.width, height: plan.size.height)
            emit(.rendering)
            let finalReport = try await renderer.renderExportStripes(source, recipe: snapshot.recipe, lut: frozenLUT,
                modelGain: model, request: renderRequest, rows: plan.memory.renderRows,
                prepare: { report in try Task.checkCancellation(); try owner.prepare(report) },
                consume: { stripe in
                    try owner.consume(stripe)
                    progress(.init(stage: .rendering, completedRows: stripe.rect.y + stripe.rect.height,
                                   totalRows: renderRequest.canvasSize.height))
                })
            let report = try owner.completed()
            let needsGain = renderRequest.includesGain
            guard (report.gain != nil) == needsGain,
                  report.presentationFrame == (snapshot.frame != nil),
                  plan.writer.capabilities(encoding: plan.encoding, bitDepth: plan.baseBitDepth,
                                           gainChannels: report.gain?.channelCount ?? 0).supported else {
                throw HyperDRError(code: "unsupported_format", message: "The rendered pair cannot be represented by this writer")
            }
            guard finalReport.canvasSize == report.canvasSize, finalReport.gain == report.gain,
                  finalReport.sourceProvenance == report.sourceProvenance,
                  finalReport.provenance == report.provenance, finalReport.resplitReasons == report.resplitReasons,
                  finalReport.resolvedAutomatic == report.resolvedAutomatic,
                  finalReport.presentationFrame == report.presentationFrame, finalReport.framePhoto == report.framePhoto else {
                throw RecipeExportError.invalidStripes
            }
            // A source edit during inference/render must not be published as the
            // old source. SessionStore rehashes on inode/ctime/mtime changes.
            let refreshed = try await sessions.session(session)
            try validateRevision(refreshed, snapshot: snapshot)
            // The collected planes are now independent. Drop graph/analysis/LUT
            // GPU caches before package allocates its whole-plane copies. The
            // local source and model stay accounted for in resident bytes.
            await renderEngine.clearCaches()
            try Task.checkCancellation()
            try await checkMemory(plan, residentBytes: resident + plan.size.pixels * (12 + 4 * (report.gain?.channelCount ?? 0)),
                                  sourcePixels: request.source.pixelSize.pixels)
            let thumbnail = try owner.thumbnail(frame: frozenFrame)
            emit(.encoding)
            var packageJSON: Data?
            var firstReaderJSON: Data?
            if plan.encoding == .adaptive && !plan.gainMap.writesGainMap {
                try SDRHEICWriter.write(owner.basePlane, to: file, quality: plan.quality)
                emit(.verifying)
                let probe = try await engine.probe(file)
                guard probe.width == plan.size.width, probe.height == plan.size.height,
                      probe.orientation == 1, probe.inputDomain == "display-referred-sdr" else {
                    throw RecipeExportError.verificationFailed("heif_sdr_readback")
                }
                firstReaderJSON = probe.rawJSON
            } else {
                let metadata = report.gain.map {
                    PackageGainMetadata(baseOffsets: [$0.baseOffset.x, $0.baseOffset.y, $0.baseOffset.z],
                                        alternateOffsets: [$0.alternateOffset.x, $0.alternateOffset.y, $0.alternateOffset.z],
                                        baseHeadroom: $0.baseHeadroom, alternateHeadroom: $0.alternateHeadroom)
                }
                let framePhoto = plan.gainMap.writesGainMap ? report.framePhoto.map {
                    FrameLayout.Rect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                } : nil
                let packaged = try await engine.package(sdr: owner.basePlane, gain: owner.gainPlane,
                    gainMetadata: metadata, to: file,
                    options: .init(format: plan.encoding.rawValue, quality: plan.quality,
                                   depth: plan.encoding == .adaptive ? plan.baseBitDepth : 8,
                                   gamut: plan.encoding.isSDR ? plan.gamut.rawValue : nil, verify: true,
                                   presentationFrame: report.presentationFrame, framePhoto: framePhoto))
                guard packaged.verified else { throw RecipeExportError.verificationFailed("package_unverified") }
                guard (packaged.gain?.clippedSamples ?? 0) == 0 else {
                    throw HyperDRError(code: "unsupported_format", message: "The writer clipped gain samples that Render must normalize")
                }
                packageJSON = packaged.rawJSON
                emit(.verifying)
            }
            // package's own verification has returned and released its decode.
            let system = try ExportVerification.system(file, plan: plan, gainMetadata: report.gain)
            try Task.checkCancellation()
            try validateRevision(try await sessions.session(session), snapshot: snapshot)
            // Render can apply the destination shoulder while building its
            // edited authored pair, before its final capability scan. Record
            // the planner's output constraint even when that scan needs no
            // further resplit; do not change the actual Render provenance.
            var conversionReasons = report.resplitReasons
            if let ceiling = plan.peakStops, actualRequest.edit.peakStops > ceiling {
                conversionReasons.insert(.outputCeiling)
            }
            let resolved = ResolvedExportSnapshot(snapshot: snapshot, plan: plan,
                resolvedAutomatic: report.resolvedAutomatic, resplitReasons: conversionReasons.map(\.rawValue),
                report: report)
            timings[stage.rawValue, default: 0] += Date().timeIntervalSince(stageStart)
            let evidence = RecipeExportReport(schema: "hyperdr.recipe-export/v1", packageJSON: packageJSON,
                firstReaderJSON: firstReaderJSON, system: system, stageSeconds: timings,
                resplitReasons: resolved.resplitReasons, transparentBackground: "black-sdr")
            emit(.publishing)
            var record = try await sessions.publishRecipeExport(session, export: prepared.id, name: file.lastPathComponent,
                resolved: resolved, reportJSON: JSONEncoder().encode(evidence), thumbnail: thumbnail)
            published = true
            var saved: SavedExport?
            var deliveryError: HyperDRError?
            if let destination {
                emit(.delivering)
                do {
                    try Task.checkCancellation()
                    let delivered = try await target.save(session: session, export: record.id, to: destination)
                    saved = delivered
                    let mark = SavedMark(fileName: delivered.name, folderDisplayName: delivered.folderDisplayName)
                    record.saved = mark
                    do { try await sessions.markSaved(session, export: record.id, saved: mark) }
                    catch {
                        // The file is already delivered. A sidecar failure must
                        // not invite the user to create a duplicate saved copy.
                        Logger(subsystem: "com.hyperdr.HyperDR", category: "Export")
                            .warning("Export delivered but its saved mark could not be persisted")
                    }
                } catch {
                    deliveryError = error as? HyperDRError ?? HyperDRError(
                        code: error is CancellationError ? "cancelled" : "export_delivery_failed", message: error.localizedDescription)
                }
            }
            await renderEngine.clearCaches()
            return RecipeExportResult(record: record, resolved: resolved, file: file, saved: saved, deliveryError: deliveryError)
        } catch {
            if let pending, !published { await sessions.discardExport(session, export: pending) }
            await renderEngine.clearCaches()
            throw error
        }
    }

    private func validateRevision(_ photo: PhotoSession, snapshot: RecipeExportSnapshot) throws {
        let revision = try RecipeSourceRevision(session: photo)
        guard revision == snapshot.source else { throw RecipeExportError.sourceChanged }
    }
    private func checkMemory(_ plan: ExportPlan, residentBytes: Int, sourcePixels: Int) async throws {
        let available = budget.availableBytes() ?? 256 * 1024 * 1024
        let needed = max(0, plan.memory.estimate.peak - residentBytes)
        guard needed <= available else { throw RecipeExportError.memoryExceeded(required: needed, available: available) }
        // Metal's recommendation is an independent GPU constraint, never the
        // process limit. Source and active graph textures still occupy memory.
        let gpu = sourcePixels * 48 + plan.photoSize.pixels * 64 + plan.size.width * min(plan.memory.renderRows, plan.size.height) * 64
        let gpuBudget = await renderEngine.device.recommendedMaxWorkingSetSize
        guard gpu <= gpuBudget else {
            throw RecipeExportError.memoryExceeded(required: gpu, available: Int(gpuBudget))
        }
    }
    private func renderGamut(_ gamut: ExportColorGamut) -> ExportGamut {
        switch gamut { case .p3: .displayP3; case .srgb: .sRGB; case .rec2020: .rec2020 }
    }
    private func fileExtension(_ encoding: ExportEncoding) -> String {
        switch encoding {
        case .adaptive, .pq, .hlg: "heic"
        case .avifPq, .avifHlg: "avif"
        case .sdrJPEG, .isoGainMapJPEG: "jpg"
        case .sdrTIFF: "tif"
        }
    }
}
