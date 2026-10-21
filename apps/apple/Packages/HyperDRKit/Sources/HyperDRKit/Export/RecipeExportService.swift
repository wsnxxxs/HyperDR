import Foundation
import os
import HyperDREngine
import HyperDRRecipe
import HyperDRRender

public struct RecipeExportReport: Sendable, Codable {
    public let schema: String
    /// Unmodified hyperdr.package/v1 bytes, absent for ImageIO HEIC writes.
    public let packageJSON: Data?
    public let firstReaderJSON: Data?
    public let system: SystemExportVerification
    /// `rendering` is preparation. `read` is synchronous ROI rendering/readback;
    /// `encoding` excludes `read` but includes native writer/verification work.
    public let stageSeconds: [String: Double]
    public let resplitReasons: [String]
    public let transparentBackground: String
    public let writer: ExportWriter?
    public let writerReason: ExportWriterReason?
    public let imageIO: ImageIOGainWriteReport?
    public let usesRowInput: Bool?
}

/// One operation at a time. Dedicated RenderEngine caches can be discarded
/// without disturbing the editor. The caller's Task owns cancellation.
public actor RecipeExportService: RecipeExportServicing {
    public private(set) var lastMemoryDiagnostic: ExportMemoryDiagnostic?
    /// Custom provider: receives the Recipe selection and returns its full model identity.
    public typealias Prediction = @Sendable (RenderSource, String) async throws -> ModelGainPrediction
    private let engine: Engine
    private let renderEngine: RenderEngine
    private let renderer: any ExportStripeRendering
    private let rowRenderer: (any ExportRowRendering)?
    private let sessions: SessionStore
    private let target: ExportTarget
    private let budget: any ExportMemoryBudget
    private let prediction: Prediction?
    private var defaultModelProvider: CoreMLModelGainProvider?
    private var busy = false

    public init(engine: Engine, renderEngine: RenderEngine, renderer: any ExportStripeRendering,
                sessions: SessionStore, target: ExportTarget,
                budget: any ExportMemoryBudget = SystemExportMemoryBudget(), prediction: Prediction? = nil,
                rowRenderer: (any ExportRowRendering)? = nil) {
        self.engine = engine; self.renderEngine = renderEngine; self.renderer = renderer
        self.sessions = sessions; self.target = target; self.budget = budget
        self.prediction = prediction
        self.rowRenderer = rowRenderer ?? (renderer as? any ExportRowRendering)
    }

    public func export(session: SessionID, snapshot: RecipeExportSnapshot,
                       request: ExportPlanRequest, lut: ColorLUT? = nil, destination: URL? = nil,
                       progress: @escaping @Sendable (RecipeExportProgress) -> Void = { _ in }) async throws -> RecipeExportResult {
        guard !busy else { throw RecipeExportError.busy }
        busy = true
        lastMemoryDiagnostic = nil
        defer { busy = false }
        var pending: ExportID?
        var published = false
        var timings: [String: Double] = [:]
        var stage = RecipeExportStage.preparing
        let operationStart = ContinuousClock.now
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
            actualRequest.capabilities = ExportEncodingCapabilities(try await engine.capabilities())
            actualRequest.allowsRowInput = request.allowsRowInput && rowRenderer != nil
            // Recipe is authoritative for the SDR switch. The selection cannot
            // turn processing back on or turn the recipe into legacy options.
            actualRequest.edit.hdrEnabled = snapshot.recipe.conditionValue("hdr.enabled")?.boolValue ?? true
            if let frame = snapshot.frame {
                guard frame.width > 0, frame.height > 0, frame.width <= 1_048_576, frame.height <= 1_048_576,
                      frame.width <= (1 << 34) / frame.height else { throw RecipeExportError.invalidSnapshot }
                actualRequest.frame = ExportFrameFacts(canvas: .init(width: frame.width, height: frame.height))
            } else { actualRequest.frame = ExportFrameFacts() }
            var plan = ExportPlanner.plan(actualRequest, budget: budget)
            // Destination availability and encoding share the same planning admission.
            let blockers = plan.blockers
            guard blockers.isEmpty else {
                recordPlanMemoryFailure(plan, residentBytes: 0)
                throw RecipeExportError.planBlocked(blockers.map(\.code))
            }
            let ext = fileExtension(plan.encoding)
            let destinationLease: SecurityScopeLease?
            if let destination { destinationLease = try await target.leaseDestination(destination, expectedExtension: ext) }
            else { destinationLease = nil }
            defer { destinationLease?.stop() }
            try await checkMemory(plan, residentBytes: 0, request: actualRequest)
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
            try await checkMemory(plan, residentBytes: retainedCPUBytes, request: actualRequest)
            if let frame = frozenFrame {
                guard frame.photo.width == plan.photoSize.width, frame.photo.height == plan.photoSize.height else {
                    throw RecipeExportError.invalidSnapshot
                }
            }
            if request.source.domain == .rawEDR { emit(.developing) }
            else { emit(.preparing) }
            let lazySource: HyperDRRender.ExportSource?
            var source: RenderSource
            if actualRequest.allowsRowInput {
                let lazy = try await renderEngine.openExportSource(photo.sourceURL,
                    options: SourceOptions(recipe: snapshot.recipe, resolution: .full))
                lazySource = lazy; source = lazy.analysisSource
            } else {
                lazySource = nil
                source = try await renderEngine.load(photo.sourceURL,
                    options: SourceOptions(recipe: snapshot.recipe, resolution: .full))
            }
            guard source.domain == snapshot.recipe.inputDomain,
                  source.nativeSize.width == request.source.pixelSize.width,
                  source.nativeSize.height == request.source.pixelSize.height else { throw RecipeExportError.sourceChanged }
            var model: ModelGainPrediction?
            if adjustments.hdr.enabled && [.ai, .capturedAI].contains(snapshot.recipe.hdrSource) {
                emit(.model)
                guard let selection = snapshot.modelSelection else { throw RecipeExportError.missingModel }
                let identity: String
                if let prediction {
                    let predicted = try await prediction(source, selection)
                    model = predicted
                    identity = predicted.modelID
                } else {
                    guard selection == ModelGain.modelName else { throw RecipeExportError.missingModel }
                    let provider: CoreMLModelGainProvider
                    if let cached = defaultModelProvider { provider = cached }
                    else {
                        provider = try CoreMLModelGainProvider(device: await renderEngine.device)
                        defaultModelProvider = provider
                    }
                    identity = provider.modelID
                    if let expected = snapshot.expectedModelIdentity, expected != identity {
                        throw RecipeExportError.missingModel
                    }
                    model = try await renderEngine.predictModelGain(source, provider: provider)
                }
                guard !identity.isEmpty, model?.sourceID == source.modelSourceID, model?.modelID == identity,
                      snapshot.expectedModelIdentity == nil || snapshot.expectedModelIdentity == identity else {
                    throw RecipeExportError.missingModel
                }
            }
            try Task.checkCancellation()
            // UI readouts can precede prediction and are only estimates. Resolve
            // the frozen Recipe with the actual model before imposing a ceiling.
            let automatic = try await renderEngine.resolvedAutomatic(source, recipe: snapshot.recipe,
                                                                      lut: frozenLUT, modelGain: model)
            guard let naturalRange = adjustments.hdr.range.map(Double.init) ?? automatic["hdr.range"],
                  naturalRange.isFinite, naturalRange >= 0 else { throw RecipeExportError.invalidSnapshot }
            actualRequest.edit.peakStops = naturalRange
            // The host reports remaining memory after source/model/analysis
            // allocation. Credit only resident allocations already charged in
            // the estimate; prediction is not part of that estimate.
            var resident = retainedCPUBytes
                + source.size.width * source.size.height * (source.domain == .dual ? 48 : 16)
                + (lazySource == nil && source.domain == .rawEDR
                    ? (request.source.sensorSize ?? request.source.pixelSize).pixels * 16 : 0)
            let remaining = budget.availableBytes() ?? 256 * 1024 * 1024
            let totalBudget = remaining.addingReportingOverflow(resident)
            plan = ExportPlanner.plan(actualRequest, budget: FixedExportMemoryBudget(
                bytes: totalBudget.overflow ? Int.max : totalBudget.partialValue))
            let resolvedBlockers = plan.blockers
            guard resolvedBlockers.isEmpty else {
                recordPlanMemoryFailure(plan, residentBytes: resident)
                if let memory = resolvedBlockers.first(where: { if case .memory = $0 { true } else { false } }),
                   case .memory(let needed, let available, let size, let edge) = memory {
                    throw RecipeExportError.memoryExceeded(.memory(needed: max(0, needed - resident),
                        available: max(0, available - resident), size: size, maxLongEdge: edge))
                }
                throw RecipeExportError.planBlocked(resolvedBlockers.map(\.code))
            }
            if !plan.memory.usesRowInput && lazySource != nil {
                source = try await renderEngine.load(photo.sourceURL,
                    options: SourceOptions(recipe: snapshot.recipe, resolution: .full))
                resident = retainedCPUBytes + request.source.pixelSize.pixels * (source.domain == .dual ? 48 : 16)
                    + (source.domain == .rawEDR ? (request.source.sensorSize ?? request.source.pixelSize).pixels * 16 : 0)
            }
            try await checkMemory(plan, residentBytes: resident, request: actualRequest)
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
            let report: ExportRenderReport
            let thumbnail: ExportThumbnail
            var packageJSON: Data?
            var firstReaderJSON: Data?
            var imageIOReport: ImageIOGainWriteReport?
            if plan.memory.usesRowInput {
                guard let rowRenderer, let lazySource,
                      Engine.supportsPackageRows(format: plan.encoding.rawValue) else {
                    throw HyperDRError(code: "unsupported_format", message: "Incremental export is unavailable")
                }
                emit(.rendering)
                let rows = try await rowRenderer.prepareRows(lazySource, recipe: snapshot.recipe, lut: frozenLUT,
                    modelGain: model, request: renderRequest, rows: plan.memory.renderRows)
                report = rows.report
                guard report.canvasSize == renderRequest.canvasSize,
                      (report.gain != nil) == renderRequest.includesGain,
                      report.presentationFrame == (snapshot.frame != nil),
                      report.framePhoto == frozenFrame?.photo,
                      plan.writer.capabilities(encoding: plan.encoding, bitDepth: plan.baseBitDepth,
                        gainChannels: report.gain?.channelCount ?? 0,
                        baseHeadroom: Double(report.gain?.baseHeadroom ?? 0)).supported else { throw RecipeExportError.invalidStripes }
                try validateRevision(try await sessions.session(session), snapshot: snapshot)
                try await checkMemory(plan, residentBytes: resident, request: actualRequest)
                let bridge = PackageRowBridge(source: rows, frame: frozenFrame, progress: progress)
                emit(.encoding)
                let metadata = report.gain.map {
                    PackageGainMetadata(baseOffsets: [$0.baseOffset.x, $0.baseOffset.y, $0.baseOffset.z],
                        alternateOffsets: [$0.alternateOffset.x, $0.alternateOffset.y, $0.alternateOffset.z],
                        baseHeadroom: $0.baseHeadroom, alternateHeadroom: $0.alternateHeadroom)
                }
                let framePhoto = plan.gainMap.writesGainMap ? report.framePhoto.map {
                    FrameLayout.Rect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                } : nil
                let packaged = try await engine.packageRows(width: plan.size.width, height: plan.size.height,
                    gainChannels: report.gain?.channelCount ?? 0, gainMetadata: metadata, rows: plan.memory.renderRows,
                    to: file, options: .init(format: plan.encoding.rawValue, quality: plan.quality,
                        depth: plan.encoding == .adaptive ? plan.baseBitDepth : 8,
                        gamut: plan.encoding.isSDR ? plan.gamut.rawValue : nil, verify: true,
                        presentationFrame: report.presentationFrame, framePhoto: framePhoto),
                    read: { y, count, base, gain in try bridge.read(y: y, count: count, base: base, gain: gain) })
                guard packaged.verified, (packaged.gain?.clippedSamples ?? 0) == 0 else {
                    throw RecipeExportError.verificationFailed("package_rows_unverified")
                }
                // Native packaging includes synchronous pull rendering. Separate
                // it before emitting verification closes the encoding clock.
                timings["read", default: 0] += bridge.readSeconds
                if ProcessInfo.processInfo.environment["HYPERDR_HEVC_TIMINGS"] != nil {
                    print("ROW_TIMING render=\(bridge.readSeconds) callback=\(bridge.callbackSeconds) overhead=\(bridge.callbackSeconds - bridge.readSeconds)")
                }
                stageStart = stageStart.addingTimeInterval(bridge.readSeconds)
                packageJSON = packaged.rawJSON
                thumbnail = try bridge.thumbnail()
                emit(.verifying)
            } else {
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
                report = try owner.completed()
                let needsGain = renderRequest.includesGain
                guard (report.gain != nil) == needsGain,
                      report.presentationFrame == (snapshot.frame != nil),
                      plan.writer.capabilities(encoding: plan.encoding, bitDepth: plan.baseBitDepth,
                                               gainChannels: report.gain?.channelCount ?? 0,
                                               baseHeadroom: Double(report.gain?.baseHeadroom ?? 0)).supported else {
                    throw HyperDRError(code: "unsupported_format", message: "The rendered pair cannot be represented by this writer")
                }
                guard finalReport.canvasSize == report.canvasSize, finalReport.gain == report.gain,
                      finalReport.sourceProvenance == report.sourceProvenance,
                      finalReport.provenance == report.provenance, finalReport.resplitReasons == report.resplitReasons,
                      finalReport.rangeBeforeCeiling == report.rangeBeforeCeiling,
                      finalReport.rangeAfterCeiling == report.rangeAfterCeiling,
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
                // source stays charged in resident bytes; prediction consumes the
                // host's measured remaining budget.
                await renderEngine.clearCaches()
                try Task.checkCancellation()
                try await checkMemory(plan, residentBytes: resident + plan.size.pixels * (12 + 4 * (report.gain?.channelCount ?? 0)),
                                      request: actualRequest)
                thumbnail = try owner.thumbnail(frame: frozenFrame)
                emit(.encoding)
                if plan.writer == .imageIO && plan.gainMap.writesGainMap {
                    guard let gain = owner.gainPlane, let metadata = report.gain else { throw RecipeExportError.invalidStripes }
                    imageIOReport = try ImageIOHEICWriter.write(base: owner.basePlane, gain: gain, metadata: metadata,
                        to: file, quality: plan.quality)
                    emit(.verifying)
                    let probe = try await engine.probe(file)
                    guard probe.width == plan.size.width, probe.height == plan.size.height,
                          probe.orientation == 1, probe.inputDomain == "dual-rendition",
                          probe.headroom.isFinite, probe.headroom >= 1 else {
                        throw RecipeExportError.verificationFailed("heif_gain_readback")
                    }
                    firstReaderJSON = probe.rawJSON
                } else if plan.encoding == .adaptive && !plan.gainMap.writesGainMap {
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
            }
            // The native verifier has released its decode. Release graph caches
            // before the independent system reader starts.
            await renderEngine.clearCaches()
            if let imageIOReport { try ImageIOHEICWriter.verify(file, expected: imageIOReport) }
            let system = try ExportVerification.system(file, plan: plan, gainMetadata: report.gain)
            try Task.checkCancellation()
            try validateRevision(try await sessions.session(session), snapshot: snapshot)
            // Range controls can narrow the pair before its adaptation scan.
            // Render reports that change separately from a boundary resplit.
            var conversionReasons = report.resplitReasons
            if report.ceilingApplied { conversionReasons.insert(.outputCeiling) }
            let resolved = ResolvedExportSnapshot(snapshot: snapshot, plan: plan, modelIdentity: model?.modelID,
                resolvedAutomatic: report.resolvedAutomatic, resplitReasons: conversionReasons.map(\.rawValue),
                report: report)
            timings[stage.rawValue, default: 0] += Date().timeIntervalSince(stageStart)
            let evidence = RecipeExportReport(schema: "hyperdr.recipe-export/v1", packageJSON: packageJSON,
                firstReaderJSON: firstReaderJSON, system: system, stageSeconds: timings,
                resplitReasons: resolved.resplitReasons, transparentBackground: "black-sdr",
                writer: plan.writer, writerReason: plan.writerReason, imageIO: imageIOReport,
                usesRowInput: plan.memory.usesRowInput)
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
            return RecipeExportResult(record: record, resolved: resolved, file: file, saved: saved, deliveryError: deliveryError,
                                      elapsed: operationStart.duration(to: .now))
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
    private func checkMemory(_ plan: ExportPlan, residentBytes: Int, request: ExportPlanRequest) async throws {
        let available = budget.availableBytes() ?? 256 * 1024 * 1024
        let needed = max(0, plan.memory.estimate.peak - residentBytes)
        guard needed <= available else {
            recordMemoryFailure(.init(check: .process, phase: .running, requiredBytes: needed, availableBytes: available,
                reason: plan.memory.usesRowInput ? .workingSet : .nonIncrementalWriter))
            throw runtimeMemoryError(plan, request: request, needed: needed,
                                     available: available, residentBytes: residentBytes)
        }
        // Metal's recommendation is an independent GPU constraint, never the
        // process limit. Source and active graph textures still occupy memory.
        let sourceSize = request.source.pixelSize
        let sourcePixels = sourceSize.pixels
        let gpu: Int
        if plan.memory.usesRowInput {
            let limit = await RenderEngine.maximumTextureDimension(device: renderEngine.device)
            gpu = ExportMemoryEstimate.rowGPUBytes(maximumTextureDimension: limit)
        } else {
            gpu = sourcePixels * 48 + plan.photoSize.pixels * 64
                + plan.size.width * min(plan.memory.renderRows, plan.size.height) * 64
        }
        let gpuBudget = await renderEngine.device.recommendedMaxWorkingSetSize
        if let failure = ExportMemoryDiagnostic.gpuFailure(required: gpu, recommended: Int(gpuBudget)) {
            recordMemoryFailure(failure)
            // The process estimator cannot prove a smaller GPU working set.
            // Keep the typed facts, without offering an unverified size fix.
            throw RecipeExportError.memoryExceeded(.memory(needed: gpu, available: Int(gpuBudget),
                size: plan.size, maxLongEdge: nil))
        }
    }
    /// Credit only allocations already included in the estimate. Freeze the
    /// measured runtime budget so the size search cannot sample a different one.
    private func runtimeMemoryError(_ plan: ExportPlan, request: ExportPlanRequest,
                                    needed: Int, available: Int, residentBytes: Int) -> RecipeExportError {
        let total = available.addingReportingOverflow(residentBytes)
        let edge = ExportPlanner.maximumLongEdge(request,
            budget: total.overflow ? Int.max : total.partialValue, upper: plan.photoSize.longEdge)
        return .memoryExceeded(.memory(needed: needed, available: available, size: plan.size, maxLongEdge: edge))
    }
    private func recordPlanMemoryFailure(_ plan: ExportPlan, residentBytes: Int) {
        guard plan.blockers.contains(where: { $0.code == "export_memory_exceeded" }) else { return }
        recordMemoryFailure(.init(check: .process, phase: .planning,
            requiredBytes: max(0, plan.memory.estimate.peak - residentBytes),
            availableBytes: max(0, (plan.memory.availableBytes ?? 256 * 1024 * 1024) - residentBytes),
            reason: plan.memory.usesRowInput ? .workingSet : .nonIncrementalWriter))
    }
    private func recordMemoryFailure(_ failure: ExportMemoryDiagnostic) {
        lastMemoryDiagnostic = failure
        Logger(subsystem: "com.hyperdr.HyperDR", category: "Export")
            .error("Export memory admission: \(failure.summary, privacy: .public)")
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
