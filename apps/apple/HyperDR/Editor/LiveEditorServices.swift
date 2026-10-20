import CoreGraphics
import AppKit
import Foundation
import HyperDREngine
import HyperDRKit
import HyperDRRender
import ImageIO
import UniformTypeIdentifiers
import os

/// The editor's service boundary backed by the native Kit.
@MainActor final class LiveEditorServices: EditorServices {
    /// What the app does with the composition root's cleanup lifecycle;
    /// injectable so tests can observe it.
    struct Lifecycle {
        var start: @MainActor (HyperDRKit) async -> Void = { await $0.start() }
        var stop: @MainActor (HyperDRKit) -> Void = { $0.stop() }
    }

    private(set) var engineStatus: EngineStatus = .starting
    private(set) var displayState = DisplayState(screenName: "", currentHeadroom: 1,
                                                 potentialHeadroom: 1, gainWeight: nil)
    let preferences: UserDefaults
    /// HyperDRRender, created on first use; a Mac without Metal gets a
    /// renderer that refuses every photo.
    private(set) lazy var rendering: any EditorRendering = {
        do { return try RenderSession() }
        catch { return UnavailableEditorRendering(reason: String(describing: error)) }
    }()

    private struct Record {
        var session: PhotoSession
        /// The file as it was when the photo was opened: what an export renders from.
        var revision: RecipeSourceRevision?
        // The task is also the cached result, including an empty result. Store
        // it before the first suspension so concurrent callers share one read.
        var captureFacts: Task<CaptureFacts, Never>?
    }

    private let readCaptureFacts: @Sendable (URL) -> CaptureFacts
    private let formats: InputFormats
    private let openableTypes: [UTType]
    private let lifecycle: Lifecycle
    private let kitTask: Task<HyperDRKit, Error>
    private(set) var kit: HyperDRKit?
    private var records: [UUID: Record] = [:]
    /// Kit's recipe export service, made with the first export.
    private let makeRecipeExport: @Sendable (HyperDRKit) throws -> any RecipeExportServicing
    private var recipeExport: (any RecipeExportServicing)?
    /// Exports in progress, by job id, with the events the editor reads.
    private var exportJobs: [String: (task: Task<Void, Never>, events: AsyncStream<EditorExportEvent>)] = [:]
    private var engineObservers: [UUID: AsyncStream<EngineStatus>.Continuation] = [:]
    private var displayObservers: [UUID: AsyncStream<DisplayState>.Continuation] = [:]
    private var started = false
    private var stopped = false
    private var terminationObserver: (any NSObjectProtocol)?

    init(configuration: KitConfiguration = KitConfiguration(), preferences: UserDefaults = .standard, lifecycle: Lifecycle = Lifecycle(),
         readCaptureFacts: @escaping @Sendable (URL) -> CaptureFacts = { CaptureFacts.read($0) },
         makeKit: @escaping @Sendable (KitConfiguration) async throws -> HyperDRKit = {
             try await HyperDRKit(configuration: $0)
         },
         makeRecipeExport: @escaping @Sendable (HyperDRKit) throws -> any RecipeExportServicing = { kit in
             // Export has its own RenderEngine, so its caches go with it.
             let render = try RenderEngine()
             return RecipeExportService(engine: kit.engine, renderEngine: render, renderer: render,
                                        sessions: kit.sessions, target: kit.exportTarget)
         }) {
        self.makeRecipeExport = makeRecipeExport
        // Kit's input table is available before the engine starts.
        let formats = InputFormats()
        self.readCaptureFacts = readCaptureFacts
        self.formats = formats
        openableTypes = formats.contentTypes
        self.lifecycle = lifecycle
        self.preferences = preferences
        kitTask = Task.detached { try await makeKit(configuration) }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        Task { [weak self] in await self?.finishStarting() }
    }

    isolated deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: - Engine and lifecycle

    private func finishStarting() async {
        do {
            let kit = try await kitTask.value
            guard !stopped else { kit.stop(); return }
            self.kit = kit
            setEngine(.ready(version: Engine.version))
        } catch {
            setEngine(.failed(UserFacingError(code: "engine_unavailable",
                                              detail: String(describing: error))))
        }
    }

    private func setEngine(_ status: EngineStatus) {
        engineStatus = status
        for observer in engineObservers.values { observer.yield(status) }
    }

    /// The current status, then every change.
    func engineUpdates() -> AsyncStream<EngineStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(engineStatus)
            engineObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.engineObservers.removeValue(forKey: id) }
            }
        }
    }

    private func requireKit() async throws -> HyperDRKit {
        if let kit { return kit }
        do { return try await kitTask.value }
        catch {
            throw UserFacingError(code: "engine_unavailable", detail: String(describing: error))
        }
    }

    /// The editor scene started: begin the startup and hourly cleanup once.
    /// Repeated calls (a reopened window) do nothing.
    func start() async {
        guard !started else { return }
        started = true
        guard let kit = try? await requireKit(), !stopped else { return }
        await lifecycle.start(kit)
    }

    /// The app is terminating. Safe to call more than once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if let kit { lifecycle.stop(kit) }
    }

    // MARK: - Formats

    var openableContentTypes: [UTType] { openableTypes }

    func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return openableTypes.contains(type)
    }

    func placeholder(for url: URL) -> EditorPhoto {
        EditorPhoto(url: url, name: url.lastPathComponent,
                    formatLabel: Self.formatLabel(for: url), byteCount: 0)
    }

    /// The label shown while a file opens, from its type alone (no I/O); the
    /// session's classified format replaces it once open.
    static func formatLabel(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "" }
        if type.conforms(to: .rawImage) { return "RAW" }
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .png) { return "PNG" }
        if type.conforms(to: .tiff) { return "TIFF" }
        if let avif = UTType("public.avif"), type.conforms(to: avif) { return "AVIF" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "HEIC" }
        return ""
    }

    // MARK: - Sessions

    func open(_ url: URL) async throws -> EditorPhoto {
        let kit = try await requireKit()
        let session: PhotoSession
        do { session = try await kit.sessions.open(url) }
        catch { throw UserFacingError.service(error) }
        return try await adopt(session, kit: kit)
    }

    /// The photo remembered from the last launch, attached and ready for the
    /// same reference + edit flow as a fresh open.
    func restoreLast() async -> RestoreResult {
        guard let kit = try? await requireKit() else { return .none }
        switch await kit.sessions.restoreLastOutcome() {
        case .none: return .none
        case .unavailable(let error, let name): return .unavailable(UserFacingError(error), name: name)
        case .restored(let session):
            do { return .restored(try await adopt(session, kit: kit)) }
            catch { return .unavailable(UserFacingError.service(error), name: session.displayName) }
        }
    }

    private func adopt(_ session: PhotoSession, kit: HyperDRKit) async throws -> EditorPhoto {
        let photo = EditorPhoto(url: session.sourceURL, name: session.displayName,
                                formatLabel: session.format.displayLabel, byteCount: session.byteCount)
        records[photo.handle] = Record(session: session, revision: try? RecipeSourceRevision(session: session))
        do {
            try Task.checkCancellation()
            return photo
        } catch {
            await close(photo)
            throw UserFacingError.service(error)
        }
    }

    func close(_ photo: EditorPhoto) async {
        guard let record = records.removeValue(forKey: photo.handle) else { return }
        record.captureFacts?.cancel()
        let kit = try? await requireKit()
        guard let kit, !records.values.contains(where: { $0.session.id == record.session.id }) else { return }
        await kit.sessions.close(record.session.id)
    }

    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts {
        guard let record = records[photo.handle] else { return CaptureFacts() }
        if let cached = record.captureFacts { return await cached.value }
        let url = record.session.sourceURL
        let read = readCaptureFacts
        let task = Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return read(url)
        }
        records[photo.handle]?.captureFacts = task
        return await task.value
    }

    // MARK: - Display

    func displayUpdates() -> AsyncStream<DisplayState> {
        // The canvas reports headroom to the model directly; nothing else
        // changes the display state yet (A3 tracks it per frame).
        let id = UUID()
        return AsyncStream { continuation in
            displayObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.displayObservers.removeValue(forKey: id) }
            }
        }
    }
}


extension LiveEditorServices {
    private func exportSession(_ photo: EditorPhoto) throws -> SessionID {
        guard let record = records[photo.handle] else { throw UserFacingError(code: "session_expired") }
        return record.session.id
    }
    func startExport(_ photo: EditorPhoto, job: RecipeExportJob, destination: URL?) async throws -> EditorExportTicket {
        let id = try exportSession(photo)
        guard exportJobs.isEmpty else { throw UserFacingError(code: "convert_in_progress") }
        let kit = try await requireKit()
        if recipeExport == nil { recipeExport = try makeRecipeExport(kit) }
        guard let service = recipeExport else { throw UserFacingError(code: "engine_unavailable") }
        // The service exports a look from the photo's own copy of its LUT
        // (history outlives the library); the library's copy goes in first.
        if let hash = job.snapshot.lutContentHash, (try? await kit.sessions.recipeLUT(hash, for: id)) == nil,
           let lut = try? LUTID(rawValue: hash.hasPrefix("sha256:") ? String(hash.dropFirst(7)) : hash) {
            _ = try? await kit.luts.apply(lut, to: id)
        }
        try Task.checkCancellation()
        guard exportJobs.isEmpty else { throw UserFacingError(code: "convert_in_progress") }
        let jobID = UUID().uuidString
        let (events, sink) = AsyncStream.makeStream(of: EditorExportEvent.self)
        let task = Task { [weak self] in
            do {
                let result = try await service.export(session: id, snapshot: job.snapshot, request: job.request,
                                                      lut: job.lut, destination: destination) { progress in
                    if let event = Self.event(progress) { sink.yield(event) }
                }
                sink.yield(.finished(result: Self.exportResult(result), failure: result.deliveryError.map(UserFacingError.init)))
            } catch {
                sink.yield(.finished(result: nil, failure: UserFacingError.service(error)))
            }
            sink.finish()
            self?.exportJobs[jobID] = nil
        }
        exportJobs[jobID] = (task, events)
        return EditorExportTicket(job: jobID)
    }
    func sourceRevision(_ photo: EditorPhoto) async throws -> RecipeSourceRevision {
        guard let revision = records[photo.handle]?.revision else { throw UserFacingError(code: "session_expired") }
        return revision
    }

    /// Kit's stages as the progress view shows them, in Kit's words (the row
    /// path's encoding says it renders too); rendering carries the rows done.
    /// Preparing is the panel's own phase.
    nonisolated private static func event(_ progress: RecipeExportProgress) -> EditorExportEvent? {
        switch progress.stage {
        case .preparing: nil
        case .model, .developing, .encoding, .verifying:
            .progress(stage: progress.stage.rawValue, fraction: 0, at: Date(), message: progress.stageMessage)
        case .rendering:
            .progress(stage: progress.stage.rawValue, fraction: progress.totalRows.map { total in
                total > 0 ? Double(progress.completedRows ?? 0) / Double(total) : 0 } ?? 0, at: Date(),
                message: progress.stageMessage)
        case .publishing: .finishing
        case .delivering: .saving
        }
    }

    /// The editor's result card from Kit's verified version.
    nonisolated private static func exportResult(_ result: RecipeExportResult) -> ExportResult {
        var value = ExportHistoryItem(result.record).version.result
        value.pixelSize = PixelSize(width: result.resolved.width, height: result.resolved.height)
        value.headroomStops = result.resolved.ceilingStops
        value.selfVerified = true // the service throws when a reader disagrees
        value.saved = result.saved.map(savedLocation)
        return value
    }
    func exportThumbnail(_ photo: EditorPhoto, version: String) async -> CGImage? {
        guard let id = try? exportSession(photo), let kit = try? await requireKit(),
              let data = await kit.sessions.exportThumbnail(id, export: ExportID(rawValue: version)) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
    }
    func exportEvents(_ job: String) -> AsyncStream<EditorExportEvent> {
        exportJobs[job]?.events ?? AsyncStream { $0.finish() }
    }
    /// Cancelling an export's task cancels the whole operation (Kit's contract).
    func cancelAllExports() async {
        let tasks = exportJobs.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
    func hasExportActivity() async -> Bool { !exportJobs.isEmpty }
    func exports(for photo: EditorPhoto) async throws -> [ExportHistoryItem] {
        let id = try exportSession(photo), kit = try await requireKit()
        // exports(for:) returns [] for an expired session; check it first.
        _ = try await kit.sessions.session(id)
        let records = await kit.sessions.exports(for: id)
        return await Task.detached { records.map(ExportHistoryItem.init) }.value
    }
    func exportTimingHistory() async -> [ExportTimingSample] {
        guard let kit = try? await requireKit() else { return [] }
        let records = await kit.sessions.recentExports()
        return await Task.detached { records.compactMap { ExportHistoryItem($0).timing } }.value
    }
    func suggestedFileName(_ photo: EditorPhoto, encoding: String) async throws -> String {
        guard let record = records[photo.handle] else { throw UserFacingError(code: "session_expired") }
        return record.session.sourceURL.deletingPathExtension().lastPathComponent + "-hyperdr."
            + EditorModel.fileExtension(encoding)
    }
    func validateDestination(_ url: URL, expectedExtension: String) async throws {
        try await requireKit().exportTarget.validateDestination(url, expectedExtension: expectedExtension)
    }
    nonisolated private static func savedLocation(_ saved: SavedExport) -> SavedLocation {
        SavedLocation(fileName: saved.name, folderLabel: SavedLocation.label(displayName: saved.folderDisplayName), reveal: { saved.reveal() })
    }

    func saveExport(_ photo: EditorPhoto, export: String, destination: URL?) async throws -> SavedLocation {
        let id = try exportSession(photo), kit = try await requireKit(), version = ExportID(rawValue: export)
        let saved: SavedExport
        if let destination { saved = try await kit.exportTarget.save(session: id, export: version, to: destination) }
        else { saved = try await kit.exportTarget.save(session: id, export: version) }
        do { try await kit.sessions.markSaved(id, export: version, saved: SavedMark(fileName: saved.name, folderDisplayName: saved.folderDisplayName)) }
        catch { Logger(subsystem: "com.hyperdr.HyperDR", category: "Export").warning("Export saved but its history mark could not be persisted") }
        return Self.savedLocation(saved)
    }
    func relink(_ photo: EditorPhoto, to url: URL) async throws -> EditorPhoto {
        guard let kit, let record = records[photo.handle] else { throw UserFacingError(code: "source_missing") }
        do {
            let session = try await kit.sessions.relink(record.session.id, to: url)
            try Task.checkCancellation()
            guard records[photo.handle] != nil else { throw CancellationError() }
            records[photo.handle]?.session = session
            return EditorPhoto(url: session.sourceURL, name: session.displayName, formatLabel: photo.formatLabel,
                               byteCount: session.byteCount, handle: photo.handle)
        } catch { throw UserFacingError.service(error) }
    }
    func transferFile(_ photo: EditorPhoto, export: String, fileName: String?) async throws -> URL {
        let id = try exportSession(photo), kit = try await requireKit()
        do { return try await kit.sessions.stageExportForTransfer(id, export: ExportID(rawValue: export), fileName: fileName) }
        catch { throw UserFacingError.service(error) }
    }
    func exportFolder() async -> ExportFolder {
        guard let kit = try? await requireKit() else { return ExportFolder() }
        let folder = await kit.exportTarget.folder
        guard folder.ready else { return ExportFolder(label: folder.label, ready: false) }
        do {
            let snapshot = try await kit.exportTarget.captureFolder()
            let target = ExportFolderTarget(reveal: { try await kit.exportTarget.reveal(folder: snapshot) }) { [weak self, kit, snapshot] photo, export in
                guard let self else { throw UserFacingError(code: "engine_unavailable") }
                let id = try exportSession(photo), version = ExportID(rawValue: export)
                let saved = try await kit.exportTarget.save(session: id, export: version, folder: snapshot)
                do { try await kit.sessions.markSaved(id, export: version, saved: SavedMark(fileName: saved.name, folderDisplayName: saved.folderDisplayName)) }
                catch { Logger(subsystem: "com.hyperdr.HyperDR", category: "Export").warning("Export saved but its history mark could not be persisted") }
                return Self.savedLocation(saved)
            }
            return ExportFolder(label: snapshot.label, ready: true, target: target)
        } catch { return ExportFolder(label: folder.label, ready: false) }
    }
    func setExportFolder(_ url: URL) async throws -> ExportFolder {
        let kit = try await requireKit()
        _ = try await kit.exportTarget.setFolder(url)
        return await exportFolder()
    }
    func encodingCapabilities() async throws -> EditorCapabilities {
        let c = try await requireKit().capabilities
        return EditorCapabilities(encodings: Dictionary(uniqueKeysWithValues: c.encodings.map { ($0.id, .init(available: $0.available, reason: $0.reason)) }),
            main8: c.encoder?.main8 ?? false, main10: c.encoder?.main10 ?? false, encoderReason: c.encoder?.reason)
    }
    func aboutInformation() async -> AboutInformation {
        let capabilities = try? await requireKit().capabilities
        return AboutInformation(bundle: .main, engineABI: Engine.abiVersion,
                                memoryBudgetBytes: capabilities?.effectiveMemoryBudgetBytes)
    }
    func diagnostics() async -> String {
        guard let kit = try? await requireKit() else { return "" }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // The RAW OS build comes exclusively from engine preview metadata.
        return String(decoding: kit.capabilities.rawJSON, as: UTF8.self)
            + "\nmacOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    private func item(_ entry: LUTEntry) -> LUTItem {
        LUTItem(id: entry.id.rawValue, name: entry.name,
            input: LUTColorSpace(rawValue: entry.input.rawValue) ?? .srgb,
            output: LUTColorSpace(rawValue: entry.output.rawValue) ?? .srgb, byteCount: entry.byteCount)
    }
    func lutEntries() async -> [LUTItem] {
        guard let kit = try? await requireKit() else { return [] }
        return await kit.luts.entries().map(item)
    }
    func lutCube(_ id: String) async throws -> String {
        do { return try await requireKit().luts.cube(LUTID(rawValue: id)) }
        catch { throw UserFacingError.service(error) }
    }
    func importLUT(_ url: URL) async throws -> LUTItem { item(try await requireKit().luts.importLUT(url)) }
    func applyLUT(_ id: String, to photo: EditorPhoto) async throws -> LUTItem {
        let session = try exportSession(photo)
        return item(try await requireKit().luts.apply(LUTID(rawValue: id), to: session))
    }
    func updateLUT(_ id: String, input: LUTColorSpace, output: LUTColorSpace) async throws -> LUTItem {
        item(try await requireKit().luts.update(LUTID(rawValue: id), input: LUTSpace(rawValue: input.rawValue)!, output: LUTSpace(rawValue: output.rawValue)!))
    }
    func removeLUT(_ id: String) async throws { try await requireKit().luts.remove(LUTID(rawValue: id)) }
    func recipeLUT(_ photo: EditorPhoto, contentHash: String) async throws -> ColorLUT {
        let session = try exportSession(photo)
        do { return try await requireKit().sessions.recipeLUT(contentHash, for: session) }
        catch { throw UserFacingError.service(error) }
    }
}
