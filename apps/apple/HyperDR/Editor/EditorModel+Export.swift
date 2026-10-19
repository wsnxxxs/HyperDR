import Foundation
import CoreGraphics
import HyperDRKit
import UniformTypeIdentifiers

struct ExportFrameCacheKey: Equatable {
    var settings: FrameSettings; var facts: CaptureFacts; var size: PixelSize
}

/// An opaque, single-use save-panel capability. Its issuer owns validity.
nonisolated struct ExportPreparationToken: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let photoSerial: Int
    fileprivate let openGeneration: Int
    fileprivate let editGeneration: Int
}

extension EditorModel {
    static func fileExtension(_ encoding: String) -> String {
        switch encoding {
        case "sdr-tiff": "tif"
        case "sdr-jpeg", "iso-gainmap-jpeg": "jpg"
        case "avif-pq", "avif-hlg": "avif"
        default: "heic"
        }
    }
    var exportContentType: UTType { UTType(filenameExtension: Self.fileExtension(edit.encoding)) ?? .data }
    var documentStatus: DocumentStatus {
        guard document?.phase == .ready, hasEditedFrame else { return .waiting }
        guard !exportVersions.isEmpty else { return .notExported }
        guard let match = exportVersions.first(where: \.matchesCurrent) else { return .modifiedSinceExport }
        return match.saved == nil ? .exportedNotSaved : .saved
    }
    /// Ordered reasons from §5.3; preview refresh deliberately does not block.
    func syncExportState() {
        export.encodingID = edit.encoding
        export.outputGamut = edit.choices["outputGamut"] == "auto" ? (edit.encoding == "sdr-tiff" ? "p3" : "srgb") : edit.choices["outputGamut"] ?? "srgb"
        export.clampSrgb = edit.clampSrgb
        if let capabilities = exportCapabilities {
            export.encodingAvailability = capabilities.availability(isHDR: source.domain == .hdr || source.domain == .dual)
        }
        let blocker: String?
        if document == nil && !isRestoring { blocker = "export.blocker.noPhoto" }
        else if isRestoring { blocker = "export.blocker.restoring" }
        else if photo == nil || document?.phase != .ready || !hasEditedFrame { blocker = "export.blocker.loading" }
        else if ai.isComputing { blocker = "export.blocker.ai" }
        else if let reason = export.encodingAvailability[edit.encoding] ?? nil { blocker = reason }
        else if supportsFrameExport && frame.isEnabled && frameLayout == nil { blocker = "export.blocker.frame" }
        else if export.isInFlight { blocker = "export.blocker.inProgress" }
        else if case .failed = engine { blocker = "err.server.engine_unavailable" }
        else if case .starting = engine { blocker = "err.server.engine_unavailable" }
        else if preferences.value.saveMode == .folder && (!preferences.exportFolder.ready || preferences.exportFolder.target == nil) { blocker = preferences.exportFolder.label.isEmpty ? "err.server.export_folder_unset" : "err.server.export_folder_unwritable" }
        else { blocker = nil }
        if export.blockerKey != blocker { export.blockerKey = blocker }
        let lutBlock: String?
        switch editingLockReason {
        case .loading: lutBlock = "lut.importBlocker.loading"
        case .restoring: lutBlock = "lut.importBlocker.restoring"
        case .computingAI: lutBlock = "lut.importBlocker.computingAI"
        case .exporting: lutBlock = "lut.importBlocker.exporting"
        case nil: lutBlock = nil
        }
        if lut.importBlockerKey != lutBlock { lut.importBlockerKey = lutBlock }
    }
    func loadExportServices() async {
        do { exportCapabilities = try await services.encodingCapabilities() }
        catch { preferences.failure = UserFacingError.service(error) }
        preferences.exportFolder = await services.exportFolder()
        preferences.diagnostics = await services.diagnostics()
        preferences.about = await services.aboutInformation()
        await refreshLUTLibrary()
        timingHistory = await services.exportTimingHistory()
        syncExportState()
    }
    func makeExportFrame() throws -> ExportFrame? {
        guard supportsFrameExport, frame.isEnabled else { return nil }
        guard let size = document?.pixelSize else { throw UserFacingError(code: "invalid_options") }
        let key = ExportFrameCacheKey(settings: frame, facts: captureFacts, size: size)
        if cachedFrameKey == key { return cachedExportFrame }
        guard let plan = try FrameExportPlan.make(settings: frame, facts: captureFacts, photoSize: size) else { return nil }
        let result = ExportFrame(spec: plan.frame, overlayPNG: plan.overlayPNG)
        cachedExportFrame = result; cachedFrameKey = key
        return result
    }
    /// Capture immediately before presenting the save panel (or starting a
    /// fixed-folder export). Only the most recently issued token remains valid.
    func prepareExport() -> ExportPreparationToken? {
        finishGestureBeforeEdit()
        syncExportState()
        guard export.blockerKey == nil, photo != nil else { return nil }
        let id = UUID()
        pendingExportToken = id
        return ExportPreparationToken(id: id, photoSerial: photoSerial,
            openGeneration: generation, editGeneration: editGeneration)
    }

    /// Stale panel callbacks are silent and must not mutate the new photo.
    func startExport(destination: URL?, token: ExportPreparationToken) {
        guard pendingExportToken == token.id, photoSerial == token.photoSerial,
              generation == token.openGeneration, editGeneration == token.editGeneration else { return }
        pendingExportToken = nil
        // A nil destination is meaningful only in fixed-folder mode. A
        // cancelled save panel must not call startExport at all.
        syncExportState()
        guard export.blockerKey == nil, let photo else { return }
        guard destination != nil || preferences.value.saveMode == .folder else { return }
        finishGestureBeforeEdit()
        pendingExportToken = nil
        let thumbnailFrame = frozenExportThumbnailFrame()
        deferredExportThumbnailTask?.cancel(); deferredExportThumbnailTask = nil
        export.reset(); exportThumbnailPersisted = false; exportThumbnailEditGeneration = editGeneration
        if thumbnailFrame == nil {
            export.thumbnail = document?.previewError == nil && (currentEditedFrame == nil || exportSummaryThumbnail == .loading) ? .loading : .unavailable
        }
        exportThumbnailNeedsDeferred = thumbnailFrame == nil && export.thumbnail == .loading
        export.phase = .preparing; export.startedAt = now(); export.stageAt = export.startedAt
        let options = effectiveOptions(), snapshot = edit
        let fixedFolder = destination == nil ? preferences.exportFolder.target : nil
        export.destination = destination.map(ExportDestination.file) ?? .folder(label: preferences.exportFolder.label)
        let framed = supportsFrameExport && frame.isEnabled
        syncControls()
        exportTask = Task { [weak self, services] in
            guard let self else { return }
            do {
                // Cancellation covers validation and Kit preparation as well as conversion.
                if let destination { try await services.validateDestination(destination, expectedExtension: Self.fileExtension(snapshot.encoding)) }
                try Task.checkCancellation()
                let frame = try makeExportFrame()
                let exportSize: PixelSize?
                if frame != nil {
                    exportSize = frameLayout.map { PixelSize(width: $0.width, height: $0.height) }
                } else { exportSize = document?.pixelSize }
                let pixels = exportSize.map { Double($0.width) * Double($0.height) } ?? 0
                export.durations = ExportETA.durations(history: timingHistory, kind: .init(isRAW: photo.formatLabel == "RAW",
                    encoding: snapshot.encoding, isAI: snapshot.aiMode == .optimized, hasFrame: framed, verifies: snapshot.verifies), pixels: pixels)
                let thumbnail = if let thumbnailFrame { await services.sdrThumbnail(of: thumbnailFrame, maxPixelSize: 256) } else { nil as CGImage? }
                try Task.checkCancellation()
                if let thumbnail { export.thumbnail = .ready(thumbnail); exportThumbnailPersisted = true }
                else if thumbnailFrame != nil { export.thumbnail = .unavailable }
                let ticket = try await services.startExport(photo, options: options, frame: frame, destination: destination, thumbnail: thumbnail)
                if thumbnailFrame == nil { fillDeferredExportThumbnail() }
                if export.phase == .preparing { export.phase = .running }
                var terminal = false
                for await event in services.exportEvents(ticket.job) {
                    guard !Task.isCancelled, self.photo == photo else { break }
                    switch event {
                    case .progress(let stage, let fraction, let at):
                        if !["complete", "error"].contains(stage) { export.progress(stage: stage, fraction: fraction, at: at) }
                    case .log(let line): export.lastLine = line
                    case .finishing: export.phase = .finishing
                    case .saving: export.phase = .saving
                    case .finished(var result, let failure):
                        terminal = true
                        if let resultValue = result, failure == nil, let fixedFolder {
                            export.phase = .saving
                            do { result?.saved = try await fixedFolder.save(photo, export: resultValue.export) }
                            catch { if self.photo == photo, !export.isStopping { finishExport(result: result, failure: UserFacingError.service(error), snapshot: snapshot, framed: framed) }; return }
                        }
                        guard self.photo == photo, !export.isStopping else { return }
                        finishExport(result: result, failure: failure, snapshot: snapshot, framed: framed)
                        return
                    }
                }
                if !terminal && !Task.isCancelled { throw UserFacingError(code: "internal_error", detail: "Export event stream ended before its terminal event") }
            } catch {
                if self.photo == photo, !export.isStopping { finishExport(result: nil, failure: UserFacingError.service(error), snapshot: snapshot, framed: framed) }
            }
        }
    }
    func finishExport(result: ExportResult?, failure: UserFacingError?, snapshot: EditSnapshot, framed: Bool) {
        var failure = failure
        var result = result
        if let started = export.startedAt { result?.elapsed = .seconds(max(0, now().timeIntervalSince(started))) }
        if let error = failure {
            let variant = error.code == "export_memory_budget" ? (framed ? "frame" : "noFrame")
                : error.code == "export_dimension_limit" && snapshot.workflow == .colorOnly ? "color" : error.variant
            var detail = error.detail
            if error.code != "raw_unsupported", let line = export.lastLine, !line.isEmpty, detail?.contains(line) != true {
                detail = detail.map { $0 + "\n" + line } ?? line
            }
            failure = UserFacingError(code: error.code, detail: detail, variant: variant)
        }
        export.isStopping = false; exportTask = nil
        if failure?.code == "session_expired" { handleExportError(failure!); return }
        if failure?.code == "cancelled" {
            export.phase = .cancelled; export.result = nil; export.failure = nil; export.saveFailure = nil
        } else if let result {
            export.result = result; export.isResultStale = false; export.saveFailure = failure
            export.failure = nil; export.phase = .succeeded
            cacheVersionThumbnail(exportThumbnailPersisted ? export.thumbnail : .unavailable, id: result.export)
        } else {
            export.failure = failure ?? UserFacingError(code: "export_failed")
            export.phase = .failed
        }
        if let failure { handleExportError(failure) }
        syncControls()
        refreshExportMetadata()
        completePendingPhotoSwitch()
    }
    func cancelExport() {
        guard export.isInFlight, !export.isStopping else { return }
        export.isStopping = true
        let task = exportTask, expectedPhoto = photo
        task?.cancel()
        Task { [weak self, services] in
            await services.cancelAllExports()
            await task?.value
            guard let self, self.photo == expectedPhoto, export.isInFlight else { return }
            finishExport(result: nil, failure: UserFacingError(code: "cancelled"), snapshot: edit, framed: frame.isEnabled)
        }
    }
    func refreshExportMetadata() {
        exportMetadataTask?.cancel(); exportMetadataTicket += 1
        guard let photo, document?.phase == .ready, !export.isInFlight else { return }
        let ticket = exportMetadataTicket, options = effectiveOptions()
        // Capture frame values at the same revision as options, before suspending.
        let frame: ExportFrame?
        do { frame = try makeExportFrame() } catch { return }
        exportMetadataTask = Task { [weak self, services] in
            do {
                try Task.checkCancellation()
                let key = try await services.exportKey(photo, options: options, frame: frame)
                try Task.checkCancellation()
                let history = try await services.exports(for: photo)
                try Task.checkCancellation()
                let name = try await services.suggestedFileName(photo, options: options)
                try Task.checkCancellation()
                let timings = await services.exportTimingHistory()
                guard let self, !Task.isCancelled, self.photo == photo, exportMetadataTicket == ticket, !export.isInFlight else { return }
                currentExportKey = key; exportHistory = history
                exportVersions = history.sorted { $0.version.createdAt == $1.version.createdAt ? $0.version.number > $1.version.number : $0.version.createdAt > $1.version.createdAt }.map { item in
                    var version = item.version; version.matchesCurrent = item.key == key; return version
                }
                if let match = exportVersions.first(where: \.matchesCurrent), export.phase != .cancelled {
                    var result = match.result
                    if result.saved?.canReveal != true, export.result?.export == result.export,
                       export.result?.saved?.canReveal == true {
                        result.saved = export.result?.saved
                    }
                    if export.result?.export != result.export { export.thumbnail = versionThumbnail(result.export) }
                    export.result = result; export.isResultStale = false
                } else { export.isResultStale = export.result != nil }
                suggestedFileName = name; timingHistory = timings
            } catch {
                guard let self, !Task.isCancelled, self.photo == photo, exportMetadataTicket == ticket else { return }
                handleExportError(UserFacingError.service(error))
            }
        }
    }
    func restore(_ version: String) {
        guard !isEditingLocked, let item = exportHistory.first(where: { $0.version.id == version }),
              exportVersions.first(where: { $0.id == version })?.matchesCurrent == false else { return }
        finishGestureBeforeEdit()
        let previous = edit; edit = item.options
        recordStep(from: previous, action: "restoreExport")
        editChanged()
    }
    func saveExport(_ version: String, destination: URL?) {
        guard let photo, exportVersions.contains(where: { $0.id == version }) else { return }
        let id = UUID()
        guard exportSaveStates[version] != .saving else { return }
        exportSaveStates[version] = .saving
        saveTaskNames[id] = exportVersions.first(where: { $0.id == version })?.fileName ?? version
        saveTasks[id] = Task { [weak self, services] in
            defer { self?.saveTasks[id] = nil; self?.saveTaskNames[id] = nil }
            do {
                let saved = try await services.saveExport(photo, export: version, destination: destination)
                guard let self, self.photo == photo, !Task.isCancelled else { return }
                exportSaveStates[version] = .saved(saved)
                if let i = exportVersions.firstIndex(where: { $0.id == version }) { exportVersions[i].result.saved = saved }
                if export.result?.export == version { export.result?.saved = saved; export.saveFailure = nil }
                refreshExportMetadata()
            } catch {
                guard let self, self.photo == photo, !Task.isCancelled else { return }
                let error = UserFacingError.service(error)
                exportSaveStates[version] = error.code == "session_expired" ? .expired : error.code == "cancelled" ? nil : .failed(error)
                if error.code != "cancelled" { export.saveFailure = error; handleExportError(error) }
            }
        }
    }
    func handleExportError(_ error: UserFacingError) {
        if error.code == "session_expired" {
            exportTask?.cancel(); exportTask = nil
            Task { [services] in await services.cancelAllExports() }
            export.reset(); closeDocument(); publishAlert(error)
        } else if error.code == "engine_unavailable" || error.code == "internal_error" { publishAlert(error) }
    }
    func prepareForPhotoSwitch() {
        resetThumbnailsForPhotoSwitch()
        pendingExportToken = nil
        exportMetadataTask?.cancel(); exportMetadataTicket += 1
        cachedFrameKey = nil; cachedExportFrame = nil
        export.reset(); exportVersions = []; exportSaveStates = [:]; exportHistory = []; currentExportKey = nil; suggestedFileName = ""
        pendingPhotoSwitch = nil; pendingSwitchStops = false
        lutTicket += 1; lutTask?.cancel(); lut.selection = nil; lut.isBusy = false
    }
    func resolvePhotoSwitch(stop: Bool) {
        guard pendingPhotoSwitch != nil else { return }
        if !stop { pendingPhotoSwitch = nil; pendingSwitchStops = false; return }
        pendingSwitchStops = true
        if export.isInFlight { cancelExport() } else { completePendingPhotoSwitch() }
    }
    func completePendingPhotoSwitch() {
        guard !export.isInFlight, let request = pendingPhotoSwitch else { return }
        pendingPhotoSwitch = nil; pendingSwitchStops = false
        switch request.kind { case .open(let url): open([url]); case .close: closeDocument() }
    }
    func pasteFiles(_ urls: [URL], containsImageData: Bool) {
        if let url = urls.first(where: canOpen) { open([url]) }
        else if containsImageData { notice = .clipboardImageUnsupported }
    }
    /// App delegate uses this even while startExport is still preparing.
    var terminationFileName: String {
        export.isInFlight ? document?.name ?? "" : saveTaskNames.values.sorted().first ?? document?.name ?? ""
    }
    var isSavingForTermination: Bool { export.phase == .saving || !saveTasks.isEmpty }
    func needsTerminationConfirmation() async -> Bool {
        if export.isInFlight || !saveTasks.isEmpty { return true }
        let active = await services.hasExportActivity()
        return active || export.isInFlight || !saveTasks.isEmpty
    }
    func stopForTermination() async {
        pendingPhotoSwitch = nil
        export.isStoppingToQuit = export.isInFlight
        export.isStopping = export.isInFlight
        exportTask?.cancel()
        let saves = Array(saveTasks.values)
        for task in saves { task.cancel() }
        await services.cancelAllExports()
        for task in saves { await task.value }
        if let task = exportTask { await task.value }
        if export.isInFlight { export.phase = .cancelled; export.result = nil; export.isStopping = false; exportTask = nil; syncControls() }
    }
}


extension EditorModel {
    func setOutputGamut(_ id: String) {
        guard photo != nil, !isEditingLocked, ["srgb", "p3"].contains(id), edit.choices["outputGamut"] != id else { return }
        finishGestureBeforeEdit(); let previous = edit
        edit.choices["outputGamut"] = id
        recordStep(from: previous, action: "outputGamut"); editChanged()
    }
    func setClampSrgb(_ on: Bool) {
        guard photo != nil, !isEditingLocked, edit.clampSrgb != on else { return }
        finishGestureBeforeEdit(); let previous = edit
        edit.clampSrgb = on
        recordStep(from: previous, action: "clampSrgb"); editChanged()
    }
    private var rawDiagnostics: String {
        guard let raw = document?.source?.raw else { return "" }
        // R1 uses the engine default raw_lens_correction=true. R2/M3-R
        // will expose its switch; until then every supported RAW applies it.
        let support = raw.lensCorrectionSupported ? "supported, on" : "unsupported"
        return "\nRAW: apple-ciraw · decoder \(raw.decoderVersion) · macOS build \(raw.osBuild)"
            + "\nCamera: \(captureFacts.model ?? "—") · Lens: \(captureFacts.lens ?? "—")"
            + "\nLens correction: " + support
    }
    /// Generate only on explicit copy, capturing one coherent edit snapshot.
    var diagnosticText: String {
        get async {
            let header = diagnosticHeader
            guard let photo else { return header + "\nEquivalent CLI command: no photo open" }
            let options = effectiveOptions()
            do {
                let frame = try makeExportFrame()
                let argv = try await services.commandLine(photo, options: options, frame: frame)
                return header + "\n" + DiagnosticCommand.text(argv)
            } catch {
                return header + "\nEquivalent CLI command: unavailable (" + UserFacingError.service(error).code + ")"
            }
        }
    }
    private var diagnosticHeader: String {
        preferences.diagnostics + rawDiagnostics + "\nDisplay: " + display.screenName
            + "\nHeadroom: \(display.currentHeadroom) / \(display.potentialHeadroom)"
            + "\nInputs: " + openableContentTypes.map(\.identifier).joined(separator: ", ")
    }
}
